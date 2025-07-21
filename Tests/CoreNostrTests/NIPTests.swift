import Testing
import Foundation
@testable import CoreNostr

@Suite("NIP Implementation Tests")
struct NIPTests {
    
    @Suite("NIP-01 Basic Protocol Tests")
    struct NIP01Tests {
        
        @Test("Create and verify text note event")
        func testTextNoteEvent() throws {
            let keyPair = try KeyPair()
            let content = "Hello, Nostr!"
            
            let event = try CoreNostr.createTextNote(
                content: content,
                keyPair: keyPair
            )
            
            #expect(event.kind == .textNote)
            #expect(event.content == content)
            #expect(event.pubkey == keyPair.publicKey.hex)
            
            let isValid = try CoreNostr.verifyEvent(event)
            #expect(isValid == true)
        }
        
        @Test("Event serialization format")
        func testEventSerialization() throws {
            let keyPair = try KeyPair()
            let event = try CoreNostr.createTextNote(
                content: "Test",
                keyPair: keyPair,
                createdAt: Date(timeIntervalSince1970: 1234567890)
            )
            
            let json = try event.jsonString()
            #expect(json.contains("\"kind\":1"))
            #expect(json.contains("\"created_at\":1234567890"))
            #expect(json.contains("\"content\":\"Test\""))
        }
    }
    
    @Suite("NIP-02 Follow List Tests")
    struct NIP02Tests {
        
        @Test("Create follow list")
        func testCreateFollowList() throws {
            let keyPair = try KeyPair()
            let followList = NostrFollowList(
                entries: [
                    FollowEntry(pubkey: PublicKey(hex: String(repeating: "a", count: 64)), relay: nil, petname: nil),
                    FollowEntry(pubkey: PublicKey(hex: String(repeating: "b", count: 64)), relay: "wss://relay.damus.io", petname: "Alice")
                ]
            )
            
            let event = try CoreNostr.createFollowListEvent(
                followList: followList,
                keyPair: keyPair
            )
            
            #expect(event.kind == .followList)
            #expect(event.tags.count == 2)
            #expect(event.tags[0][0] == "p")
            #expect(event.tags[1][0] == "p")
            #expect(event.tags[1].count == 4) // ["p", pubkey, relay, petname]
        }
        
        @Test("Parse follow list from event")
        func testParseFollowList() throws {
            let keyPair = try KeyPair()
            let originalList = NostrFollowList(
                entries: [
                    FollowEntry(pubkey: PublicKey(hex: String(repeating: "c", count: 64)), relay: "wss://nostr.wine", petname: "Bob")
                ]
            )
            
            let event = try CoreNostr.createFollowListEvent(
                followList: originalList,
                keyPair: keyPair
            )
            
            let parsedList = try NostrFollowList(from: event)
            
            #expect(parsedList.entries.count == 1)
            #expect(parsedList.entries[0].pubkey.hex == String(repeating: "c", count: 64))
            #expect(parsedList.entries[0].relay == "wss://nostr.wine")
            #expect(parsedList.entries[0].petname == "Bob")
        }
    }
    
    @Suite("NIP-05 DNS Verification Tests")
    struct NIP05Tests {
        
        @Test("Parse NIP-05 identifier")
        func testParseIdentifier() throws {
            let identifier = try NostrNIP05Identifier("alice@example.com")
            
            #expect(identifier.localPart == "alice")
            #expect(identifier.domain == "example.com")
            #expect(identifier.description == "alice@example.com")
        }
        
        @Test("Parse underscore identifier")
        func testParseUnderscoreIdentifier() throws {
            let identifier = try NostrNIP05Identifier("_@example.com")
            
            #expect(identifier.localPart == "_")
            #expect(identifier.domain == "example.com")
        }
        
        @Test("Invalid identifier formats")
        func testInvalidIdentifiers() {
            #expect(throws: NostrError.self) {
                _ = try NostrNIP05Identifier("notvalid")
            }
            
            #expect(throws: NostrError.self) {
                _ = try NostrNIP05Identifier("@example.com")
            }
            
            #expect(throws: NostrError.self) {
                _ = try NostrNIP05Identifier("alice@")
            }
        }
        
        @Test("NIP-05 response parsing")
        func testResponseParsing() throws {
            let json = """
            {
                "names": {
                    "alice": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    "_": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                },
                "relays": {
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": ["wss://relay1.com", "wss://relay2.com"]
                }
            }
            """
            
            let data = Data(json.utf8)
            let response = try JSONDecoder().decode(NostrNIP05Response.self, from: data)
            
            #expect(response.names.count == 2)
            #expect(response.names["alice"] == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            #expect(response.relays?["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]?.count == 2)
        }
    }
    
    @Suite("NIP-10 Reply Threading Tests")
    struct NIP10Tests {
        
        @Test("Create reply with NIP-10 tags")
        func testCreateReply() throws {
            let keyPair = try KeyPair()
            let rootEventId = EventID(hex: String(repeating: "a", count: 64))
            let replyToEventId = EventID(hex: String(repeating: "b", count: 64))
            
            let replyTags = NIP10.createReplyTags(
                rootEvent: rootEventId,
                replyToEvent: replyToEventId,
                mentionedEvents: []
            )
            
            #expect(replyTags.count == 2)
            #expect(replyTags[0] == ["e", rootEventId.hex, "", "root"])
            #expect(replyTags[1] == ["e", replyToEventId.hex, "", "reply"])
        }
        
        @Test("Parse thread from event")
        func testParseThread() throws {
            let event = NostrEvent(
                id: EventID(hex: String(repeating: "c", count: 64)),
                pubkey: PublicKey(hex: String(repeating: "d", count: 64)),
                createdAt: Date(),
                kind: .textNote,
                tags: [
                    ["e", String(repeating: "a", count: 64), "wss://relay.com", "root"],
                    ["e", String(repeating: "b", count: 64), "", "reply"],
                    ["e", String(repeating: "e", count: 64)]
                ],
                content: "Reply content",
                signature: Signature(hex: String(repeating: "f", count: 128))
            )
            
            let thread = NIP10.parseThread(from: event)
            
            #expect(thread.root?.eventId.hex == String(repeating: "a", count: 64))
            #expect(thread.root?.relay == "wss://relay.com")
            #expect(thread.replyTo?.eventId.hex == String(repeating: "b", count: 64))
            #expect(thread.mentions.count == 1)
            #expect(thread.mentions[0].eventId.hex == String(repeating: "e", count: 64))
        }
    }
    
    @Suite("NIP-19 Bech32 Encoding Tests")
    struct NIP19Tests {
        
        @Test("Encode and decode npub")
        func testNpub() throws {
            let publicKey = PublicKey(hex: String(repeating: "a", count: 64))
            let npub = publicKey.npub
            
            #expect(npub.starts(with: "npub1"))
            
            let decoded = try PublicKey(npub: npub)
            #expect(decoded.hex == publicKey.hex)
        }
        
        @Test("Encode and decode nsec")
        func testNsec() throws {
            let privateKey = PrivateKey(hex: String(repeating: "b", count: 64))
            let nsec = privateKey.nsec
            
            #expect(nsec.starts(with: "nsec1"))
            
            let decoded = try PrivateKey(nsec: nsec)
            #expect(decoded.hex == privateKey.hex)
        }
        
        @Test("Encode and decode note")
        func testNote() throws {
            let eventId = EventID(hex: String(repeating: "c", count: 64))
            let note = eventId.note
            
            #expect(note.starts(with: "note1"))
            
            let decoded = try EventID(note: note)
            #expect(decoded.hex == eventId.hex)
        }
        
        @Test("Encode and decode nprofile")
        func testNProfile() throws {
            let profile = NProfile(
                pubkey: PublicKey(hex: String(repeating: "d", count: 64)),
                relays: ["wss://relay1.com", "wss://relay2.com"]
            )
            
            let encoded = try profile.bech32String()
            #expect(encoded.starts(with: "nprofile1"))
            
            if case let .nprofile(decoded) = try Bech32Entity.decode(encoded) {
                #expect(decoded.pubkey.hex == profile.pubkey.hex)
                #expect(decoded.relays == profile.relays)
            } else {
                Issue.record("Failed to decode nprofile")
            }
        }
    }
    
    @Suite("NIP-25 Reactions Tests")
    struct NIP25Tests {
        
        @Test("Create reaction event")
        func testCreateReaction() throws {
            let keyPair = try KeyPair()
            let reactingTo = EventID(hex: String(repeating: "a", count: 64))
            let reactingToPubkey = PublicKey(hex: String(repeating: "b", count: 64))
            
            let reaction = try NIP25.createReaction(
                content: "+",
                reactingTo: reactingTo,
                reactingToPubkey: reactingToPubkey,
                keyPair: keyPair
            )
            
            #expect(reaction.kind == .reaction)
            #expect(reaction.content == "+")
            #expect(reaction.tags.contains(["e", reactingTo.hex]))
            #expect(reaction.tags.contains(["p", reactingToPubkey.hex]))
        }
        
        @Test("Create custom emoji reaction")
        func testCustomEmojiReaction() throws {
            let keyPair = try KeyPair()
            let reactingTo = EventID(hex: String(repeating: "c", count: 64))
            let reactingToPubkey = PublicKey(hex: String(repeating: "d", count: 64))
            
            let reaction = try NIP25.createReaction(
                content: "🚀",
                reactingTo: reactingTo,
                reactingToPubkey: reactingToPubkey,
                keyPair: keyPair
            )
            
            #expect(reaction.content == "🚀")
        }
        
        @Test("Parse reaction target")
        func testParseReactionTarget() throws {
            let reaction = NostrEvent(
                id: EventID(hex: String(repeating: "e", count: 64)),
                pubkey: PublicKey(hex: String(repeating: "f", count: 64)),
                createdAt: Date(),
                kind: .reaction,
                tags: [
                    ["e", String(repeating: "a", count: 64)],
                    ["p", String(repeating: "b", count: 64)]
                ],
                content: "-",
                signature: Signature(hex: String(repeating: "0", count: 128))
            )
            
            let target = NIP25.parseReactionTarget(from: reaction)
            
            #expect(target?.eventId.hex == String(repeating: "a", count: 64))
            #expect(target?.pubkey.hex == String(repeating: "b", count: 64))
        }
    }
    
    @Suite("NIP-42 Authentication Tests")
    struct NIP42Tests {
        
        @Test("Parse auth challenge")
        func testParseAuthChallenge() throws {
            let message = RelayMessage.auth(challenge: "challenge123")
            
            if case let .auth(challenge) = message {
                let authChallenge = AuthChallenge(challenge: challenge, relay: "wss://relay.example.com")
                #expect(authChallenge.challenge == "challenge123")
                #expect(authChallenge.relay == "wss://relay.example.com")
            } else {
                Issue.record("Failed to parse auth message")
            }
        }
        
        @Test("Create auth response")
        func testCreateAuthResponse() throws {
            let keyPair = try KeyPair()
            let challenge = AuthChallenge(challenge: "test-challenge", relay: "wss://relay.test.com")
            
            let response = try AuthResponse.create(
                for: challenge,
                using: keyPair
            )
            
            #expect(response.event.kind == .clientAuthentication)
            #expect(response.event.tags.contains(["relay", challenge.relay]))
            #expect(response.event.tags.contains(["challenge", challenge.challenge]))
            
            let isValid = try CoreNostr.verifyEvent(response.event)
            #expect(isValid == true)
        }
    }
}