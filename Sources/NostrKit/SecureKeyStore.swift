import Foundation
import CoreNostr
import Security

/// A secure storage system for NOSTR keys using the iOS Keychain.
///
/// SecureKeyStore provides secure storage and management of NOSTR keys with features like:
/// - Keychain-based secure storage using Vault
/// - Multiple identity management with derivation paths
/// - Key backup and recovery
/// - Permission-based access control
/// - Biometric authentication support
///
/// ## Example
/// ```swift
/// let keyStore = SecureKeyStore()
/// 
/// // Store a key pair
/// try await keyStore.store(keyPair, for: "main")
/// 
/// // Retrieve with biometric authentication
/// let keyPair = try await keyStore.retrieve(identity: "main", authenticationRequired: true)
/// 
/// // Derive a new identity
/// let workIdentity = try await keyStore.deriveIdentity(from: "main", path: "work")
/// ```
public actor SecureKeyStore {
    
    // MARK: - Types
    
    /// Represents a stored identity with metadata
    public struct StoredIdentity: Codable, Sendable {
        public let id: String
        public let name: String
        public let createdAt: Date
        public let lastUsedAt: Date
        public let derivationPath: String?
        public let parentIdentity: String?
        public var metadata: [String: String]
        
        public init(
            id: String,
            name: String,
            createdAt: Date = Date(),
            lastUsedAt: Date = Date(),
            derivationPath: String? = nil,
            parentIdentity: String? = nil,
            metadata: [String: String] = [:]
        ) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.lastUsedAt = lastUsedAt
            self.derivationPath = derivationPath
            self.parentIdentity = parentIdentity
            self.metadata = metadata
        }
    }
    
    /// Key access permissions
    public struct KeyPermissions: Codable, Sendable {
        public let canSign: Bool
        public let canDecrypt: Bool
        public let canDerive: Bool
        public let requiresBiometrics: Bool
        public let expiresAt: Date?
        
        public static let full = KeyPermissions(
            canSign: true,
            canDecrypt: true,
            canDerive: true,
            requiresBiometrics: false,
            expiresAt: nil
        )
        
        public static let signOnly = KeyPermissions(
            canSign: true,
            canDecrypt: false,
            canDerive: false,
            requiresBiometrics: true,
            expiresAt: nil
        )
        
        public static let readOnly = KeyPermissions(
            canSign: false,
            canDecrypt: true,
            canDerive: false,
            requiresBiometrics: false,
            expiresAt: nil
        )
        
        public init(
            canSign: Bool,
            canDecrypt: Bool,
            canDerive: Bool,
            requiresBiometrics: Bool,
            expiresAt: Date? = nil
        ) {
            self.canSign = canSign
            self.canDecrypt = canDecrypt
            self.canDerive = canDerive
            self.requiresBiometrics = requiresBiometrics
            self.expiresAt = expiresAt
        }
    }
    
    /// Key backup format
    public struct KeyBackup: Codable, Sendable {
        public let version: Int
        public let identities: [BackupIdentity]
        public let createdAt: Date
        public let checksum: String
        
        public struct BackupIdentity: Codable, Sendable {
            public let identity: StoredIdentity
            public let encryptedPrivateKey: String
            public let publicKey: String
            public let salt: String
            public let iterations: Int
        }
    }
    
    /// Errors specific to key storage
    public enum KeyStoreError: Error, LocalizedError {
        case identityNotFound(String)
        case identityAlreadyExists(String)
        case keychainError(Error)
        case authenticationFailed
        case permissionDenied(String)
        case backupCorrupted
        case invalidDerivationPath
        case biometricsNotAvailable
        
        public var errorDescription: String? {
            switch self {
            case .identityNotFound(let id):
                return "Identity '\(id)' not found in keystore"
            case .identityAlreadyExists(let id):
                return "Identity '\(id)' already exists"
            case .keychainError(let error):
                return "Keychain error: \(error.localizedDescription)"
            case .authenticationFailed:
                return "Authentication failed"
            case .permissionDenied(let action):
                return "Permission denied for action: \(action)"
            case .backupCorrupted:
                return "Backup data is corrupted or invalid"
            case .invalidDerivationPath:
                return "Invalid derivation path"
            case .biometricsNotAvailable:
                return "Biometric authentication is not available"
            }
        }
    }
    
    // MARK: - Properties
    
    private let keychain: KeychainWrapper
    private let identityPrefix = "nostrkit.identity"
    private let metadataPrefix = "nostrkit.metadata"
    private let permissionsPrefix = "nostrkit.permissions"
    
    // MARK: - Initialization
    
    /// Creates a new secure key store
    public init() {
        self.keychain = KeychainWrapper(service: "com.nostrkit.keystore")
    }
    
    // MARK: - Key Storage
    
    /// Stores a key pair for an identity
    /// - Parameters:
    ///   - keyPair: The key pair to store
    ///   - identity: The identity identifier
    ///   - name: Human-readable name for the identity
    ///   - permissions: Access permissions for this key
    ///   - metadata: Additional metadata to store
    public func store(
        _ keyPair: KeyPair,
        for identity: String,
        name: String? = nil,
        permissions: KeyPermissions = .full,
        metadata: [String: String] = [:]
    ) async throws {
        // Check if identity already exists
        let privateKeyKey = "\(identityPrefix).\(identity).private"
        if await keychain.exists(key: privateKeyKey) {
            throw KeyStoreError.identityAlreadyExists(identity)
        }
        
        // Store private key with appropriate security
        try await keychain.save(
            keyPair.privateKey,
            forKey: privateKeyKey,
            requiresBiometrics: permissions.requiresBiometrics
        )
        
        // Store public key (less sensitive, can be accessed more easily)
        let publicKeyKey = "\(identityPrefix).\(identity).public"
        try await keychain.save(
            keyPair.publicKey,
            forKey: publicKeyKey
        )
        
        // Store identity metadata
        let storedIdentity = StoredIdentity(
            id: identity,
            name: name ?? identity,
            metadata: metadata
        )
        
        let metadataKey = "\(metadataPrefix).\(identity)"
        let metadataData = try JSONEncoder().encode(storedIdentity)
        try await keychain.save(metadataData, forKey: metadataKey)
        
        // Store permissions
        let permissionsKey = "\(permissionsPrefix).\(identity)"
        let permissionsData = try JSONEncoder().encode(permissions)
        try await keychain.save(permissionsData, forKey: permissionsKey)
    }
    
    /// Retrieves a key pair for an identity
    /// - Parameters:
    ///   - identity: The identity identifier
    ///   - authenticationRequired: Whether to require authentication
    /// - Returns: The key pair if found
    public func retrieve(
        identity: String,
        authenticationRequired: Bool = false
    ) async throws -> KeyPair {
        // Check permissions
        let permissions = try await getPermissions(for: identity)
        
        if permissions.expiresAt != nil && permissions.expiresAt! < Date() {
            throw KeyStoreError.permissionDenied("Key access has expired")
        }
        
        // Retrieve private key
        let privateKeyKey = "\(identityPrefix).\(identity).private"
        let nsec: String
        
        // If biometrics are required, authenticate and load
        if permissions.requiresBiometrics || authenticationRequired {
            do {
                nsec = try await keychain.loadStringWithBiometrics(
                    key: privateKeyKey,
                    reason: "Authenticate to access your Nostr identity"
                )
            } catch {
                if let keychainError = error as? KeychainWrapper.KeychainError {
                    switch keychainError {
                    case .noData:
                        throw KeyStoreError.identityNotFound(identity)
                    default:
                        throw KeyStoreError.biometricsNotAvailable
                    }
                }
                throw KeyStoreError.identityNotFound(identity)
            }
        } else {
            do {
                nsec = try await keychain.loadString(key: privateKeyKey)
            } catch {
                throw KeyStoreError.identityNotFound(identity)
            }
        }
        
        // Update last used timestamp
        await updateLastUsed(for: identity)
        
        return try KeyPair(privateKey: nsec)
    }
    
    /// Deletes an identity from the keystore
    /// - Parameter identity: The identity to delete
    public func delete(identity: String) async throws {
        let privateKeyKey = "\(identityPrefix).\(identity).private"
        let publicKeyKey = "\(identityPrefix).\(identity).public"
        let metadataKey = "\(metadataPrefix).\(identity)"
        let permissionsKey = "\(permissionsPrefix).\(identity)"
        
        try await keychain.delete(key: privateKeyKey)
        try await keychain.delete(key: publicKeyKey)
        try await keychain.delete(key: metadataKey)
        try await keychain.delete(key: permissionsKey)
    }
    
    /// Lists all stored identities
    /// - Returns: Array of stored identities
    public func listIdentities() async throws -> [StoredIdentity] {
        var identities: [StoredIdentity] = []
        
        // Get all keys
        let allKeys = await keychain.allKeys()
        
        // Find identity metadata keys
        let metadataKeys = allKeys.filter { $0.hasPrefix(metadataPrefix) }
        
        for key in metadataKeys {
            if let data = try? await keychain.load(key: key),
               let identity = try? JSONDecoder().decode(StoredIdentity.self, from: data) {
                identities.append(identity)
            }
        }
        
        return identities.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }
    
    // MARK: - Key Derivation
    
    /// Derives a new identity from an existing one
    /// - Parameters:
    ///   - parentIdentity: The parent identity to derive from
    ///   - path: The derivation path component
    ///   - name: Name for the new identity
    /// - Returns: The identity ID of the derived key
    @discardableResult
    public func deriveIdentity(
        from parentIdentity: String,
        path: String,
        name: String? = nil
    ) async throws -> String {
        // Retrieve parent key
        let parentKey = try await retrieve(identity: parentIdentity)
        
        // Check derivation permissions
        let permissions = try await getPermissions(for: parentIdentity)
        guard permissions.canDerive else {
            throw KeyStoreError.permissionDenied("Key derivation not allowed")
        }
        
        // Generate deterministic child identity ID
        let childIdentity = "\(parentIdentity):\(path)"
        
        // Derive child key using BIP32-style derivation
        // For simplicity, we'll use HMAC-based derivation
        let pathData = Data(path.utf8)
        let privateKeyData = Data(hex: parentKey.privateKey)
        let derivedPrivateKey = try NostrCrypto.hmacSHA256(
            key: privateKeyData,
            message: pathData
        )
        
        let derivedKeyPair = try KeyPair(privateKey: derivedPrivateKey.hex)
        
        // Store derived key with metadata
        try await store(
            derivedKeyPair,
            for: childIdentity,
            name: name ?? "\(parentIdentity) - \(path)",
            permissions: permissions, // Inherit permissions
            metadata: [
                "derivation_path": path,
                "parent_identity": parentIdentity
            ]
        )
        
        // Update parent identity metadata
        if let parentMetadata = try await getIdentity(parentIdentity) {
            var updatedMetadata = parentMetadata
            updatedMetadata.metadata["derived_children"] = 
                (parentMetadata.metadata["derived_children"] ?? "") + ",\(childIdentity)"
            
            let metadataKey = "\(metadataPrefix).\(parentIdentity)"
            let metadataData = try JSONEncoder().encode(updatedMetadata)
            try await keychain.save(metadataData, forKey: metadataKey)
        }
        
        return childIdentity
    }
    
    // MARK: - Key Backup & Recovery
    
    /// Creates a backup of all identities
    /// - Parameter password: Password to encrypt the backup
    /// - Returns: Encrypted backup data
    public func createBackup(password: String) async throws -> Data {
        let identities = try await listIdentities()
        var backupIdentities: [KeyBackup.BackupIdentity] = []
        
        for identity in identities {
            let keyPair = try await retrieve(identity: identity.id)
            
            // Generate salt for this identity
            let salt = try NostrCrypto.randomBytes(count: 32)
            
            // Derive encryption key from password
            let iterations = 100_000
            let keyData = try deriveKey(
                from: password,
                salt: salt,
                iterations: iterations
            )
            
            // Encrypt private key
            let iv = try NostrCrypto.randomBytes(count: 16)
            let encrypted = try NostrCrypto.aesEncrypt(
                plaintext: Data(keyPair.privateKey.utf8),
                key: keyData,
                iv: iv
            )
            
            let encryptedWithIV = iv + encrypted
            
            backupIdentities.append(
                KeyBackup.BackupIdentity(
                    identity: identity,
                    encryptedPrivateKey: encryptedWithIV.base64EncodedString(),
                    publicKey: keyPair.publicKey,
                    salt: salt.base64EncodedString(),
                    iterations: iterations
                )
            )
        }
        
        let backup = KeyBackup(
            version: 1,
            identities: backupIdentities,
            createdAt: Date(),
            checksum: "" // Will be set after encoding
        )
        
        var backupData = try JSONEncoder().encode(backup)
        
        // Add checksum
        let checksum = NostrCrypto.sha256(backupData).hex
        var backupWithChecksum = backup
        backupWithChecksum = KeyBackup(
            version: backup.version,
            identities: backup.identities,
            createdAt: backup.createdAt,
            checksum: checksum
        )
        
        backupData = try JSONEncoder().encode(backupWithChecksum)
        
        return backupData
    }
    
    /// Restores identities from a backup
    /// - Parameters:
    ///   - backupData: The backup data
    ///   - password: Password to decrypt the backup
    ///   - overwrite: Whether to overwrite existing identities
    /// - Returns: Number of identities restored
    @discardableResult
    public func restoreBackup(
        from backupData: Data,
        password: String,
        overwrite: Bool = false
    ) async throws -> Int {
        let backup = try JSONDecoder().decode(KeyBackup.self, from: backupData)
        
        // Verify checksum
        var backupForChecksum = backup
        backupForChecksum = KeyBackup(
            version: backup.version,
            identities: backup.identities,
            createdAt: backup.createdAt,
            checksum: ""
        )
        
        let dataForChecksum = try JSONEncoder().encode(backupForChecksum)
        let calculatedChecksum = NostrCrypto.sha256(dataForChecksum).hex
        
        guard calculatedChecksum == backup.checksum else {
            throw KeyStoreError.backupCorrupted
        }
        
        var restoredCount = 0
        
        for backupIdentity in backup.identities {
            // Check if identity exists
            let exists = (try? await getIdentity(backupIdentity.identity.id)) != nil
            
            if exists && !overwrite {
                continue
            }
            
            // Decrypt private key
            let salt = Data(base64Encoded: backupIdentity.salt)!
            let keyData = try deriveKey(
                from: password,
                salt: salt,
                iterations: backupIdentity.iterations
            )
            
            let encryptedData = Data(base64Encoded: backupIdentity.encryptedPrivateKey)!
            let iv = encryptedData.prefix(16)
            let ciphertext = encryptedData.dropFirst(16)
            
            let decrypted = try NostrCrypto.aesDecrypt(
                ciphertext: ciphertext,
                key: keyData,
                iv: iv
            )
            
            let privateKeyHex = String(data: decrypted, encoding: .utf8)!
            let keyPair = try KeyPair(privateKey: privateKeyHex)
            
            // Restore identity
            try await store(
                keyPair,
                for: backupIdentity.identity.id,
                name: backupIdentity.identity.name,
                metadata: backupIdentity.identity.metadata
            )
            
            restoredCount += 1
        }
        
        return restoredCount
    }
    
    // MARK: - Permissions
    
    /// Updates permissions for an identity
    /// - Parameters:
    ///   - identity: The identity to update
    ///   - permissions: New permissions
    public func updatePermissions(
        for identity: String,
        permissions: KeyPermissions
    ) async throws {
        // Verify identity exists
        _ = try await getIdentity(identity)
        
        let permissionsKey = "\(permissionsPrefix).\(identity)"
        let permissionsData = try JSONEncoder().encode(permissions)
        try await keychain.save(permissionsData, forKey: permissionsKey)
    }
    
    /// Checks if biometric authentication is available
    /// - Returns: Whether biometrics can be used
    public func isBiometricAuthenticationAvailable() async -> Bool {
        await keychain.canUseBiometrics()
    }
    
    // MARK: - Private Methods
    
    private func getIdentity(_ identity: String) async throws -> StoredIdentity? {
        let metadataKey = "\(metadataPrefix).\(identity)"
        guard let data = try? await keychain.load(key: metadataKey) else {
            return nil
        }
        
        return try JSONDecoder().decode(StoredIdentity.self, from: data)
    }
    
    private func getPermissions(for identity: String) async throws -> KeyPermissions {
        let permissionsKey = "\(permissionsPrefix).\(identity)"
        guard let data = try? await keychain.load(key: permissionsKey) else {
            throw KeyStoreError.identityNotFound(identity)
        }
        
        return try JSONDecoder().decode(KeyPermissions.self, from: data)
    }
    
    private func updateLastUsed(for identity: String) async {
        guard var storedIdentity = try? await getIdentity(identity) else { return }
        
        storedIdentity = StoredIdentity(
            id: storedIdentity.id,
            name: storedIdentity.name,
            createdAt: storedIdentity.createdAt,
            lastUsedAt: Date(),
            derivationPath: storedIdentity.derivationPath,
            parentIdentity: storedIdentity.parentIdentity,
            metadata: storedIdentity.metadata
        )
        
        let metadataKey = "\(metadataPrefix).\(identity)"
        if let data = try? JSONEncoder().encode(storedIdentity) {
            try? await keychain.save(data, forKey: metadataKey)
        }
    }
    
    private func deriveKey(from password: String, salt: Data, iterations: Int) throws -> Data {
        // Use PBKDF2 for key derivation
        let passwordData = Data(password.utf8)
        var derivedKey = Data(count: 32)
        
        let result = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress,
                        passwordData.count,
                        saltBytes.baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedKeyBytes.baseAddress,
                        32
                    )
                }
            }
        }
        
        guard result == kCCSuccess else {
            throw NostrError.cryptographyError(operation: .keyDerivation, reason: "PBKDF2 failed")
        }
        
        return derivedKey
    }
}

// MARK: - Convenience Extensions

extension SecureKeyStore {
    
    /// Signs an event using a stored identity
    /// - Parameters:
    ///   - event: The event to sign
    ///   - identity: The identity to use for signing
    /// - Returns: The signed event
    public func signEvent(
        _ event: inout NostrEvent,
        with identity: String
    ) async throws -> NostrEvent {
        let permissions = try await getPermissions(for: identity)
        guard permissions.canSign else {
            throw KeyStoreError.permissionDenied("Signing not allowed for this identity")
        }
        
        let keyPair = try await retrieve(identity: identity)
        return try keyPair.signEvent(event)
    }
    
    /// Decrypts a message using a stored identity
    /// - Parameters:
    ///   - message: The encrypted message
    ///   - from: The sender's public key
    ///   - identity: The identity to use for decryption
    /// - Returns: The decrypted message
    public func decrypt(
        message: String,
        from senderPubkey: PublicKey,
        using identity: String
    ) async throws -> String {
        let permissions = try await getPermissions(for: identity)
        guard permissions.canDecrypt else {
            throw KeyStoreError.permissionDenied("Decryption not allowed for this identity")
        }
        
        let keyPair = try await retrieve(identity: identity)
        return try keyPair.decrypt(message: message, from: senderPubkey)
    }
}

// MARK: - Import CommonCrypto for PBKDF2

import CommonCrypto