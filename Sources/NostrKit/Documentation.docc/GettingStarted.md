# Getting Started with NostrKit

Learn how to set up NostrKit in your iOS application and connect to the Nostr network.

## Installation

### Swift Package Manager

Add NostrKit to your project using Swift Package Manager:

1. In Xcode, select **File → Add Package Dependencies**
2. Enter the package URL: `https://github.com/SparrowTek/NostrKit.git`
3. Select the version or branch you want to use
4. Add NostrKit to your target

### Package.swift

If you're using Package.swift, add NostrKit as a dependency:

```swift
dependencies: [
    .package(url: "https://github.com/SparrowTek/NostrKit.git", from: "1.0.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: ["NostrKit"]
    )
]
```

## Basic Setup

### 1. Import NostrKit

```swift
import NostrKit
import CoreNostr
```

### 2. Create a Key Pair

```swift
// Generate a new key pair
let keyPair = try KeyPair()

// Or use an existing private key
let keyPair = try KeyPair(privateKey: "your-hex-private-key")

// Get the public key for sharing
let npub = keyPair.npub // Bech32-encoded public key
let publicKeyHex = keyPair.publicKey // Hex-encoded public key
```

### 3. Set Up Relay Pool

```swift
@MainActor
class NostrManager: ObservableObject {
    let relayPool = RelayPool()
    let keyPair: KeyPair
    
    init() throws {
        // Load or generate key pair
        self.keyPair = try KeyPair()
        
        Task {
            await setupRelays()
        }
    }
    
    func setupRelays() async {
        do {
            // Add popular relays
            try await relayPool.addRelay(url: "wss://relay.damus.io")
            try await relayPool.addRelay(url: "wss://relay.nostr.band")
            try await relayPool.addRelay(url: "wss://nos.lol")
            
            // Connect to all relays
            await relayPool.connectAll()
        } catch {
            print("Failed to set up relays: \(error)")
        }
    }
}
```

### 4. Publish Your First Event

```swift
func publishTextNote(content: String) async throws {
    // Create a text note event (kind 1)
    let event = try NostrEvent(
        pubkey: keyPair.publicKey,
        createdAt: Date(),
        kind: 1,
        tags: [],
        content: content
    )
    
    // Sign the event
    let signedEvent = try keyPair.signEvent(event)
    
    // Publish to all connected relays
    let results = await relayPool.publish(signedEvent)
    
    // Check results
    for result in results {
        if result.success {
            print("Published to \(result.relay)")
        } else if let error = result.error {
            print("Failed to publish to \(result.relay): \(error)")
        }
    }
}
```

### 5. Subscribe to Events

```swift
func subscribeToGlobalFeed() async throws {
    // Create a filter for text notes
    let filter = Filter(
        kinds: [1], // Text notes
        limit: 50   // Last 50 events
    )
    
    // Subscribe to events
    let subscription = try await relayPool.subscribe(filters: [filter])
    
    // Process incoming events
    Task {
        for await event in await subscription.events {
            print("New event from \(event.pubkey): \(event.content)")
            
            // Update your UI here
            await MainActor.run {
                // Update UI with new event
            }
        }
    }
}
```

## Complete Example

Here's a complete SwiftUI example:

```swift
import SwiftUI
import NostrKit
import CoreNostr

struct ContentView: View {
    @StateObject private var nostrManager = NostrManager()
    @State private var messageText = ""
    
    var body: some View {
        NavigationView {
            VStack {
                // Connection status
                HStack {
                    Circle()
                        .fill(nostrManager.isConnected ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    
                    Text(nostrManager.isConnected ? "Connected" : "Disconnected")
                        .font(.caption)
                    
                    Spacer()
                }
                .padding(.horizontal)
                
                // Event feed
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(nostrManager.events, id: \.id) { event in
                            EventRow(event: event)
                        }
                    }
                    .padding()
                }
                
                // Message composer
                HStack {
                    TextField("What's happening?", text: $messageText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    
                    Button("Post") {
                        Task {
                            await nostrManager.postMessage(messageText)
                            messageText = ""
                        }
                    }
                    .disabled(messageText.isEmpty || !nostrManager.isConnected)
                }
                .padding()
            }
            .navigationTitle("Nostr Feed")
        }
        .task {
            await nostrManager.connect()
        }
    }
}

@MainActor
class NostrManager: ObservableObject {
    @Published var events: [NostrEvent] = []
    @Published var isConnected = false
    
    private let relayPool = RelayPool()
    private let keyPair: KeyPair
    private var subscription: PoolSubscription?
    
    init() {
        do {
            // Generate or load key pair
            self.keyPair = try KeyPair()
        } catch {
            fatalError("Failed to create key pair: \(error)")
        }
    }
    
    func connect() async {
        do {
            // Add relays
            try await relayPool.addRelay(url: "wss://relay.damus.io")
            try await relayPool.addRelay(url: "wss://nos.lol")
            
            // Connect
            await relayPool.connectAll()
            isConnected = true
            
            // Subscribe to global feed
            await subscribeToFeed()
        } catch {
            print("Connection failed: \(error)")
            isConnected = false
        }
    }
    
    func subscribeToFeed() async {
        do {
            let filter = Filter(
                kinds: [1],
                limit: 20
            )
            
            subscription = try await relayPool.subscribe(filters: [filter])
            
            // Listen for events
            Task {
                guard let subscription = subscription else { return }
                
                for await event in await subscription.events {
                    await MainActor.run {
                        // Add to beginning of array for newest first
                        self.events.insert(event, at: 0)
                        
                        // Limit array size
                        if self.events.count > 100 {
                            self.events.removeLast()
                        }
                    }
                }
            }
        } catch {
            print("Subscription failed: \(error)")
        }
    }
    
    func postMessage(_ content: String) async {
        do {
            let event = try NostrEvent(
                pubkey: keyPair.publicKey,
                createdAt: Date(),
                kind: 1,
                tags: [],
                content: content
            )
            
            let signedEvent = try keyPair.signEvent(event)
            _ = await relayPool.publish(signedEvent)
            
            // Add to local feed immediately
            await MainActor.run {
                self.events.insert(signedEvent, at: 0)
            }
        } catch {
            print("Failed to post: \(error)")
        }
    }
}

struct EventRow: View {
    let event: NostrEvent
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(event.pubkey.prefix(8)) + "...")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(event.content)
                .font(.body)
            
            Text(formattedDate)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
    
    var formattedDate: String {
        let date = Date(timeIntervalSince1970: TimeInterval(event.createdAt))
        let formatter = RelativeDateTimeFormatter()
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
```

## Next Steps

- Learn about [Wallet Integration](NIP47WalletConnect)
- Explore [Profile Management](ProfileManager)
- Understand [Event Types](BasicConcepts#event-types)
- Implement [Direct Messages](EncryptionManager)

## Best Practices

1. **Always handle errors** - Network operations can fail
2. **Use async/await** - All network operations are asynchronous
3. **Manage subscriptions** - Close subscriptions when no longer needed
4. **Cache events locally** - Use EventCache for offline support
5. **Respect rate limits** - Don't overwhelm relays with requests

## Troubleshooting

### Connection Issues

If you can't connect to relays:
- Check your internet connection
- Verify relay URLs are correct
- Some relays may be down or require authentication
- Try using different relays

### Event Not Publishing

If events aren't publishing:
- Ensure you're connected to at least one relay
- Verify your event is properly signed
- Check relay responses for error messages
- Some relays may filter certain content

### Missing Events

If you're not receiving expected events:
- Check your filters are correct
- Ensure you're subscribed to the right relays
- Some relays may not have all events
- Consider subscribing to more relays