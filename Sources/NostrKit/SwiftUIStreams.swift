import Foundation
import SwiftUI
import Combine
import CoreNostr

/// SwiftUI-friendly wrapper for NostrKit event streams
@MainActor
@Observable
public class NostrEventStream {
    
    // MARK: - Published Properties
    
    public private(set) var events: [NostrEvent] = []
    public private(set) var isLoading = false
    public private(set) var error: Error?
    public private(set) var connectionState: ConnectionState = .disconnected
    
    // MARK: - Properties
    
    private let relayPool: RelayPool
    private var subscriptions: [String: PoolSubscription] = [:]
    private var eventTasks: [String: Task<Void, Never>] = [:]
    private let bufferSize: Int
    private let deduplicationWindow: TimeInterval
    private var seenEventIds: Set<EventID> = []
    private var eventTimestamps: [EventID: Date] = [:]
    
    // MARK: - Initialization
    
    public init(
        relayPool: RelayPool,
        bufferSize: Int = 1000,
        deduplicationWindow: TimeInterval = 300 // 5 minutes
    ) {
        self.relayPool = relayPool
        self.bufferSize = bufferSize
        self.deduplicationWindow = deduplicationWindow
    }
    
    deinit {
//        for task in eventTasks.values {
//            task.cancel()
//        }
    }
    
    // MARK: - Public Methods
    
    /// Subscribes to events matching the filter
    public func subscribe(
        to filter: Filter,
        id: String? = nil
    ) async {
        let subscriptionId = id ?? UUID().uuidString
        
        isLoading = true
        error = nil
        
        do {
            let subscription = try await relayPool.subscribe(filters: [filter], id: subscriptionId)
            subscriptions[subscriptionId] = subscription
            await startListening(subscription: subscription, id: subscriptionId)
        } catch {
            self.error = error
            isLoading = false
        }
    }
    
    /// Subscribes to multiple filters
    public func subscribe(
        to filters: [Filter],
        id: String? = nil
    ) async {
        let subscriptionId = id ?? UUID().uuidString
        
        isLoading = true
        error = nil
        
        do {
            let subscription = try await relayPool.subscribe(filters: filters, id: subscriptionId)
            subscriptions[subscriptionId] = subscription
            await startListening(subscription: subscription, id: subscriptionId)
        } catch {
            self.error = error
            isLoading = false
        }
    }
    
    /// Unsubscribes from a specific subscription
    public func unsubscribe(id: String) async {
        subscriptions.removeValue(forKey: id)
        eventTasks[id]?.cancel()
        eventTasks.removeValue(forKey: id)
        
        await relayPool.closeSubscription(id: id)
    }
    
    /// Unsubscribes from all subscriptions
    public func unsubscribeAll() async {
        for (id, _) in subscriptions {
            await relayPool.closeSubscription(id: id)
        }
        subscriptions.removeAll()
        
        for task in eventTasks.values {
            task.cancel()
        }
        eventTasks.removeAll()
    }
    
    /// Publishes an event to all connected relays
    public func publish(_ event: NostrEvent) async {
        let results = await relayPool.publish(event)
        
        // Check if any publish failed
        for result in results {
            if !result.success {
                self.error = NostrKitError.publishFailed(
                    eventId: event.id,
                    message: result.message ?? "Unknown error"
                )
                break
            }
        }
    }
    
    /// Clears all cached events
    public func clearEvents() {
        events.removeAll()
        seenEventIds.removeAll()
        eventTimestamps.removeAll()
    }
    
    /// Clears the current error
    public func clearError() {
        error = nil
    }
    
    // MARK: - Private Methods
    
    private func startListening(subscription: PoolSubscription, id: String) async {
        guard eventTasks[id] == nil else { return }
        
        let task = Task { [weak self] in
            guard let self = self else { return }
            
            await self.listenForEvents(subscription: subscription, id: id)
        }
        
        eventTasks[id] = task
    }
    
    private func listenForEvents(subscription: PoolSubscription, id: String) async {
        isLoading = true
        
        for await event in await subscription.events {
            await addEvent(event)
        }
        
        isLoading = false
    }
    
    private func addEvent(_ event: NostrEvent) async {
        // Deduplicate
        guard !seenEventIds.contains(event.id) else { return }
        
        seenEventIds.insert(event.id)
        eventTimestamps[event.id] = Date()
        
        // Add to events array
        events.append(event)
        
        // Maintain buffer size
        if events.count > bufferSize {
            let removeCount = events.count - bufferSize
            events.removeFirst(removeCount)
        }
        
        // Clean old deduplication entries
        await cleanOldDeduplicationEntries()
    }
    
    private func cleanOldDeduplicationEntries() async {
        let cutoff = Date().addingTimeInterval(-deduplicationWindow)
        
        eventTimestamps = eventTimestamps.filter { _, timestamp in
            timestamp > cutoff
        }
        
        seenEventIds = Set(eventTimestamps.keys)
    }
}

// MARK: - Event Query Builder

/// Fluent API for building event queries
public class EventQueryBuilder {
    private var filters: [Filter] = []
    
    public init() {}
    
    /// Adds a filter for specific authors
    @discardableResult
    public func authors(_ pubkeys: [PublicKey]) -> EventQueryBuilder {
        filters.append(Filter(authors: pubkeys))
        return self
    }
    
    /// Adds a filter for specific event kinds
    @discardableResult
    public func kinds(_ kinds: [Int]) -> EventQueryBuilder {
        filters.append(Filter(kinds: kinds))
        return self
    }
    
    /// Adds a time range filter
    @discardableResult
    public func timeRange(from: Date? = nil, to: Date? = nil) -> EventQueryBuilder {
        filters.append(Filter(since: from, until: to))
        return self
    }
    
    /// Adds a filter for events referencing specific events
    @discardableResult
    public func referencingEvents(_ eventIds: [EventID]) -> EventQueryBuilder {
        filters.append(Filter(e: eventIds))
        return self
    }
    
    /// Adds a filter for events mentioning specific users
    @discardableResult
    public func mentioningUsers(_ pubkeys: [PublicKey]) -> EventQueryBuilder {
        filters.append(Filter(p: pubkeys))
        return self
    }
    
    /// Adds a search filter (NIP-50)
    @discardableResult
    public func search(_ query: String) -> EventQueryBuilder {
        filters.append(Filter(search: query))
        return self
    }
    
    /// Limits the number of results
    @discardableResult
    public func limit(_ count: Int) -> EventQueryBuilder {
        if var lastFilter = filters.last {
            filters.removeLast()
            lastFilter.limit = count
            filters.append(lastFilter)
        } else {
            filters.append(Filter(limit: count))
        }
        return self
    }
    
    /// Builds the final filter array
    public func build() -> [Filter] {
        filters.isEmpty ? [Filter()] : filters
    }
}

// MARK: - Async Stream Extensions

extension RelayPool {
    /// Returns an async stream of events for a specific filter
    public func events(
        for filter: Filter,
        subscriptionId: String? = nil
    ) -> AsyncThrowingStream<NostrEvent, Error> {
        let id = subscriptionId ?? UUID().uuidString
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let subscription = try await subscribe(filters: [filter], id: id)
                    
                    for await event in await subscription.events {
                        continuation.yield(event)
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    /// Returns an async stream of events for the current user
    public func userEvents(
        pubkey: PublicKey,
        kinds: [Int]? = nil
    ) -> AsyncThrowingStream<NostrEvent, Error> {
        let filter = Filter(
            authors: [pubkey],
            kinds: kinds
        )
        
        return events(for: filter)
    }
    
    /// Returns an async stream of mentions for a user
    public func mentions(
        for pubkey: PublicKey
    ) -> AsyncThrowingStream<NostrEvent, Error> {
        let filter = Filter(
            kinds: [1], // Text notes
            p: [pubkey]
        )
        
        return events(for: filter)
    }
    
    /// Returns an async stream of replies to an event
    public func replies(
        to eventId: EventID
    ) -> AsyncThrowingStream<NostrEvent, Error> {
        let filter = Filter(
            kinds: [1], // Text notes
            e: [eventId]
        )
        
        return events(for: filter)
    }
}
