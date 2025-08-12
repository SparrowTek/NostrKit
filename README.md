# NostrKit

iOS-specific NOSTR implementation providing networking, relay management, and high-level features for building NOSTR applications on Apple platforms.

## Overview

NostrKit implements the iOS-specific components needed for NOSTR applications, including WebSocket connections, relay pool management, secure key storage, and high-level managers for common NOSTR operations. It builds on top of [CoreNostr](../CoreNostr) which provides the platform-agnostic protocol implementation.

## Key Features

### 🌐 Relay Management
- **RelayService**: WebSocket-based relay connections with automatic reconnection
- **RelayPool**: Connection pooling with health monitoring and load balancing
- **RelayDiscovery**: NIP-65 relay discovery and bootstrap relay configuration
- **SubscriptionManager**: Event deduplication and subscription lifecycle management

### 🔐 Security & Storage
- **SecureKeyStore**: Keychain-based secure key storage with biometric authentication
- **EncryptionManager**: NIP-04 and NIP-44 message encryption/decryption
- **EventCache**: LRU memory cache for events with configurable size limits

### 📱 High-Level Managers
- **ProfileManager**: User profile fetching, caching, and NIP-05 verification
- **ContentManager**: Thread reconstruction, article publishing, reactions, and reposts
- **SocialManager**: Follow lists, communities, notifications, and zap management

### 🔧 Utilities
- **QueryBuilder**: Fluent API for constructing NOSTR filters
- **KeychainWrapper**: iOS keychain integration with biometric support
- **Network diagnostics**: Connection health monitoring and statistics

## Installation

Add NostrKit to your iOS project using Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/SparrowTek/NostrKit.git", from: "1.0.0")
]
```

## Usage Examples

### Setting Up a Relay Pool

```swift
import NostrKit
import CoreNostr

// Create and configure relay pool
let pool = RelayPool(configuration: .default)

// Add relays with metadata
try await pool.addRelay(
    url: "wss://relay.damus.io",
    metadata: RelayPool.RelayMetadata(
        read: true,
        write: true,
        isPrimary: true
    )
)

// Monitor relay health
await pool.setDelegate(self)
```

### Secure Key Management

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
```

### Publishing Content

```swift
let contentManager = ContentManager(
    relayPool: pool,
    eventCache: eventCache,
    keyStore: keyStore
)

// Publish an article (NIP-23)
let article = try await contentManager.publishArticle(
    title: "My First Article",
    content: markdownContent,
    summary: "A brief summary",
    tags: ["nostr", "tutorial"],
    using: "main-identity"
)

// Create a reply with proper threading (NIP-10)
let reply = try await contentManager.reply(
    to: parentEventId,
    content: "Great post!",
    using: "main-identity"
)
```

### Managing Social Features

```swift
let socialManager = SocialManager(
    relayPool: pool,
    eventCache: eventCache
)

// Update follow list
try await socialManager.updateFollowList(
    adding: [newFollowPubkey],
    removing: [],
    using: "main-identity"
)

// Create a zap request (NIP-57)
let zapRequest = try await socialManager.createZapRequest(
    to: recipientPubkey,
    amount: 1000,
    comment: "Thanks for the great content!",
    using: "main-identity"
)
```

### Event Subscriptions

```swift
// Build a complex filter
let filter = QueryBuilder()
    .authors(["pubkey1", "pubkey2"])
    .kinds([.textNote, .longFormContent])
    .since(Date().addingTimeInterval(-86400))
    .tag("t", values: ["nostr", "bitcoin"])
    .limit(100)
    .build()

// Subscribe and process events
let subscription = try await pool.subscribe(filters: [filter])

for await event in subscription.events {
    print("Received: \(event.content)")
}
```

## Architecture

### Core Components

- **RelayService**: Individual relay connection management
- **RelayPool**: Coordinates multiple relay connections
- **EventCache**: In-memory event storage with LRU eviction
- **SecureKeyStore**: Keychain-based identity management

### Manager Layer

- **ProfileManager**: User metadata and NIP-05 verification
- **ContentManager**: Content creation, threading, and interactions
- **SocialManager**: Social graph and community features
- **EncryptionManager**: Message encryption/decryption

### Supporting Types

- **SubscriptionManager**: Manages active subscriptions
- **RelayDiscovery**: Discovers relays via NIP-65
- **QueryBuilder**: Filter construction helper

## Testing

NostrKit includes comprehensive test coverage:

```bash
# Run all tests
swift test

# Run unit tests only
swift test --filter NostrKitUnitTests

# Run integration tests (requires network)
swift test --filter RelayIntegrationTests
```

### Test Categories
- **Unit Tests**: Test individual components without network
- **Integration Tests**: Test real relay connections
- **Performance Tests**: Verify message handling at scale

## Requirements

- iOS 17.0+ / macOS 14.0+
- Swift 5.9+
- Xcode 15.0+

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

## Related Projects

- [CoreNostr](../CoreNostr): Platform-agnostic NOSTR implementation
- [NOSTR Protocol](https://github.com/nostr-protocol/nostr): Protocol specification
- [NIPs](https://github.com/nostr-protocol/nips): NOSTR Implementation Possibilities