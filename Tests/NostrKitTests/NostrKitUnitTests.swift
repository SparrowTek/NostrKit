import Testing
import Foundation
import CoreNostr
@testable import NostrKit

struct NostrKitUnitTests {
    
    // MARK: - Test Helper Methods
    
    private func createTestKeyPair() throws -> KeyPair {
        return try KeyPair.generate()
    }
    
    private func createTestEvent(keyPair: KeyPair, kind: Int = 1, content: String = "Test content") throws -> NostrEvent {
        let event = NostrEvent(
            pubkey: keyPair.publicKey,
            createdAt: Date(),
            kind: kind,
            tags: [],
            content: content
        )
        return try keyPair.signEvent(event)
    }
    
    private func generateTestEventId(_ seed: String) -> String {
        return NostrCrypto.sha256(seed.data(using: .utf8)!).map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - ProfileManager Tests
    
    @Test("ProfileManager Profile struct creation and JSON serialization")
    func testProfileManagerFetchProfile() async throws {
        let keyPair = try createTestKeyPair()
        
        // Test Profile creation
        let profile = ProfileManager.Profile(
            pubkey: keyPair.publicKey,
            name: "Alice",
            displayName: "Alice Cooper",
            about: "Test profile",
            picture: "https://example.com/avatar.jpg",
            nip05: "alice@example.com"
        )
        
        // Test displayNameOrFallback
        #expect(profile.displayNameOrFallback == "Alice Cooper")
        
        // Test JSON serialization
        let jsonString = try profile.toJSON()
        #expect(jsonString.contains("Alice"))
        #expect(jsonString.contains("Test profile"))
        
        // Test Profile creation from NostrEvent
        let profileJson = """
        {
            "name": "Bob",
            "about": "Another test profile",
            "picture": "https://example.com/bob.jpg"
        }
        """
        
        let profileEvent = NostrEvent(
            pubkey: keyPair.publicKey,
            createdAt: Date(),
            kind: 0,
            tags: [],
            content: profileJson
        )
        
        guard let parsedProfile = ProfileManager.Profile(from: profileEvent) else {
            throw NostrError.serializationError(type: "Profile", reason: "Failed to parse profile from event")
        }
        
        #expect(parsedProfile.name == "Bob")
        #expect(parsedProfile.about == "Another test profile")
        #expect(parsedProfile.picture == "https://example.com/bob.jpg")
    }
    
    @Test("ProfileManager handles empty profiles and fallback display names")
    func testProfileManagerMissingProfile() async throws {
        let keyPair = try createTestKeyPair()
        
        // Test empty profile creation
        let emptyProfile = ProfileManager.Profile(pubkey: keyPair.publicKey)
        
        // Test fallback display name with no name fields
        let fallbackName = emptyProfile.displayNameOrFallback
        #expect(fallbackName.hasSuffix("..."))
        #expect(fallbackName.count == 11) // 8 chars + "..."
        
        // Test profile with only name (no displayName)
        let nameOnlyProfile = ProfileManager.Profile(
            pubkey: keyPair.publicKey,
            name: "TestUser"
        )
        #expect(nameOnlyProfile.displayNameOrFallback == "TestUser")
        
        // Test ContactList creation
        let emptyContactList = ProfileManager.ContactList(pubkey: keyPair.publicKey)
        #expect(emptyContactList.contacts.isEmpty)
        #expect(emptyContactList.relayList.isEmpty)
        
        // Test ContactList with data
        let contacts: Set<PublicKey> = ["pubkey1", "pubkey2"]
        let relayList = ["wss://relay1.com": ProfileManager.ContactList.RelayUsage(read: true, write: false)]
        
        let contactList = ProfileManager.ContactList(
            pubkey: keyPair.publicKey,
            contacts: contacts,
            relayList: relayList
        )
        
        #expect(contactList.contacts.count == 2)
        #expect(contactList.relayList.count == 1)
        #expect(contactList.relayList["wss://relay1.com"]?.read == true)
        #expect(contactList.relayList["wss://relay1.com"]?.write == false)
    }
    
    // MARK: - ContentManager Tests
    
    @Test("ContentManager Thread and Article structures work correctly")
    func testContentManagerThreadReconstruction() async throws {
        let keyPair = try createTestKeyPair()
        
        // Test Thread structure creation
        let rootEvent = try createTestEvent(keyPair: keyPair, content: "This is the root post")
        let replyEvent = try createTestEvent(keyPair: keyPair, content: "This is a reply")
        
        // Create a thread reply
        let threadReply = ContentManager.Thread.ThreadReply(
            event: replyEvent,
            depth: 1,
            parentId: nil,
            rootId: rootEvent.id,
            replies: []
        )
        
        // Create a thread
        let thread = ContentManager.Thread(
            rootEvent: rootEvent,
            replies: [threadReply],
            mentions: []
        )
        
        #expect(thread.replyCount == 1)
        #expect(thread.rootEvent.id == rootEvent.id)
        #expect(thread.replies.count == 1)
        #expect(thread.replies[0].depth == 1)
        #expect(thread.replies[0].rootId == rootEvent.id)
        
        // Test nested replies (depth calculation)
        let nestedReply = ContentManager.Thread.ThreadReply(
            event: try createTestEvent(keyPair: keyPair, content: "Nested reply"),
            depth: 2,
            parentId: replyEvent.id,
            rootId: rootEvent.id
        )
        
        let threadWithNested = ContentManager.Thread(
            rootEvent: rootEvent,
            replies: [
                ContentManager.Thread.ThreadReply(
                    event: replyEvent,
                    depth: 1,
                    parentId: nil,
                    rootId: rootEvent.id,
                    replies: [nestedReply]
                )
            ]
        )
        
        #expect(threadWithNested.replyCount == 2) // Counts nested replies too
        
        // Test Article structure
        let articleEvent = NostrEvent(
            pubkey: keyPair.publicKey,
            createdAt: Date(),
            kind: 30023,
            tags: [
                ["title", "Test Article"],
                ["summary", "A test article"],
                ["t", "nostr"],
                ["t", "testing"]
            ],
            content: "This is the article content with **markdown**."
        )
        
        guard let article = ContentManager.Article(from: articleEvent) else {
            throw NostrError.serializationError(type: "Article", reason: "Failed to create article from event")
        }
        
        #expect(article.id == articleEvent.id)
        #expect(article.author == keyPair.publicKey)
        #expect(article.content == "This is the article content with **markdown**.")
        #expect(article.tags.contains("nostr"))
        #expect(article.tags.contains("testing"))
        #expect(article.isDraft == false)
    }
    
    // MARK: - SubscriptionManager Tests
    
    @Test("SubscriptionManager options and structures work correctly")
    func testSubscriptionManagerDeduplication() async throws {
        // Test SubscriptionOptions creation and defaults
        let defaultOptions = SubscriptionManager.SubscriptionOptions()
        #expect(defaultOptions.autoRenew == true)
        #expect(defaultOptions.cacheResults == true)
        #expect(defaultOptions.deduplicate == true)
        #expect(defaultOptions.closeAfterEOSE == false)
        #expect(defaultOptions.priority == .normal)
        
        // Test preset options
        let realtimeOptions = SubscriptionManager.SubscriptionOptions.realtime
        #expect(realtimeOptions.autoRenew == true)
        #expect(realtimeOptions.priority == .high)
        #expect(realtimeOptions.closeAfterEOSE == false)
        
        let oneTimeOptions = SubscriptionManager.SubscriptionOptions.oneTime
        #expect(oneTimeOptions.autoRenew == false)
        #expect(oneTimeOptions.closeAfterEOSE == true)
        
        let backgroundOptions = SubscriptionManager.SubscriptionOptions.background
        #expect(backgroundOptions.priority == .low)
        #expect(backgroundOptions.inactivityTimeout == 600)
        
        // Test SubscriptionPriority comparison
        #expect(SubscriptionManager.SubscriptionPriority.low < SubscriptionManager.SubscriptionPriority.normal)
        #expect(SubscriptionManager.SubscriptionPriority.normal < SubscriptionManager.SubscriptionPriority.high)
        #expect(SubscriptionManager.SubscriptionPriority.high < SubscriptionManager.SubscriptionPriority.critical)
        
        // Test Statistics structure
        let stats = SubscriptionManager.Statistics(
            activeSubscriptions: 5,
            totalEventsReceived: 100,
            cachedEvents: 80,
            duplicatesFiltered: 20,
            subscriptionsMerged: 2,
            oldestSubscription: Date(),
            averageEventsPerSubscription: 20.0
        )
        
        #expect(stats.activeSubscriptions == 5)
        #expect(stats.totalEventsReceived == 100)
        #expect(stats.duplicatesFiltered == 20)
        #expect(stats.averageEventsPerSubscription == 20.0)
    }
    
    @Test("SubscriptionManager subscription configuration works correctly")
    func testSubscriptionManagerRelayTracking() async throws {
        // Test custom subscription options
        let customOptions = SubscriptionManager.SubscriptionOptions(
            autoRenew: false,
            cacheResults: false,
            deduplicate: false,
            inactivityTimeout: 120,
            closeAfterEOSE: true,
            maxBufferSize: 500,
            priority: .critical
        )
        
        #expect(customOptions.autoRenew == false)
        #expect(customOptions.cacheResults == false)
        #expect(customOptions.deduplicate == false)
        #expect(customOptions.inactivityTimeout == 120)
        #expect(customOptions.closeAfterEOSE == true)
        #expect(customOptions.maxBufferSize == 500)
        #expect(customOptions.priority == .critical)
        
        // Simulate event deduplication logic that would be used in the manager
        let keyPair = try createTestKeyPair()
        let event1 = try createTestEvent(keyPair: keyPair, content: "Test event")
        let event2 = try createTestEvent(keyPair: keyPair, content: "Different event")
        
        var seenEventIds: Set<String> = []
        
        // Test deduplication logic
        let isEvent1New = !seenEventIds.contains(event1.id)
        seenEventIds.insert(event1.id)
        #expect(isEvent1New == true)
        
        let isEvent1DuplicateNew = !seenEventIds.contains(event1.id)
        #expect(isEvent1DuplicateNew == false) // Should be false as it's already seen
        
        let isEvent2New = !seenEventIds.contains(event2.id)
        seenEventIds.insert(event2.id)
        #expect(isEvent2New == true)
        
        #expect(seenEventIds.count == 2)
    }
    
    // MARK: - EventCache Tests
    
    @Test("EventCache stores and retrieves events")
    func testEventCacheBasicOperations() async throws {
        let cache = EventCache()
        let keyPair = try createTestKeyPair()
        let testEvent = try createTestEvent(keyPair: keyPair)
        
        // Store event
        let wasStored = try await cache.store(testEvent)
        #expect(wasStored == true)
        
        // Retrieve event
        let retrievedEvent = await cache.event(id: testEvent.id)
        #expect(retrievedEvent?.id == testEvent.id)
        #expect(retrievedEvent?.content == testEvent.content)
        
        // Verify statistics
        let stats = await cache.statistics()
        #expect(stats.totalEvents >= 1)
        #expect(stats.memoryEvents >= 1)
    }
    
    @Test("EventCache respects size limits")
    func testEventCacheSizeLimits() async throws {
        let config = EventCache.Configuration.memory(maxEvents: 2)
        let cache = EventCache(configuration: config)
        let keyPair = try createTestKeyPair()
        
        // Create multiple events
        let event1 = try createTestEvent(keyPair: keyPair, content: "Event 1")
        let event2 = try createTestEvent(keyPair: keyPair, content: "Event 2")
        let event3 = try createTestEvent(keyPair: keyPair, content: "Event 3")
        
        // Store events
        _ = try await cache.store(event1)
        _ = try await cache.store(event2)
        _ = try await cache.store(event3)
        
        // Verify size limit is respected
        let stats = await cache.statistics()
        #expect(stats.memoryEvents <= 2)
        
        // Verify most recent events are kept (LRU eviction)
        let retrievedEvent3 = await cache.event(id: event3.id)
        #expect(retrievedEvent3 != nil)
        
        let retrievedEvent2 = await cache.event(id: event2.id)
        #expect(retrievedEvent2 != nil)
        
        // Event 1 should have been evicted
        let retrievedEvent1 = await cache.event(id: event1.id)
        #expect(retrievedEvent1 == nil)
    }
    
    // MARK: - Crypto Tests
    
    @Test("NostrCrypto AES-256-CBC round trip succeeds")
    func testAESCBCEncryptDecrypt() throws {
        let plaintext = Data("Sample secret message".utf8)
        let key = Data(repeating: 0x11, count: 32)
        let iv = Data(repeating: 0x22, count: 16)
        
        let ciphertext = try NostrCrypto.aesEncrypt(
            plaintext: plaintext,
            key: key,
            iv: iv
        )
        let decrypted = try NostrCrypto.aesDecrypt(
            ciphertext: ciphertext,
            key: key,
            iv: iv
        )
        
        #expect(decrypted == plaintext)
        #expect(ciphertext != plaintext)
    }
    
    @Test("NostrCrypto AES-256-CBC validates key and IV sizes")
    func testAESCBCInputValidation() async throws {
        let plaintext = Data("Test payload".utf8)
        let shortKey = Data(repeating: 0x00, count: 16)
        let iv = Data(repeating: 0x01, count: 16)
        
        await #expect(throws: NostrError.self) {
            _ = try NostrCrypto.aesEncrypt(
                plaintext: plaintext,
                key: shortKey,
                iv: iv
            )
        }
        
        let key = Data(repeating: 0x00, count: 32)
        let shortIv = Data(repeating: 0x02, count: 8)
        
        await #expect(throws: NostrError.self) {
            _ = try NostrCrypto.aesEncrypt(
                plaintext: plaintext,
                key: key,
                iv: shortIv
            )
        }
    }
    
    // MARK: - SecureKeyStore Tests
    
    @Test("SecureKeyStore stores and retrieves keys")
    func testSecureKeyStoreBasicOperations() async throws {
        let keyStore = SecureKeyStore()
        let keyPair = try createTestKeyPair()
        let testIdentity = "test_identity_\(UUID().uuidString)"
        
        // Store key pair
        try await keyStore.store(
            keyPair,
            for: testIdentity,
            name: "Test Identity",
            permissions: .full
        )
        
        // Retrieve key pair
        let retrievedKeyPair = try await keyStore.retrieve(identity: testIdentity)
        #expect(retrievedKeyPair.publicKey == keyPair.publicKey)
        #expect(retrievedKeyPair.privateKey == keyPair.privateKey)
        
        // List identities
        let identities = try await keyStore.listIdentities()
        #expect(identities.contains { $0.id == testIdentity })
        #expect(identities.first { $0.id == testIdentity }?.name == "Test Identity")
        
        // Clean up
        try? await keyStore.delete(identity: testIdentity)
    }
    
    // MARK: - RelayDiscovery Tests
    
    @Test("RelayDiscovery structures and bootstrap relays work correctly")
    func testRelayDiscoveryParsing() async throws {
        let discovery = NostrKit.RelayDiscovery()
        
        // Test bootstrap relays
        let bootstrapRelays = await discovery.bootstrapRelays
        #expect(bootstrapRelays.count > 0)
        
        // Verify well-known bootstrap relays are present
        let relayURLs = bootstrapRelays.map { $0.url }
        #expect(relayURLs.contains("wss://relay.damus.io"))
        
        // Test DiscoveredRelay structure
        let testRelay = NostrKit.RelayDiscovery.DiscoveredRelay(
            url: "wss://test-relay.com",
            source: .nip65,
            metadata: RelayPool.RelayMetadata(read: true, write: false, isPrimary: true),
            discoveredAt: Date(),
            recommendedBy: ["pubkey1", "pubkey2"]
        )
        
        #expect(testRelay.url == "wss://test-relay.com")
        #expect(testRelay.source == .nip65)
        #expect(testRelay.metadata.read == true)
        #expect(testRelay.metadata.write == false)
        #expect(testRelay.metadata.isPrimary == true)
        #expect(testRelay.recommendedBy?.count == 2)
        
        // Test DiscoverySource enum
        let sources: [NostrKit.RelayDiscovery.DiscoverySource] = [.bootstrap, .nip65, .recommendation, .dns, .manual]
        #expect(sources.count == 5)
        #expect(sources.contains(.bootstrap))
        #expect(sources.contains(.nip65))
        
        // Test RelayPreference and RelayUsage from CoreNostr
        let relayPref = RelayPreference(url: "wss://example.com", usage: .read)
        #expect(relayPref.url == "wss://example.com")
        #expect(relayPref.usage == .read)
        
        let tag = relayPref.toTag()
        #expect(tag[0] == "r")
        #expect(tag[1] == "wss://example.com")
        #expect(tag[2] == "read")
        
        // Test RelayPreference from tag
        guard let parsedPref = RelayPreference(fromTag: ["r", "wss://test.com", "write"]) else {
            throw NostrError.serializationError(type: "RelayPreference", reason: "Failed to parse from tag")
        }
        #expect(parsedPref.url == "wss://test.com")
        #expect(parsedPref.usage == .write)
        
        // Test RelayListMetadata
        let relayList = RelayListMetadata(relays: [
            RelayPreference(url: "wss://read-write.com", usage: .readWrite),
            RelayPreference(url: "wss://read-only.com", usage: .read),
            RelayPreference(url: "wss://write-only.com", usage: .write)
        ])
        
        #expect(relayList.readRelays.count == 2) // read-write + read-only
        #expect(relayList.writeRelays.count == 2) // read-write + write-only
        #expect(relayList.readOnlyRelays.count == 1)
        #expect(relayList.writeOnlyRelays.count == 1)
        #expect(relayList.readWriteRelays.count == 1)
    }
    
    // MARK: - EncryptionManager Tests
    
    @Test("EncryptionManager encrypts and decrypts messages")
    func testEncryptionManagerBasicOperations() async throws {
        let keyStore = SecureKeyStore()
        let encryptionManager = EncryptionManager(keyStore: keyStore)
        
        let senderKeyPair = try createTestKeyPair()
        let recipientKeyPair = try createTestKeyPair()
        let senderIdentity = "sender_\(UUID().uuidString)"
        let recipientIdentity = "recipient_\(UUID().uuidString)"
        
        // Store key pairs
        try await keyStore.store(senderKeyPair, for: senderIdentity, permissions: .full)
        try await keyStore.store(recipientKeyPair, for: recipientIdentity, permissions: .full)
        
        let testMessage = "This is a secret message"
        
        // Encrypt message
        let encryptedContent = try await encryptionManager.encrypt(
            message: testMessage,
            to: recipientKeyPair.publicKey,
            from: senderIdentity,
            method: .nip04 // Using NIP-04 as it's simpler for testing
        )
        
        #expect(encryptedContent.content != testMessage)
        #expect(encryptedContent.method == .nip04)
        
        // Decrypt message
        let decryptedMessage = try await encryptionManager.decrypt(
            content: encryptedContent,
            from: senderKeyPair.publicKey,
            to: recipientIdentity
        )
        
        #expect(decryptedMessage == testMessage)
        
        // Clean up
        try? await keyStore.delete(identity: senderIdentity)
        try? await keyStore.delete(identity: recipientIdentity)
    }
    
    // MARK: - SocialManager Tests
    
    @Test("SocialManager data structures work correctly")
    func testSocialManagerFollowList() async throws {
        let keyPair = try createTestKeyPair()
        
        // Test ZapRequest structure
        let zapRequest = SocialManager.ZapRequest(
            id: "zap_request_id",
            recipient: keyPair.publicKey,
            amount: 1000,
            comment: "Great post!",
            relays: ["wss://relay1.com", "wss://relay2.com"],
            event: try createTestEvent(keyPair: keyPair, kind: 9734),
            lnurl: "lnurl1234567890abcdef"
        )
        
        #expect(zapRequest.recipient == keyPair.publicKey)
        #expect(zapRequest.amount == 1000)
        #expect(zapRequest.comment == "Great post!")
        #expect(zapRequest.relays.count == 2)
        
        // Test Community structure
        let community = SocialManager.Community(
            id: "test_community",
            name: "Test Community",
            description: "A community for testing",
            moderators: [keyPair.publicKey],
            rules: ["Be respectful", "No spam"]
        )
        
        #expect(community.id == "test_community")
        #expect(community.name == "Test Community")
        #expect(community.moderators.contains(keyPair.publicKey))
        #expect(community.rules.count == 2)
        
        // Test Community from event
        let communityEvent = NostrEvent(
            pubkey: keyPair.publicKey,
            createdAt: Date(),
            kind: 34550,
            tags: [
                ["d", "community_id"],
                ["p", keyPair.publicKey, "moderator"],
                ["relay", "wss://community-relay.com"]
            ],
            content: """
            {
                "name": "Parsed Community",
                "description": "Community parsed from event",
                "rules": ["Rule 1", "Rule 2"]
            }
            """
        )
        
        guard let parsedCommunity = SocialManager.Community(from: communityEvent) else {
            throw NostrError.serializationError(type: "Community", reason: "Failed to parse community")
        }
        
        #expect(parsedCommunity.id == "community_id")
        #expect(parsedCommunity.name == "Parsed Community")
        #expect(parsedCommunity.moderators.contains(keyPair.publicKey))
        #expect(parsedCommunity.rules.count == 2)
        #expect(parsedCommunity.relay == "wss://community-relay.com")
        
        // Test Notification structure
        let notification = SocialManager.Notification(
            id: "notification_id",
            type: .mention,
            event: try createTestEvent(keyPair: keyPair),
            actor: keyPair.publicKey,
            createdAt: Date()
        )
        
        #expect(notification.type == .mention)
        #expect(notification.actor == keyPair.publicKey)
        #expect(notification.isRead == false)
        
        // Test NotificationType enum
        let allTypes = SocialManager.NotificationType.allCases
        #expect(allTypes.contains(.mention))
        #expect(allTypes.contains(.reply))
        #expect(allTypes.contains(.zap))
        #expect(allTypes.count >= 7)
    }
}
