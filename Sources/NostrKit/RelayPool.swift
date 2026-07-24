import Foundation
import CoreNostr

/// Errors that can occur in relay operations
public enum RelayError: Error, LocalizedError {
    case timeout
    case eventRejected(reason: String?)
    case connectionFailed(Error)
    case notConnected
    
    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "Operation timed out"
        case .eventRejected(let reason):
            return "Event rejected: \(reason ?? "No reason provided")"
        case .connectionFailed(let error):
            return "Connection failed: \(error.localizedDescription)"
        case .notConnected:
            return "Not connected to relay"
        }
    }
}

/// A pool of relay connections that manages multiple relays with load balancing, health monitoring, and automatic failover.
///
/// The RelayPool provides high-level functionality for:
/// - Managing connections to multiple relays
/// - Automatic reconnection with exponential backoff
/// - Health monitoring and relay scoring
/// - Load balancing across healthy relays
/// - Broadcasting events to multiple relays
/// - Aggregating responses from multiple relays
///
/// ## Example
/// ```swift
/// let pool = RelayPool()
/// 
/// // Add relays
/// try await pool.addRelay(url: "wss://relay.damus.io")
/// try await pool.addRelay(url: "wss://relay.nostr.band")
/// 
/// // Connect to all relays
/// try await pool.connectAll()
/// 
/// // Publish an event to all connected relays
/// let event = try CoreNostr.createTextNote(content: "Hello, Nostr!", keyPair: keyPair)
/// let results = await pool.publish(event)
/// 
/// // Subscribe across all relays
/// let subscription = try await pool.subscribe(filters: [Filter(kinds: [.textNote])])
/// for await event in subscription.events {
///     print("Received event: \(event.content)")
/// }
/// ```
public actor RelayPool {
    
    // MARK: - Types
    
    /// Represents a relay in the pool with its connection and metadata
    public struct Relay: Sendable {
        /// The connection driving this relay. `RelayService` in production;
        /// tests inject scripted conformances to exercise pool behavior.
        let connection: any RelayConnection

        /// The production relay service backing this relay.
        ///
        /// `nil` only when a test injected a non-`RelayService` connection.
        public var service: RelayService? { connection as? RelayService }

        /// The relay URL
        public let url: String
        
        /// Current connection state
        public var state: ConnectionState = .disconnected
        
        /// Health score (0.0 to 1.0, where 1.0 is perfectly healthy)
        public var healthScore: Double = 1.0
        
        /// Number of consecutive connection failures
        public var failureCount: Int = 0
        
        /// Last successful connection time
        public var lastConnectedAt: Date?
        
        /// Last error encountered
        public var lastError: Error?
        
        /// Relay information from NIP-11
        public var info: RelayInformation?
        
        /// Custom relay metadata (e.g., read/write preferences from NIP-65)
        public var metadata: RelayMetadata?
        
        /// Statistics for this relay
        public var stats: RelayStatistics = RelayStatistics()
    }
    
    /// Relay connection states
    public enum ConnectionState: String, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case failed
    }
    
    /// Relay metadata for NIP-65 support
    public struct RelayMetadata: Sendable {
        public let read: Bool
        public let write: Bool
        public let isPrimary: Bool
        
        public init(read: Bool = true, write: Bool = true, isPrimary: Bool = false) {
            self.read = read
            self.write = write
            self.isPrimary = isPrimary
        }
    }
    
    /// Statistics for relay performance monitoring
    public struct RelayStatistics: Sendable {
        public var eventsReceived: Int = 0
        public var eventsSent: Int = 0
        public var subscriptionCount: Int = 0
        public var averageResponseTime: TimeInterval = 0
        public var uptime: TimeInterval = 0
        public var lastActivity: Date?
    }
    
    /// Result of publishing an event to multiple relays
    public struct PublishResult: Sendable {
        public let relay: String
        public let success: Bool
        public let message: String?
        public let error: Error?
    }
    
    /// Options for relay pool behavior
    public struct Configuration: Sendable {
        /// Maximum number of relays to connect to simultaneously
        public let maxConnections: Int
        
        /// Initial reconnection delay in seconds
        public let initialReconnectDelay: TimeInterval
        
        /// Maximum reconnection delay in seconds
        public let maxReconnectDelay: TimeInterval
        
        /// Backoff multiplier for exponential backoff
        public let backoffMultiplier: Double
        
        /// Time to wait for relay responses before considering it unhealthy
        public let healthCheckTimeout: TimeInterval
        
        /// Minimum health score before relay is considered unhealthy
        public let minHealthScore: Double
        
        /// Whether to automatically reconnect on disconnection
        public let autoReconnect: Bool
        
        /// Whether to automatically discover relays from NIP-65
        public let autoDiscoverRelays: Bool
        
        public init(
            maxConnections: Int = 10,
            initialReconnectDelay: TimeInterval = 1.0,
            maxReconnectDelay: TimeInterval = 300.0,
            backoffMultiplier: Double = 2.0,
            healthCheckTimeout: TimeInterval = 5.0,
            minHealthScore: Double = 0.5,
            autoReconnect: Bool = true,
            autoDiscoverRelays: Bool = true
        ) {
            self.maxConnections = maxConnections
            self.initialReconnectDelay = initialReconnectDelay
            self.maxReconnectDelay = maxReconnectDelay
            self.backoffMultiplier = backoffMultiplier
            self.healthCheckTimeout = healthCheckTimeout
            self.minHealthScore = minHealthScore
            self.autoReconnect = autoReconnect
            self.autoDiscoverRelays = autoDiscoverRelays
        }
    }
    
    // MARK: - Properties
    
    /// All relays in the pool
    private var relays: [String: Relay] = [:]
    
    /// Active subscriptions
    private var subscriptions: [String: PoolSubscription] = [:]
    
    /// Pending OK responses tracked by relay URL and event ID
    private var pendingOKResponses: [String: [EventID: CheckedContinuation<PublishResult, Never>]] = [:]

    /// Monitor tasks per relay URL, so they can be cancelled when the relay
    /// is removed (or when the whole pool shuts down) instead of leaking.
    private var monitorTasks: [String: Task<Void, Never>] = [:]

    /// Pending reconnection backoff tasks per relay URL. Tracked so an
    /// intentional disconnect, relay removal, or explicit connect can cancel
    /// the timer instead of letting it dial a relay nobody wants anymore.
    private var reconnectTasks: [String: Task<Void, Never>] = [:]

    /// Relays the caller deliberately disconnected. A monitor exiting for one
    /// of these URLs must NOT schedule an auto-reconnect — `disconnectAll()`
    /// means *stay down* until the caller connects again.
    private var intentionallyDisconnected: Set<String> = []

    /// NIP-42 authenticator installed on every current and future relay.
    private var authenticator: (@Sendable (AuthChallenge) async throws -> AuthResponse)?

    /// Per-(subscription|relay) resubscribe attempts after a server-side
    /// CLOSED, so a relay that keeps closing us can't cause an infinite REQ
    /// loop. Reset when the relay (re)connects.
    private var closedResubscribeAttempts: [String: Int] = [:]
    
    /// Configuration for the relay pool
    public let configuration: Configuration
    
    /// Delegate for relay pool events
    public weak var delegate: RelayPoolDelegate?
    
    /// Currently connected relays
    public var connectedRelays: [Relay] {
        relays.values.filter { $0.state == .connected }
    }
    
    /// Healthy relays (connected with good health score)
    public var healthyRelays: [Relay] {
        connectedRelays.filter { $0.healthScore >= configuration.minHealthScore }
    }
    
    // MARK: - Initialization
    
    /// Creates a new relay pool with the specified configuration
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }
    
    // MARK: - Relay Management
    
    /// Adds a relay to the pool
    /// - Parameters:
    ///   - url: The WebSocket URL of the relay
    ///   - metadata: Optional metadata for the relay
    /// - Returns: The added relay
    @discardableResult
    public func addRelay(url: String, metadata: RelayMetadata? = nil) throws -> Relay {
        guard Validation.isValidRelayURL(url) else {
            throw NostrError.invalidURI(uri: url, reason: "Invalid WebSocket URL format")
        }
        return try addRelay(url: url, metadata: metadata, connection: RelayService(url: url))
    }

    /// Adds a relay backed by an explicit connection. Internal so tests can
    /// inject scripted `RelayConnection` conformances; the public overload
    /// always creates a real `RelayService`.
    @discardableResult
    func addRelay(url: String, metadata: RelayMetadata? = nil, connection: any RelayConnection) throws -> Relay {
        // Check if relay already exists
        if let existingRelay = relays[url] {
            return existingRelay
        }

        // Check max connections
        if relays.count >= configuration.maxConnections {
            throw NostrError.rateLimited(
                limit: configuration.maxConnections,
                resetTime: nil
            )
        }

        let relay = Relay(
            connection: connection,
            url: url,
            metadata: metadata
        )

        relays[url] = relay

        // Note: the monitor task is started in `connect(to:)`, not here.
        // RelayService recreates its message stream on each connect, so the
        // monitor must be (re)created per connection to use the fresh stream.

        return relay
    }
    
    /// Removes a relay from the pool
    /// - Parameter url: The URL of the relay to remove
    public func removeRelay(url: String) async {
        guard let relay = relays[url] else { return }

        // Cancel the monitor task first so it doesn't try to read the relay
        // after we've removed it, and kill any pending reconnect timer.
        monitorTasks.removeValue(forKey: url)?.cancel()
        reconnectTasks.removeValue(forKey: url)?.cancel()
        intentionallyDisconnected.remove(url)
        clearClosedResubscribeAttempts(for: url)

        // Disconnect if connected
        if relay.state == .connected {
            await relay.connection.disconnect()
        }

        // Clean up any pending OK responses
        if let pendingResponses = pendingOKResponses[url] {
            for (_, continuation) in pendingResponses {
                continuation.resume(returning: PublishResult(
                    relay: url,
                    success: false,
                    message: "Relay removed",
                    error: RelayError.notConnected
                ))
            }
            pendingOKResponses.removeValue(forKey: url)
        }

        // Remove from pool
        relays.removeValue(forKey: url)

        // Clean up subscriptions for this relay
        for subscription in subscriptions.values {
            await subscription.removeRelay(url: url)
        }
    }
    
    /// Connects to a specific relay
    /// - Parameter url: The URL of the relay to connect
    public func connect(to url: String) async throws {
        guard let connection = relays[url]?.connection else {
            throw NostrError.notFound(resource: "Relay with URL \(url)")
        }

        // An explicit connect always re-arms auto-reconnect for this relay.
        intentionallyDisconnected.remove(url)

        // A live connection stays live — re-dialing a healthy socket tears it
        // down mid-flight (cancelling handshakes and NIP-11 fetches) only to
        // rebuild what already worked.
        if relays[url]?.state == .connected { return }

        // A dial is already in flight — wait for it to resolve rather than
        // stomping the half-open socket with a second dial. Concurrent callers
        // (retry loops) all converge on the one dial.
        if relays[url]?.state == .connecting {
            try await waitForInFlightDial(url: url)
            return
        }

        // `.reconnecting` means a backoff timer is pending, not a live dial —
        // the caller wants a connection NOW, so cancel the timer and dial.
        reconnectTasks.removeValue(forKey: url)?.cancel()

        mutateRelay(url) { $0.state = .connecting }

        do {
            await connection.setAuthenticator(authenticator)
            try await connection.connect()

            mutateRelay(url) {
                $0.state = .connected
                $0.lastConnectedAt = Date()
                $0.failureCount = 0
                $0.lastError = nil
                $0.healthScore = 1.0
            }
            clearClosedResubscribeAttempts(for: url)

            // Start a fresh monitor for this connection. The previous monitor
            // (if any) has already exited because its message stream finished
            // when the prior connection dropped; we cancel defensively in case
            // it was still in-flight, then attach to the new stream that
            // `connection.connect()` rebuilt.
            monitorTasks[url]?.cancel()
            monitorTasks[url] = Task { [weak self] in
                await self?.monitorRelay(url: url)
            }

            // Re-attach every active subscription. On a RECONNECT this is what
            // keeps long-lived subscriptions alive — the previous socket's
            // REQs died with it, and a bunker that silently loses its request
            // subscription is deaf. On a first connect it attaches
            // subscriptions that were registered while this relay was down.
            await attachSubscriptions(to: url)

            // Fetch relay information
            await fetchRelayInformation(for: url)

            // Notify delegate
            await delegate?.relayPool(self, didConnectTo: url)

        } catch {
            mutateRelay(url) {
                $0.state = .failed
                $0.lastError = error
                $0.failureCount += 1
            }

            // Update health score
            await updateHealthScore(for: url, eventType: .connectionFailure)

            // Schedule reconnection if enabled
            if configuration.autoReconnect {
                scheduleReconnection(for: url)
            }

            throw error
        }
    }

    /// Waits for an in-flight dial on `url` to resolve.
    ///
    /// Returns once the relay reaches `.connected`; throws the dial's error if
    /// it resolves to a failure, or `RelayError.timeout` if it never resolves
    /// within the deadline. Sleeping yields the actor, so the owning dial makes
    /// progress while callers wait.
    private func waitForInFlightDial(url: String, deadline: Duration = .seconds(15)) async throws {
        let clock = ContinuousClock()
        let start = clock.now

        while clock.now - start < deadline {
            switch relays[url]?.state {
            case .connected:
                return
            case .connecting, .reconnecting:
                try? await Task.sleep(for: .milliseconds(100))
            case .failed, .disconnected:
                throw relays[url]?.lastError ?? RelayError.notConnected
            case nil:
                throw NostrError.notFound(resource: "Relay with URL \(url)")
            }
        }

        throw RelayError.timeout
    }

    /// Connects to all relays in the pool
    public func connectAll() async {
        await withTaskGroup(of: Void.self) { group in
            for url in relays.keys {
                group.addTask {
                    try? await self.connect(to: url)
                }
            }
        }
    }
    
    /// Disconnects from a specific relay and keeps it down.
    ///
    /// This is an *intentional* disconnect: auto-reconnect is suppressed for
    /// this relay until the next `connect(to:)`/`connectAll()`.
    /// - Parameter url: The URL of the relay to disconnect
    public func disconnect(from url: String) async {
        guard let connection = relays[url]?.connection else { return }

        // Mark BEFORE tearing down the socket: the monitor observes the
        // stream finishing and must already know this drop is deliberate.
        intentionallyDisconnected.insert(url)
        reconnectTasks.removeValue(forKey: url)?.cancel()

        await connection.disconnect()
        mutateRelay(url) { $0.state = .disconnected }
        
        // Clean up any pending OK responses
        if let pendingResponses = pendingOKResponses[url] {
            for (_, continuation) in pendingResponses {
                continuation.resume(returning: PublishResult(
                    relay: url,
                    success: false,
                    message: "Relay disconnected",
                    error: RelayError.notConnected
                ))
            }
            pendingOKResponses.removeValue(forKey: url)
        }
        
        await delegate?.relayPool(self, didDisconnectFrom: url)
    }
    
    /// Disconnects from all relays
    public func disconnectAll() async {
        await withTaskGroup(of: Void.self) { group in
            for url in relays.keys {
                group.addTask {
                    await self.disconnect(from: url)
                }
            }
        }
    }
    
    // MARK: - Event Publishing
    
    /// Publishes an event to all writable relays
    /// - Parameter event: The event to publish
    /// - Returns: Results from each relay
    public func publish(_ event: NostrEvent) async -> [PublishResult] {
        var writableRelays = healthyRelays.filter { relay in
            relay.metadata?.write ?? true
        }

        // If no healthy relays, attempt to reconnect before giving up
        if writableRelays.isEmpty {
            await connectAll()
            writableRelays = healthyRelays.filter { relay in
                relay.metadata?.write ?? true
            }
        }

        return await withTaskGroup(of: PublishResult.self) { group in
            for relay in writableRelays {
                group.addTask {
                    await self.publishToRelay(event, relay: relay)
                }
            }
            
            var results: [PublishResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
    
    /// Publishes an event to specific relays
    /// - Parameters:
    ///   - event: The event to publish
    ///   - relayURLs: URLs of relays to publish to
    /// - Returns: Results from each relay
    public func publish(_ event: NostrEvent, to relayURLs: [String]) async -> [PublishResult] {
        let targetRelays = relayURLs.compactMap { url in
            relays[url]
        }.filter { relay in
            relay.state == .connected && (relay.metadata?.write ?? true)
        }
        
        return await withTaskGroup(of: PublishResult.self) { group in
            for relay in targetRelays {
                group.addTask {
                    await self.publishToRelay(event, relay: relay)
                }
            }
            
            var results: [PublishResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
    
    // MARK: - Subscriptions
    
    /// Creates a subscription across all readable relays.
    ///
    /// The subscription is registered with the pool first and attached to
    /// every currently-connected readable relay. Relays that are offline (or
    /// added later) pick the subscription up automatically when they connect —
    /// so subscribing while temporarily offline succeeds and goes live as
    /// relays come up, and reconnects transparently re-establish it.
    ///
    /// - Parameters:
    ///   - filters: Filters for the subscription
    ///   - id: Optional subscription ID (generated if not provided)
    /// - Returns: A pool subscription that aggregates events from all relays
    /// - Throws: `NostrError.notFound` if the pool has no relays at all
    public func subscribe(
        filters: [Filter],
        id: String? = nil
    ) async throws -> PoolSubscription {
        let subscriptionId = id ?? UUID().uuidString

        guard !relays.isEmpty else {
            throw NostrError.notFound(resource: "No relays in pool")
        }

        let subscription = PoolSubscription(
            id: subscriptionId,
            filters: filters,
            pool: self
        )

        subscriptions[subscriptionId] = subscription

        // Attach to whatever is connected right now; the rest attach on
        // (re)connect via `attachSubscriptions(to:)`.
        let readableURLs = connectedRelays
            .filter { $0.metadata?.read ?? true }
            .map { $0.url }
        await subscription.subscribeToRelays(readableURLs)

        return subscription
    }
    
    /// Closes a subscription
    /// - Parameter id: The subscription ID to close
    public func closeSubscription(id: String) async {
        guard let subscription = subscriptions[id] else { return }

        await subscription.close()
        subscriptions.removeValue(forKey: id)
    }

    // MARK: - Authentication (NIP-42)

    /// Installs a NIP-42 authenticator on every current and future relay in
    /// the pool. Relays that demand auth (AUTH challenges, `auth-required:`
    /// CLOSED reasons) are answered automatically once this is set.
    public func setAuthenticator(_ handler: (@Sendable (AuthChallenge) async throws -> AuthResponse)?) async {
        authenticator = handler
        for relay in relays.values {
            await relay.connection.setAuthenticator(handler)
        }
    }

    /// Convenience: authenticate to relays with the given key pair.
    public func setAuthenticator(keyPair: KeyPair) async {
        await setAuthenticator { challenge in
            try CoreNostr.authenticate(challenge: challenge, keyPair: keyPair)
        }
    }
    
    // MARK: - Private Methods

    /// Mutate the relay record at `url` atomically from within the actor's
    /// context. Centralizes the read-modify-write on `relays[url]` so callers
    /// never hold a stale struct copy across an `await` — a re-entrant update
    /// to the same dict (e.g. stats increments from `monitorRelay`) would
    /// otherwise be silently overwritten when the stale copy is written back.
    @discardableResult
    private func mutateRelay(_ url: String, _ body: (inout Relay) -> Void) -> Relay? {
        guard var relay = relays[url] else { return nil }
        body(&relay)
        relays[url] = relay
        return relay
    }

    private func publishToRelay(_ event: NostrEvent, relay: Relay) async -> PublishResult {
        let startTime = Date()
        let relayURL = relay.url
        let eventId = event.id

        // Three paths can resume the continuation: the OK handler in `monitorRelay`,
        // the 5s timeout below, and the publish-failure branch. Because `publishEvent`
        // is an `await` on this actor, the OK handler can run (and remove+resume the
        // continuation) during that suspension. Every resume path must therefore claim
        // the continuation atomically via `removeValue(forKey:)`; whoever wins resumes
        // exactly once and everyone else becomes a no-op.
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<PublishResult, Never>) in
            if pendingOKResponses[relayURL] == nil {
                pendingOKResponses[relayURL] = [:]
            }
            pendingOKResponses[relayURL]?[eventId] = continuation

            Task {
                do {
                    try await relay.connection.publishEvent(event)

                    mutateRelay(relayURL) {
                        $0.stats.eventsSent += 1
                        $0.stats.lastActivity = Date()
                    }

                    try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s OK timeout

                    if let pending = pendingOKResponses[relayURL]?.removeValue(forKey: eventId) {
                        pending.resume(returning: PublishResult(
                            relay: relayURL,
                            success: false,
                            message: "Timeout waiting for OK response",
                            error: RelayError.timeout
                        ))
                    }
                } catch {
                    if let pending = pendingOKResponses[relayURL]?.removeValue(forKey: eventId) {
                        pending.resume(returning: PublishResult(
                            relay: relayURL,
                            success: false,
                            message: nil,
                            error: error
                        ))
                    }
                }
            }
        }

        // Update response time statistics
        if result.success {
            let responseTime = Date().timeIntervalSince(startTime)
            mutateRelay(relay.url) {
                $0.stats.averageResponseTime =
                    ($0.stats.averageResponseTime + responseTime) / 2
            }
        } else {
            await updateHealthScore(for: relay.url, eventType: .publishFailure)
        }

        return result
    }
    
    private func monitorRelay(url: String) async {
        guard let connection = relays[url]?.connection else { return }

        // Snapshot the messages stream for this connection. Each call to
        // `connect()` mints a fresh stream, so this loop is bound to
        // exactly one connection's lifetime; on disconnect it exits and the
        // next successful connect spawns a new monitor task.
        let stream = await connection.messages
        for await message in stream {
            // Stats update is done synchronously via the helper so any
            // concurrent mutation (e.g. `publishToRelay` bumping `eventsSent`)
            // isn't overwritten by a stale copy held across an await below.
            mutateRelay(url) { r in
                r.stats.lastActivity = Date()
                if case .event = message {
                    r.stats.eventsReceived += 1
                }
            }

            switch message {
            case .event(_, let event):
                if event.kind == EventKind.nwcResponse.rawValue {
                    poolLogger.debug("NWC response received - id: \(event.id.prefix(16)), from: \(event.pubkey.prefix(16))...")
                }
            case .notice(let notice):
                poolLogger.info("Notice from \(url): \(notice)")
            case .ok(let eventId, let accepted, let okMessage):
                if let pending = pendingOKResponses[url]?.removeValue(forKey: eventId) {
                    pending.resume(returning: PublishResult(
                        relay: url,
                        success: accepted,
                        message: okMessage,
                        error: accepted ? nil : RelayError.eventRejected(reason: okMessage)
                    ))
                }
                if !accepted {
                    poolLogger.warning("Event rejected by \(url): \(okMessage ?? "No reason")")
                    await updateHealthScore(for: url, eventType: .eventRejected)
                }
            case .closed(let subscriptionId, let closedMessage):
                poolLogger.info("Subscription \(subscriptionId) closed by \(url): \(closedMessage ?? "No reason")")
                handleServerClosedSubscription(subscriptionId, on: url, reason: closedMessage)
            default:
                break
            }

            // Forward message to relevant subscriptions
            for subscription in subscriptions.values {
                await subscription.handleMessage(message, from: url)
            }
        }

        // Connection dropped — this monitor task is done. Drop our handle so
        // a future `connect(to:)` doesn't see a stale entry, then optionally
        // schedule a reconnection that will spawn a fresh monitor on success.
        // A deliberate `disconnect(from:)` stays down: reconnecting after the
        // caller asked to disconnect would resurrect connections forever.
        mutateRelay(url) { $0.state = .disconnected }
        monitorTasks.removeValue(forKey: url)

        if configuration.autoReconnect && !intentionallyDisconnected.contains(url) {
            scheduleReconnection(for: url)
        }
    }

    /// A relay closed one of our subscriptions server-side (CLOSED message).
    ///
    /// Left alone this deafens the subscription on that relay even though the
    /// socket is healthy — fatal for long-lived listeners like a NIP-46
    /// bunker. Retry a bounded number of times; an `auth-required:` reason
    /// waits for the NIP-42 handshake (driven by the relay service's
    /// authenticator) before re-REQ-ing.
    private func handleServerClosedSubscription(_ subscriptionId: String, on url: String, reason: String?) {
        guard subscriptions[subscriptionId] != nil else { return }

        let attemptKey = "\(subscriptionId)|\(url)"
        let attempts = closedResubscribeAttempts[attemptKey, default: 0]
        guard attempts < 3 else {
            poolLogger.warning("Subscription \(subscriptionId) closed by \(url) \(attempts) times — not retrying")
            return
        }
        closedResubscribeAttempts[attemptKey] = attempts + 1

        let authRequired = reason?.hasPrefix("auth-required:") == true
        if authRequired && authenticator == nil {
            poolLogger.warning("\(url) requires NIP-42 auth for subscription \(subscriptionId) but no authenticator is set")
            return
        }

        // Detached so the monitor loop keeps draining messages while we wait;
        // the auth delay gives the relay service's AUTH round-trip time to
        // complete before the re-REQ.
        Task { [weak self] in
            try? await Task.sleep(for: authRequired ? .seconds(1) : .milliseconds(250))
            await self?.finishClosedResubscribe(subscriptionId, on: url)
        }
    }

    private func finishClosedResubscribe(_ subscriptionId: String, on url: String) async {
        guard let subscription = subscriptions[subscriptionId] else { return }
        guard relays[url]?.state == .connected else { return }
        await subscription.attachRelay(url)
    }

    /// Re-attaches every active subscription to a relay that just
    /// (re)connected. REQs reusing a subscription id replace the previous
    /// server-side subscription, so this is safe on fresh connects too.
    private func attachSubscriptions(to url: String) async {
        guard let relay = relays[url], relay.metadata?.read ?? true else { return }
        for subscription in subscriptions.values {
            await subscription.attachRelay(url)
        }
    }

    private func clearClosedResubscribeAttempts(for url: String) {
        let suffix = "|\(url)"
        for key in closedResubscribeAttempts.keys where key.hasSuffix(suffix) {
            closedResubscribeAttempts.removeValue(forKey: key)
        }
    }
    
    /// Schedules a backoff-delayed reconnect as a tracked, cancellable task.
    ///
    /// Task-based (rather than sleeping inline) so intentional disconnects and
    /// relay removal can cancel a pending timer, and so repeated failures
    /// chain through fresh tasks instead of recursing through an ever-growing
    /// await stack during long outages.
    private func scheduleReconnection(for url: String) {
        guard reconnectTasks[url] == nil else { return }
        guard !intentionallyDisconnected.contains(url) else { return }
        guard let updated = mutateRelay(url, { $0.state = .reconnecting }) else { return }

        let delay = min(
            configuration.initialReconnectDelay * pow(configuration.backoffMultiplier, Double(updated.failureCount)),
            configuration.maxReconnectDelay
        )

        reconnectTasks[url] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.performScheduledReconnect(for: url)
        }
    }

    private func performScheduledReconnect(for url: String) async {
        reconnectTasks[url] = nil
        guard relays[url]?.state == .reconnecting else { return }
        // A failed dial schedules the next attempt itself (with an increased
        // failure count feeding the backoff).
        try? await connect(to: url)
    }
    
    /// Adjusts a relay's `healthScore` (0.0–1.0) by a per-event-type delta and
    /// notifies the delegate if the score crosses the unhealthy threshold.
    ///
    /// The weights are tuned so that a single connection failure (−0.3)
    /// dominates several successes (+0.05 each), which pushes chronically
    /// flaky relays below `configuration.minHealthScore` quickly while
    /// transient blips recover within a few successful operations. The score
    /// is clamped to `[0, 1]` on each update.
    ///
    /// | Event                | Impact |
    /// |----------------------|--------|
    /// | connectionSuccess    | +0.10  |
    /// | connectionFailure    | −0.30  |
    /// | publishSuccess       | +0.05  |
    /// | publishFailure       | −0.10  |
    /// | subscriptionSuccess  | +0.05  |
    /// | subscriptionFailure  | −0.10  |
    /// | eventRejected        | −0.05  |
    /// | timeout              | −0.20  |
    private func updateHealthScore(for url: String, eventType: HealthEvent) async {
        let impact: Double
        switch eventType {
        case .connectionSuccess:
            impact = 0.1
        case .connectionFailure:
            impact = -0.3
        case .publishSuccess:
            impact = 0.05
        case .publishFailure:
            impact = -0.1
        case .subscriptionSuccess:
            impact = 0.05
        case .subscriptionFailure:
            impact = -0.1
        case .eventRejected:
            impact = -0.05
        case .timeout:
            impact = -0.2
        }

        guard let updated = mutateRelay(url, {
            $0.healthScore = max(0, min(1, $0.healthScore + impact))
        }) else { return }

        // Notify delegate if relay became unhealthy
        if updated.healthScore < configuration.minHealthScore {
            await delegate?.relayPool(self, relay: url, becameUnhealthyWithScore: updated.healthScore)
        }
    }
    
    private func fetchRelayInformation(for url: String) async {
        guard relays[url] != nil else { return }

        // Convert WebSocket URL to HTTP(S) URL
        var httpURL = url
        if httpURL.hasPrefix("wss://") {
            httpURL = httpURL.replacingOccurrences(of: "wss://", with: "https://")
        } else if httpURL.hasPrefix("ws://") {
            httpURL = httpURL.replacingOccurrences(of: "ws://", with: "http://")
        }

        // Ensure URL has trailing slash
        if !httpURL.hasSuffix("/") {
            httpURL += "/"
        }

        guard let infoURL = URL(string: httpURL) else { return }

        do {
            // Create request with Accept header for NIP-11
            var request = URLRequest(url: infoURL)
            request.setValue("application/nostr+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10.0

            let (data, response) = try await URLSession.shared.data(for: request)

            // Check response
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                relayLogger.warning("Failed to fetch relay information from \(url)")
                return
            }

            // Decode relay information
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let relayInfo = try decoder.decode(RelayInformation.self, from: data)

            // Write back through the helper — not through a stale `var` held
            // across the `URLSession` await above.
            mutateRelay(url) { $0.info = relayInfo }

            relayLogger.debug("Fetched relay information for \(url): \(relayInfo.name ?? "Unknown")")

        } catch {
            relayLogger.error("Error fetching relay information from \(url)", error: error)
        }
    }
    
    private enum HealthEvent {
        case connectionSuccess
        case connectionFailure
        case publishSuccess
        case publishFailure
        case subscriptionSuccess
        case subscriptionFailure
        case eventRejected
        case timeout
    }
}

// MARK: - PoolSubscription

/// A subscription that aggregates events from multiple relays
public actor PoolSubscription {
    /// Cap on remembered event ids for deduplication. Long-lived
    /// subscriptions (a NIP-46 bunker listens for days) would otherwise grow
    /// this set without bound. Oldest ids are evicted first; a relay
    /// re-delivering an event older than the window re-yields it, which
    /// consumers already tolerate far better than unbounded memory growth.
    private static let maxSeenEventIds = 4096

    nonisolated public let id: String
    nonisolated public let filters: [Filter]
    private weak var pool: RelayPool?
    private var relaySubscriptions: [String: Bool] = [:] // URL -> isEOSE
    private var seenEventIds: Set<String> = []
    private var seenEventOrder: [String] = []
    private let eventSubject = AsyncStream<NostrEvent>.makeStream()

    /// Stream of deduplicated events from all relays
    public var events: AsyncStream<NostrEvent> {
        eventSubject.stream
    }

    init(id: String, filters: [Filter], pool: RelayPool) {
        self.id = id
        self.filters = filters
        self.pool = pool
    }

    func subscribeToRelays(_ urls: [String]) async {
        for url in urls {
            await attachRelay(url)
        }
    }

    /// Sends this subscription's REQ to one connected relay.
    ///
    /// Called on initial subscribe AND every time a relay (re)connects —
    /// resetting the relay's EOSE flag so end-of-stored-events is tracked per
    /// connection, not per process lifetime. Re-REQ-ing an id the relay
    /// already knows simply replaces the server-side subscription (NIP-01).
    func attachRelay(_ url: String) async {
        guard let pool = pool else { return }
        guard let relay = await pool.getRelay(url),
              relay.state == .connected else { return }

        do {
            try await relay.connection.subscribe(id: id, filters: filters)
            relaySubscriptions[url] = false
        } catch {
            subscriptionLogger.warning("Failed to subscribe to \(url): \(error)")
        }
    }

    func handleMessage(_ message: RelayMessage, from url: String) async {
        switch message {
        case .event(let subId, let event):
            if subId == id {
                // Deduplicate events, bounding the memory used to remember them
                if seenEventIds.insert(event.id).inserted {
                    seenEventOrder.append(event.id)
                    trimSeenEventsIfNeeded()
                    // Log NWC response events for debugging
                    if event.kind == EventKind.nwcResponse.rawValue {
                        subscriptionLogger.debug("Yielding NWC response - subId: \(id.prefix(8)), eventId: \(event.id.prefix(16))")
                    }
                    eventSubject.continuation.yield(event)
                }
            }

        case .eose(let subId):
            if subId == id {
                relaySubscriptions[url] = true

                // Check if all relays have sent EOSE
                let allEOSE = relaySubscriptions.values.allSatisfy { $0 }
                if allEOSE, let pool = pool {
                    // All relays have sent their stored events
                    await pool.delegate?.relayPool(pool, subscription: id, receivedEOSEFromAllRelays: true)
                }
            }

        default:
            break
        }
    }

    /// Evicts the oldest remembered event ids once the cap is exceeded.
    /// Trims in batches so the O(n) array compaction amortizes instead of
    /// running on every event at the cap.
    private func trimSeenEventsIfNeeded() {
        guard seenEventOrder.count > Self.maxSeenEventIds + 512 else { return }
        let overflow = seenEventOrder.count - Self.maxSeenEventIds
        for evicted in seenEventOrder.prefix(overflow) {
            seenEventIds.remove(evicted)
        }
        seenEventOrder.removeFirst(overflow)
    }

    func removeRelay(url: String) async {
        relaySubscriptions.removeValue(forKey: url)
    }

    func close() async {
        guard let pool = pool else { return }

        // Close subscription on all relays
        for url in relaySubscriptions.keys {
            if let relay = await pool.getRelay(url),
               relay.state == .connected {
                try? await relay.connection.closeSubscription(id: id)
            }
        }

        eventSubject.continuation.finish()
    }
}

// MARK: - RelayPoolDelegate

/// Delegate protocol for relay pool events
public protocol RelayPoolDelegate: AnyObject, Sendable {
    /// Called when a relay connects successfully
    func relayPool(_ pool: RelayPool, didConnectTo relay: String) async
    
    /// Called when a relay disconnects
    func relayPool(_ pool: RelayPool, didDisconnectFrom relay: String) async
    
    /// Called when a relay becomes unhealthy
    func relayPool(_ pool: RelayPool, relay: String, becameUnhealthyWithScore score: Double) async
    
    /// Called when all relays in a subscription have sent EOSE
    func relayPool(_ pool: RelayPool, subscription: String, receivedEOSEFromAllRelays: Bool) async
}

// MARK: - Helper Extensions

extension RelayPool {
    /// Gets a relay by URL (internal use)
    func getRelay(_ url: String) -> Relay? {
        relays[url]
    }
}

// MARK: - Relay Information (NIP-11)

/// Information about a relay's capabilities and limitations
public struct RelayInformation: Codable, Sendable {
    public let name: String?
    public let description: String?
    public let pubkey: String?
    public let contact: String?
    public let supportedNips: [Int]?
    public let software: String?
    public let version: String?
    public let limitation: Limitation?
    
    public struct Limitation: Codable, Sendable {
        public let maxMessageLength: Int?
        public let maxSubscriptions: Int?
        public let maxFilters: Int?
        public let maxLimit: Int?
        public let maxSubidLength: Int?
        public let maxEventTags: Int?
        public let maxContentLength: Int?
        public let minPowDifficulty: Int?
        public let authRequired: Bool?
        public let paymentRequired: Bool?
        public let createdAtLowerLimit: Int?
        public let createdAtUpperLimit: Int?
        
        enum CodingKeys: String, CodingKey {
            case maxMessageLength = "max_message_length"
            case maxSubscriptions = "max_subscriptions"
            case maxFilters = "max_filters"
            case maxLimit = "max_limit"
            case maxSubidLength = "max_subid_length"
            case maxEventTags = "max_event_tags"
            case maxContentLength = "max_content_length"
            case minPowDifficulty = "min_pow_difficulty"
            case authRequired = "auth_required"
            case paymentRequired = "payment_required"
            case createdAtLowerLimit = "created_at_lower_limit"
            case createdAtUpperLimit = "created_at_upper_limit"
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case name
        case description
        case pubkey
        case contact
        case supportedNips = "supported_nips"
        case software
        case version
        case limitation
    }
}