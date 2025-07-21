import Foundation
import CoreNostr

/// Manages multiple subscriptions efficiently with automatic renewal, caching, and optimization.
///
/// SubscriptionManager provides high-level subscription management with features like:
/// - Automatic subscription renewal
/// - Result caching and deduplication
/// - Subscription merging for efficiency
/// - EOSE tracking for data loading
/// - Automatic cleanup of inactive subscriptions
///
/// ## Example
/// ```swift
/// let manager = SubscriptionManager(relayPool: pool, cache: cache)
/// 
/// // Create a managed subscription
/// let subscription = try await manager.subscribe(
///     query: QueryBuilder().kinds(.textNote).limit(50),
///     options: .init(autoRenew: true, cacheResults: true)
/// )
/// 
/// // Listen for events
/// for await event in subscription.events {
///     print("New event: \(event.content)")
/// }
/// ```
public actor SubscriptionManager {
    
    // MARK: - Types
    
    /// A managed subscription with additional features
    public struct ManagedSubscription {
        /// Unique subscription ID
        public let id: String
        
        /// The underlying pool subscription
        public let poolSubscription: PoolSubscription
        
        /// Original filters
        public let filters: [Filter]
        
        /// Subscription options
        public let options: SubscriptionOptions
        
        /// Creation time
        public let createdAt: Date
        
        /// Last activity time
        public var lastActivity: Date
        
        /// Whether EOSE has been received from all relays
        public var isEOSE: Bool = false
        
        /// Number of events received
        public var eventCount: Int = 0
        
        /// Stream of events from this subscription
        public let events: AsyncStream<NostrEvent>
        
        /// Continuation for the event stream
        fileprivate let continuation: AsyncStream<NostrEvent>.Continuation
    }
    
    /// Options for subscription behavior
    public struct SubscriptionOptions: Sendable {
        /// Whether to automatically renew the subscription
        public let autoRenew: Bool
        
        /// Whether to cache received events
        public let cacheResults: Bool
        
        /// Whether to deduplicate events across subscriptions
        public let deduplicate: Bool
        
        /// Timeout for considering subscription inactive
        public let inactivityTimeout: TimeInterval
        
        /// Whether to automatically close after EOSE
        public let closeAfterEOSE: Bool
        
        /// Maximum number of events to buffer
        public let maxBufferSize: Int
        
        /// Priority for subscription ordering
        public let priority: SubscriptionPriority
        
        public init(
            autoRenew: Bool = true,
            cacheResults: Bool = true,
            deduplicate: Bool = true,
            inactivityTimeout: TimeInterval = 300, // 5 minutes
            closeAfterEOSE: Bool = false,
            maxBufferSize: Int = 1000,
            priority: SubscriptionPriority = .normal
        ) {
            self.autoRenew = autoRenew
            self.cacheResults = cacheResults
            self.deduplicate = deduplicate
            self.inactivityTimeout = inactivityTimeout
            self.closeAfterEOSE = closeAfterEOSE
            self.maxBufferSize = maxBufferSize
            self.priority = priority
        }
        
        /// Default options for real-time subscriptions
        public static let realtime = SubscriptionOptions(
            autoRenew: true,
            cacheResults: true,
            closeAfterEOSE: false,
            priority: .high
        )
        
        /// Default options for one-time queries
        public static let oneTime = SubscriptionOptions(
            autoRenew: false,
            cacheResults: true,
            closeAfterEOSE: true,
            priority: .normal
        )
        
        /// Default options for background sync
        public static let background = SubscriptionOptions(
            autoRenew: true,
            cacheResults: true,
            inactivityTimeout: 600,
            priority: .low
        )
    }
    
    /// Subscription priority levels
    public enum SubscriptionPriority: Int, Sendable, Comparable {
        case low = 0
        case normal = 1
        case high = 2
        case critical = 3
        
        public static func < (lhs: SubscriptionPriority, rhs: SubscriptionPriority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
    
    /// Statistics about managed subscriptions
    public struct Statistics: Sendable {
        public let activeSubscriptions: Int
        public let totalEventsReceived: Int
        public let cachedEvents: Int
        public let duplicatesFiltered: Int
        public let subscriptionsMerged: Int
        public let oldestSubscription: Date?
        public let averageEventsPerSubscription: Double
    }
    
    // MARK: - Properties
    
    private let relayPool: RelayPool
    private let cache: EventCache?
    private var subscriptions: [String: ManagedSubscription] = [:]
    private var mergedSubscriptions: [String: Set<String>] = [:] // merged ID -> original IDs
    private var seenEventIds: Set<String> = []
    private var stats = ManagerStats()
    private var cleanupTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    /// Creates a new subscription manager
    /// - Parameters:
    ///   - relayPool: The relay pool to use for subscriptions
    ///   - cache: Optional event cache for storing results
    public init(relayPool: RelayPool, cache: EventCache? = nil) {
        self.relayPool = relayPool
        self.cache = cache
        
        // Start cleanup task
        Task {
            await startCleanupTask()
        }
    }
    
    deinit {
        cleanupTask?.cancel()
    }
    
    // MARK: - Subscription Management
    
    /// Creates a managed subscription
    /// - Parameters:
    ///   - filters: Filters for the subscription
    ///   - options: Subscription options
    ///   - id: Optional subscription ID
    /// - Returns: A managed subscription
    public func subscribe(
        filters: [Filter],
        options: SubscriptionOptions = .realtime,
        id: String? = nil
    ) async throws -> ManagedSubscription {
        let subscriptionId = id ?? UUID().uuidString
        
        // Check for mergeable subscriptions
        if options.deduplicate {
            if let merged = findMergeableSubscription(for: filters) {
                return try await mergeIntoExisting(merged, filters: filters, id: subscriptionId)
            }
        }
        
        // Create new pool subscription
        let poolSubscription = try await relayPool.subscribe(
            filters: filters,
            id: subscriptionId
        )
        
        // Create event stream
        var continuation: AsyncStream<NostrEvent>.Continuation?
        let events = AsyncStream<NostrEvent> { cont in
            continuation = cont
        }
        
        let managed = ManagedSubscription(
            id: subscriptionId,
            poolSubscription: poolSubscription,
            filters: filters,
            options: options,
            createdAt: Date(),
            lastActivity: Date(),
            events: events,
            continuation: continuation!
        )
        
        subscriptions[subscriptionId] = managed
        
        // Start monitoring the subscription
        Task {
            await monitorSubscription(managed)
        }
        
        return managed
    }
    
    /// Creates a managed subscription using a query builder
    /// - Parameters:
    ///   - query: Query builder
    ///   - options: Subscription options
    ///   - id: Optional subscription ID
    /// - Returns: A managed subscription
    public func subscribe(
        query: QueryBuilder,
        options: SubscriptionOptions = .realtime,
        id: String? = nil
    ) async throws -> ManagedSubscription {
        try await subscribe(
            filters: [query.build()],
            options: options,
            id: id
        )
    }
    
    /// Creates multiple managed subscriptions
    /// - Parameters:
    ///   - queries: Array of query builders
    ///   - options: Subscription options
    /// - Returns: Array of managed subscriptions
    public func subscribeMany(
        queries: [QueryBuilder],
        options: SubscriptionOptions = .realtime
    ) async throws -> [ManagedSubscription] {
        var subscriptions: [ManagedSubscription] = []
        
        for query in queries {
            let subscription = try await subscribe(
                query: query,
                options: options
            )
            subscriptions.append(subscription)
        }
        
        return subscriptions
    }
    
    /// Closes a subscription
    /// - Parameter id: Subscription ID to close
    public func closeSubscription(_ id: String) async {
        guard let managed = subscriptions[id] else { return }
        
        await relayPool.closeSubscription(id: managed.poolSubscription.id)
        managed.continuation.finish()
        subscriptions.removeValue(forKey: id)
        
        // Clean up merged subscriptions
        for (mergedId, originalIds) in mergedSubscriptions {
            if originalIds.contains(id) {
                var updatedIds = originalIds
                updatedIds.remove(id)
                
                if updatedIds.isEmpty {
                    mergedSubscriptions.removeValue(forKey: mergedId)
                    if subscriptions[mergedId] != nil {
                        await closeSubscription(mergedId)
                    }
                } else {
                    mergedSubscriptions[mergedId] = updatedIds
                }
            }
        }
    }
    
    /// Closes all subscriptions
    public func closeAll() async {
        let allIds = Array(subscriptions.keys)
        for id in allIds {
            await closeSubscription(id)
        }
    }
    
    /// Renews a subscription
    /// - Parameter id: Subscription ID to renew
    public func renewSubscription(_ id: String) async throws {
        guard var managed = subscriptions[id] else {
            throw NostrError.notFound(resource: "Subscription with ID \(id)")
        }
        
        // Close old pool subscription
        await relayPool.closeSubscription(id: managed.poolSubscription.id)
        
        // Create new pool subscription
        let newPoolSubscription = try await relayPool.subscribe(
            filters: managed.filters,
            id: id
        )
        
        // Update managed subscription
        managed = ManagedSubscription(
            id: managed.id,
            poolSubscription: newPoolSubscription,
            filters: managed.filters,
            options: managed.options,
            createdAt: managed.createdAt,
            lastActivity: Date(),
            isEOSE: false,
            eventCount: managed.eventCount,
            events: managed.events,
            continuation: managed.continuation
        )
        
        subscriptions[id] = managed
    }
    
    // MARK: - Query Methods
    
    /// Gets current statistics
    public func statistics() async -> Statistics {
        let activeCount = subscriptions.count
        let totalEvents = subscriptions.values.reduce(0) { $0 + $1.eventCount }
        let avgEvents = activeCount > 0 ? Double(totalEvents) / Double(activeCount) : 0
        let oldest = subscriptions.values.map { $0.createdAt }.min()
        
        return Statistics(
            activeSubscriptions: activeCount,
            totalEventsReceived: stats.totalEventsReceived,
            cachedEvents: stats.cachedEvents,
            duplicatesFiltered: stats.duplicatesFiltered,
            subscriptionsMerged: stats.subscriptionsMerged,
            oldestSubscription: oldest,
            averageEventsPerSubscription: avgEvents
        )
    }
    
    /// Gets active subscriptions
    public func activeSubscriptions() -> [ManagedSubscription] {
        Array(subscriptions.values)
    }
    
    /// Gets subscription by ID
    public func subscription(id: String) -> ManagedSubscription? {
        subscriptions[id]
    }
    
    // MARK: - Private Methods
    
    private func monitorSubscription(_ subscription: ManagedSubscription) async {
        for await event in await subscription.poolSubscription.events {
            await handleEvent(event, for: subscription)
        }
        
        // Subscription ended
        if subscription.options.autoRenew {
            try? await renewSubscription(subscription.id)
        } else {
            await closeSubscription(subscription.id)
        }
    }
    
    private func handleEvent(_ event: NostrEvent, for subscription: ManagedSubscription) async {
        // Update activity
        if var managed = subscriptions[subscription.id] {
            managed.lastActivity = Date()
            managed.eventCount += 1
            subscriptions[subscription.id] = managed
        }
        
        stats.totalEventsReceived += 1
        
        // Deduplicate if enabled
        if subscription.options.deduplicate {
            if seenEventIds.contains(event.id) {
                stats.duplicatesFiltered += 1
                return
            }
            seenEventIds.insert(event.id)
            
            // Keep seen events set from growing too large
            if seenEventIds.count > 100_000 {
                seenEventIds.removeAll()
            }
        }
        
        // Cache if enabled
        if subscription.options.cacheResults, let cache = cache {
            _ = try? await cache.store(event)
            stats.cachedEvents += 1
        }
        
        // Yield to subscription stream
        subscription.continuation.yield(event)
        
        // Yield to any merged subscriptions
        if let originalIds = mergedSubscriptions.first(where: { $0.key == subscription.id })?.value {
            for originalId in originalIds {
                if let original = subscriptions[originalId] {
                    original.continuation.yield(event)
                }
            }
        }
    }
    
    private func findMergeableSubscription(for filters: [Filter]) -> ManagedSubscription? {
        // Simple merging strategy: find subscriptions with similar filters
        for subscription in subscriptions.values {
            if canMerge(filters: filters, with: subscription.filters) {
                return subscription
            }
        }
        return nil
    }
    
    private func canMerge(filters: [Filter], with existing: [Filter]) -> Bool {
        // Simple merge check - can be made more sophisticated
        // For now, only merge if they have the same kinds and no specific IDs
        guard filters.count == 1 && existing.count == 1 else { return false }
        
        let filter = filters[0]
        let existingFilter = existing[0]
        
        // Don't merge if querying specific IDs
        if filter.ids != nil || existingFilter.ids != nil { return false }
        
        // Check if kinds match
        let kindsMatch = filter.kinds == existingFilter.kinds
        
        // Check if time ranges overlap significantly
        let timeOverlap = timeRangesOverlap(filter, existingFilter)
        
        return kindsMatch && timeOverlap
    }
    
    private func timeRangesOverlap(_ filter1: Filter, _ filter2: Filter) -> Bool {
        // If either has no time constraints, they overlap
        if (filter1.since == nil && filter1.until == nil) ||
           (filter2.since == nil && filter2.until == nil) {
            return true
        }
        
        // Check for actual overlap
        let start1 = filter1.since.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date.distantPast
        let end1 = filter1.until.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date.distantFuture
        let start2 = filter2.since.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date.distantPast
        let end2 = filter2.until.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date.distantFuture
        
        return start1 <= end2 && start2 <= end1
    }
    
    private func mergeIntoExisting(
        _ existing: ManagedSubscription,
        filters: [Filter],
        id: String
    ) async throws -> ManagedSubscription {
        // Track the merge
        if mergedSubscriptions[existing.id] == nil {
            mergedSubscriptions[existing.id] = Set([existing.id])
        }
        mergedSubscriptions[existing.id]?.insert(id)
        
        stats.subscriptionsMerged += 1
        
        // Create a virtual subscription that shares the same pool subscription
        var continuation: AsyncStream<NostrEvent>.Continuation?
        let events = AsyncStream<NostrEvent> { cont in
            continuation = cont
        }
        
        let merged = ManagedSubscription(
            id: id,
            poolSubscription: existing.poolSubscription,
            filters: filters,
            options: existing.options,
            createdAt: Date(),
            lastActivity: Date(),
            events: events,
            continuation: continuation!
        )
        
        subscriptions[id] = merged
        
        return merged
    }
    
    private func startCleanupTask() {
        cleanupTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 1 minute
                await performCleanup()
            }
        }
    }
    
    private func performCleanup() async {
        let now = Date()
        var toClose: [String] = []
        
        for (id, subscription) in subscriptions {
            // Check inactivity
            let inactiveTime = now.timeIntervalSince(subscription.lastActivity)
            if inactiveTime > subscription.options.inactivityTimeout {
                toClose.append(id)
                continue
            }
            
            // Check EOSE closure
            if subscription.options.closeAfterEOSE && subscription.isEOSE {
                toClose.append(id)
                continue
            }
        }
        
        // Close inactive subscriptions
        for id in toClose {
            await closeSubscription(id)
        }
    }
}

// MARK: - Supporting Types

private struct ManagerStats {
    var totalEventsReceived: Int = 0
    var cachedEvents: Int = 0
    var duplicatesFiltered: Int = 0
    var subscriptionsMerged: Int = 0
}

// MARK: - RelayPoolDelegate Extension

extension SubscriptionManager: RelayPoolDelegate {
    
    public func relayPool(_ pool: RelayPool, didConnectTo relay: String) async {
        // Resubscribe active subscriptions on new relay connections
        for subscription in subscriptions.values where subscription.options.autoRenew {
            // The pool will handle resubscription internally
        }
    }
    
    public func relayPool(_ pool: RelayPool, didDisconnectFrom relay: String) async {
        // No action needed - pool handles reconnection
    }
    
    public func relayPool(_ pool: RelayPool, relay: String, becameUnhealthyWithScore score: Double) async {
        // Log unhealthy relay
        print("[SubscriptionManager] Relay \(relay) became unhealthy with score \(score)")
    }
    
    public func relayPool(_ pool: RelayPool, subscription: String, receivedEOSEFromAllRelays: Bool) async {
        // Mark subscription as EOSE
        if var managed = subscriptions[subscription] {
            managed.isEOSE = true
            subscriptions[subscription] = managed
            
            // Close if configured
            if managed.options.closeAfterEOSE {
                await closeSubscription(subscription)
            }
        }
    }
}

// MARK: - Convenience Extensions

extension SubscriptionManager {
    
    /// Creates a one-time query subscription that closes after EOSE
    /// - Parameters:
    ///   - query: Query builder
    ///   - timeout: Maximum time to wait for results
    /// - Returns: Array of events
    public func query(
        _ query: QueryBuilder,
        timeout: TimeInterval = 10
    ) async throws -> [NostrEvent] {
        let subscription = try await subscribe(
            query: query,
            options: .oneTime
        )
        
        var events: [NostrEvent] = []
        
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await closeSubscription(subscription.id)
        }
        
        for await event in subscription.events {
            events.append(event)
        }
        
        timeoutTask.cancel()
        
        return events
    }
    
    /// Creates a real-time subscription for a specific author
    /// - Parameters:
    ///   - author: The author's public key
    ///   - kinds: Event kinds to filter
    /// - Returns: Managed subscription
    public func subscribeToAuthor(
        _ author: PublicKey,
        kinds: [EventKind]? = nil
    ) async throws -> ManagedSubscription {
        let query = QueryBuilder()
            .authors(author)
        
        let finalQuery = kinds.map { query.kinds($0) } ?? query
        
        return try await subscribe(query: finalQuery)
    }
    
    /// Creates a real-time subscription for mentions
    /// - Parameter pubkey: The public key to watch for mentions
    /// - Returns: Managed subscription
    public func subscribeToMentions(
        of pubkey: PublicKey
    ) async throws -> ManagedSubscription {
        let query = QueryBuilder()
            .referencingUsers(pubkey)
            .kinds(.textNote)
        
        return try await subscribe(query: query)
    }
}