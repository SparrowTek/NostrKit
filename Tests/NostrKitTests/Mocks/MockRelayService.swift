import Foundation
import CoreNostr
@testable import NostrKit

protocol RelayServiceProtocol: Actor {
    var url: URL { get }
    var state: NostrKit.RelayPool.ConnectionState { get }
    func connect() async throws
    func disconnect() async
    func send(_ message: ClientMessage) async throws
    func subscribe(filters: [Filter], id: String) async throws
    func closeSubscription(id: String) async
}

actor MockRelayService: RelayServiceProtocol {
    let url: URL
    private(set) var state: NostrKit.RelayPool.ConnectionState = .disconnected
    private var mockResponses: [String: [RelayMessage]] = [:]
    private var mockEvents: [NostrEvent] = []
    private var shouldFailConnection = false
    private var connectionDelay: TimeInterval = 0.01
    
    init(url: URL) {
        self.url = url
    }
    
    func setMockEvents(_ events: [NostrEvent]) {
        mockEvents = events
    }
    
    func setConnectionFailure(_ shouldFail: Bool) {
        shouldFailConnection = shouldFail
    }
    
    func setConnectionDelay(_ delay: TimeInterval) {
        connectionDelay = delay
    }
    
    func connect() async throws {
        state = .connecting
        
        if shouldFailConnection {
            state = .disconnected
            throw NostrError.networkError(
                operation: .connect,
                reason: "Mock connection failure"
            )
        }
        
        try await Task.sleep(nanoseconds: UInt64(connectionDelay * 1_000_000_000))
        state = .connected
    }
    
    func disconnect() async {
        state = .disconnected
        mockResponses.removeAll()
    }
    
    func send(_ message: ClientMessage) async throws {
        guard state == .connected else {
            throw NostrError.networkError(
                operation: .send,
                reason: "Not connected"
            )
        }
        
        switch message {
        case .event(let event):
            // Simulate OK response for event publishing
            let okMessage = RelayMessage.ok(
                eventId: event.id,
                accepted: true,
                message: "Mock: Event accepted"
            )
            // Store for later retrieval if needed
            mockResponses["event-\(event.id)"] = [okMessage]
            
        case .req(let subscriptionId, let filters):
            // Store mock events as responses for this subscription
            var responses: [RelayMessage] = []
            
            for event in mockEvents {
                // Simple filter matching - just check if event matches any filter
                if matchesAnyFilter(event: event, filters: filters) {
                    responses.append(.event(subscriptionId: subscriptionId, event: event))
                }
            }
            
            // Add EOSE at the end
            responses.append(.eose(subscriptionId: subscriptionId))
            mockResponses[subscriptionId] = responses
            
        case .close(let subscriptionId):
            mockResponses.removeValue(forKey: subscriptionId)
        }
    }
    
    func subscribe(filters: [Filter], id: String) async throws {
        try await send(.req(subscriptionId: id, filters: filters))
    }
    
    func closeSubscription(id: String) async {
        try? await send(.close(subscriptionId: id))
    }
    
    func getMockResponses(for subscriptionId: String) -> [RelayMessage] {
        return mockResponses[subscriptionId] ?? []
    }
    
    private func matchesAnyFilter(event: NostrEvent, filters: [Filter]) -> Bool {
        for filter in filters {
            // Simple matching logic - can be expanded as needed
            
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