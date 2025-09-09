# ``NostrKit``

A comprehensive iOS/macOS SDK for building production-ready NOSTR applications with advanced networking, caching, and social features.

## Overview

NostrKit is the premier iOS and macOS implementation of the NOSTR protocol, designed specifically for Apple platform developers. It provides everything you need to build world-class decentralized social applications with minimal effort and maximum performance.

This SDK handles all the complex aspects of NOSTR development:
- WebSocket connection management with automatic reconnection
- Multi-relay coordination and load balancing
- Event caching and deduplication
- Secure key storage with biometric authentication
- Profile and social graph management
- Lightning integration for zaps
- And much more...

### Why NostrKit?

Building a NOSTR application involves many challenges:
- Managing unreliable WebSocket connections
- Coordinating between multiple relays
- Handling duplicate events from different relays
- Securely storing user keys
- Implementing complex NIPs correctly
- Optimizing for mobile battery and data usage

NostrKit solves all these problems with a clean, Swift-native API that feels right at home on Apple platforms.

## Getting Started

### Installation

Add NostrKit to your Xcode project:

1. In Xcode, select **File → Add Package Dependencies**
2. Enter the repository URL: `https://github.com/SparrowTek/NostrKit.git`
3. Select your desired version or branch
4. Add NostrKit to your app target

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/SparrowTek/NostrKit.git", from: "1.0.0")
]
```

### Your First NOSTR App

Here's a complete example to get you started:

```swift
import SwiftUI
import NostrKit
import CoreNostr

@main
struct MyNostrApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var relayPool = RelayPool()
    @State private var events: [NostrEvent] = []
    @State private var isConnected = false
    
    var body: some View {
        NavigationStack {
            List(events, id: \.id) { event in
                VStack(alignment: .leading) {
                    Text(event.content)
                        .font(.body)
                    Text(event.createdAt.formatted())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("NOSTR Feed")
            .toolbar {
                ToolbarItem(placement: .status) {
                    Label(
                        isConnected ? "Connected" : "Disconnected",
                        systemImage: isConnected ? "wifi" : "wifi.slash"
                    )
                }
            }
        }
        .task {
            await setupNostr()
        }
    }
    
    func setupNostr() async {
        do {
            // Connect to popular relays
            try await relayPool.addRelay(url: "wss://relay.damus.io")
            try await relayPool.addRelay(url: "wss://nos.lol")
            try await relayPool.connectAll()
            
            isConnected = true
            
            // Subscribe to text notes
            let subscription = try await relayPool.subscribe(
                filters: [Filter(kinds: [.textNote], limit: 50)]
            )
            
            // Process incoming events
            for await event in subscription.events {
                events.append(event)
            }
        } catch {
            print("Error: \(error)")
        }
    }
}
```

## Core Concepts

### The NOSTR Protocol

NOSTR (Notes and Other Stuff Transmitted by Relays) is a simple, decentralized protocol for social media and other applications. Key concepts:

- **Events**: The fundamental unit of data in NOSTR
- **Relays**: Servers that store and forward events
- **Keys**: Public/private key pairs that identify users
- **Filters**: Queries to retrieve specific events
- **NIPs**: NOSTR Implementation Possibilities (protocol extensions)

### NostrKit Architecture

NostrKit is organized into several layers:

1. **Network Layer**: Manages WebSocket connections to relays
2. **Protocol Layer**: Handles NOSTR protocol messages
3. **Cache Layer**: Stores and retrieves events efficiently
4. **Manager Layer**: Provides high-level APIs for common tasks
5. **Security Layer**: Manages keys and encryption

### Threading and Concurrency

NostrKit is built with Swift concurrency in mind:

- All async operations use Swift's async/await
- Actors ensure thread safety
- AsyncSequence for event streams
- Structured concurrency for proper resource management

## Essential Components

### RelayPool

The ``RelayPool`` is your main interface for interacting with NOSTR relays:

```swift
let pool = RelayPool(configuration: .default)

// Add relays
try await pool.addRelay(url: "wss://relay.example.com")

// Publish events
let event = try CoreNostr.createTextNote(keyPair: keyPair, content: "Hello!")
let results = await pool.publish(event)

// Subscribe to events
let subscription = try await pool.subscribe(filters: [filter])
for await event in subscription.events {
    // Process events
}
```

### SecureKeyStore

The ``SecureKeyStore`` provides secure key management with iOS Keychain:

```swift
let keyStore = SecureKeyStore()

// Store keys securely
try await keyStore.store(keyPair, for: "main", permissions: .biometricRequired)

// Retrieve with authentication
let keyPair = try await keyStore.retrieve(identity: "main")
```

### ProfileManager

The ``ProfileManager`` handles user profiles and metadata:

```swift
let profileManager = ProfileManager(relayPool: pool)

// Fetch profiles
let profile = try await profileManager.fetchProfile(pubkey: pubkey)

// Update your profile
try await profileManager.updateProfile(
    keyPair: keyPair,
    name: "Alice",
    about: "iOS Developer"
)
```

## Topics

### Essentials
- <doc:GettingStarted>
- <doc:BasicConcepts>
- <doc:FirstNostrApp>
- ``RelayPool``
- ``SecureKeyStore``
- ``EventCache``

### Networking
- <doc:ManagingRelays>
- <doc:ConnectionResilience>
- <doc:RelayDiscovery>
- ``RelayService``
- ``ResilientRelayService``
- ``NetworkResilience``

### Events & Subscriptions
- <doc:PublishingEvents>
- <doc:SubscribingToEvents>
- <doc:EventFiltering>
- ``SubscriptionManager``
- ``QueryBuilder``
- ``Filter``

### User Profiles
- <doc:ProfileManagement>
- <doc:NIP05Verification>
- <doc:ContactLists>
- ``ProfileManager``
- ``Profile``

### Content Creation
- <doc:CreatingContent>
- <doc:ThreadingReplies>
- <doc:LongFormContent>
- ``ContentManager``
- ``NostrEvent``

### Social Features
- <doc:SocialInteractions>
- <doc:LightningZaps>
- <doc:Communities>
- ``SocialManager``
- ``ZapRequest``

### Security
- <doc:KeyManagement>
- <doc:MessageEncryption>
- <doc:BiometricAuth>
- ``EncryptionManager``
- ``KeychainWrapper``

### Advanced Topics
- <doc:CustomNIPs>
- <doc:PerformanceOptimization>
- <doc:BackgroundProcessing>
- <doc:MigrationGuide>

### SwiftUI Integration
- <doc:SwiftUIIntegration>
- <doc:ObservableModels>
- <doc:RealtimeUpdates>
- ``SwiftUIStreams``

### Testing
- <doc:TestingStrategies>
- <doc:MockingRelays>
- <doc:IntegrationTests>

## Platform Support

NostrKit supports the following platforms:

- **iOS 17.0+**: Full support with all features
- **macOS 14.0+**: Full support with Mac-specific optimizations
- **iPadOS 17.0+**: Optimized for larger screens
- **Mac Catalyst**: Supported with iOS compatibility
- **tvOS 17.0+**: Limited support (no keychain)
- **watchOS 10.0+**: Limited support (companion app mode)
- **visionOS 1.0+**: Full support with spatial computing features

## See Also

- ``CoreNostr``: The protocol implementation layer
- [NOSTR Protocol Specification](https://github.com/nostr-protocol/nostr)
- [NIP Repository](https://github.com/nostr-protocol/nips)
- [NostrKit GitHub](https://github.com/SparrowTek/NostrKit)