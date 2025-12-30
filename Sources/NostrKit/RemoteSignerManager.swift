//
//  RemoteSignerManager.swift
//  NostrKit
//
//  NIP-46: Nostr Remote Signing
//

import Foundation
import CoreNostr
import Combine
import OSLog

// MARK: - RemoteSignerManager

/// Manages connections to remote signers using the NIP-46 protocol.
///
/// `RemoteSignerManager` enables applications to request cryptographic operations
/// (signing, encryption, decryption) from a remote signer ("bunker") without
/// exposing private keys to the client application.
///
/// ## Overview
///
/// NIP-46 separates key storage from applications, allowing users to keep their
/// private keys in a secure signer application while still using other Nostr clients.
///
/// ### Key Features
/// - Event signing without exposing private keys
/// - NIP-04 and NIP-44 encryption/decryption via remote signer
/// - Two connection flows: bunker-initiated and client-initiated
/// - Automatic reconnection with exponential backoff
/// - Auth challenge handling for web-based signers
///
/// ## Connection Flows
///
/// ### Bunker-Initiated (bunker://)
/// The user provides a `bunker://` URI from their signer application:
/// ```swift
/// let uri = "bunker://pubkey?relay=wss://relay.example.com&secret=..."
/// try await signerManager.connect(bunkerURI: uri)
/// ```
///
/// ### Client-Initiated (nostrconnect://)
/// Your app creates a `nostrconnect://` URI for the user to scan:
/// ```swift
/// let uri = signerManager.createNostrConnectURI(
///     relays: ["wss://relay.example.com"],
///     name: "My App",
///     permissions: [.init(method: .signEvent)]
/// )
/// // Display URI as QR code
/// try await signerManager.waitForConnection(uri: uri)
/// ```
///
/// ## Example Usage
///
/// ```swift
/// @StateObject private var signerManager = RemoteSignerManager()
///
/// // Connect using bunker URI
/// try await signerManager.connect(bunkerURI: "bunker://...")
///
/// // Sign an event
/// let unsigned = NIP46.UnsignedEvent(
///     kind: 1,
///     content: "Hello Nostr!",
///     tags: []
/// )
/// let signedEvent = try await signerManager.signEvent(unsigned)
///
/// // Get the user's public key
/// let pubkey = try await signerManager.getPublicKey()
/// ```
@MainActor
public class RemoteSignerManager: ObservableObject {
    
    // MARK: - Types
    
    /// Represents a connection to a remote signer.
    public struct SignerConnection: Codable, Identifiable, Sendable {
        /// Unique identifier for this connection.
        public let id: String
        
        /// The remote signer's public key (hex format).
        public let signerPubkey: String
        
        /// Relay URLs for communication.
        public let relays: [String]
        
        /// The secret for connection authentication.
        public let secret: String?
        
        /// Optional human-readable alias for this connection.
        public let alias: String?
        
        /// Timestamp when this connection was established.
        public let createdAt: Date
        
        /// The user's public key (may differ from signer pubkey).
        public var userPubkey: String?
        
        /// Creates a new signer connection.
        public init(
            signerPubkey: String,
            relays: [String],
            secret: String?,
            alias: String? = nil,
            userPubkey: String? = nil
        ) {
            self.id = UUID().uuidString
            self.signerPubkey = signerPubkey
            self.relays = relays
            self.secret = secret
            self.alias = alias
            self.createdAt = Date()
            self.userPubkey = userPubkey
        }
    }
    
    /// The current state of the signer connection.
    public enum ConnectionState: Equatable {
        /// No active connection.
        case disconnected
        
        /// Currently establishing connection.
        case connecting
        
        /// Successfully connected and ready for operations.
        case connected
        
        /// Waiting for the remote signer to connect (client-initiated flow).
        case waitingForSigner
        
        /// Authentication required - user must visit the provided URL.
        case authRequired(URL)
        
        /// Connection attempt failed with an error.
        case failed(String)
        
        public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected),
                 (.connecting, .connecting),
                 (.connected, .connected),
                 (.waitingForSigner, .waitingForSigner):
                return true
            case (.authRequired(let lhsURL), .authRequired(let rhsURL)):
                return lhsURL == rhsURL
            case (.failed(let lhsMsg), .failed(let rhsMsg)):
                return lhsMsg == rhsMsg
            default:
                return false
            }
        }
    }
    
    // MARK: - Published Properties
    
    /// The currently active signer connection.
    @Published public private(set) var activeConnection: SignerConnection?
    
    /// The current connection state.
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    
    /// The user's public key from the remote signer.
    @Published public private(set) var userPublicKey: String?
    
    /// Indicates whether an operation is currently in progress.
    @Published public private(set) var isLoading = false
    
    /// The most recent error that occurred.
    @Published public private(set) var lastError: Error?
    
    // MARK: - Private Properties
    
    private let relayPool: any WalletRelayPool
    private let keychain: any WalletStorage
    
    /// Client keypair used for encryption with the signer.
    private var clientKeyPair: KeyPair?
    
    /// Active subscriptions: requestId -> subscriptionId
    private var subscriptions: [String: String] = [:]
    
    /// Subscription for incoming responses.
    private var responseSubscription: String?
    
    /// Task listening for responses.
    private var responseListenerTask: Task<Void, Never>?
    
    /// Set of processed response IDs to prevent duplicates.
    private var processedResponses: Set<String> = []
    
    /// Rate limiter for requests.
    private var rateLimiter: SignerRateLimiter
    
    /// Reconnection state.
    private var reconnectionTask: Task<Void, Never>?
    private var reconnectionAttempts: Int = 0
    private var isAutoReconnectEnabled: Bool = true
    
    // MARK: - Constants
    
    private static let keychainService = "com.nostrkit.nip46"
    private static let connectionKey = "signer_connection"
    private static let clientKeyKey = "client_keypair"
    
    /// Request timeout in nanoseconds (30 seconds).
    private static let requestTimeoutNanoseconds: UInt64 = 30_000_000_000
    
    /// Maximum reconnection attempts.
    private static let maxReconnectionAttempts: Int = 10
    
    /// Base delay for exponential backoff (1 second).
    private static let baseReconnectionDelay: TimeInterval = 1.0
    
    /// Maximum delay between reconnection attempts (5 minutes).
    private static let maxReconnectionDelay: TimeInterval = 300.0
    
    // MARK: - Initialization
    
    /// Creates a new remote signer manager.
    ///
    /// The manager automatically loads any previously saved connection from the Keychain.
    public init(maxRequestsPerMinute: Int = 30) {
        self.relayPool = RelayPool()
        self.keychain = KeychainWrapper(service: Self.keychainService)
        self.rateLimiter = SignerRateLimiter(maxRequestsPerMinute: maxRequestsPerMinute)
        
        Task {
            await loadConnection()
        }
    }
    
    /// Internal initializer for testing.
    init(
        relayPool: any WalletRelayPool,
        keychain: any WalletStorage,
        maxRequestsPerMinute: Int = 30
    ) {
        self.relayPool = relayPool
        self.keychain = keychain
        self.rateLimiter = SignerRateLimiter(maxRequestsPerMinute: maxRequestsPerMinute)
    }
    
    // MARK: - Connection Management
    
    /// Connects to a remote signer using a bunker:// URI.
    ///
    /// This is the bunker-initiated flow where the signer provides credentials to the client.
    ///
    /// - Parameters:
    ///   - uri: A bunker URI in the format `bunker://<pubkey>?relay=...&secret=...`
    ///   - alias: Optional human-readable name for this connection
    ///
    /// - Throws: `NIP46.NIP46Error` if connection fails
    ///
    /// ## Example
    ///
    /// ```swift
    /// let uri = "bunker://abc123...?relay=wss://relay.example.com&secret=xyz"
    /// try await signerManager.connect(bunkerURI: uri, alias: "My Signer")
    /// ```
    public func connect(bunkerURI uri: String, alias: String? = nil) async throws {
        guard let bunkerURI = NIP46.BunkerURI(from: uri) else {
            throw NIP46.NIP46Error.invalidURI
        }
        
        connectionState = .connecting
        isLoading = true
        defer { isLoading = false }
        
        do {
            // Generate or load client keypair
            let clientKP = try await getOrCreateClientKeyPair()
            self.clientKeyPair = clientKP
            
            // Add relays
            for relay in bunkerURI.relays {
                try await relayPool.addRelay(url: relay)
            }
            await relayPool.connectAll()
            
            // Subscribe to responses before sending connect request
            try await subscribeToResponses(signerPubkey: bunkerURI.signerPubkey)
            
            // Send connect request
            let connectRequest = NIP46.connectRequest(
                signerPubkey: bunkerURI.signerPubkey,
                secret: bunkerURI.secret
            )
            
            let response = try await sendRequest(
                connectRequest,
                signerPubkey: bunkerURI.signerPubkey,
                clientKeyPair: clientKP
            )
            
            // Handle auth challenge if needed
            if response.isAuthChallenge, let authURL = response.authURL {
                connectionState = .authRequired(authURL)
                throw NIP46.NIP46Error.authRequired(authURL)
            }
            
            // Verify connection success
            if let error = response.error, response.result != "ack" {
                throw NIP46.NIP46Error.connectionFailed(error)
            }
            
            // Create and store connection
            var connection = SignerConnection(
                signerPubkey: bunkerURI.signerPubkey,
                relays: bunkerURI.relays,
                secret: bunkerURI.secret,
                alias: alias
            )
            
            // Get the user's public key
            let pubkeyResponse = try await sendRequest(
                NIP46.getPublicKeyRequest(),
                signerPubkey: bunkerURI.signerPubkey,
                clientKeyPair: clientKP
            )
            
            if let pubkey = pubkeyResponse.result, pubkey.count == 64 {
                connection.userPubkey = pubkey
                self.userPublicKey = pubkey
            }
            
            activeConnection = connection
            await saveConnection()
            
            connectionState = .connected
            
            nip46Logger.info("Connected to remote signer", metadata: LogMetadata([
                "signer": bunkerURI.signerPubkey.prefix(8).description,
                "relays": String(bunkerURI.relays.count)
            ]))
            
        } catch {
            connectionState = .failed(error.localizedDescription)
            lastError = error
            throw error
        }
    }
    
    /// Creates a nostrconnect:// URI for the signer to connect to.
    ///
    /// Use this for the client-initiated flow where your app displays a QR code
    /// for the user to scan with their signer application.
    ///
    /// - Parameters:
    ///   - relays: Relay URLs where the client is listening
    ///   - permissions: Optional permissions to request
    ///   - name: Optional application name
    ///   - url: Optional application URL
    ///   - image: Optional application image URL
    ///
    /// - Returns: A `NostrConnectURI` that can be displayed as a QR code
    ///
    /// ## Example
    ///
    /// ```swift
    /// let uri = try signerManager.createNostrConnectURI(
    ///     relays: ["wss://relay.example.com"],
    ///     permissions: [NIP46.Permission(method: .signEvent)],
    ///     name: "My App"
    /// )
    /// // Display uri.toString() as QR code
    /// ```
    public func createNostrConnectURI(
        relays: [String],
        permissions: [NIP46.Permission]? = nil,
        name: String? = nil,
        url: String? = nil,
        image: String? = nil
    ) throws -> NIP46.NostrConnectURI {
        // Generate client keypair if needed
        let clientKP = try KeyPair.generate()
        self.clientKeyPair = clientKP
        
        // Generate a random secret
        var secretBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &secretBytes) == errSecSuccess else {
            throw NIP46.NIP46Error.connectionFailed("Failed to generate secret")
        }
        let secret = secretBytes.map { String(format: "%02x", $0) }.joined()
        
        let permString: String?
        if let perms = permissions {
            permString = NIP46.formatPermissions(perms)
        } else {
            permString = nil
        }
        
        return NIP46.NostrConnectURI(
            clientPubkey: clientKP.publicKey,
            relays: relays,
            secret: secret,
            permissions: permString,
            name: name,
            url: url,
            image: image
        )
    }
    
    /// Waits for a remote signer to connect using a nostrconnect:// URI.
    ///
    /// This method blocks until the signer connects or the timeout is reached.
    ///
    /// - Parameters:
    ///   - uri: The NostrConnectURI created by `createNostrConnectURI()`
    ///   - timeout: Maximum time to wait in seconds (default: 300 = 5 minutes)
    ///   - alias: Optional human-readable name for this connection
    ///
    /// - Throws: `NIP46.NIP46Error.timeout` if no connection is established
    ///
    /// ## Example
    ///
    /// ```swift
    /// let uri = try signerManager.createNostrConnectURI(...)
    /// // Display QR code to user
    /// try await signerManager.waitForConnection(uri: uri, timeout: 120)
    /// // User has connected their signer
    /// ```
    public func waitForConnection(
        uri: NIP46.NostrConnectURI,
        timeout: TimeInterval = 300,
        alias: String? = nil
    ) async throws {
        guard let clientKP = clientKeyPair else {
            throw NIP46.NIP46Error.connectionFailed("Client keypair not initialized")
        }
        
        connectionState = .waitingForSigner
        isLoading = true
        defer { isLoading = false }
        
        do {
            // Add relays
            for relay in uri.relays {
                try await relayPool.addRelay(url: relay)
            }
            await relayPool.connectAll()
            
            // Subscribe for incoming connect responses
            let filter = Filter(
                kinds: [EventKind.remoteSigningRequest.rawValue],
                p: [clientKP.publicKey]
            )
            
            let subscription = try await relayPool.walletSubscribe(filters: [filter], id: nil)
            
            // Wait for connect response with timeout
            let result: NostrEvent? = try await withThrowingTaskGroup(of: NostrEvent?.self) { group in
                group.addTask {
                    for await event in subscription.events {
                        // Decrypt and check if it's a connect response with matching secret
                        do {
                            let response = try NIP46.parseResponseEvent(
                                event: event,
                                clientSecret: clientKP.privateKey,
                                signerPubkey: event.pubkey
                            )
                            
                            // Check for "ack" or secret match
                            if response.result == "ack" || response.result == uri.secret {
                                return event
                            }
                        } catch {
                            // Ignore parsing errors, keep waiting
                            continue
                        }
                    }
                    return nil
                }
                
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return nil
                }
                
                if let first = try await group.next() {
                    group.cancelAll()
                    return first
                }
                
                group.cancelAll()
                return nil
            }
            
            await relayPool.closeSubscription(id: subscription.id)
            
            guard let connectEvent = result else {
                connectionState = .failed("Connection timed out")
                throw NIP46.NIP46Error.timeout
            }
            
            // Create connection from the event
            var connection = SignerConnection(
                signerPubkey: connectEvent.pubkey,
                relays: uri.relays,
                secret: uri.secret,
                alias: alias
            )
            
            // Subscribe to responses from this signer
            try await subscribeToResponses(signerPubkey: connectEvent.pubkey)
            
            // Get the user's public key
            let pubkeyResponse = try await sendRequest(
                NIP46.getPublicKeyRequest(),
                signerPubkey: connectEvent.pubkey,
                clientKeyPair: clientKP
            )
            
            if let pubkey = pubkeyResponse.result, pubkey.count == 64 {
                connection.userPubkey = pubkey
                self.userPublicKey = pubkey
            }
            
            activeConnection = connection
            await saveConnection()
            await saveClientKeyPair()
            
            connectionState = .connected
            
            nip46Logger.info("Remote signer connected", metadata: LogMetadata([
                "signer": connectEvent.pubkey.prefix(8).description
            ]))
            
        } catch {
            connectionState = .failed(error.localizedDescription)
            lastError = error
            throw error
        }
    }
    
    /// Disconnects from the remote signer.
    ///
    /// This closes all subscriptions and clears the active connection.
    /// The connection can be re-established using `reconnect()`.
    public func disconnect() async {
        connectionState = .disconnected
        
        // Cancel response listener
        responseListenerTask?.cancel()
        responseListenerTask = nil
        
        // Close subscriptions
        for subscriptionId in subscriptions.values {
            await relayPool.closeSubscription(id: subscriptionId)
        }
        subscriptions.removeAll()
        
        if let responseSubscription = responseSubscription {
            await relayPool.closeSubscription(id: responseSubscription)
            self.responseSubscription = nil
        }
        
        // Disconnect from relays
        await relayPool.disconnectAll()
        
        // Clear state
        activeConnection = nil
        userPublicKey = nil
        processedResponses.removeAll()
        
        nip46Logger.info("Disconnected from remote signer")
    }
    
    /// Reconnects to the previously connected signer.
    ///
    /// Use this to re-establish a connection after network issues.
    ///
    /// - Throws: `NIP46.NIP46Error` if no previous connection exists or reconnection fails
    public func reconnect() async throws {
        guard let connection = activeConnection else {
            throw NIP46.NIP46Error.signerDisconnected
        }
        
        let clientKP: KeyPair
        if let existingKeyPair = clientKeyPair {
            clientKP = existingKeyPair
        } else if let loadedKeyPair = try? await loadClientKeyPair() {
            clientKP = loadedKeyPair
        } else {
            throw NIP46.NIP46Error.connectionFailed("No client keypair available")
        }
        self.clientKeyPair = clientKP
        
        connectionState = .connecting
        
        do {
            // Reconnect to relays
            for relay in connection.relays {
                try await relayPool.addRelay(url: relay)
            }
            await relayPool.connectAll()
            
            // Re-subscribe to responses
            try await subscribeToResponses(signerPubkey: connection.signerPubkey)
            
            // Verify connection with ping
            let pingResponse = try await sendRequest(
                NIP46.pingRequest(),
                signerPubkey: connection.signerPubkey,
                clientKeyPair: clientKP
            )
            
            guard pingResponse.result == "pong" else {
                throw NIP46.NIP46Error.connectionFailed("Ping failed")
            }
            
            connectionState = .connected
            reconnectionAttempts = 0
            
            nip46Logger.info("Reconnected to remote signer")
            
        } catch {
            connectionState = .failed(error.localizedDescription)
            lastError = error
            throw error
        }
    }
    
    // MARK: - Signing Operations
    
    /// Signs an event using the remote signer.
    ///
    /// The signer will add the `id`, `pubkey`, and `sig` fields to the event.
    ///
    /// - Parameter event: The unsigned event to sign
    ///
    /// - Returns: The fully signed `NostrEvent`
    ///
    /// - Throws: `NIP46.NIP46Error.signingFailed` if signing fails
    ///
    /// ## Example
    ///
    /// ```swift
    /// let unsigned = NIP46.UnsignedEvent(
    ///     kind: 1,
    ///     content: "Hello Nostr!",
    ///     tags: []
    /// )
    /// let signed = try await signerManager.signEvent(unsigned)
    /// // signed.sig is now populated
    /// ```
    public func signEvent(_ event: NIP46.UnsignedEvent) async throws -> NostrEvent {
        let (connection, clientKP) = try ensureConnected()
        try enforceRateLimit()
        
        isLoading = true
        defer { isLoading = false }
        
        let request = try NIP46.signEventRequest(event: event)
        let response = try await sendRequest(
            request,
            signerPubkey: connection.signerPubkey,
            clientKeyPair: clientKP
        )
        
        // Handle auth challenge
        if response.isAuthChallenge, let authURL = response.authURL {
            connectionState = .authRequired(authURL)
            throw NIP46.NIP46Error.authRequired(authURL)
        }
        
        if let error = response.error {
            throw NIP46.NIP46Error.signingFailed(error)
        }
        
        guard let signedEventJSON = response.result,
              let data = signedEventJSON.data(using: .utf8) else {
            throw NIP46.NIP46Error.invalidResponse
        }
        
        let signedEvent = try JSONDecoder().decode(NostrEvent.self, from: data)
        
        nip46Logger.debug("Event signed", metadata: LogMetadata([
            "kind": String(signedEvent.kind),
            "id": signedEvent.id.prefix(8).description
        ]))
        
        return signedEvent
    }
    
    /// Gets the user's public key from the remote signer.
    ///
    /// - Returns: The user's public key in hex format
    ///
    /// - Throws: `NIP46.NIP46Error` if the request fails
    ///
    /// ## Example
    ///
    /// ```swift
    /// let pubkey = try await signerManager.getPublicKey()
    /// print("User pubkey: \(pubkey)")
    /// ```
    public func getPublicKey() async throws -> String {
        let (connection, clientKP) = try ensureConnected()
        try enforceRateLimit()
        
        isLoading = true
        defer { isLoading = false }
        
        let request = NIP46.getPublicKeyRequest()
        let response = try await sendRequest(
            request,
            signerPubkey: connection.signerPubkey,
            clientKeyPair: clientKP
        )
        
        if let error = response.error {
            throw NIP46.NIP46Error.connectionFailed(error)
        }
        
        guard let pubkey = response.result, pubkey.count == 64 else {
            throw NIP46.NIP46Error.invalidResponse
        }
        
        self.userPublicKey = pubkey
        
        return pubkey
    }
    
    /// Pings the remote signer to check connectivity.
    ///
    /// - Returns: `true` if the signer responds with "pong"
    ///
    /// - Throws: `NIP46.NIP46Error` if the ping fails
    public func ping() async throws -> Bool {
        let (connection, clientKP) = try ensureConnected()
        try enforceRateLimit()
        
        let request = NIP46.pingRequest()
        let response = try await sendRequest(
            request,
            signerPubkey: connection.signerPubkey,
            clientKeyPair: clientKP
        )
        
        return response.result == "pong"
    }
    
    // MARK: - Encryption Operations
    
    /// Encrypts plaintext using NIP-04 via the remote signer.
    ///
    /// - Parameters:
    ///   - plaintext: The text to encrypt
    ///   - recipientPubkey: The recipient's public key
    ///
    /// - Returns: The encrypted ciphertext
    ///
    /// - Throws: `NIP46.NIP46Error.encryptionFailed` if encryption fails
    public func nip04Encrypt(plaintext: String, recipientPubkey: String) async throws -> String {
        let (connection, clientKP) = try ensureConnected()
        try enforceRateLimit()
        
        isLoading = true
        defer { isLoading = false }
        
        let request = NIP46.nip04EncryptRequest(thirdPartyPubkey: recipientPubkey, plaintext: plaintext)
        let response = try await sendRequest(
            request,
            signerPubkey: connection.signerPubkey,
            clientKeyPair: clientKP
        )
        
        if let error = response.error {
            throw NIP46.NIP46Error.encryptionFailed(error)
        }
        
        guard let ciphertext = response.result else {
            throw NIP46.NIP46Error.invalidResponse
        }
        
        return ciphertext
    }
    
    /// Decrypts NIP-04 ciphertext via the remote signer.
    ///
    /// - Parameters:
    ///   - ciphertext: The encrypted text
    ///   - senderPubkey: The sender's public key
    ///
    /// - Returns: The decrypted plaintext
    ///
    /// - Throws: `NIP46.NIP46Error.decryptionFailed` if decryption fails
    public func nip04Decrypt(ciphertext: String, senderPubkey: String) async throws -> String {
        let (connection, clientKP) = try ensureConnected()
        try enforceRateLimit()
        
        isLoading = true
        defer { isLoading = false }
        
        let request = NIP46.nip04DecryptRequest(thirdPartyPubkey: senderPubkey, ciphertext: ciphertext)
        let response = try await sendRequest(
            request,
            signerPubkey: connection.signerPubkey,
            clientKeyPair: clientKP
        )
        
        if let error = response.error {
            throw NIP46.NIP46Error.decryptionFailed(error)
        }
        
        guard let plaintext = response.result else {
            throw NIP46.NIP46Error.invalidResponse
        }
        
        return plaintext
    }
    
    /// Encrypts plaintext using NIP-44 via the remote signer.
    ///
    /// - Parameters:
    ///   - plaintext: The text to encrypt
    ///   - recipientPubkey: The recipient's public key
    ///
    /// - Returns: The encrypted ciphertext
    ///
    /// - Throws: `NIP46.NIP46Error.encryptionFailed` if encryption fails
    public func nip44Encrypt(plaintext: String, recipientPubkey: String) async throws -> String {
        let (connection, clientKP) = try ensureConnected()
        try enforceRateLimit()
        
        isLoading = true
        defer { isLoading = false }
        
        let request = NIP46.nip44EncryptRequest(thirdPartyPubkey: recipientPubkey, plaintext: plaintext)
        let response = try await sendRequest(
            request,
            signerPubkey: connection.signerPubkey,
            clientKeyPair: clientKP
        )
        
        if let error = response.error {
            throw NIP46.NIP46Error.encryptionFailed(error)
        }
        
        guard let ciphertext = response.result else {
            throw NIP46.NIP46Error.invalidResponse
        }
        
        return ciphertext
    }
    
    /// Decrypts NIP-44 ciphertext via the remote signer.
    ///
    /// - Parameters:
    ///   - ciphertext: The encrypted text
    ///   - senderPubkey: The sender's public key
    ///
    /// - Returns: The decrypted plaintext
    ///
    /// - Throws: `NIP46.NIP46Error.decryptionFailed` if decryption fails
    public func nip44Decrypt(ciphertext: String, senderPubkey: String) async throws -> String {
        let (connection, clientKP) = try ensureConnected()
        try enforceRateLimit()
        
        isLoading = true
        defer { isLoading = false }
        
        let request = NIP46.nip44DecryptRequest(thirdPartyPubkey: senderPubkey, ciphertext: ciphertext)
        let response = try await sendRequest(
            request,
            signerPubkey: connection.signerPubkey,
            clientKeyPair: clientKP
        )
        
        if let error = response.error {
            throw NIP46.NIP46Error.decryptionFailed(error)
        }
        
        guard let plaintext = response.result else {
            throw NIP46.NIP46Error.invalidResponse
        }
        
        return plaintext
    }
    
    // MARK: - Reconnection
    
    /// Enables or disables automatic reconnection.
    public func setAutoReconnect(enabled: Bool) {
        isAutoReconnectEnabled = enabled
        if !enabled {
            cancelReconnection()
        }
    }
    
    /// Cancels any pending reconnection attempts.
    public func cancelReconnection() {
        reconnectionTask?.cancel()
        reconnectionTask = nil
        reconnectionAttempts = 0
    }
    
    /// Called when connection is lost to trigger automatic reconnection.
    public func handleConnectionLost() {
        guard case .connected = connectionState else { return }
        
        connectionState = .disconnected
        nip46Logger.warning("Connection lost, attempting to reconnect")
        
        scheduleReconnection()
    }
    
    // MARK: - Private Methods
    
    private func ensureConnected() throws -> (SignerConnection, KeyPair) {
        guard let connection = activeConnection else {
            throw NIP46.NIP46Error.signerDisconnected
        }
        guard let clientKP = clientKeyPair else {
            throw NIP46.NIP46Error.connectionFailed("Client keypair not initialized")
        }
        return (connection, clientKP)
    }
    
    private func enforceRateLimit() throws {
        guard rateLimiter.consume() else {
            throw NIP46.NIP46Error.connectionFailed("Too many requests. Please wait.")
        }
    }
    
    private func subscribeToResponses(signerPubkey: String) async throws {
        guard let clientKP = clientKeyPair else { return }
        
        // Cancel existing subscription
        responseListenerTask?.cancel()
        if let existing = responseSubscription {
            await relayPool.closeSubscription(id: existing)
        }
        
        // Subscribe to responses addressed to us
        let filter = Filter(
            authors: [signerPubkey],
            kinds: [EventKind.remoteSigningRequest.rawValue],
            p: [clientKP.publicKey]
        )
        
        let subscription = try await relayPool.walletSubscribe(filters: [filter], id: nil)
        responseSubscription = subscription.id
        
        // No need to listen here - responses are handled per-request
    }
    
    private func sendRequest(
        _ request: NIP46.Request,
        signerPubkey: String,
        clientKeyPair: KeyPair
    ) async throws -> NIP46.Response {
        // Create request event
        let requestEvent = try NIP46.createRequestEvent(
            request: request,
            signerPubkey: signerPubkey,
            clientKeyPair: clientKeyPair
        )
        
        nip46Logger.debug("Sending request", metadata: LogMetadata([
            "method": request.method,
            "id": request.id.prefix(8).description
        ]))
        
        // Subscribe to response
        let filter = Filter(
            authors: [signerPubkey],
            kinds: [EventKind.remoteSigningRequest.rawValue],
            p: [clientKeyPair.publicKey]
        )
        
        let subscription = try await relayPool.walletSubscribe(filters: [filter], id: nil)
        subscriptions[request.id] = subscription.id
        
        // Publish request
        let publishResults = await relayPool.publish(requestEvent)
        guard publishResults.contains(where: { $0.success }) else {
            await relayPool.closeSubscription(id: subscription.id)
            subscriptions.removeValue(forKey: request.id)
            throw NIP46.NIP46Error.connectionFailed("Failed to publish request to any relay")
        }
        
        // Wait for response with timeout
        let requestId = request.id
        let clientSecret = clientKeyPair.privateKey
        
        do {
            let result: NIP46.Response? = try await withThrowingTaskGroup(of: NIP46.Response?.self) { group in
                // Response listener task
                group.addTask {
                    for await event in subscription.events {
                        guard event.pubkey == signerPubkey else { continue }
                        guard event.kind == EventKind.remoteSigningRequest.rawValue else { continue }
                        
                        // Try to parse response
                        do {
                            let response = try NIP46.parseResponseEvent(
                                event: event,
                                clientSecret: clientSecret,
                                signerPubkey: signerPubkey
                            )
                            
                            // Check if this response matches our request
                            if response.id == requestId {
                                return response
                            }
                        } catch {
                            // Ignore parsing errors, keep listening
                            continue
                        }
                    }
                    return nil
                }
                
                // Timeout task
                group.addTask {
                    try await Task.sleep(nanoseconds: Self.requestTimeoutNanoseconds)
                    return nil
                }
                
                if let first = try await group.next() {
                    group.cancelAll()
                    return first
                }
                
                group.cancelAll()
                return nil
            }
            
            await relayPool.closeSubscription(id: subscription.id)
            subscriptions.removeValue(forKey: request.id)
            
            guard let response = result else {
                throw NIP46.NIP46Error.timeout
            }
            
            // Mark as processed
            processedResponses.insert(response.id)
            
            return response
            
        } catch is CancellationError {
            await relayPool.closeSubscription(id: subscription.id)
            subscriptions.removeValue(forKey: request.id)
            throw NIP46.NIP46Error.connectionFailed("Request was cancelled")
        } catch {
            await relayPool.closeSubscription(id: subscription.id)
            subscriptions.removeValue(forKey: request.id)
            throw error
        }
    }
    
    private func scheduleReconnection() {
        guard isAutoReconnectEnabled else { return }
        guard activeConnection != nil else { return }
        guard reconnectionAttempts < Self.maxReconnectionAttempts else {
            nip46Logger.error("Maximum reconnection attempts reached", metadata: LogMetadata([
                "attempts": String(reconnectionAttempts)
            ]))
            connectionState = .failed("Connection failed after \(reconnectionAttempts) attempts")
            return
        }
        
        reconnectionTask?.cancel()
        
        let baseDelay = Self.baseReconnectionDelay * pow(2.0, Double(reconnectionAttempts))
        let jitter = Double.random(in: 0...0.3) * baseDelay
        let delay = min(baseDelay + jitter, Self.maxReconnectionDelay)
        
        nip46Logger.info("Scheduling reconnection", metadata: LogMetadata([
            "attempt": String(reconnectionAttempts + 1),
            "delay_seconds": String(format: "%.1f", delay)
        ]))
        
        reconnectionTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
                guard !Task.isCancelled else { return }
                guard let self = self else { return }
                
                self.reconnectionAttempts += 1
                
                do {
                    try await self.reconnect()
                    self.reconnectionAttempts = 0
                    nip46Logger.info("Reconnection successful")
                } catch {
                    nip46Logger.warning("Reconnection attempt failed: \(error.localizedDescription)", metadata: LogMetadata([
                        "attempt": String(self.reconnectionAttempts)
                    ]))
                    self.scheduleReconnection()
                }
            } catch {
                // Task cancelled or sleep failed
            }
        }
    }
    
    // MARK: - Persistence
    
    private func getOrCreateClientKeyPair() async throws -> KeyPair {
        if let existing = try? await loadClientKeyPair() {
            return existing
        }
        
        let newKeyPair = try KeyPair.generate()
        self.clientKeyPair = newKeyPair
        await saveClientKeyPair()
        return newKeyPair
    }
    
    private func loadClientKeyPair() async throws -> KeyPair {
        let data = try await keychain.load(key: Self.clientKeyKey)
        guard let privateKey = String(data: data, encoding: .utf8) else {
            throw NIP46.NIP46Error.connectionFailed("Invalid stored keypair")
        }
        return try KeyPair(privateKey: privateKey)
    }
    
    private func saveClientKeyPair() async {
        guard let clientKP = clientKeyPair,
              let data = clientKP.privateKey.data(using: .utf8) else { return }
        
        do {
            try await keychain.store(data, forKey: Self.clientKeyKey)
        } catch {
            nip46Logger.error("Failed to save client keypair", error: error)
        }
    }
    
    private func loadConnection() async {
        do {
            let data = try await keychain.load(key: Self.connectionKey)
            let connection = try JSONDecoder().decode(SignerConnection.self, from: data)
            activeConnection = connection
            userPublicKey = connection.userPubkey
            
            // Try to load client keypair
            if let clientKP = try? await loadClientKeyPair() {
                self.clientKeyPair = clientKP
            }
        } catch {
            // No saved connection
        }
    }
    
    private func saveConnection() async {
        guard let connection = activeConnection else { return }
        
        do {
            let data = try JSONEncoder().encode(connection)
            try await keychain.store(data, forKey: Self.connectionKey)
        } catch {
            nip46Logger.error("Failed to save connection", error: error)
        }
    }
}

// MARK: - Rate Limiter

/// Simple token bucket rate limiter for NIP-46 requests.
private struct SignerRateLimiter {
    private let maxTokens: Double
    private let refillInterval: TimeInterval
    private var availableTokens: Double
    private var lastRefill: Date
    
    init(maxRequestsPerMinute: Int) {
        self.maxTokens = Double(maxRequestsPerMinute)
        self.refillInterval = 60.0
        self.availableTokens = Double(maxRequestsPerMinute)
        self.lastRefill = Date()
    }
    
    mutating func consume() -> Bool {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        if elapsed > 0 {
            let refill = (elapsed / refillInterval) * maxTokens
            availableTokens = min(maxTokens, availableTokens + refill)
            lastRefill = now
        }
        
        if availableTokens >= 1 {
            availableTokens -= 1
            return true
        }
        return false
    }
}
