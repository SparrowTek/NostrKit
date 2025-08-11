import Foundation
import CoreNostr
@testable import NostrKit

actor MockRelayPool {
    private var mockEvents: [NostrEvent] = []
    private var mockRelays: [URL: MockRelayService] = [:]
    private var activeSubscriptions: [String: MockSubscription] = [:]
    private var shouldFailPublish = false
    private var publishDelay: TimeInterval = 0.01
    
    struct MockSubscription {
        let id: String
        let filters: [Filter]
        let events: AsyncStream<NostrEvent>
        let continuation: AsyncStream<NostrEvent>.Continuation
    }
    
    init() {}
    
    func setMockEvents(_ events: [NostrEvent]) {
        mockEvents = events
    }
    
    func setPublishFailure(_ shouldFail: Bool) {
        shouldFailPublish = shouldFail
    }
    
    func setPublishDelay(_ delay: TimeInterval) {
        publishDelay = delay
    }
    
    func addRelay(_ url: URL) async throws {
        let mockRelay = MockRelayService(url: url)
        mockRelay.setMockEvents(mockEvents)
        try await mockRelay.connect()
        mockRelays[url] = mockRelay
    }
    
    func removeRelay(_ url: URL) async {
        if let relay = mockRelays[url] {
            await relay.disconnect()
            mockRelays.removeValue(forKey: url)
        }
    }
    
    func publish(_ event: NostrEvent) async -> [(relayURL: URL, success: Bool, error: Error?)] {
        var results: [(relayURL: URL, success: Bool, error: Error?)] = []
        
        // Simulate publish delay
        try? await Task.sleep(nanoseconds: UInt64(publishDelay * 1_000_000_000))
        
        if shouldFailPublish {
            for url in mockRelays.keys {
                results.append((
                    relayURL: url,
                    success: false,
                    error: NostrError.networkError(
                        operation: .send,
                        reason: "Mock publish failure"
                    )
                ))
            }
        } else {
            for (url, relay) in mockRelays {
                do {
                    try await relay.send(.event(event))
                    results.append((relayURL: url, success: true, error: nil))
                } catch {
                    results.append((relayURL: url, success: false, error: error))
                }
            }
        }
        
        return results
    }
    
    func subscribe(filters: [Filter], id: String) async throws -> RelayPool.Subscription {
        // Create async stream for events
        let (stream, continuation) = AsyncStream<NostrEvent>.makeStream()
        
        let mockSubscription = MockSubscription(
            id: id,
            filters: filters,
            events: stream,
            continuation: continuation
        )
        
        activeSubscriptions[id] = mockSubscription
        
        // Send matching events
        Task {
            for event in mockEvents {
                if matchesAnyFilter(event: event, filters: filters) {
                    continuation.yield(event)
                }
            }
            
            // Don't finish the stream immediately - keep it open for tests
            // continuation.finish()
        }
        
        // Create and return a subscription object
        return RelayPool.Subscription(
            id: id,
            filters: filters,
            events: stream
        )
    }
    
    func closeSubscription(id: String) async {
        if let subscription = activeSubscriptions[id] {
            subscription.continuation.finish()
            activeSubscriptions.removeValue(forKey: id)
        }
        
        // Close on all relays
        for relay in mockRelays.values {
            await relay.closeSubscription(id: id)
        }
    }
    
    func closeAllSubscriptions() async {
        for id in activeSubscriptions.keys {
            await closeSubscription(id: id)
        }
    }
    
    func getConnectedRelays() -> [URL] {
        return Array(mockRelays.keys)
    }
    
    func getHealthyRelays() -> [URL] {
        return mockRelays.compactMap { url, relay in
            // In mock, all connected relays are "healthy"
            return url
        }
    }
    
    func simulateIncomingEvent(_ event: NostrEvent, forSubscription subscriptionId: String) {
        if let subscription = activeSubscriptions[subscriptionId] {
            // Check if event matches filters
            if matchesAnyFilter(event: event, filters: subscription.filters) {
                subscription.continuation.yield(event)
            }
        }
    }
    
    private func matchesAnyFilter(event: NostrEvent, filters: [Filter]) -> Bool {
        for filter in filters {
            // Simple matching logic
            
            // Check event IDs
            if let ids = filter.ids, !ids.isEmpty {
                if !ids.contains(event.id) {
                    continue
                }
            }
            
            // Check authors
            if let authors = filter.authors, !authors.isEmpty {
                if !authors.contains(event.pubkey) {
                    continue
                }
            }
            
            // Check kinds
            if let kinds = filter.kinds, !kinds.isEmpty {
                if !kinds.contains(event.kind.rawValue) {
                    continue
                }
            }
            
            // Check created_at times
            if let since = filter.since {
                if event.createdAt < since {
                    continue
                }
            }
            
            if let until = filter.until {
                if event.createdAt > until {
                    continue
                }
            }
            
            // Check tags
            if let tags = filter.tags {
                var allTagsMatch = true
                for (tagName, tagValues) in tags {
                    let eventTagValues = event.tags
                        .filter { $0.name == tagName }
                        .flatMap { $0.values }
                    
                    if !tagValues.contains(where: { eventTagValues.contains($0) }) {
                        allTagsMatch = false
                        break
                    }
                }
                if !allTagsMatch {
                    continue
                }
            }
            
            // If we got here, this filter matches
            return true
        }
        
        return false
    }
}

// Extension to make RelayPool.Subscription initializable for mocks
extension RelayPool.Subscription {
    init(id: String, filters: [Filter], events: AsyncStream<NostrEvent>) {
        self.id = id
        self.filters = filters
        self.events = events
    }
}