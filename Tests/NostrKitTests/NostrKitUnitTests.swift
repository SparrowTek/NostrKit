import Testing
import Foundation
import CoreNostr
@testable import NostrKit

struct NostrKitUnitTests {
    
    // MARK: - ProfileManager Tests
    
    @Test("ProfileManager fetches and caches profile metadata")
    func testProfileManagerFetchProfile() async throws {
        // Setup
        let mockPool = MockRelayPool()
        let eventCache = EventCache()
        let profileManager = ProfileManager(relayPool: mockPool as! RelayPool, eventCache: eventCache)
        
        let testPubkey = "test_pubkey_123"
        let testMetadata = NostrMetadata(
            name: "Test User",
            about: "Test bio",
            picture: "https://example.com/avatar.jpg",
            nip05: "test@example.com"
        )
        
        // Create mock metadata event
        let keyPair = try CoreNostr.generateKeyPair()
        let metadataEvent = try NostrEvent(
            kind: .metadata,
            content: try JSONEncoder().encode(testMetadata).base64EncodedString(),
            tags: [],
            keyPair: keyPair
        )
        
        await mockPool.setMockEvents([metadataEvent])
        
        // Test
        let profile = try await profileManager.fetchProfile(pubkey: testPubkey, force: false)
        
        // Verify
        #expect(profile != nil)
        #expect(profile?.name == testMetadata.name)
        #expect(profile?.about == testMetadata.about)
        
        // Verify caching works
        let cachedProfile = try await profileManager.fetchProfile(pubkey: testPubkey, force: false)
        #expect(cachedProfile?.name == testMetadata.name)
    }
    
    @Test("ProfileManager handles missing profiles gracefully")
    func testProfileManagerMissingProfile() async throws {
        // Setup
        let mockPool = MockRelayPool()
        let eventCache = EventCache()
        let profileManager = ProfileManager(relayPool: mockPool as! RelayPool, eventCache: eventCache)
        
        await mockPool.setMockEvents([]) // No events
        
        // Test
        let profile = try await profileManager.fetchProfile(pubkey: "nonexistent_pubkey", force: false)
        
        // Verify
        #expect(profile == nil)
    }
    
    // MARK: - ContentManager Tests
    
    @Test("ContentManager reconstructs thread correctly")
    func testContentManagerThreadReconstruction() async throws {
        // Setup
        let mockPool = MockRelayPool()
        let eventCache = EventCache()
        let contentManager = ContentManager(relayPool: mockPool as! RelayPool, eventCache: eventCache)
        
        let keyPair = try CoreNostr.generateKeyPair()
        
        // Create a thread of events
        let rootEvent = try NostrEvent(
            kind: .textNote,
            content: "Root message",
            tags: [],
            keyPair: keyPair
        )
        
        let reply1 = try NostrEvent(
            kind: .textNote,
            content: "Reply 1",
            tags: [
                Tag(name: "e", values: [rootEvent.id]),
                Tag(name: "p", values: [rootEvent.pubkey])
            ],
            keyPair: keyPair
        )
        
        let reply2 = try NostrEvent(
            kind: .textNote,
            content: "Reply 2",
            tags: [
                Tag(name: "e", values: [reply1.id]),
                Tag(name: "p", values: [reply1.pubkey])
            ],
            keyPair: keyPair
        )
        
        await mockPool.setMockEvents([rootEvent, reply1, reply2])
        
        // Test
        let thread = try await contentManager.reconstructThread(for: reply2.id)
        
        // Verify
        #expect(thread.count >= 2)
        #expect(thread.contains { $0.id == rootEvent.id })
        #expect(thread.contains { $0.id == reply1.id })
    }
    
    // MARK: - SubscriptionManager Tests
    
    @Test("SubscriptionManager deduplicates events")
    func testSubscriptionManagerDeduplication() async throws {
        // Setup
        let subscriptionManager = SubscriptionManager()
        
        let keyPair = try CoreNostr.generateKeyPair()
        let event = try NostrEvent(
            kind: .textNote,
            content: "Test event",
            tags: [],
            keyPair: keyPair
        )
        
        // Test - Add same event multiple times
        let added1 = await subscriptionManager.addEvent(event, from: "relay1")
        let added2 = await subscriptionManager.addEvent(event, from: "relay2")
        let added3 = await subscriptionManager.addEvent(event, from: "relay1")
        
        // Verify
        #expect(added1 == true)  // First addition succeeds
        #expect(added2 == false) // Duplicate from different relay
        #expect(added3 == false) // Duplicate from same relay
        
        let events = await subscriptionManager.getEvents(for: "test_subscription")
        #expect(events.count <= 1) // Should have at most 1 event
    }
    
    @Test("SubscriptionManager tracks relay sources")
    func testSubscriptionManagerRelayTracking() async throws {
        // Setup
        let subscriptionManager = SubscriptionManager()
        
        let keyPair = try CoreNostr.generateKeyPair()
        let event1 = try NostrEvent(
            kind: .textNote,
            content: "Event 1",
            tags: [],
            keyPair: keyPair
        )
        
        let event2 = try NostrEvent(
            kind: .textNote,
            content: "Event 2",
            tags: [],
            keyPair: keyPair
        )
        
        // Test
        _ = await subscriptionManager.addEvent(event1, from: "wss://relay1.com")
        _ = await subscriptionManager.addEvent(event2, from: "wss://relay2.com")
        
        // Verify
        let relays1 = await subscriptionManager.getRelays(for: event1.id)
        let relays2 = await subscriptionManager.getRelays(for: event2.id)
        
        #expect(relays1.contains("wss://relay1.com"))
        #expect(relays2.contains("wss://relay2.com"))
    }
    
    // MARK: - EventCache Tests
    
    @Test("EventCache stores and retrieves events")
    func testEventCacheBasicOperations() async throws {
        // Setup
        let cache = EventCache()
        let keyPair = try CoreNostr.generateKeyPair()
        
        let event = try NostrEvent(
            kind: .textNote,
            content: "Cached event",
            tags: [],
            keyPair: keyPair
        )
        
        // Test
        try await cache.store(event)
        let retrieved = await cache.get(eventId: event.id)
        
        // Verify
        #expect(retrieved != nil)
        #expect(retrieved?.id == event.id)
        #expect(retrieved?.content == event.content)
    }
    
    @Test("EventCache respects size limits")
    func testEventCacheSizeLimits() async throws {
        // Setup
        let cache = EventCache(maxMemoryItems: 5)
        let keyPair = try CoreNostr.generateKeyPair()
        
        var events: [NostrEvent] = []
        
        // Create 10 events
        for i in 0..<10 {
            let event = try NostrEvent(
                kind: .textNote,
                content: "Event \(i)",
                tags: [],
                keyPair: keyPair
            )
            events.append(event)
            try await cache.store(event)
        }
        
        // Verify - only recent events should be in memory
        let stats = await cache.getStatistics()
        #expect(stats.memoryCount <= 5)
        
        // Most recent events should still be retrievable
        let recent = await cache.get(eventId: events[9].id)
        #expect(recent != nil)
    }
    
    // MARK: - QueryBuilder Tests
    
    @Test("QueryBuilder constructs valid filters")
    func testQueryBuilderFilterConstruction() throws {
        // Test basic filter
        let filter1 = QueryBuilder()
            .authors(["pubkey1", "pubkey2"])
            .kinds([.textNote, .metadata])
            .since(Date(timeIntervalSince1970: 1000))
            .until(Date(timeIntervalSince1970: 2000))
            .limit(50)
            .build()
        
        #expect(filter1.authors?.count == 2)
        #expect(filter1.kinds?.count == 2)
        #expect(filter1.since == 1000)
        #expect(filter1.until == 2000)
        #expect(filter1.limit == 50)
        
        // Test tag filter
        let filter2 = QueryBuilder()
            .tag("e", values: ["event1", "event2"])
            .tag("p", values: ["pubkey1"])
            .build()
        
        #expect(filter2.tags?["e"]?.count == 2)
        #expect(filter2.tags?["p"]?.count == 1)
    }
    
    @Test("QueryBuilder handles empty filters")
    func testQueryBuilderEmptyFilter() throws {
        let filter = QueryBuilder().build()
        
        #expect(filter.ids == nil)
        #expect(filter.authors == nil)
        #expect(filter.kinds == nil)
        #expect(filter.tags == nil)
        #expect(filter.since == nil)
        #expect(filter.until == nil)
        #expect(filter.limit == nil)
    }
    
    // MARK: - SecureKeyStore Tests
    
    @Test("SecureKeyStore stores and retrieves keys")
    func testSecureKeyStoreBasicOperations() async throws {
        // Setup
        let keyStore = SecureKeyStore()
        let testKey = "test_private_key_123"
        let identifier = "user1"
        
        // Test store
        let permissions = KeyPermissions(requiresBiometrics: false)
        try await keyStore.store(
            privateKey: testKey,
            for: identifier,
            permissions: permissions
        )
        
        // Test retrieve
        let retrieved = try await keyStore.retrieve(for: identifier)
        
        // Verify
        #expect(retrieved == testKey)
        
        // Test delete
        try await keyStore.delete(for: identifier)
        
        // Verify deletion
        do {
            _ = try await keyStore.retrieve(for: identifier)
            Issue.record("Expected error when retrieving deleted key")
        } catch {
            // Expected error
        }
    }
    
    // MARK: - RelayDiscovery Tests
    
    @Test("RelayDiscovery parses relay lists from events")
    func testRelayDiscoveryParsing() async throws {
        // Setup
        let mockPool = MockRelayPool()
        let discovery = RelayDiscovery(pool: mockPool as! RelayPool)
        
        let keyPair = try CoreNostr.generateKeyPair()
        
        // Create relay list event (NIP-65)
        let relayListEvent = try NostrEvent(
            kind: EventKind(rawValue: 10002)!, // Relay list metadata
            content: "",
            tags: [
                Tag(name: "r", values: ["wss://relay1.com", "read"]),
                Tag(name: "r", values: ["wss://relay2.com", "write"]),
                Tag(name: "r", values: ["wss://relay3.com"])
            ],
            keyPair: keyPair
        )
        
        await mockPool.setMockEvents([relayListEvent])
        
        // Test
        let relayList = try await discovery.discoverRelays(for: keyPair.publicKey)
        
        // Verify
        #expect(relayList.relays.count == 3)
        #expect(relayList.relays.contains { $0.url == "wss://relay1.com" && $0.permission == "read" })
        #expect(relayList.relays.contains { $0.url == "wss://relay2.com" && $0.permission == "write" })
        #expect(relayList.relays.contains { $0.url == "wss://relay3.com" })
    }
    
    // MARK: - EncryptionManager Tests
    
    @Test("EncryptionManager encrypts and decrypts messages")
    func testEncryptionManagerBasicOperations() async throws {
        // Setup
        let encryptionManager = EncryptionManager()
        let senderKeyPair = try CoreNostr.generateKeyPair()
        let recipientKeyPair = try CoreNostr.generateKeyPair()
        
        let originalMessage = "Secret message 🔐"
        
        // Test encryption
        let encrypted = try await encryptionManager.encrypt(
            message: originalMessage,
            to: recipientKeyPair.publicKey,
            using: senderKeyPair
        )
        
        #expect(!encrypted.isEmpty)
        #expect(encrypted != originalMessage)
        
        // Test decryption
        let decrypted = try await encryptionManager.decrypt(
            encryptedMessage: encrypted,
            from: senderKeyPair.publicKey,
            using: recipientKeyPair
        )
        
        #expect(decrypted == originalMessage)
    }
    
    // MARK: - SocialManager Tests
    
    @Test("SocialManager manages follow lists")
    func testSocialManagerFollowList() async throws {
        // Setup
        let mockPool = MockRelayPool()
        let eventCache = EventCache()
        let socialManager = SocialManager(relayPool: mockPool as! RelayPool, eventCache: eventCache)
        
        let keyPair = try CoreNostr.generateKeyPair()
        
        // Create follow list event
        let followListEvent = try NostrEvent(
            kind: .followList,
            content: "",
            tags: [
                Tag(name: "p", values: ["pubkey1", "relay1", "petname1"]),
                Tag(name: "p", values: ["pubkey2", "relay2", "petname2"]),
                Tag(name: "p", values: ["pubkey3"])
            ],
            keyPair: keyPair
        )
        
        await mockPool.setMockEvents([followListEvent])
        
        // Test
        let followList = try await socialManager.getFollowList(for: keyPair.publicKey)
        
        // Verify
        #expect(followList?.follows.count == 3)
        #expect(followList?.follows.contains { $0.pubkey == "pubkey1" && $0.petname == "petname1" })
        #expect(followList?.follows.contains { $0.pubkey == "pubkey2" && $0.petname == "petname2" })
        #expect(followList?.follows.contains { $0.pubkey == "pubkey3" && $0.petname == nil })
    }
}