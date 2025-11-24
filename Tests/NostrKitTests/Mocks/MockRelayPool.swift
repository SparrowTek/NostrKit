import Foundation
import CoreNostr
@testable import NostrKit

// Protocol to define what we need from RelayPool for testing
protocol RelayPoolProtocol {
    func addRelay(_ url: URL) async throws
    func removeRelay(_ url: URL) async
    func publish(_ event: NostrEvent) async -> [(relayURL: URL, success: Bool, error: Error?)]
    func subscribe(filters: [Filter], id: String) async throws -> MockSubscriptionResult
    func closeSubscription(id: String) async
    func closeAllSubscriptions() async
    func getConnectedRelays() -> [URL]
    func getHealthyRelays() -> [URL]
}

// Simple subscription result that mocks PoolSubscription behavior
struct MockSubscriptionResult {
    let id: String
    let filters: [Filter]
    let events: AsyncStream<NostrEvent>
}

actor MockRelayPool: RelayPoolProtocol, WalletRelayPool {
    private var mockEvents: [NostrEvent] = []
    private var mockRelays: [URL: MockRelayService] = [:]
    private var activeSubscriptions: [String: MockSubscription] = [:]
    private var shouldFailPublish = false
    private var publishDelay: TimeInterval = 0.01
    private var responseFactory: ((NostrEvent) -> NostrEvent?)?
    private(set) var publishedEvents: [NostrEvent] = []
    
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
    
    func setResponseFactory(_ factory: @escaping (NostrEvent) -> NostrEvent?) {
        responseFactory = factory
    }
    
    func addRelay(url: String) async throws {
        guard let parsed = URL(string: url) else {
            throw NostrError.invalidURI(uri: url, reason: "Invalid mock relay URL")
        }
        try await addRelay(parsed)
    }
    
    func addRelay(_ url: URL) async throws {
        let mockRelay = MockRelayService(url: url)
        await mockRelay.setMockEvents(mockEvents)
        try await mockRelay.connect()
        mockRelays[url] = mockRelay
    }
    
    func removeRelay(_ url: URL) async {
        if let relay = mockRelays[url] {
            await relay.disconnect()
            mockRelays.removeValue(forKey: url)
        }
    }
    
    nonisolated func connectAll() async {
        // Mocks eagerly connect in addRelay
    }
    
    func publish(_ event: NostrEvent) async -> [RelayPool.PublishResult] {
        var results: [RelayPool.PublishResult] = []
        publishedEvents.append(event)
        
        // Simulate publish delay
        try? await Task.sleep(nanoseconds: UInt64(publishDelay * 1_000_000_000))
        
        if shouldFailPublish {
            for url in mockRelays.keys {
                results.append(
                    RelayPool.PublishResult(
                        relay: url.absoluteString,
                        success: false,
                        message: nil,
                        error: NostrError.networkError(
                            operation: .send,
                            reason: "Mock publish failure"
                        )
                    )
                )
            }
        } else {
            for (url, relay) in mockRelays {
                do {
                    try await relay.send(.event(event))
                    
                    if let response = responseFactory?(event) {
                        for (id, subscription) in activeSubscriptions {
                            if matchesAnyFilter(event: response, filters: subscription.filters) {
                                subscription.continuation.yield(response)
                            }
                            // Keep stream open for further events
                            activeSubscriptions[id] = subscription
                        }
                    }
                    
                    results.append(
                        RelayPool.PublishResult(
                            relay: url.absoluteString,
                            success: true,
                            message: nil,
                            error: nil
                        )
                    )
                } catch {
                    results.append(
                        RelayPool.PublishResult(
                            relay: url.absoluteString,
                            success: false,
                            message: nil,
                            error: error
                        )
                    )
                }
            }
        }
        
        return results
    }
    
    func subscribe(filters: [Filter], id: String) async throws -> MockSubscriptionResult {
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
        return MockSubscriptionResult(
            id: id,
            filters: filters,
            events: stream
        )
    }
    
    func walletSubscribe(filters: [Filter], id: String? = nil) async throws -> WalletSubscription {
        let subId = id ?? UUID().uuidString
        let subscription = try await subscribe(filters: filters, id: subId)
        return WalletSubscription(id: subscription.id, events: subscription.events)
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
    
    nonisolated func getConnectedRelays() -> [URL] {
        return [] // Simplified for mock - would need proper actor access in real implementation
    }
    
    nonisolated func getHealthyRelays() -> [URL] {
        return [] // Simplified for mock - would need proper actor access in real implementation
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
                if !kinds.contains(event.kind) {
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
            
            // Check e tags (event references)
            if let eventIds = filter.e, !eventIds.isEmpty {
                let referencedEvents = event.tags
                    .filter { $0.count >= 2 && $0[0] == "e" }
                    .map { $0[1] }
                
                if !eventIds.contains(where: { referencedEvents.contains($0) }) {
                    continue
                }
            }
            
            // Check p tags (pubkey references)
            if let pubkeys = filter.p, !pubkeys.isEmpty {
                let referencedPubkeys = event.tags
                    .filter { $0.count >= 2 && $0[0] == "p" }
                    .map { $0[1] }
                
                if !pubkeys.contains(where: { referencedPubkeys.contains($0) }) {
                    continue
                }
            }
            
            // If we got here, this filter matches
            return true
        }
        
        return false
    }
}

// Note: PoolSubscription is an actor and doesn't support convenience initializers
// We'll work with the existing initializer in the actor
