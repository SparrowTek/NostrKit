import Foundation
import CoreNostr

/// High-level encryption manager that provides various encryption schemes for NOSTR.
///
/// EncryptionManager supports multiple encryption methods including:
/// - NIP-04 (deprecated but still supported for compatibility)
/// - NIP-44 (modern encryption standard)
/// - NIP-59 (gift wrap for anonymous events)
/// - Group encryption
/// - Forward secrecy options
///
/// ## Example
/// ```swift
/// let encryption = EncryptionManager(keyStore: keyStore)
/// 
/// // Send an encrypted message
/// let encrypted = try await encryption.encrypt(
///     message: "Secret message",
///     to: recipientPubkey,
///     from: "main",
///     method: .nip44
/// )
/// 
/// // Create a gift-wrapped event
/// let giftWrapped = try await encryption.giftWrap(
///     event: event,
///     to: recipientPubkey,
///     from: "anon"
/// )
/// ```
public actor EncryptionManager {
    
    // MARK: - Types
    
    /// Encryption methods available
    public enum EncryptionMethod: String, CaseIterable, Sendable {
        case nip04 = "NIP-04"
        case nip44 = "NIP-44"
        case custom = "Custom"
        
        public var eventKind: Int {
            switch self {
            case .nip04:
                return 4 // Encrypted direct message
            case .nip44:
                return 13 // Kind 13 for NIP-44 sealed messages
            case .custom:
                return 30078 // Custom encrypted content
            }
        }
        
        public var isDeprecated: Bool {
            self == .nip04
        }
    }
    
    /// Encryption session for forward secrecy
    public struct EncryptionSession: Sendable {
        public let id: String
        public let localIdentity: String
        public let remotePublicKey: PublicKey
        public var ephemeralKeys: [EphemeralKey]
        public let createdAt: Date
        public let expiresAt: Date
        
        public struct EphemeralKey: Codable, Sendable {
            fileprivate let keyPair: StoredKeyPair
            public let index: Int
            public let usedAt: Date?
        }
    }
    
    /// Group encryption key
    public struct GroupKey: Codable, Sendable {
        public let groupId: String
        public let key: Data
        public let createdAt: Date
        public let members: [PublicKey]
        public let version: Int
    }
    
    /// Encrypted content with metadata
    public struct EncryptedContent: Sendable {
        public let content: String
        public let method: EncryptionMethod
        public let ephemeralKey: PublicKey?
        public let sessionId: String?
    }
    
    /// Gift wrap result
    public struct GiftWrap: Sendable {
        public let sealEvent: NostrEvent
        public let giftWrapEvent: NostrEvent
        public let ephemeralKey: KeyPair
    }
    
    // MARK: - Properties
    
    private let keyStore: SecureKeyStore
    private var sessions: [String: EncryptionSession] = [:]
    private var groupKeys: [String: GroupKey] = [:]
    private let sessionDuration: TimeInterval = 3600 // 1 hour
    
    // MARK: - Initialization
    
    public init(keyStore: SecureKeyStore) {
        self.keyStore = keyStore
    }
    
    // MARK: - Direct Encryption
    
    /// Encrypts a message to a recipient
    /// - Parameters:
    ///   - message: The message to encrypt
    ///   - recipientPublicKey: The recipient's public key
    ///   - senderIdentity: The sender's identity in the keystore
    ///   - method: Encryption method to use
    /// - Returns: Encrypted content
    public func encrypt(
        message: String,
        to recipientPublicKey: PublicKey,
        from senderIdentity: String,
        method: EncryptionMethod = .nip44
    ) async throws -> EncryptedContent {
        let senderKeyPair = try await keyStore.retrieve(identity: senderIdentity)
        
        let encryptedMessage: String
        
        switch method {
        case .nip04:
            encryptedMessage = try senderKeyPair.encrypt(
                message: message,
                to: recipientPublicKey
            )
            
        case .nip44:
            encryptedMessage = try NIP44.encrypt(
                plaintext: message,
                senderPrivateKey: senderKeyPair.privateKey,
                recipientPublicKey: recipientPublicKey
            )
            
        case .custom:
            // Custom encryption could use a different scheme
            encryptedMessage = try await customEncrypt(
                message: message,
                to: recipientPublicKey,
                from: senderKeyPair
            )
        }
        
        return EncryptedContent(
            content: encryptedMessage,
            method: method,
            ephemeralKey: nil,
            sessionId: nil
        )
    }
    
    /// Decrypts a message from a sender
    /// - Parameters:
    ///   - content: The encrypted content
    ///   - senderPublicKey: The sender's public key
    ///   - recipientIdentity: The recipient's identity in the keystore
    /// - Returns: Decrypted message
    public func decrypt(
        content: EncryptedContent,
        from senderPublicKey: PublicKey,
        to recipientIdentity: String
    ) async throws -> String {
        let recipientKeyPair = try await keyStore.retrieve(identity: recipientIdentity)
        
        switch content.method {
        case .nip04:
            return try recipientKeyPair.decrypt(
                message: content.content,
                from: senderPublicKey
            )
            
        case .nip44:
            return try NIP44.decrypt(
                payload: content.content,
                recipientPrivateKey: recipientKeyPair.privateKey,
                senderPublicKey: senderPublicKey
            )
            
        case .custom:
            return try await customDecrypt(
                content: content.content,
                from: senderPublicKey,
                to: recipientKeyPair
            )
        }
    }
    
    // MARK: - Forward Secrecy
    
    /// Creates an encryption session with forward secrecy
    /// - Parameters:
    ///   - remotePublicKey: The remote party's public key
    ///   - localIdentity: Local identity to use
    ///   - ephemeralKeyCount: Number of ephemeral keys to pre-generate
    /// - Returns: Session ID
    @discardableResult
    public func createSession(
        with remotePublicKey: PublicKey,
        using localIdentity: String,
        ephemeralKeyCount: Int = 10
    ) async throws -> String {
        let sessionId = UUID().uuidString
        
        // Generate ephemeral keys
        var ephemeralKeys: [EncryptionSession.EphemeralKey] = []
        for i in 0..<ephemeralKeyCount {
            let keyPair = try KeyPair.generate()
            let storedKeyPair = StoredKeyPair(
                privateKey: keyPair.privateKey,
                publicKey: keyPair.publicKey
            )
            ephemeralKeys.append(
                EncryptionSession.EphemeralKey(
                    keyPair: storedKeyPair,
                    index: i,
                    usedAt: nil
                )
            )
        }
        
        let session = EncryptionSession(
            id: sessionId,
            localIdentity: localIdentity,
            remotePublicKey: remotePublicKey,
            ephemeralKeys: ephemeralKeys,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(sessionDuration)
        )
        
        sessions[sessionId] = session
        
        // Clean up expired sessions
        await cleanupExpiredSessions()
        
        return sessionId
    }
    
    /// Encrypts a message using a forward secrecy session
    /// - Parameters:
    ///   - message: The message to encrypt
    ///   - sessionId: The session ID
    /// - Returns: Encrypted content with ephemeral key
    public func encryptWithSession(
        message: String,
        sessionId: String
    ) async throws -> EncryptedContent {
        guard var session = sessions[sessionId] else {
            throw NostrError.notFound(resource: "Encryption session \(sessionId)")
        }
        
        // Check if session is expired
        if session.expiresAt < Date() {
            sessions.removeValue(forKey: sessionId)
            throw NostrError.validationError(
                field: "session",
                reason: "Session has expired"
            )
        }
        
        // Find next unused ephemeral key
        guard let ephemeralKeyIndex = session.ephemeralKeys.firstIndex(where: { $0.usedAt == nil }) else {
            throw NostrError.validationError(
                field: "ephemeralKeys",
                reason: "No unused ephemeral keys available"
            )
        }
        
        var ephemeralKey = session.ephemeralKeys[ephemeralKeyIndex]
        let keyPair = try KeyPair(
            privateKey: ephemeralKey.keyPair.privateKey
        )
        
        // Encrypt with ephemeral key
        let encrypted = try NIP44.encrypt(
            plaintext: message,
            senderPrivateKey: keyPair.privateKey,
            recipientPublicKey: session.remotePublicKey
        )
        
        // Mark key as used
        ephemeralKey = EncryptionSession.EphemeralKey(
            keyPair: ephemeralKey.keyPair,
            index: ephemeralKey.index,
            usedAt: Date()
        )
        session.ephemeralKeys[ephemeralKeyIndex] = ephemeralKey
        sessions[sessionId] = session
        
        return EncryptedContent(
            content: encrypted,
            method: .nip44,
            ephemeralKey: keyPair.publicKey,
            sessionId: sessionId
        )
    }
    
    // MARK: - Gift Wrap (NIP-59)
    
    /// Creates a gift-wrapped event for anonymous communication
    /// - Parameters:
    ///   - event: The event to wrap
    ///   - recipientPublicKey: The recipient's public key
    ///   - senderIdentity: Optional sender identity (nil for anonymous)
    /// - Returns: Gift wrap containing seal and gift wrap events
    public func giftWrap(
        event: NostrEvent,
        to recipientPublicKey: PublicKey,
        from senderIdentity: String? = nil
    ) async throws -> GiftWrap {
        // Create ephemeral key for the gift wrap
        let ephemeralKey = try KeyPair.generate()
        
        // Get sender key (or use ephemeral for anonymous)
        let senderKey: KeyPair
        if let identity = senderIdentity {
            senderKey = try await keyStore.retrieve(identity: identity)
        } else {
            senderKey = ephemeralKey
        }
        
        // Serialize the inner event
        _ = try event.jsonString()
        
        // Create rumor (unsigned event)
        let rumor = Rumor(
            pubkey: senderKey.publicKey,
            createdAt: Date(),
            kind: event.kind,
            tags: event.tags,
            content: event.content
        )
        
        // Create seal event (kind 13)
        let sealContent = try NIP44.encrypt(
            plaintext: try JSONEncoder().encode(rumor).base64EncodedString(),
            senderPrivateKey: senderKey.privateKey,
            recipientPublicKey: recipientPublicKey
        )
        
        var sealEvent = NostrEvent(
            pubkey: senderKey.publicKey,
            createdAt: Date().addingTimeInterval(-Double.random(in: 0...172800)), // Random time up to 2 days ago
            kind: 13, // Seal event kind
            tags: [],
            content: sealContent
        )
        
        sealEvent = try senderKey.signEvent(sealEvent)
        
        // Create gift wrap event (kind 1059)
        let giftWrapContent = try NIP44.encrypt(
            plaintext: try sealEvent.jsonString(),
            senderPrivateKey: ephemeralKey.privateKey,
            recipientPublicKey: recipientPublicKey
        )
        
        var giftWrapEvent = NostrEvent(
            pubkey: ephemeralKey.publicKey,
            createdAt: Date().addingTimeInterval(-Double.random(in: 0...172800)), // Random time up to 2 days ago
            kind: 1059, // Gift wrap kind
            tags: [["p", recipientPublicKey]],
            content: giftWrapContent
        )
        
        giftWrapEvent = try ephemeralKey.signEvent(giftWrapEvent)
        
        return GiftWrap(
            sealEvent: sealEvent,
            giftWrapEvent: giftWrapEvent,
            ephemeralKey: ephemeralKey
        )
    }
    
    /// Unwraps a gift-wrapped event
    /// - Parameters:
    ///   - giftWrapEvent: The gift wrap event (kind 1059)
    ///   - recipientIdentity: The recipient's identity
    /// - Returns: The unwrapped original event
    public func unwrapGift(
        _ giftWrapEvent: NostrEvent,
        using recipientIdentity: String
    ) async throws -> NostrEvent {
        guard giftWrapEvent.kind == 1059 else {
            throw NostrError.validationError(
                field: "kind",
                reason: "Not a gift wrap event"
            )
        }
        
        let recipientKey = try await keyStore.retrieve(identity: recipientIdentity)
        
        // Decrypt gift wrap to get seal event
        let sealEventJson = try NIP44.decrypt(
            payload: giftWrapEvent.content,
            recipientPrivateKey: recipientKey.privateKey,
            senderPublicKey: giftWrapEvent.pubkey
        )
        
        let sealEvent = try JSONDecoder().decode(NostrEvent.self, from: Data(sealEventJson.utf8))
        
        // Decrypt seal to get rumor
        let rumorData = try NIP44.decrypt(
            payload: sealEvent.content,
            recipientPrivateKey: recipientKey.privateKey,
            senderPublicKey: sealEvent.pubkey
        )
        
        guard let rumorBase64 = Data(base64Encoded: rumorData) else {
            throw NostrError.serializationError(type: "Rumor", reason: "Invalid base64")
        }
        
        let rumor = try JSONDecoder().decode(Rumor.self, from: rumorBase64)
        
        // Convert rumor to event
        let event = try NostrEvent(
            id: try rumor.calculateId(),
            pubkey: rumor.pubkey,
            createdAt: Int64(rumor.createdAt.timeIntervalSince1970),
            kind: rumor.kind,
            tags: rumor.tags,
            content: rumor.content,
            sig: String(repeating: "0", count: 128) // Dummy signature
        )
        
        return event
    }
    
    // MARK: - Group Encryption
    
    /// Creates a group encryption key
    /// - Parameters:
    ///   - groupId: Unique group identifier
    ///   - members: Public keys of group members
    /// - Returns: The group ID
    @discardableResult
    public func createGroup(
        id groupId: String,
        members: [PublicKey]
    ) async throws -> String {
        // Generate group key
        let groupKey = try NostrCrypto.randomBytes(count: 32)
        
        let group = GroupKey(
            groupId: groupId,
            key: groupKey,
            createdAt: Date(),
            members: members,
            version: 1
        )
        
        groupKeys[groupId] = group
        
        // Distribute key to members (would need to be sent via encrypted DMs)
        // This is a simplified version - in practice you'd need key agreement
        
        return groupId
    }
    
    /// Encrypts a message for a group
    /// - Parameters:
    ///   - message: The message to encrypt
    ///   - groupId: The group ID
    /// - Returns: Encrypted content
    public func encryptForGroup(
        message: String,
        groupId: String
    ) async throws -> String {
        guard let group = groupKeys[groupId] else {
            throw NostrError.notFound(resource: "Group \(groupId)")
        }
        
        // Use AES-GCM for group encryption
        let nonce = try NostrCrypto.randomBytes(count: 12)
        let encrypted = try NostrCrypto.aesGCMEncrypt(
            plaintext: Data(message.utf8),
            key: group.key,
            nonce: nonce
        )
        
        // Combine nonce and ciphertext
        let combined = nonce + encrypted
        return combined.base64EncodedString()
    }
    
    /// Decrypts a group message
    /// - Parameters:
    ///   - encryptedMessage: The encrypted message
    ///   - groupId: The group ID
    /// - Returns: Decrypted message
    public func decryptFromGroup(
        encryptedMessage: String,
        groupId: String
    ) async throws -> String {
        guard let group = groupKeys[groupId] else {
            throw NostrError.notFound(resource: "Group \(groupId)")
        }
        
        guard let combined = Data(base64Encoded: encryptedMessage) else {
            throw NostrError.serializationError(
                type: "GroupMessage",
                reason: "Invalid base64"
            )
        }
        
        guard combined.count > 12 else {
            throw NostrError.validationError(
                field: "encryptedMessage",
                reason: "Message too short"
            )
        }
        
        let nonce = combined.prefix(12)
        let ciphertext = combined.dropFirst(12)
        
        let decrypted = try NostrCrypto.aesGCMDecrypt(
            ciphertext: ciphertext,
            key: group.key,
            nonce: nonce
        )
        
        guard let message = String(data: decrypted, encoding: .utf8) else {
            throw NostrError.serializationError(
                type: "GroupMessage",
                reason: "Invalid UTF-8"
            )
        }
        
        return message
    }
    
    // MARK: - Key Rotation
    
    /// Rotates encryption keys for a group
    /// - Parameter groupId: The group ID
    /// - Returns: New version number
    @discardableResult
    public func rotateGroupKey(groupId: String) async throws -> Int {
        guard let group = groupKeys[groupId] else {
            throw NostrError.notFound(resource: "Group \(groupId)")
        }
        
        // Generate new key
        let newKey = try NostrCrypto.randomBytes(count: 32)
        
        // Create new version
        let newGroup = GroupKey(
            groupId: group.groupId,
            key: newKey,
            createdAt: Date(),
            members: group.members,
            version: group.version + 1
        )
        
        groupKeys[groupId] = newGroup
        
        // In practice, you'd need to distribute the new key to members
        
        return newGroup.version
    }
    
    // MARK: - Privacy Features
    
    /// Creates an ephemeral event that expires
    /// - Parameters:
    ///   - content: Event content
    ///   - kind: Event kind
    ///   - expiresIn: Time until expiration in seconds
    ///   - identity: Identity to use for signing
    /// - Returns: Ephemeral event with expiration
    public func createEphemeralEvent(
        content: String,
        kind: EventKind,
        expiresIn: TimeInterval,
        using identity: String
    ) async throws -> NostrEvent {
        let keyPair = try await keyStore.retrieve(identity: identity)
        
        let expirationTime = Date().addingTimeInterval(expiresIn)
        
        var event = NostrEvent(
            pubkey: keyPair.publicKey,
            createdAt: Date(),
            kind: kind.rawValue,
            tags: [
                ["expiration", String(Int(expirationTime.timeIntervalSince1970))]
            ],
            content: content
        )
        
        event = try keyPair.signEvent(event)
        
        return event
    }
    
    /// Suggests privacy-preserving relays for a message
    /// - Parameters:
    ///   - event: The event to send
    ///   - recipientPublicKey: The recipient's public key
    /// - Returns: Suggested relay URLs
    public func suggestPrivacyRelays(
        for event: NostrEvent,
        to recipientPublicKey: PublicKey
    ) async -> [String] {
        // This is a simplified version
        // In practice, you'd want to:
        // 1. Check recipient's relay list
        // 2. Find common relays
        // 3. Prefer onion/privacy-focused relays
        // 4. Avoid relays that require authentication
        
        let privacyRelays = [
            "wss://relay.snort.social",
            "wss://nostr.wine",
            "wss://relay.damus.io"
        ]
        
        // For gift-wrapped events, use different relays
        if event.kind == 1059 {
            return [
                "wss://relay.nostr.band",
                "wss://nos.lol"
            ]
        }
        
        return privacyRelays
    }
    
    // MARK: - Private Methods
    
    private func customEncrypt(
        message: String,
        to recipientPublicKey: PublicKey,
        from senderKeyPair: KeyPair
    ) async throws -> String {
        // Custom encryption implementation
        // This could use a different algorithm or protocol
        // For now, we'll use NIP-44 as the base
        return try NIP44.encrypt(
            plaintext: message,
            senderPrivateKey: senderKeyPair.privateKey,
            recipientPublicKey: recipientPublicKey
        )
    }
    
    private func customDecrypt(
        content: String,
        from senderPublicKey: PublicKey,
        to recipientKeyPair: KeyPair
    ) async throws -> String {
        // Custom decryption implementation
        return try NIP44.decrypt(
            payload: content,
            recipientPrivateKey: recipientKeyPair.privateKey,
            senderPublicKey: senderPublicKey
        )
    }
    
    private func cleanupExpiredSessions() async {
        let now = Date()
        sessions = sessions.filter { _, session in
            session.expiresAt > now
        }
    }
}

// MARK: - Supporting Types

/// Stored key pair for serialization
private struct StoredKeyPair: Codable, Sendable {
    let privateKey: String
    let publicKey: String
}

/// Unsigned event (rumor) for NIP-59
private struct Rumor: Codable, Sendable {
    let pubkey: PublicKey
    let createdAt: Date
    let kind: Int
    let tags: [[String]]
    let content: String
    
    func calculateId() throws -> EventID {
        // Calculate ID same as regular event but without signature
        let serialized = [
            0,
            pubkey,
            Int(createdAt.timeIntervalSince1970),
            kind,
            tags,
            content
        ] as [Any]
        
        let jsonData = try JSONSerialization.data(
            withJSONObject: serialized,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        
        let hash = NostrCrypto.sha256(jsonData)
        return hash.hex
    }
    
    enum CodingKeys: String, CodingKey {
        case pubkey
        case createdAt = "created_at"
        case kind
        case tags
        case content
    }
}

// MARK: - NostrCrypto Extensions

extension NostrCrypto {
    /// AES-GCM encryption
    static func aesGCMEncrypt(plaintext: Data, key: Data, nonce: Data) throws -> Data {
        // Implementation would use CryptoKit's AES.GCM
        // This is a placeholder
        return try NostrCrypto.aesEncrypt(plaintext: plaintext, key: key, iv: nonce)
    }
    
    /// AES-GCM decryption
    static func aesGCMDecrypt(ciphertext: Data, key: Data, nonce: Data) throws -> Data {
        // Implementation would use CryptoKit's AES.GCM
        // This is a placeholder
        return try NostrCrypto.aesDecrypt(ciphertext: ciphertext, key: key, iv: nonce)
    }
}