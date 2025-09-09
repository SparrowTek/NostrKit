# NostrKit

A powerful iOS SDK for building NOSTR applications with advanced networking, caching, and social features.

## Overview

NostrKit is the iOS-specific implementation of the NOSTR protocol, providing production-ready networking, relay management, and platform-optimized features for building world-class NOSTR applications on Apple platforms.

Built on top of [CoreNostr](../CoreNostr) for protocol primitives, NostrKit adds:
- 🌐 **Relay Management**: Intelligent connection pooling with automatic failover
- 📡 **WebSocket Networking**: Native URLSession-based WebSocket implementation  
- 💾 **Smart Caching**: Event and profile caching with SwiftData
- 🔐 **Secure Storage**: Keychain integration for key management
- 📱 **iOS Optimizations**: Platform-specific performance enhancements
- ⚡ **Lightning Integration**: Native support for Zaps (NIP-57)
- 👥 **Social Features**: Complete social graph management

## Key Features

### Relay Infrastructure
- **RelayPool**: Multi-relay management with load balancing
- **Auto-reconnection**: Exponential backoff with jitter
- **Health Monitoring**: Real-time relay scoring and failover
- **Resilient Networking**: Connection resilience with retry strategies
- **Relay Discovery**: NIP-65 based relay discovery

### Event Management  
- **Smart Caching**: In-memory and persistent event caching
- **Subscription Management**: Efficient subscription handling
- **Event Deduplication**: Automatic duplicate filtering
- **Query Builder**: Type-safe filter construction
- **Batch Operations**: Optimized bulk event processing

### Social Features
- **Profile Management**: Complete profile CRUD operations
- **NIP-05 Verification**: DNS-based identity verification
- **Contact Lists**: Follow/unfollow with list management
- **Lightning Zaps**: Send and receive zaps (NIP-57)
- **Communities**: Group support (NIP-29/72)
- **Notifications**: Real-time mention notifications

### Security & Storage
- **Keychain Integration**: Secure key storage
- **Encrypted Storage**: NIP-44 encrypted local storage
- **Biometric Authentication**: Face ID/Touch ID support
- **Key Derivation**: HD wallet support (NIP-06)
- **Session Management**: Secure session handling

## Installation

Add NostrKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/SparrowTek/NostrKit.git", from: "1.0.0")
]
```

## Quick Start

```swift
import NostrKit
import CoreNostr

// Initialize the relay pool
let relayPool = RelayPool()

// Add relays
try await relayPool.addRelay(url: "wss://relay.damus.io")
try await relayPool.addRelay(url: "wss://nos.lol")
try await relayPool.addRelay(url: "wss://relay.nostr.band")

// Connect to all relays
try await relayPool.connectAll()

// Create and publish an event
let keyPair = try CoreNostr.createKeyPair()
let event = try CoreNostr.createTextNote(
    keyPair: keyPair,
    content: "Hello from NostrKit! 🚀"
)

let results = await relayPool.publish(event)
print("Published to \(results.successes.count) relays")

// Subscribe to events
let subscription = try await relayPool.subscribe(
    filters: [
        Filter(kinds: [.textNote], limit: 20)
    ]
)

for await event in subscription.events {
    print("New event: \(event.content)")
}
```

## Core Components

### RelayPool - Multi-Relay Management

```swift
// Configure relay pool with custom settings
let config = RelayPoolConfiguration(
    maxRelaysPerPool: 10,
    connectionTimeout: 5.0,
    reconnectStrategy: .exponentialBackoff(
        initialDelay: 1.0,
        maxDelay: 60.0,
        jitter: 0.3
    ),
    loadBalancingStrategy: .roundRobin
)

let relayPool = RelayPool(configuration: config)

// Add relays with metadata
try await relayPool.addRelay(
    url: "wss://relay.damus.io",
    metadata: RelayPool.RelayMetadata(
        read: true,
        write: true,
        isPrimary: true
    )
)

// Monitor relay health
await relayPool.setDelegate(self)
```

### SecureKeyStore - Key Management

```swift
let keyStore = SecureKeyStore()

// Store a key pair with biometric protection
try await keyStore.store(
    keyPair,
    for: "main-identity",
    name: "My Nostr Identity",
    permissions: .biometricRequired
)

// Retrieve with authentication
let keyPair = try await keyStore.retrieve(
    identity: "main-identity",
    authenticationRequired: true
)

// List all identities
let identities = try await keyStore.listIdentities()
```

### ProfileManager - User Profiles

```swift
let profileManager = ProfileManager(
    relayPool: relayPool,
    cache: EventCache()
)

// Fetch and verify a profile
let profile = try await profileManager.fetchProfile(pubkey: pubkey)
if let nip05 = profile.nip05 {
    let isVerified = try await profileManager.verifyNIP05(
        identifier: nip05,
        pubkey: pubkey
    )
}

// Update your profile
try await profileManager.updateProfile(
    keyPair: keyPair,
    name: "Alice",
    about: "Building on NOSTR",
    picture: "https://example.com/avatar.jpg",
    nip05: "alice@example.com"
)

// Batch fetch profiles
let profiles = try await profileManager.fetchProfiles(
    pubkeys: [pubkey1, pubkey2, pubkey3]
)
```

### ContentManager - Content Publishing

```swift
let contentManager = ContentManager(
    relayPool: relayPool,
    eventCache: eventCache,
    keyStore: keyStore
)

// Publish an article (NIP-23)
let article = try await contentManager.publishArticle(
    title: "Understanding NOSTR",
    content: markdownContent,
    summary: "A comprehensive guide to NOSTR",
    tags: ["nostr", "tutorial", "decentralized"],
    publishedAt: Date(),
    using: "main-identity"
)

// Create a reply with proper threading (NIP-10)
let reply = try await contentManager.reply(
    to: parentEventId,
    content: "Great post! Here's my thoughts...",
    mentioning: [authorPubkey],
    using: "main-identity"
)

// React to content (NIP-25)
try await contentManager.react(
    to: eventId,
    reaction: "⚡",
    using: "main-identity"
)

// Repost content
try await contentManager.repost(
    eventId: eventId,
    comment: "Worth reading!",
    using: "main-identity"
)
```

### SocialManager - Social Features

```swift
let socialManager = SocialManager(
    relayPool: relayPool,
    profileManager: profileManager
)

// Manage follow lists
try await socialManager.updateFollowList(
    adding: [newFollowPubkey],
    removing: [unfollowPubkey],
    using: "main-identity"
)

// Send a zap (NIP-57)
let zapRequest = try await socialManager.createZapRequest(
    to: recipientPubkey,
    amount: 1000, // millisats
    comment: "Great post! ⚡",
    keyPair: keyPair
)

// Join a community
try await socialManager.joinCommunity(
    communityId,
    using: "main-identity"
)

// Check notifications
let notifications = try await socialManager.fetchNotifications(
    for: "main-identity",
    since: lastChecked
)
```

### EventCache - High-Performance Caching

```swift
// Configure cache with size limits
let cache = EventCache(
    memoryLimit: 10_000, // events
    diskLimit: 100_000,  // events
    ttl: 3600 // seconds
)

// Pre-warm cache
try await cache.preload(
    filters: [
        Filter(kinds: [.textNote], limit: 100)
    ]
)

// Query cached events
let cachedEvents = cache.query(
    filter: Filter(
        authors: [pubkey],
        kinds: [.textNote]
    )
)

// Monitor cache performance
let stats = cache.statistics()
print("Cache hit rate: \(stats.hitRate)%")
```

### SubscriptionManager - Event Subscriptions

```swift
let subscriptionManager = SubscriptionManager(relayPool: relayPool)

// Create a subscription with auto-management
let subscription = try await subscriptionManager.subscribe(
    filters: [
        Filter(kinds: [.textNote], limit: 20)
    ],
    options: SubscriptionOptions(
        closeOnEOSE: false,
        bufferSize: 1000,
        deduplication: .aggressive
    )
)

// Process events
for await event in subscription.events {
    // Events are automatically deduplicated
    print("New event: \(event.content)")
}

// Subscription is automatically closed when out of scope
```

## Advanced Usage

### Query Builder

```swift
// Build complex filters with type safety
let filter = QueryBuilder()
    .authors(["pubkey1", "pubkey2"])
    .kinds([.textNote, .longFormContent, .reaction])
    .since(Date().addingTimeInterval(-86400))
    .until(Date())
    .tag("t", values: ["nostr", "bitcoin"])
    .tag("p", values: [mentionedPubkey])
    .limit(100)
    .build()

// Use in subscriptions
let subscription = try await pool.subscribe(filters: [filter])
```

### Network Resilience

```swift
// Configure resilient relay service
let resilientService = ResilientRelayService(
    baseURL: "wss://relay.example.com",
    configuration: ResilienceConfiguration(
        maxRetries: 5,
        retryDelay: 1.0,
        backoffMultiplier: 2.0,
        maxBackoffDelay: 60.0,
        connectionTimeout: 10.0,
        circuitBreakerThreshold: 3,
        circuitBreakerResetTime: 30.0
    )
)

// Monitor connection health
resilientService.onConnectionStateChange = { state in
    switch state {
    case .connected:
        print("Connected successfully")
    case .reconnecting(attempt: let attempt):
        print("Reconnecting... (attempt \(attempt))")
    case .circuitOpen:
        print("Circuit breaker open - too many failures")
    }
}
```

### Encryption Manager

```swift
let encryptionManager = EncryptionManager()

// Encrypt a direct message (NIP-44)
let encrypted = try await encryptionManager.encrypt(
    plaintext: "Secret message",
    to: recipientPubkey,
    keyPair: keyPair
)

// Decrypt a received message
let decrypted = try await encryptionManager.decrypt(
    ciphertext: encrypted,
    from: senderPubkey,
    keyPair: keyPair
)

// Create a gift-wrapped event (NIP-59)
let giftWrapped = try await encryptionManager.giftWrap(
    event: event,
    to: recipientPubkey,
    keyPair: keyPair
)
```

## Architecture

### Design Principles

1. **Protocol Separation**: Clean separation between protocol (CoreNostr) and platform (NostrKit)
2. **Actor-based Concurrency**: Thread-safe by design using Swift actors
3. **Progressive Enhancement**: Start simple, add complexity as needed
4. **Resilience First**: Built for unreliable networks and failing relays
5. **Type Safety**: Leverage Swift's type system for correctness

### Component Architecture

```
┌─────────────────────────────────────────┐
│           Your NOSTR App                │
├─────────────────────────────────────────┤
│              NostrKit                   │
│  ┌───────────┬────────────┬──────────┐ │
│  │RelayPool  │ProfileMgr  │SocialMgr │ │
│  ├───────────┼────────────┼──────────┤ │
│  │EventCache │SecureStore │Encryption│ │
│  └───────────┴────────────┴──────────┘ │
├─────────────────────────────────────────┤
│             CoreNostr                   │
│    (Protocol Implementation)            │
└─────────────────────────────────────────┘
```

## Testing

### Unit Testing

```swift
import Testing
@testable import NostrKit

@Test
func testRelayConnection() async throws {
    let relay = RelayService()
    try await relay.connect(to: mockRelayURL)
    #expect(relay.isConnected)
}

@Test
func testEventCaching() async throws {
    let cache = EventCache(memoryLimit: 100)
    let event = createMockEvent()
    
    cache.store(event)
    let retrieved = cache.get(eventId: event.id)
    
    #expect(retrieved == event)
}
```

### Integration Testing

```swift
@Test
func testEndToEndPublishing() async throws {
    let pool = RelayPool()
    try await pool.addRelay(url: testRelayURL)
    
    let event = try CoreNostr.createTextNote(
        keyPair: testKeyPair,
        content: "Test message"
    )
    
    let results = await pool.publish(event)
    #expect(results.successes.count > 0)
}
```

## Best Practices

### Connection Management
- Start with 3-5 relays for redundancy
- Monitor relay health and rotate failing relays
- Use relay discovery for finding user-specific relays
- Implement connection pooling for efficiency

### Event Handling
- Always validate event signatures
- Implement proper error handling for malformed events  
- Use event caching to reduce relay load
- Batch similar requests when possible

### Security
- Never expose private keys in logs or UI
- Use Keychain for all key storage
- Implement biometric authentication for sensitive operations
- Validate all external data before processing

### Performance  
- Use subscription filters to minimize data transfer
- Implement progressive loading for large datasets
- Cache frequently accessed data
- Use background queues for heavy processing

## Troubleshooting

### Common Issues

**Relay Connection Failures**
- Check network connectivity
- Verify WebSocket URL format (wss://)
- Ensure relay supports required NIPs
- Check for rate limiting

**Event Validation Errors**
- Verify event signature
- Check timestamp validity
- Ensure proper event structure
- Validate required fields

**Performance Issues**
- Reduce subscription scope with filters
- Enable event caching
- Limit concurrent relay connections
- Use batch operations

## Migration Guide

### From Other NOSTR Libraries

```swift
// Before (generic library)
let client = NostrClient()
client.connect("wss://relay.example.com")
client.subscribe(filter)

// After (NostrKit)
let pool = RelayPool()
try await pool.addRelay(url: "wss://relay.example.com")
let subscription = try await pool.subscribe(filters: [filter])
```

## Requirements

- iOS 17.0+ / macOS 14.0+ / tvOS 17.0+ / watchOS 10.0+
- Swift 6.0+
- Xcode 16.0+

## Dependencies

NostrKit leverages:
- **CoreNostr**: Platform-agnostic NOSTR protocol implementation
- **LocalAuthentication**: Biometric authentication
- **Foundation.URLSession**: WebSocket connections

See [Package.swift](Package.swift) for the complete dependency list.

## Contributing

Contributions are welcome! Please:
1. Follow existing code patterns and Swift conventions
2. Add tests for new functionality
3. Update documentation as needed
4. Ensure all tests pass before submitting PRs

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Resources

- [NOSTR Protocol](https://github.com/nostr-protocol/nostr)
- [NIP Repository](https://github.com/nostr-protocol/nips)
- [CoreNostr](../CoreNostr) - Platform-agnostic protocol implementation
- [Awesome NOSTR](https://github.com/aljazceru/awesome-nostr) - Curated list of NOSTR resources