//
//  WalletConnectManager.swift
//  NostrKit
//
//  Created by Nostr Team on 1/12/25.
//

import Foundation
import CoreNostr
import Combine

/// Manages Nostr Wallet Connect (NIP-47) connections and operations
@MainActor
public class WalletConnectManager: ObservableObject {
    
    // MARK: - Types
    
    /// Represents a wallet connection
    public struct WalletConnection: Codable, Identifiable {
        public let id: String
        public let uri: NWCConnectionURI
        public let alias: String?
        public let createdAt: Date
        public var lastUsedAt: Date?
        public var capabilities: NWCInfo?
        
        public init(uri: NWCConnectionURI, alias: String? = nil) {
            self.id = UUID().uuidString
            self.uri = uri
            self.alias = alias
            self.createdAt = Date()
        }
    }
    
    /// Payment result
    public struct PaymentResult {
        public let preimage: String
        public let feesPaid: Int64?
        public let paymentHash: String?
    }
    
    /// Connection state
    public enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case failed(Error)
    }
    
    // MARK: - Published Properties
    
    /// All stored wallet connections
    @Published public private(set) var connections: [WalletConnection] = []
    
    /// Currently active connection
    @Published public var activeConnection: WalletConnection?
    
    /// Current connection state
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    
    /// Last known balance in millisats
    @Published public private(set) var balance: Int64?
    
    /// Recent transactions
    @Published public private(set) var recentTransactions: [NWCTransaction] = []
    
    /// Loading state
    @Published public private(set) var isLoading = false
    
    /// Last error
    @Published public private(set) var lastError: Error?
    
    // MARK: - Private Properties
    
    private let keychain: KeychainWrapper
    private let relayPool: RelayPool
    private var subscriptions: [String: String] = [:] // requestId -> subscriptionId
    private var pendingRequests: [String: CheckedContinuation<NostrEvent, Error>] = [:]
    private var notificationSubscription: String?
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Constants
    
    private static let keychainService = "com.nostrkit.nwc"
    private static let connectionsKey = "wallet_connections"
    private static let activeConnectionKey = "active_connection"
    
    // MARK: - Initialization
    
    public init() {
        self.keychain = KeychainWrapper(service: Self.keychainService)
        self.relayPool = RelayPool()
        
        Task {
            await loadConnections()
        }
    }
    
    // MARK: - Connection Management
    
    /// Connect to a wallet using a NWC URI
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
    
    /// Disconnect from the active wallet
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
    
    /// Remove a wallet connection
    public func removeConnection(_ connection: WalletConnection) async {
        connections.removeAll { $0.id == connection.id }
        await saveConnections()
        
        if activeConnection?.id == connection.id {
            await disconnect()
        }
    }
    
    /// Switch to a different wallet connection
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
    
    /// Reconnect to the active wallet
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
    
    /// Pay a lightning invoice
    public func payInvoice(_ invoice: String, amount: Int64? = nil) async throws -> PaymentResult {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }
        
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
            clientSecret: connection.uri.secret
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
        if var conn = connections.first(where: { $0.id == connection.id }) {
            conn.lastUsedAt = Date()
            await saveConnections()
        }
        
        return PaymentResult(
            preimage: preimage,
            feesPaid: feesPaid,
            paymentHash: paymentHash
        )
    }
    
    /// Get wallet balance
    public func getBalance() async throws -> Int64 {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }
        
        isLoading = true
        defer { isLoading = false }
        
        let requestEvent = try NostrEvent.nwcRequest(
            method: .getBalance,
            walletPubkey: connection.uri.walletPubkey,
            clientSecret: connection.uri.secret
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
    
    /// Create a lightning invoice
    public func makeInvoice(amount: Int64, description: String? = nil, expiry: Int? = nil) async throws -> String {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }
        
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
            clientSecret: connection.uri.secret
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
    
    /// List recent transactions
    public func listTransactions(from: Date? = nil, until: Date? = nil, limit: Int? = nil) async throws -> [NWCTransaction] {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }
        
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
            clientSecret: connection.uri.secret
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
    
    private func fetchWalletInfo(walletPubkey: String) async throws -> NWCInfo? {
        // Create filter for info event
        let filter = Filter(
            authors: [walletPubkey],
            kinds: [EventKind.nwcInfo.rawValue],
            limit: 1
        )
        
        // Subscribe and collect info event
        let subscription = try await relayPool.subscribe(
            filters: [filter],
            id: "nwc-info-\(UUID().uuidString)"
        )
        
        var infoEvent: NostrEvent?
        
        // Collect events with timeout
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
        }
        
        for await event in await subscription.events {
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
        // Publish request
        let publishResults = await relayPool.publish(request)
        
        // Check if at least one relay accepted the event
        guard publishResults.contains(where: { $0.success }) else {
            throw NWCError(code: .other, message: "Failed to publish request to any relay")
        }
        
        // Subscribe to responses
        let filter = Filter(
            authors: [activeConnection?.uri.walletPubkey ?? ""],
            kinds: [EventKind.nwcResponse.rawValue],
            e: [request.id]
        )
        
        // Wait for response with timeout
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let subscription = try await relayPool.subscribe(filters: [filter])
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
                    for await event in await subscription.events {
                        if event.tags.contains(where: { $0.count >= 2 && $0[0] == "e" && $0[1] == request.id }) {
                            pendingRequests.removeValue(forKey: request.id)
                            await relayPool.closeSubscription(id: subscription.id)
                            subscriptions.removeValue(forKey: request.id)
                            continuation.resume(returning: event)
                            break
                        }
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
        
        // Subscribe to notification events
        let clientPubkey = try! KeyPair(privateKey: connection.uri.secret).publicKey
        let filter = Filter(
            authors: [connection.uri.walletPubkey],
            kinds: [EventKind.nwcNotification.rawValue, EventKind.nwcNotificationLegacy.rawValue],
            p: [clientPubkey]
        )
        
        do {
            let subscription = try await relayPool.subscribe(filters: [filter])
            notificationSubscription = subscription.id
            
            Task {
                for await event in await subscription.events {
                    await handleNotification(event)
                }
            }
        } catch {
            print("Failed to subscribe to notifications: \(error)")
        }
    }
    
    private func handleNotification(_ event: NostrEvent) async {
        guard let connection = activeConnection else { return }
        
        do {
            let decryptedContent = try event.decryptNWCContent(
                with: connection.uri.secret,
                peerPubkey: connection.uri.walletPubkey
            )
            
            let notification = try JSONDecoder().decode(NWCNotification.self, from: Data(decryptedContent.utf8))
            
            // Handle different notification types
            switch notification.notificationType {
            case .paymentReceived:
                print("Payment received notification")
                // Update balance
                _ = try? await getBalance()
                
            case .paymentSent:
                print("Payment sent notification")
                // Update balance and transaction list
                _ = try? await getBalance()
                _ = try? await listTransactions(limit: 10)
            }
            
        } catch {
            print("Failed to handle notification: \(error)")
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

public extension WalletConnectManager {
    
    /// Check if wallet supports a specific method
    func supportsMethod(_ method: NWCMethod) -> Bool {
        guard let capabilities = activeConnection?.capabilities else {
            return false
        }
        return capabilities.methods.contains(method)
    }
    
    /// Check if wallet supports notifications
    var supportsNotifications: Bool {
        guard let capabilities = activeConnection?.capabilities else {
            return false
        }
        return !capabilities.notifications.isEmpty
    }
    
    /// Get preferred encryption scheme
    var preferredEncryption: NWCEncryption {
        guard let capabilities = activeConnection?.capabilities else {
            return .nip04 // Default to legacy
        }
        return capabilities.encryptionSchemes.contains(.nip44) ? .nip44 : .nip04
    }
}