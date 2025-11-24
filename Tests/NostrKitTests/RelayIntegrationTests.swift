import Testing
import Foundation
@testable import NostrKit
@testable import CoreNostr

@Suite("Relay Integration Tests", .serialized, .disabled("Requires external relays; skipped in sandboxed/test environments"))
struct RelayIntegrationTests {
    
    // Mock relay URLs for testing
    let testRelayURL = "wss://relay.damus.io"
    let invalidRelayURL = "wss://invalid.relay.test"
    
    @Suite("RelayService Connection Tests")
    struct ConnectionTests {
        
        @Test("Connect to relay", .timeLimit(.minutes(1)))
        func testConnectToRelay() async throws {
            let relay = RelayService(url: "wss://relay.damus.io")
            
            try await relay.connect()
            
            // Give it a moment to establish connection
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            
            // The relay should be connected
            // Note: We can't directly check connection state without exposing it
            // But we can try to disconnect without error
            await relay.disconnect()
        }
        
        @Test("Handle invalid relay URL")
        func testInvalidRelayURL() async throws {
            // Test invalid scheme
            let relay1 = RelayService(url: "https://relay.damus.io")
            await #expect(throws: RelayServiceError.self) {
                try await relay1.connect()
            }
            
            // Test malformed URL
            let relay2 = RelayService(url: "not a valid url")
            await #expect(throws: RelayServiceError.self) {
                try await relay2.connect()
            }
        }
        
        @Test("Disconnect from relay")
        func testDisconnect() async throws {
            let relay = RelayService(url: "wss://relay.damus.io")
            
            try await relay.connect()
            await relay.disconnect()
            
            // Should be able to reconnect after disconnect
            try await relay.connect()
            await relay.disconnect()
        }
    }
    
    @Suite("Message Exchange Tests")
    struct MessageTests {
        
        @Test("Send event to relay", .timeLimit(.minutes(1)))
        func testSendEvent() async throws {
            let relay = RelayService(url: "wss://relay.damus.io")
            let keyPair = try CoreNostr.createKeyPair()
            actor EventState {
                private(set) var receivedOK = false
                private(set) var receivedEventId: String?
                private(set) var acceptedEvent = false
                private(set) var errorMessage: String?
                
                func record(eventId: String, accepted: Bool, message: String?) {
                    receivedOK = true
                    receivedEventId = eventId
                    acceptedEvent = accepted
                    errorMessage = message
                }
                
                func snapshot() -> (Bool, String?, Bool, String?) {
                    (receivedOK, receivedEventId, acceptedEvent, errorMessage)
                }
            }
            let state = EventState()
            
            let event = try CoreNostr.createTextNote(
                keyPair: keyPair,
                content: "NostrKit integration test: \(UUID().uuidString)"
            )
            
            try await relay.connect()
            
            // Set up message stream handler
            Task {
                let stream = await relay.messages
                for await message in stream {
                    if case let .ok(eventId, accepted, msg) = message {
                        await state.record(eventId: eventId, accepted: accepted, message: msg)
                        break
                    }
                }
            }
            
            // Send the event
            try await relay.publishEvent(event)
            
            // Wait for OK response
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            
            let snapshot = await state.snapshot()
            #expect(snapshot.0 == true)
            #expect(snapshot.1 == event.id)
            if !snapshot.2, let errorMessage = snapshot.3 {
                print("Relay rejected event with message: \(errorMessage)")
            }
            // Some relays may reject events from new/unknown pubkeys
            // or have other policies. We'll consider it a pass if we got a response.
            #expect(snapshot.0 == true)
            
            await relay.disconnect()
        }
        
        @Test("Subscribe to events", .timeLimit(.minutes(1)))
        func testSubscription() async throws {
            let relay = RelayService(url: "wss://relay.damus.io")
            
            try await relay.connect()
            
            actor SubscriptionState {
                private(set) var receivedEvents: [NostrEvent] = []
                private(set) var receivedEOSE = false
                
                func add(event: NostrEvent) {
                    receivedEvents.append(event)
                }
                
                func setEOSE() { receivedEOSE = true }
                
                func snapshot() -> ([NostrEvent], Bool) {
                    (receivedEvents, receivedEOSE)
                }
            }
            let state = SubscriptionState()
            
            let subscriptionId = "test-sub-\(UUID().uuidString)"
            let filter = Filter(
                kinds: [EventKind.textNote.rawValue],
                limit: 5
            )

            // Set up message stream handler
            Task {
                let stream = await relay.messages
                for await message in stream {
                    switch message {
                    case let .event(subId, event):
                        if subId == subscriptionId {
                            await state.add(event: event)
                        }
                    case let .eose(subId):
                        if subId == subscriptionId {
                            await state.setEOSE()
                        }
                    default:
                        break
                    }
                }
            }
            
            // Subscribe
            try await relay.subscribe(id: subscriptionId, filters: [filter])
            
            // Wait for EOSE
            try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            
            let snapshot = await state.snapshot()
            #expect(snapshot.1 == true)
            #expect(snapshot.0.count > 0)
            // Relays may return slightly more than the limit
            #expect(snapshot.0.count <= 10) // Allow some flexibility
            
            // All events should be text notes
            for event in snapshot.0 {
                #expect(event.kind == EventKind.textNote.rawValue)
            }
            
            // Close subscription
            try await relay.closeSubscription(id: subscriptionId)
            
            await relay.disconnect()
        }
        
        @Test("Handle multiple subscriptions", .timeLimit(.minutes(1)))
        func testMultipleSubscriptions() async throws {
            let relay = RelayService(url: "wss://relay.damus.io")
            
            try await relay.connect()
            
            let sub1 = "sub1-\(UUID().uuidString)"
            let sub2 = "sub2-\(UUID().uuidString)"
            
            let filter1 = Filter(kinds: [EventKind.textNote.rawValue], limit: 3)
            let filter2 = Filter(kinds: [EventKind.setMetadata.rawValue], limit: 3)
            
            actor MultiSubState {
                private(set) var events1: [NostrEvent] = []
                private(set) var events2: [NostrEvent] = []
                
                func add(subId: String, event: NostrEvent, sub1: String, sub2: String) {
                    if subId == sub1 {
                        events1.append(event)
                    } else if subId == sub2 {
                        events2.append(event)
                    }
                }
                
                func snapshot() -> ([NostrEvent], [NostrEvent]) {
                    (events1, events2)
                }
            }
            let state = MultiSubState()
            
            // Set up message handler
            Task {
                let stream = await relay.messages
                for await message in stream {
                    if case let .event(subId, event) = message {
                        await state.add(subId: subId, event: event, sub1: sub1, sub2: sub2)
                    }
                }
            }
            
            // Subscribe to both
            try await relay.subscribe(id: sub1, filters: [filter1])
            try await relay.subscribe(id: sub2, filters: [filter2])
            
            // Wait for events
            try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            
            let snapshot = await state.snapshot()
            // Should have received events for both subscriptions
            #expect(snapshot.0.count > 0)
            #expect(snapshot.1.count > 0)
            
            // Events should match their filters
            for event in snapshot.0 {
                #expect(event.kind == EventKind.textNote.rawValue)
            }
            for event in snapshot.1 {
                #expect(event.kind == EventKind.setMetadata.rawValue)
            }
            
            // Clean up
            try await relay.closeSubscription(id: sub1)
            try await relay.closeSubscription(id: sub2)
            await relay.disconnect()
        }
    }
    
    @Suite("Error Handling Tests")
    struct ErrorTests {
        
        @Test("Handle relay notices")
        func testRelayNotices() async throws {
            let relay = RelayService(url: "wss://relay.damus.io")
            
            try await relay.connect()
            
            // Try to subscribe with an invalid filter that might trigger a notice
            // Using empty subscription ID which some relays reject
            do {
                try await relay.subscribe(id: "", filters: [])
            } catch {
                // Expected to fail
            }
            
            // Give relay time to send notice
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            
            // Note: Not all relays send notices for all errors
            // This test might not always receive a notice
            
            await relay.disconnect()
        }
        
        @Test("Handle connection drops", .timeLimit(.minutes(1)))
        func testConnectionResilience() async throws {
            // Test multiple connections to the same relay
            let relay1 = RelayService(url: "wss://relay.damus.io")
            
            try await relay1.connect()
            
            // Simulate some activity
            let filter = Filter(kinds: [EventKind.textNote.rawValue], limit: 1)
            try await relay1.subscribe(id: "test-sub", filters: [filter])
            
            // Disconnect
            await relay1.disconnect()
            
            // Create a new relay service instance for reconnection
            // (RelayService doesn't support reconnection after disconnect)
            let relay2 = RelayService(url: "wss://relay.damus.io")
            try await relay2.connect()
            
            // And resubscribe
            try await relay2.subscribe(id: "test-sub-2", filters: [filter])
            
            await relay2.disconnect()
        }
    }
    
    @Suite("Performance Tests")
    struct PerformanceTests {
        
        @Test("Send multiple events rapidly", .timeLimit(.minutes(2)))
        func testRapidEventSending() async throws {
            let relay = RelayService(url: "wss://relay.damus.io")
            let keyPair = try CoreNostr.createKeyPair()
            
            try await relay.connect()
            
            let eventCount = 10
            var sentEvents: [NostrEvent] = []
            
            actor OKCounter {
                private(set) var count = 0
                func increment() { count += 1 }
                func value() -> Int { count }
            }
            let okCounter = OKCounter()
            
            // Set up OK counter
            Task {
                let stream = await relay.messages
                for await message in stream {
                    if case .ok = message {
                        await okCounter.increment()
                    }
                }
            }
            
            // Send events rapidly
            for i in 0..<eventCount {
                let event = try CoreNostr.createTextNote(
                    keyPair: keyPair,
                    content: "Rapid test event #\(i): \(UUID().uuidString)"
                )
                sentEvents.append(event)
                try await relay.publishEvent(event)
            }
            
            // Wait for all OKs
            try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            
            // Should have received OK for most/all events
            // Some relays might rate limit, so we check for at least half
            let okCount = await okCounter.value()
            #expect(okCount >= eventCount / 2)
            
            await relay.disconnect()
        }
        
        @Test("Handle large subscription results", .timeLimit(.minutes(1)))
        func testLargeSubscription() async throws {
            let relay = RelayService(url: "wss://relay.damus.io")
            
            try await relay.connect()
            
            // Request a large number of events
            let filter = Filter(
                kinds: [EventKind.textNote.rawValue],
                limit: 100
            )
            
            actor LargeSubState {
                private(set) var eventCount = 0
                private(set) var receivedEOSE = false
                
                func increment() { eventCount += 1 }
                func setEOSE() { receivedEOSE = true }
                func snapshot() -> (Int, Bool) { (eventCount, receivedEOSE) }
            }
            let state = LargeSubState()
            
            // Count events
            Task {
                let stream = await relay.messages
                for await message in stream {
                    switch message {
                    case .event:
                        await state.increment()
                    case .eose:
                        await state.setEOSE()
                    default:
                        break
                    }
                }
            }
            
            try await relay.subscribe(id: "large-sub", filters: [filter])
            
            // Wait for EOSE
            try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            
            let snapshot = await state.snapshot()
            #expect(snapshot.1 == true)
            #expect(snapshot.0 > 0)
            // Relays may return slightly more than the limit
            #expect(snapshot.0 <= 110) // Allow 10% margin
            
            await relay.disconnect()
        }
    }
}

// Test helpers
extension RelayService {
    /// Helper to wait for a specific message type
    func waitForMessage(
        matching predicate: @escaping (RelayMessage) -> Bool,
        timeout: TimeInterval = 5.0
    ) async throws -> RelayMessage? {
        let start = Date()
        
        for await message in messages {
            if predicate(message) {
                return message
            }
            
            if Date().timeIntervalSince(start) > timeout {
                break
            }
        }
        
        return nil
    }
}
