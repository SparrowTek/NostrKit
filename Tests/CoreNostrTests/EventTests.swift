import Testing
import Foundation
@testable import CoreNostr

@Suite("Event Creation and Verification Tests")
struct EventTests {
    
    @Suite("Event Creation Tests")
    struct EventCreationTests {
        
        @Test("Create basic event")
        func testCreateBasicEvent() throws {
            let keyPair = try KeyPair.generate()
            let content = "Test content"
            let kind = EventKind.textNote
            let tags: [[String]] = [["t", "nostr"], ["t", "test"]]
            
            let event = try CoreNostr.createEvent(
                kind: kind,
                content: content,
                tags: tags,
                keyPair: keyPair
            )
            
            #expect(event.kind == kind.rawValue)
            #expect(event.content == content)
            #expect(event.tags == tags)
            #expect(event.pubkey == keyPair.publicKey)
            #expect(event.id.count == 64)
            #expect(event.sig.count == 128)
        }
        
        @Test("Create event with custom timestamp")
        func testCreateEventWithTimestamp() throws {
            let keyPair = try KeyPair.generate()
            let customDate = Date(timeIntervalSince1970: 1234567890)
            
            let event = try CoreNostr.createEvent(
                kind: .textNote,
                content: "Test",
                tags: [],
                keyPair: keyPair,
                createdAt: customDate
            )
            
            #expect(Date(timeIntervalSince1970: TimeInterval(event.createdAt)) == customDate)
        }
        
        @Test("Create metadata event")
        func testCreateMetadataEvent() throws {
            let keyPair = try KeyPair.generate()
            let metadata = UserMetadata(
                name: "Alice",
                displayName: "Alice in Nostrland",
                about: "Testing Nostr",
                picture: "https://example.com/alice.jpg",
                banner: "https://example.com/banner.jpg",
                nip05: "alice@example.com",
                lud16: "alice@walletofsatoshi.com"
            )
            
            let event = try CoreNostr.createMetadataEvent(
                metadata: metadata,
                keyPair: keyPair
            )
            
            #expect(event.kind == EventKind.setMetadata.rawValue)
            
            let decodedMetadata = try JSONDecoder().decode(UserMetadata.self, from: Data(event.content.utf8))
            #expect(decodedMetadata.name == metadata.name)
            #expect(decodedMetadata.displayName == metadata.displayName)
            #expect(decodedMetadata.about == metadata.about)
        }
        
        @Test("Create deletion event")
        func testCreateDeletionEvent() throws {
            let keyPair = try KeyPair.generate()
            let eventToDelete1 = String(repeating: "a", count: 64)
            let eventToDelete2 = String(repeating: "b", count: 64)
            
            let deletionEvent = try CoreNostr.createDeletionEvent(
                eventIds: [eventToDelete1, eventToDelete2],
                reason: "Mistake in content",
                keyPair: keyPair
            )
            
            #expect(deletionEvent.kind == EventKind.deletion.rawValue)
            #expect(deletionEvent.content == "Mistake in content")
            #expect(deletionEvent.tags.count == 2)
            #expect(deletionEvent.tags[0] == ["e", eventToDelete1])
            #expect(deletionEvent.tags[1] == ["e", eventToDelete2])
        }
    }
    
    @Suite("Event Signing Tests")
    struct EventSigningTests {
        
        @Test("Sign event with different keypairs")
        func testSignWithDifferentKeypairs() throws {
            let keyPair1 = try KeyPair()
            let keyPair2 = try KeyPair()
            
            let event1 = try CoreNostr.createTextNote(
                content: "Same content",
                keyPair: keyPair1
            )
            
            let event2 = try CoreNostr.createTextNote(
                content: "Same content",
                keyPair: keyPair2
            )
            
            #expect(event1.pubkey != event2.pubkey)
            #expect(event1.signature != event2.signature)
            #expect(event1.id != event2.id) // Different pubkey means different ID
        }
        
        @Test("Event ID calculation")
        func testEventIdCalculation() throws {
            let keyPair = try KeyPair.generate()
            let event = try CoreNostr.createTextNote(
                content: "Test",
                keyPair: keyPair,
                createdAt: Date(timeIntervalSince1970: 1234567890)
            )
            
            // Manually calculate event ID
            let serialized = [
                0,
                event.pubkey,
                Int(event.createdAt.timeIntervalSince1970),
                event.kind.rawValue,
                event.tags,
                event.content
            ] as [Any]
            
            let jsonData = try JSONSerialization.data(withJSONObject: serialized, options: [.sortedKeys, .withoutEscapingSlashes])
            let hash = NostrCrypto.sha256(jsonData)
            let calculatedId = hash.hex
            
            #expect(event.id.hex == calculatedId)
        }
        
        @Test("Signature verification internals")
        func testSignatureVerificationInternals() throws {
            let keyPair = try KeyPair.generate()
            let event = try CoreNostr.createTextNote(
                content: "Verify me",
                keyPair: keyPair
            )
            
            // Verify signature manually
            let publicKey = try secp256k1.Signing.XonlyKey(
                rawRepresentation: Data(hex: event.pubkey)!
            )
            
            let signature = try secp256k1.Signing.SchnorrSignature(
                rawRepresentation: Data(hex: event.signature.hex)!
            )
            
            let messageData = Data(hex: event.id.hex)!
            let isValid = publicKey.isValidSignature(signature, for: messageData)
            
            #expect(isValid == true)
        }
    }
    
    @Suite("Event Verification Tests")
    struct EventVerificationTests {
        
        @Test("Verify valid event")
        func testVerifyValidEvent() throws {
            let keyPair = try KeyPair.generate()
            let event = try CoreNostr.createTextNote(
                content: "Valid event",
                keyPair: keyPair
            )
            
            let isValid = try CoreNostr.verifyEvent(event)
            #expect(isValid == true)
        }
        
        @Test("Verify event with tampered content")
        func testVerifyTamperedContent() throws {
            let keyPair = try KeyPair.generate()
            var event = try CoreNostr.createTextNote(
                content: "Original content",
                keyPair: keyPair
            )
            
            // Tamper with content
            event = NostrEvent(
                id: event.id,
                pubkey: event.pubkey,
                createdAt: event.createdAt,
                kind: event.kind,
                tags: event.tags,
                content: "Tampered content", // Changed
                signature: event.signature
            )
            
            let isValid = try CoreNostr.verifyEvent(event)
            #expect(isValid == false)
        }
        
        @Test("Verify event with wrong signature")
        func testVerifyWrongSignature() throws {
            let keyPair = try KeyPair.generate()
            var event = try CoreNostr.createTextNote(
                content: "Test content",
                keyPair: keyPair
            )
            
            // Replace signature with a different one
            let otherKeyPair = try KeyPair()
            let otherEvent = try CoreNostr.createTextNote(
                content: "Different",
                keyPair: otherKeyPair
            )
            
            event = NostrEvent(
                id: event.id,
                pubkey: event.pubkey,
                createdAt: event.createdAt,
                kind: event.kind,
                tags: event.tags,
                content: event.content,
                signature: otherEvent.signature // Wrong signature
            )
            
            let isValid = try CoreNostr.verifyEvent(event)
            #expect(isValid == false)
        }
        
        @Test("Verify event with invalid ID")
        func testVerifyInvalidId() throws {
            let keyPair = try KeyPair.generate()
            var event = try CoreNostr.createTextNote(
                content: "Test",
                keyPair: keyPair
            )
            
            // Change the ID
            event = NostrEvent(
                id: EventID(hex: String(repeating: "f", count: 64)), // Wrong ID
                pubkey: event.pubkey,
                createdAt: event.createdAt,
                kind: event.kind,
                tags: event.tags,
                content: event.content,
                signature: event.signature
            )
            
            let isValid = try CoreNostr.verifyEvent(event)
            #expect(isValid == false)
        }
    }
    
    @Suite("Event Filtering Tests")
    struct EventFilteringTests {
        
        @Test("Filter matches event")
        func testFilterMatches() throws {
            let keyPair = try KeyPair.generate()
            let event = try CoreNostr.createTextNote(
                content: "Hello world",
                keyPair: keyPair,
                tags: [["t", "greeting"]]
            )
            
            // Filter by author
            var filter = Filter(authors: [keyPair.publicKey.hex])
            #expect(filter.matches(event) == true)
            
            // Filter by kind
            filter = Filter(kinds: [.textNote])
            #expect(filter.matches(event) == true)
            
            // Filter by tag
            filter = Filter(tags: ["t": ["greeting"]])
            #expect(filter.matches(event) == true)
            
            // Filter that doesn't match
            filter = Filter(authors: [String(repeating: "z", count: 64)])
            #expect(filter.matches(event) == false)
        }
        
        @Test("Filter with time range")
        func testFilterTimeRange() throws {
            let keyPair = try KeyPair.generate()
            let now = Date()
            let event = try CoreNostr.createTextNote(
                content: "Now",
                keyPair: keyPair,
                createdAt: now
            )
            
            // Event is within range
            var filter = Filter(
                since: now.addingTimeInterval(-3600), // 1 hour ago
                until: now.addingTimeInterval(3600)   // 1 hour from now
            )
            #expect(filter.matches(event) == true)
            
            // Event is outside range
            filter = Filter(
                since: now.addingTimeInterval(3600),   // 1 hour from now
                until: now.addingTimeInterval(7200)    // 2 hours from now
            )
            #expect(filter.matches(event) == false)
        }
        
        @Test("Complex filter combinations")
        func testComplexFilter() throws {
            let keyPair = try KeyPair.generate()
            let event = try CoreNostr.createTextNote(
                content: "Complex event",
                keyPair: keyPair,
                tags: [
                    ["t", "nostr"],
                    ["p", String(repeating: "a", count: 64)]
                ]
            )
            
            let filter = Filter(
                authors: [keyPair.publicKey.hex],
                kinds: [.textNote],
                tags: [
                    "t": ["nostr"],
                    "p": [String(repeating: "a", count: 64)]
                ]
            )
            
            #expect(filter.matches(event) == true)
        }
    }
    
    @Suite("Event Serialization Tests")
    struct EventSerializationTests {
        
        @Test("Serialize to JSON")
        func testSerializeToJSON() throws {
            let keyPair = try KeyPair.generate()
            let event = try CoreNostr.createTextNote(
                content: "Serialize me",
                keyPair: keyPair,
                tags: [["e", String(repeating: "a", count: 64)]]
            )
            
            let json = try event.jsonString()
            
            #expect(json.contains("\"id\":\""))
            #expect(json.contains("\"pubkey\":\""))
            #expect(json.contains("\"created_at\":"))
            #expect(json.contains("\"kind\":1"))
            #expect(json.contains("\"content\":\"Serialize me\""))
            #expect(json.contains("\"sig\":\""))
        }
        
        @Test("Deserialize from JSON")
        func testDeserializeFromJSON() throws {
            let keyPair = try KeyPair.generate()
            let originalEvent = try CoreNostr.createTextNote(
                content: "Original",
                keyPair: keyPair,
                createdAt: Date(timeIntervalSince1970: 1234567890),
                tags: [["t", "test"]]
            )
            
            let json = try originalEvent.jsonString()
            let data = Data(json.utf8)
            let decodedEvent = try JSONDecoder().decode(NostrEvent.self, from: data)
            
            #expect(decodedEvent.id == originalEvent.id)
            #expect(decodedEvent.pubkey == originalEvent.pubkey)
            #expect(decodedEvent.createdAt == originalEvent.createdAt)
            #expect(decodedEvent.kind == originalEvent.kind)
            #expect(decodedEvent.content == originalEvent.content)
            #expect(decodedEvent.tags == originalEvent.tags)
            #expect(decodedEvent.signature == originalEvent.signature)
        }
        
        @Test("Round-trip serialization preserves event")
        func testRoundTripSerialization() throws {
            let keyPair = try KeyPair.generate()
            let event = try CoreNostr.createEvent(
                kind: .reaction,
                content: "🚀",
                tags: [
                    ["e", String(repeating: "b", count: 64)],
                    ["p", String(repeating: "c", count: 64)],
                    ["emoji", "rocket", "https://example.com/rocket.png"]
                ],
                keyPair: keyPair
            )
            
            // Serialize and deserialize
            let json = try event.jsonString()
            let data = Data(json.utf8)
            let deserializedEvent = try JSONDecoder().decode(NostrEvent.self, from: data)
            
            // Verify it's still valid
            let isValid = try CoreNostr.verifyEvent(deserializedEvent)
            #expect(isValid == true)
            
            // Verify all fields match
            #expect(deserializedEvent.id == event.id)
            #expect(deserializedEvent.pubkey == event.pubkey)
            #expect(deserializedEvent.content == event.content)
            #expect(deserializedEvent.tags == event.tags)
        }
    }
}

// Helper struct for metadata testing
struct UserMetadata: Codable {
    let name: String?
    let displayName: String?
    let about: String?
    let picture: String?
    let banner: String?
    let nip05: String?
    let lud16: String?
    
    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case about
        case picture
        case banner
        case nip05
        case lud16
    }
}