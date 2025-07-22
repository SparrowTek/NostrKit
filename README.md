# NostrKit

A Swift implementation of the Nostr protocol, providing a comprehensive SDK for building Nostr applications on Apple platforms.

## Overview

NostrKit is a Swift package that implements the [Nostr protocol](https://github.com/nostr-protocol/nostr) - a simple, open protocol for creating censorship-resistant global social networks. The package is split into two main targets:

- **CoreNostr**: Platform-agnostic core functionality that can be shared across all platforms
- **NostrKit**: iOS-specific implementations including WebSocket networking and relay management

## Features

### Core Protocol Support
- ✅ **NIP-01**: Basic protocol flow (events, signatures, subscriptions)
- ✅ **NIP-02**: Contact lists and petnames
- ✅ **NIP-04**: Encrypted direct messages
- ✅ **NIP-05**: DNS-based internet identifiers
- ✅ **NIP-06**: Basic key derivation from mnemonic seed phrase
- ✅ **NIP-09**: Event deletion
- ✅ **NIP-10**: Reply threading conventions
- ✅ **NIP-11**: Relay information document
- ✅ **NIP-13**: Proof of work
- ✅ **NIP-19**: bech32-encoded entities
- ✅ **NIP-21**: nostr: URL scheme
- ✅ **NIP-23**: Long-form content
- ✅ **NIP-25**: Reactions
- ✅ **NIP-27**: Text note references
- ✅ **NIP-42**: Authentication of clients to relays
- ✅ **NIP-50**: Search capability
- ✅ **NIP-51**: Lists (mute, pin, bookmarks, communities)
- ✅ **NIP-57**: Lightning Zaps
- ✅ **NIP-58**: Badges
- ✅ **NIP-65**: Relay list metadata

### Key Components

#### Event Management
- Create and sign Nostr events
- Verify event signatures
- Serialize/deserialize events
- Event filtering and matching

#### Cryptography
- Key pair generation and management
- Message signing and verification
- NIP-04 encryption/decryption
- BIP-39 mnemonic support
- BIP-32 key derivation

#### Relay Communication
- WebSocket-based relay connections
- Connection pooling and management
- Automatic reconnection
- Message queuing and delivery
- NIP-42 authentication support

#### User Experience Features
- Profile management and NIP-05 verification
- Content threading and long-form articles
- Reactions, reposts, and zaps
- Community/group support
- Notification handling

## Installation

### Swift Package Manager

Add NostrKit to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/SparrowTek/NostrKit.git", from: "1.0.0")
]
```

Or add it through Xcode:
1. File → Add Package Dependencies
2. Enter the repository URL: `https://github.com/SparrowTek/NostrKit.git`
3. Select the version and add to your project

## Usage

### Basic Event Creation

```swift
import NostrKit
import CoreNostr

// Generate a new key pair
let keyPair = try KeyPair.generate()

// Create a text note
let event = try CoreNostr.createTextNote(
    content: "Hello, Nostr!",
    keyPair: keyPair
)

// Verify the event
let isValid = try CoreNostr.verifyEvent(event)
```

### Connecting to Relays

```swift
// Create a relay pool
let pool = RelayPool()

// Add relays
try await pool.addRelay(url: "wss://relay.damus.io")
try await pool.addRelay(url: "wss://nostr.wine")

// Subscribe to events
let filter = Filter(
    kinds: [EventKind.textNote.rawValue],
    limit: 20
)

await pool.subscribe(id: "my-subscription", filters: [filter])

// Listen for events
for await (relay, message) in pool.messages {
    switch message {
    case .event(let subId, let event):
        print("New event from \(relay): \(event.content)")
    case .eose(let subId):
        print("End of stored events for subscription: \(subId)")
    default:
        break
    }
}
```

### Profile Management

```swift
let profileManager = ProfileManager(cacheManager: cacheManager, relayPool: pool)

// Fetch user metadata
let metadata = try await profileManager.fetchMetadata(for: publicKey)

// Verify NIP-05 identifier
let verification = try await profileManager.verifyNIP05(
    identifier: "alice@example.com",
    pubkey: publicKey
)
```

### Content Operations

```swift
let contentManager = ContentManager(relayPool: pool, cacheManager: cacheManager)

// Reconstruct a thread
let thread = try await contentManager.reconstructThread(for: eventId)

// Create a reaction
let reaction = try await contentManager.createReaction(
    to: eventId,
    content: "👍",
    using: "my-identity"
)
```

### Lightning Zaps

```swift
let socialManager = SocialManager(
    relayPool: pool,
    cacheManager: cacheManager,
    identityManager: identityManager
)

// Create a zap request
let zapRequest = try await socialManager.createZapRequest(
    to: recipientPubkey,
    amount: 1000, // satoshis
    comment: "Great post!",
    eventId: eventId,
    using: "my-identity"
)
```

## Architecture

### CoreNostr (Platform-agnostic)
- Event models and serialization
- Cryptographic operations
- Protocol message types
- Filters and subscriptions
- NIP implementations

### NostrKit (iOS-specific)
- WebSocket relay connections
- Relay pool management
- Profile management
- Content management
- Social features
- Caching and persistence

## Requirements

- iOS 17.0+ / macOS 14.0+
- Swift 5.9+
- Xcode 15.0+

## Dependencies

- [swift-secp256k1](https://github.com/21-DOT-DEV/swift-secp256k1) - Cryptographic operations
- [swift-crypto](https://github.com/apple/swift-crypto) - Additional cryptography
- [CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift) - AES encryption
- [BigInt](https://github.com/attaswift/BigInt) - Large number operations
- [SwiftCBOR](https://github.com/valpackett/SwiftCBOR) - CBOR encoding/decoding
- [Vault](https://github.com/SparrowTek/Vault) - Keychain management

## Testing

The project includes comprehensive test suites:

```bash
# Run all tests
swift test

# Run specific test suite
swift test --filter CoreNostrTests
swift test --filter NostrKitTests
```

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- The [Nostr Protocol](https://github.com/nostr-protocol/nostr) community
- [rust-nostr](https://github.com/rust-nostr/nostr) for inspiration
- All the NIP authors and contributors