//
//  WalletConnectManager.swift
//  NostrKit
//
//  Created by Nostr Team on 1/12/25.
//

import Foundation
import CoreNostr
import Combine
import OSLog

// MARK: - RelayPool Conformance

extension RelayPool: WalletRelayPool {
    func addRelay(url: String) async throws {
        _ = try self.addRelay(url: url, metadata: nil)
    }
    
    func walletSubscribe(filters: [Filter], id: String?) async throws -> WalletSubscription {
        let poolSubscription = try await subscribe(filters: filters, id: id)
        let stream = await poolSubscription.events
        return WalletSubscription(id: poolSubscription.id, events: stream)
    }
}

// MARK: - Supporting Types

protocol WalletRelayPool: Actor {
    func addRelay(url: String) async throws
    func connectAll() async
    func publish(_ event: NostrEvent) async -> [RelayPool.PublishResult]
    func walletSubscribe(filters: [Filter], id: String?) async throws -> WalletSubscription
    func closeSubscription(id: String) async
    func disconnectAll() async
}

/// Minimal subscription wrapper to decouple WalletConnectManager from the underlying relay pool implementation.
public struct WalletSubscription: Sendable {
    public let id: String
    public let events: AsyncStream<NostrEvent>
}

/// Simple token bucket rate limiter used to throttle NWC requests per wallet.
private struct NWCRateLimiter {
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

/// Manages Lightning wallet connections using the Nostr Wallet Connect protocol (NIP-47).
///
/// `WalletConnectManager` provides a complete interface for integrating Lightning payments
/// into your Nostr application. It handles connection management, payment operations,
/// and real-time notifications from wallet services.
///
/// ## Overview
///
/// The manager maintains persistent connections to NWC-compatible wallet services through
/// Nostr relays, enabling seamless Lightning Network integration. All connections are
/// stored securely in the iOS Keychain and automatically restored on app launch.
///
/// ### Key Features
/// - Multiple wallet connection management
/// - Secure connection storage in Keychain
/// - Real-time payment notifications
/// - Automatic reconnection handling
/// - Support for both NIP-04 and NIP-44 encryption
///
/// ## Example Usage
///
/// ```swift
/// @StateObject private var walletManager = WalletConnectManager()
///
/// // Connect to a wallet
/// try await walletManager.connect(
///     uri: "nostr+walletconnect://pubkey?relay=wss://relay.com&secret=..."
/// )
///
/// // Pay an invoice
/// let result = try await walletManager.payInvoice("lnbc1000n1...")
/// print("Payment completed with preimage: \(result.preimage)")
///
/// // Check balance
/// let balance = try await walletManager.getBalance()
/// print("Balance: \(balance) millisats")
/// ```
///
/// ## Topics
///
/// ### Essentials
/// - ``connect(uri:alias:)``
/// - ``disconnect()``
/// - ``payInvoice(_:amount:)``
/// - ``getBalance()``
///
/// ### Connection Management
/// - ``connections``
/// - ``activeConnection``
/// - ``connectionState``
/// - ``switchConnection(to:)``
/// - ``removeConnection(_:)``
/// - ``reconnect()``
///
/// ### Payment Operations
/// - ``makeInvoice(amount:description:expiry:)``
/// - ``listTransactions(from:until:limit:)``
///
/// ### State Observation
/// - ``balance``
/// - ``recentTransactions``
/// - ``isLoading``
/// - ``lastError``
///
/// ### Utility Methods
/// - ``supportsMethod(_:)``
/// - ``supportsNotifications``
/// - ``preferredEncryption``
@MainActor
public class WalletConnectManager: ObservableObject {
    
    // MARK: - Types
    
    /// Represents a persistent wallet connection with its metadata and capabilities.
    ///
    /// Each connection stores the NWC URI components and tracks usage statistics.
    /// Connections are automatically persisted to the Keychain for secure storage.
    public struct WalletConnection: Codable, Identifiable {
        /// Unique identifier for this connection.
        public let id: String
        
        /// The parsed NWC connection URI containing wallet pubkey, relays, and secret.
        public let uri: NWCConnectionURI
        
        /// Optional human-readable alias for this wallet connection.
        public let alias: String?
        
        /// Timestamp when this connection was first established.
        public let createdAt: Date
        
        /// Timestamp of the most recent successful operation with this wallet.
        public var lastUsedAt: Date?
        
        /// Wallet capabilities including supported methods and encryption schemes.
        ///
        /// This is populated by querying the wallet's info event (kind 13194) after connection.
        public var capabilities: NWCInfo?
        
        /// Creates a new wallet connection.
        ///
        /// - Parameters:
        ///   - uri: The parsed NWC connection URI
        ///   - alias: Optional human-readable name for this connection
        public init(uri: NWCConnectionURI, alias: String? = nil) {
            self.id = UUID().uuidString
            self.uri = uri
            self.alias = alias
            self.createdAt = Date()
        }
    }
    
    /// The result of a successful Lightning payment.
    ///
    /// Contains the payment proof (preimage) and optional fee information.
    public struct PaymentResult {
        /// The payment preimage serving as proof of payment.
        ///
        /// This 32-byte value is the cryptographic proof that the payment was completed.
        public let preimage: String
        
        /// The amount of fees paid in millisatoshis, if reported by the wallet.
        public let feesPaid: Int64?
        
        /// The payment hash, if provided by the wallet.
        public let paymentHash: String?
    }
    
    /// Represents the current state of the wallet connection.
    ///
    /// Use this to update your UI based on connection status.
    public enum ConnectionState {
        /// No active wallet connection.
        case disconnected
        
        /// Currently establishing connection to wallet service.
        case connecting
        
        /// Successfully connected and ready for operations.
        case connected
        
        /// Connection attempt failed with an error.
        case failed(Error)
    }
    
    // MARK: - Published Properties
    
    /// All wallet connections stored in the Keychain.
    ///
    /// This array persists across app launches and is automatically loaded on initialization.
    @Published public private(set) var connections: [WalletConnection] = []
    
    /// The currently active wallet connection used for payment operations.
    ///
    /// Set this to `nil` to disconnect, or use ``switchConnection(to:)`` to change wallets.
    @Published public var activeConnection: WalletConnection?
    
    /// The current connection state of the active wallet.
    ///
    /// Observe this property to update your UI based on connection status.
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    
    /// The last known wallet balance in millisatoshis.
    ///
    /// This value is updated when calling ``getBalance()`` or when receiving payment notifications.
    /// - Note: 1000 millisats = 1 satoshi
    @Published public private(set) var balance: Int64?
    
    /// Recent transactions fetched from the wallet.
    ///
    /// Updated by calling ``listTransactions(from:until:limit:)`` or via notifications.
    @Published public private(set) var recentTransactions: [NWCTransaction] = []
    
    /// Indicates whether an operation is currently in progress.
    ///
    /// Use this to show loading indicators in your UI.
    @Published public private(set) var isLoading = false
    
    /// The most recent error that occurred, if any.
    ///
    /// This is set when operations fail and can be used for error reporting.
    @Published public private(set) var lastError: Error?
    
    // MARK: - Private Properties
    
    private let keychain: KeychainWrapper
    private let relayPool: any WalletRelayPool
    private var subscriptions: [String: String] = [:] // requestId -> subscriptionId
    private var pendingRequests: [String: CheckedContinuation<NostrEvent, Error>] = [:]
    private var notificationSubscription: String?
    private var cancellables = Set<AnyCancellable>()
    private var processedResponses: Set<String> = []
    private var processedNotifications: Set<String> = []
    private var rateLimiter: NWCRateLimiter
    
    // MARK: - Constants
    
    private static let keychainService = "com.nostrkit.nwc"
    private static let connectionsKey = "wallet_connections"
    private static let activeConnectionKey = "active_connection"
    
    // MARK: - Initialization
    
    /// Creates a new wallet connect manager instance.
    ///
    /// The manager automatically loads any previously saved connections from the Keychain
    /// on initialization. No manual setup is required.
    ///
    /// - Note: The manager must be used on the main actor for SwiftUI compatibility.
    public init(maxRequestsPerMinute: Int = 30) {
        self.keychain = KeychainWrapper(service: Self.keychainService)
        self.relayPool = RelayPool()
        self.rateLimiter = NWCRateLimiter(maxRequestsPerMinute: maxRequestsPerMinute)
        
        Task {
            await loadConnections()
        }
    }
    
    // Internal initializer for testing/custom injection
    init(
        relayPool: any WalletRelayPool,
        keychain: KeychainWrapper,
        seedConnections: [WalletConnection]? = nil,
        activeConnectionId: String? = nil,
        maxRequestsPerMinute: Int = 30
    ) {
        self.keychain = keychain
        self.relayPool = relayPool
        self.rateLimiter = NWCRateLimiter(maxRequestsPerMinute: maxRequestsPerMinute)
        
        if let seedConnections {
            self.connections = seedConnections
            if let activeId = activeConnectionId {
                self.activeConnection = seedConnections.first(where: { $0.id == activeId })
            } else {
                self.activeConnection = seedConnections.first
            }
        }
    }
    
    // MARK: - Connection Management
    
    /// Establishes a connection to a Lightning wallet using a NWC URI.
    ///
    /// This method connects to the specified wallet service through the provided relays,
    /// fetches the wallet's capabilities, and stores the connection securely in the Keychain.
    /// If this is the first connection, it automatically becomes the active connection.
    ///
    /// - Parameters:
    ///   - uri: A NWC connection URI in the format `nostr+walletconnect://pubkey?relay=...&secret=...`
    ///   - alias: An optional human-readable name for this wallet connection
    ///
    /// - Throws:
    ///   - ``NWCError`` with code `.other` if the URI is invalid
    ///   - ``RelayError`` if connection to relays fails
    ///   - Other network-related errors
    ///
    /// - Important: The connection URI contains sensitive information and should be obtained
    ///   securely from the user's wallet provider.
    ///
    /// ## Example
    ///
    /// ```swift
    /// do {
    ///     try await walletManager.connect(
    ///         uri: "nostr+walletconnect://abc123...?relay=wss://relay.getalby.com/v1&secret=...",
    ///         alias: "My Alby Wallet"
    ///     )
    ///     print("Connected to wallet!")
    /// } catch {
    ///     print("Connection failed: \(error)")
    /// }
    /// ```
    ///
    /// - Note: The connection process includes:
    ///   1. Parsing and validating the URI
    ///   2. Connecting to specified relays
    ///   3. Fetching wallet capabilities
    ///   4. Storing connection securely
    ///   5. Subscribing to payment notifications
    public func connect(uri: String, alias: String? = nil) async throws {
        guard let nwcURI = NWCConnectionURI(from: uri) else {
            throw NWCError(code: .other, message: "Invalid NWC URI")
        }
        
        connectionState = .connecting
        isLoading = true
        defer { isLoading = false }
        
        do {
            // Add relays to the pool
            for relay in nwcURI.relays {
                try await relayPool.addRelay(url: relay)
            }
            
            // Connect to relays
            await relayPool.connectAll()
            
            // Create and store connection
            var connection = WalletConnection(uri: nwcURI, alias: alias)
            
            // Fetch wallet capabilities
            if let info = try await fetchWalletInfo(walletPubkey: nwcURI.walletPubkey) {
                connection.capabilities = info
            }
            
            // Store connection
            connections.append(connection)
            await saveConnections()
            
            // Set as active if it's the first connection
            if activeConnection == nil {
                activeConnection = connection
                await saveActiveConnection()
            }
            
            connectionState = .connected
            
            // Subscribe to notifications
            await subscribeToNotifications()
            
        } catch {
            connectionState = .failed(error)
            lastError = error
            throw error
        }
    }
    
    /// Disconnects from the currently active wallet.
    ///
    /// This method closes all active subscriptions, disconnects from relays,
    /// and clears the active connection. The connection remains stored and can
    /// be reactivated later using ``reconnect()`` or ``switchConnection(to:)``.
    ///
    /// - Note: This does not remove the wallet from stored connections.
    ///   Use ``removeConnection(_:)`` to permanently remove a wallet.
    ///
    /// ## Example
    ///
    /// ```swift
    /// await walletManager.disconnect()
    /// // The wallet is now disconnected but still saved
    /// ```
    public func disconnect() async {
        connectionState = .disconnected
        
        // Cancel all subscriptions
        for subscriptionId in subscriptions.values {
            await relayPool.closeSubscription(id: subscriptionId)
        }
        subscriptions.removeAll()
        
        if let notificationSubscription = notificationSubscription {
            await relayPool.closeSubscription(id: notificationSubscription)
            self.notificationSubscription = nil
        }
        
        // Disconnect from relays
        await relayPool.disconnectAll()
        
        // Clear active connection
        activeConnection = nil
        await saveActiveConnection()
        
        // Clear cached data
        balance = nil
        recentTransactions = []
    }
    
    /// Permanently removes a wallet connection from storage.
    ///
    /// This removes the connection from the Keychain and disconnects if it's currently active.
    ///
    /// - Parameter connection: The wallet connection to remove
    ///
    /// - Note: This action cannot be undone. The user will need to re-enter
    ///   the connection URI to use this wallet again.
    ///
    /// ## Example
    ///
    /// ```swift
    /// if let walletToRemove = walletManager.connections.first {
    ///     await walletManager.removeConnection(walletToRemove)
    /// }
    /// ```
    public func removeConnection(_ connection: WalletConnection) async {
        connections.removeAll { $0.id == connection.id }
        await saveConnections()
        
        if activeConnection?.id == connection.id {
            await disconnect()
        }
    }
    
    /// Switches the active wallet to a different stored connection.
    ///
    /// This method disconnects from the current wallet (if any) and connects
    /// to the specified wallet connection.
    ///
    /// - Parameter connection: The wallet connection to activate
    ///
    /// - Throws:
    ///   - ``NWCError`` if the connection is not found in stored connections
    ///   - Connection errors if establishing the new connection fails
    ///
    /// ## Example
    ///
    /// ```swift
    /// if let secondWallet = walletManager.connections[1] {
    ///     try await walletManager.switchConnection(to: secondWallet)
    /// }
    /// ```
    public func switchConnection(to connection: WalletConnection) async throws {
        guard connections.contains(where: { $0.id == connection.id }) else {
            throw NWCError(code: .other, message: "Connection not found")
        }
        
        // Disconnect current
        await disconnect()
        
        // Set new active connection
        activeConnection = connection
        await saveActiveConnection()
        
        // Connect to new wallet
        try await reconnect()
    }
    
    /// Reconnects to the currently active wallet.
    ///
    /// Use this method to re-establish a connection after network issues
    /// or when returning from background.
    ///
    /// - Throws:
    ///   - ``NWCError`` if no active connection is set
    ///   - Connection errors if establishing the connection fails
    ///
    /// ## Example
    ///
    /// ```swift
    /// // After network recovery
    /// do {
    ///     try await walletManager.reconnect()
    /// } catch {
    ///     print("Reconnection failed: \(error)")
    /// }
    /// ```
    public func reconnect() async throws {
        guard let connection = activeConnection else {
            throw NWCError(code: .other, message: "No active connection")
        }
        
        connectionState = .connecting
        
        do {
            // Add relays to the pool
            for relay in connection.uri.relays {
                try await relayPool.addRelay(url: relay)
            }
            
            // Connect to relays
            await relayPool.connectAll()
            
            connectionState = .connected
            
            // Subscribe to notifications
            await subscribeToNotifications()
            
        } catch {
            connectionState = .failed(error)
            lastError = error
            throw error
        }
    }
    
    // MARK: - Payment Operations
    
    /// Pays a Lightning invoice using the connected wallet.
    ///
    /// This method sends a payment request to the connected wallet service and waits
    /// for confirmation. The wallet must have sufficient balance and the invoice must be valid.
    ///
    /// - Parameters:
    ///   - invoice: A BOLT11 Lightning invoice string (e.g., "lnbc1000n1...")
    ///   - amount: Optional amount override in millisatoshis. Only valid for zero-amount invoices.
    ///
    /// - Returns: A ``PaymentResult`` containing the payment preimage and optional fee information.
    ///
    /// - Throws:
    ///   - ``NWCError/insufficientBalance``: The wallet doesn't have enough funds
    ///   - ``NWCError/paymentFailed``: The payment could not be completed
    ///   - ``NWCError/unauthorized``: No active wallet connection
    ///   - ``NWCError/rateLimited``: Too many requests in a short time
    ///
    /// - Important: Always check the wallet balance before attempting large payments.
    ///
    /// ## Example
    ///
    /// ```swift
    /// do {
    ///     let invoice = "lnbc1000n1..." // From recipient
    ///     let result = try await walletManager.payInvoice(invoice)
    ///     
    ///     print("Payment successful!")
    ///     print("Preimage: \(result.preimage)")
    ///     
    ///     if let fees = result.feesPaid {
    ///         print("Fees: \(fees) millisats")
    ///     }
    /// } catch let error as NWCError {
    ///     switch error.code {
    ///     case .insufficientBalance:
    ///         print("Not enough funds")
    ///     case .paymentFailed:
    ///         print("Payment failed: \(error.message)")
    ///     default:
    ///         print("Error: \(error.message)")
    ///     }
    /// }
    /// ```
    ///
    /// - Note: The payment process is atomic - either it completes fully or fails completely.
    public func payInvoice(_ invoice: String, amount: Int64? = nil) async throws -> PaymentResult {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }
        guard supportsMethod(.payInvoice) else {
            throw NWCError(code: .notImplemented, message: "Wallet does not support pay_invoice")
        }
        try enforceRateLimit()
        
        isLoading = true
        defer { isLoading = false }
        
        // Create pay invoice request
        var params: [String: AnyCodable] = ["invoice": AnyCodable(invoice)]
        if let amount = amount {
            params["amount"] = AnyCodable(amount)
        }
        
        let requestEvent = try NostrEvent.nwcRequest(
            method: .payInvoice,
            params: params,
            walletPubkey: connection.uri.walletPubkey,
            clientSecret: connection.uri.secret,
            encryption: try resolveEncryption()
        )
        
        // Send request and wait for response
        let response = try await sendRequestAndWaitForResponse(requestEvent)
        
        // Decrypt and parse response
        let decryptedContent = try response.decryptNWCContent(
            with: connection.uri.secret,
            peerPubkey: connection.uri.walletPubkey
        )
        
        let responseData = try JSONDecoder().decode(NWCResponse.self, from: Data(decryptedContent.utf8))
        
        if let error = responseData.error {
            throw error
        }
        
        guard let result = responseData.result,
              let preimage = result["preimage"]?.value as? String else {
            throw NWCError(code: .other, message: "Invalid response format")
        }
        
        let feesPaid = result["fees_paid"]?.value as? Int64
        let paymentHash = result["payment_hash"]?.value as? String
        
        // Update last used timestamp
        if let idx = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[idx].lastUsedAt = Date()
            await saveConnections()
        }
        
        return PaymentResult(
            preimage: preimage,
            feesPaid: feesPaid,
            paymentHash: paymentHash
        )
    }
    
    /// Retrieves the current balance from the connected wallet.
    ///
    /// The balance is returned in millisatoshis (1/1000 of a satoshi).
    ///
    /// - Returns: The wallet balance in millisatoshis
    ///
    /// - Throws:
    ///   - ``NWCError/unauthorized``: No active wallet connection
    ///   - ``NWCError/notImplemented``: Wallet doesn't support balance queries
    ///   - Network or parsing errors
    ///
    /// ## Example
    ///
    /// ```swift
    /// do {
    ///     let balanceMillisats = try await walletManager.getBalance()
    ///     let balanceSats = balanceMillisats / 1000
    ///     print("Balance: \(balanceSats) sats")
    /// } catch {
    ///     print("Failed to get balance: \(error)")
    /// }
    /// ```
    ///
    /// - Note: The balance is also stored in the ``balance`` published property for observation.
    public func getBalance() async throws -> Int64 {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }
        guard supportsMethod(.getBalance) else {
            throw NWCError(code: .notImplemented, message: "Wallet does not support balance queries")
        }
        try enforceRateLimit()
        
        isLoading = true
        defer { isLoading = false }
        
        let requestEvent = try NostrEvent.nwcRequest(
            method: .getBalance,
            walletPubkey: connection.uri.walletPubkey,
            clientSecret: connection.uri.secret,
            encryption: try resolveEncryption()
        )
        
        let response = try await sendRequestAndWaitForResponse(requestEvent)
        
        let decryptedContent = try response.decryptNWCContent(
            with: connection.uri.secret,
            peerPubkey: connection.uri.walletPubkey
        )
        
        let responseData = try JSONDecoder().decode(NWCResponse.self, from: Data(decryptedContent.utf8))
        
        if let error = responseData.error {
            throw error
        }
        
        guard let result = responseData.result,
              let balance = result["balance"]?.value as? Int64 else {
            throw NWCError(code: .other, message: "Invalid response format")
        }
        
        self.balance = balance
        return balance
    }
    
    /// Creates a Lightning invoice for receiving payments.
    ///
    /// Generates a BOLT11 invoice that others can pay to send funds to your wallet.
    ///
    /// - Parameters:
    ///   - amount: The amount to receive in millisatoshis
    ///   - description: Optional description/memo for the invoice
    ///   - expiry: Optional expiry time in seconds (default varies by wallet)
    ///
    /// - Returns: A BOLT11 invoice string that can be paid by others
    ///
    /// - Throws:
    ///   - ``NWCError/unauthorized``: No active wallet connection
    ///   - ``NWCError/notImplemented``: Wallet doesn't support invoice creation
    ///   - Other wallet-specific errors
    ///
    /// ## Example
    ///
    /// ```swift
    /// do {
    ///     // Create invoice for 1000 sats
    ///     let invoice = try await walletManager.makeInvoice(
    ///         amount: 1_000_000, // 1000 sats in millisats
    ///         description: "Coffee payment",
    ///         expiry: 3600 // 1 hour
    ///     )
    ///     
    ///     // Display as QR code or share
    ///     showQRCode(for: invoice)
    /// } catch {
    ///     print("Failed to create invoice: \(error)")
    /// }
    /// ```
    public func makeInvoice(amount: Int64, description: String? = nil, expiry: Int? = nil) async throws -> String {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }
        guard supportsMethod(.makeInvoice) else {
            throw NWCError(code: .notImplemented, message: "Wallet does not support invoice creation")
        }
        try enforceRateLimit()
        
        isLoading = true
        defer { isLoading = false }
        
        var params: [String: AnyCodable] = ["amount": AnyCodable(amount)]
        if let description = description {
            params["description"] = AnyCodable(description)
        }
        if let expiry = expiry {
            params["expiry"] = AnyCodable(expiry)
        }
        
        let requestEvent = try NostrEvent.nwcRequest(
            method: .makeInvoice,
            params: params,
            walletPubkey: connection.uri.walletPubkey,
            clientSecret: connection.uri.secret,
            encryption: try resolveEncryption()
        )
        
        let response = try await sendRequestAndWaitForResponse(requestEvent)
        
        let decryptedContent = try response.decryptNWCContent(
            with: connection.uri.secret,
            peerPubkey: connection.uri.walletPubkey
        )
        
        let responseData = try JSONDecoder().decode(NWCResponse.self, from: Data(decryptedContent.utf8))
        
        if let error = responseData.error {
            throw error
        }
        
        guard let result = responseData.result,
              let invoice = result["invoice"]?.value as? String else {
            throw NWCError(code: .other, message: "Invalid response format")
        }
        
        return invoice
    }
    
    /// Retrieves transaction history from the connected wallet.
    ///
    /// Fetches a list of recent transactions within the specified time range.
    ///
    /// - Parameters:
    ///   - from: Optional start date for the transaction range
    ///   - until: Optional end date for the transaction range
    ///   - limit: Maximum number of transactions to return
    ///
    /// - Returns: An array of ``NWCTransaction`` objects representing the transaction history
    ///
    /// - Throws:
    ///   - ``NWCError/unauthorized``: No active wallet connection
    ///   - ``NWCError/notImplemented``: Wallet doesn't support transaction listing
    ///   - Network or parsing errors
    ///
    /// ## Example
    ///
    /// ```swift
    /// do {
    ///     // Get last 7 days of transactions
    ///     let weekAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
    ///     let transactions = try await walletManager.listTransactions(
    ///         from: weekAgo,
    ///         limit: 50
    ///     )
    ///     
    ///     for tx in transactions {
    ///         print("\(tx.type): \(tx.amount) millisats")
    ///     }
    /// } catch {
    ///     print("Failed to load transactions: \(error)")
    /// }
    /// ```
    ///
    /// - Note: The transactions are also stored in ``recentTransactions`` for observation.
    public func listTransactions(from: Date? = nil, until: Date? = nil, limit: Int? = nil) async throws -> [NWCTransaction] {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }
        guard supportsMethod(.listTransactions) else {
            throw NWCError(code: .notImplemented, message: "Wallet does not support transaction listing")
        }
        try enforceRateLimit()
        
        isLoading = true
        defer { isLoading = false }
        
        var params: [String: AnyCodable] = [:]
        if let from = from {
            params["from"] = AnyCodable(Int64(from.timeIntervalSince1970))
        }
        if let until = until {
            params["until"] = AnyCodable(Int64(until.timeIntervalSince1970))
        }
        if let limit = limit {
            params["limit"] = AnyCodable(limit)
        }
        
        let requestEvent = try NostrEvent.nwcRequest(
            method: .listTransactions,
            params: params,
            walletPubkey: connection.uri.walletPubkey,
            clientSecret: connection.uri.secret,
            encryption: try resolveEncryption()
        )
        
        let response = try await sendRequestAndWaitForResponse(requestEvent)
        
        let decryptedContent = try response.decryptNWCContent(
            with: connection.uri.secret,
            peerPubkey: connection.uri.walletPubkey
        )
        
        let responseData = try JSONDecoder().decode(NWCResponse.self, from: Data(decryptedContent.utf8))
        
        if let error = responseData.error {
            throw error
        }
        
        guard let result = responseData.result,
              let transactionsData = result["transactions"]?.value as? [[String: Any]] else {
            throw NWCError(code: .other, message: "Invalid response format")
        }
        
        // Parse transactions
        let transactions = try transactionsData.compactMap { txData -> NWCTransaction? in
            let jsonData = try JSONSerialization.data(withJSONObject: txData)
            return try JSONDecoder().decode(NWCTransaction.self, from: jsonData)
        }
        
        self.recentTransactions = transactions
        return transactions
    }
    
    // MARK: - Private Methods
    
    private func enforceRateLimit() throws {
        guard rateLimiter.consume() else {
            throw NWCError(code: .rateLimited, message: "Too many wallet requests. Please wait.")
        }
    }
    
    private func resolveEncryption() throws -> NWCEncryption {
        guard let capabilities = activeConnection?.capabilities else {
            return .nip44
        }
        
        if capabilities.encryptionSchemes.contains(.nip44) {
            return .nip44
        }
        if capabilities.encryptionSchemes.contains(.nip04) {
            return .nip04
        }
        
        throw NWCError(code: .unsupportedEncryption, message: "Wallet does not support a compatible encryption scheme")
    }
    
    private func fetchWalletInfo(walletPubkey: String) async throws -> NWCInfo? {
        // Create filter for info event
        let filter = Filter(
            authors: [walletPubkey],
            kinds: [EventKind.nwcInfo.rawValue],
            limit: 1
        )
        
        // Subscribe and collect info event
            let subscription = try await relayPool.walletSubscribe(
                filters: [filter],
                id: "nwc-info-\(UUID().uuidString)"
            )
        
        var infoEvent: NostrEvent?
        
        // Collect events with timeout
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
        }
        
        for await event in subscription.events {
            infoEvent = event
            break
        }
        
        timeoutTask.cancel()
        await relayPool.closeSubscription(id: subscription.id)
        
        guard let event = infoEvent else {
            return nil
        }
        
        return NWCInfo(content: event.content, tags: event.tags)
    }
    
    private func sendRequestAndWaitForResponse(_ request: NostrEvent) async throws -> NostrEvent {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }
        
        nwcLogger.debug("Publishing NWC request", metadata: LogMetadata([
            "request_id": request.id,
            "wallet": connection.uri.walletPubkey
        ]))
        
        // Publish request
        let publishResults = await relayPool.publish(request)
        
        // Check if at least one relay accepted the event
        guard publishResults.contains(where: { $0.success }) else {
            throw NWCError(code: .other, message: "Failed to publish request to any relay")
        }
        
        // Subscribe to responses
        let filter = Filter(
            authors: [connection.uri.walletPubkey],
            kinds: [EventKind.nwcResponse.rawValue],
            e: [request.id]
        )
        
        // Wait for response with timeout
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let subscription = try await relayPool.walletSubscribe(filters: [filter], id: nil)
                    subscriptions[request.id] = subscription.id
                    
                    // Set up timeout
                    Task {
                        try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                        if pendingRequests[request.id] != nil {
                            pendingRequests.removeValue(forKey: request.id)
                            continuation.resume(throwing: RelayError.timeout)
                        }
                    }
                    
                    // Store continuation
                    pendingRequests[request.id] = continuation
                    
                    // Listen for response
                    for await event in subscription.events {
                        guard !processedResponses.contains(event.id) else { continue }
                        guard event.pubkey == connection.uri.walletPubkey else { continue }
                        guard event.kind == EventKind.nwcResponse.rawValue else { continue }
                        
                        guard event.tags.contains(where: { $0.count >= 2 && $0[0] == "e" && $0[1] == request.id }) else {
                            continue
                        }
                        
                        processedResponses.insert(event.id)
                        pendingRequests.removeValue(forKey: request.id)
                        await relayPool.closeSubscription(id: subscription.id)
                        subscriptions.removeValue(forKey: request.id)
                        continuation.resume(returning: event)
                        break
                    }
                } catch {
                    pendingRequests.removeValue(forKey: request.id)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func subscribeToNotifications() async {
        guard let connection = activeConnection else { return }
        
        // Check if wallet supports notifications
        guard let capabilities = connection.capabilities,
              !capabilities.notifications.isEmpty else {
            return
        }
        
        guard let clientPubkey = try? KeyPair(privateKey: connection.uri.secret).publicKey else {
            nwcLogger.error("Failed to derive client pubkey for notifications")
            return
        }
        let filter = Filter(
            authors: [connection.uri.walletPubkey],
            kinds: [EventKind.nwcNotification.rawValue, EventKind.nwcNotificationLegacy.rawValue],
            p: [clientPubkey]
        )
        
        do {
            let subscription = try await relayPool.walletSubscribe(filters: [filter], id: nil)
            notificationSubscription = subscription.id
            
            Task {
                for await event in subscription.events {
                    await handleNotification(event)
                }
            }
        } catch {
            nwcLogger.error("Failed to subscribe to notifications", error: error)
        }
    }
    
    private func handleNotification(_ event: NostrEvent) async {
        guard let connection = activeConnection else { return }
        
        guard !processedNotifications.contains(event.id) else { return }
        guard event.pubkey == connection.uri.walletPubkey else { return }
        processedNotifications.insert(event.id)
        
        do {
            let decryptedContent = try event.decryptNWCContent(
                with: connection.uri.secret,
                peerPubkey: connection.uri.walletPubkey
            )
            
            let notification = try JSONDecoder().decode(NWCNotification.self, from: Data(decryptedContent.utf8))
            
            // Handle different notification types
            switch notification.notificationType {
            case .paymentReceived:
                nwcLogger.info("Payment received notification", metadata: LogMetadata(["wallet": connection.uri.walletPubkey]))
                // Update balance
                _ = try? await getBalance()
                
            case .paymentSent:
                nwcLogger.info("Payment sent notification", metadata: LogMetadata(["wallet": connection.uri.walletPubkey]))
                // Update balance and transaction list
                _ = try? await getBalance()
                _ = try? await listTransactions(limit: 10)
            }
            
        } catch {
            nwcLogger.error("Failed to handle notification", error: error)
        }
    }
    
    // MARK: - Persistence
    
    private func loadConnections() async {
        do {
            let data = try await keychain.load(key: Self.connectionsKey)
            connections = try JSONDecoder().decode([WalletConnection].self, from: data)
            
            // Load active connection
            if let activeData = try? await keychain.load(key: Self.activeConnectionKey) {
                let activeId = String(data: activeData, encoding: .utf8)
                activeConnection = connections.first { $0.id == activeId }
            }
        } catch {
            // No saved connections
            connections = []
        }
    }
    
    private func saveConnections() async {
        do {
            let data = try JSONEncoder().encode(connections)
            try await keychain.save(data, forKey: Self.connectionsKey)
        } catch {
            print("Failed to save connections: \(error)")
        }
    }
    
    private func saveActiveConnection() async {
        do {
            if let activeId = activeConnection?.id,
               let data = activeId.data(using: .utf8) {
                try await keychain.save(data, forKey: Self.activeConnectionKey)
            } else {
                try await keychain.delete(key: Self.activeConnectionKey)
            }
        } catch {
            print("Failed to save active connection: \(error)")
        }
    }
}

// MARK: - Convenience Extensions

extension WalletConnectManager {
    
    /// Checks if the active wallet supports a specific NWC method.
    ///
    /// Use this to conditionally enable features based on wallet capabilities.
    ///
    /// - Parameter method: The NWC method to check support for
    /// - Returns: `true` if the wallet supports the method, `false` otherwise
    ///
    /// ## Example
    ///
    /// ```swift
    /// if walletManager.supportsMethod(.payInvoice) {
    ///     // Show payment UI
    /// } else {
    ///     // Show "not supported" message
    /// }
    /// ```
    public func supportsMethod(_ method: NWCMethod) -> Bool {
        guard let capabilities = activeConnection?.capabilities else {
            return false
        }
        return capabilities.methods.contains(method)
    }
    
    /// Indicates whether the active wallet supports real-time notifications.
    ///
    /// When `true`, the wallet will send notifications for incoming and outgoing payments.
    public var supportsNotifications: Bool {
        guard let capabilities = activeConnection?.capabilities else {
            return false
        }
        return !capabilities.notifications.isEmpty
    }
    
    /// The preferred encryption scheme for the active wallet connection.
    ///
    /// Returns NIP-44 if supported, otherwise falls back to NIP-04 for legacy compatibility.
    public var preferredEncryption: NWCEncryption {
        guard let capabilities = activeConnection?.capabilities else {
            return .nip04 // Default to legacy
        }
        return capabilities.encryptionSchemes.contains(.nip44) ? .nip44 : .nip04
    }
}
