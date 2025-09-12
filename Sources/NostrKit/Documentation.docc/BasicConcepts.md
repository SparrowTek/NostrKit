# Basic Concepts

Understand the fundamental concepts of Nostr and how they're implemented in NostrKit.

## Overview

Nostr (Notes and Other Stuff Transmitted by Relays) is a decentralized protocol for social networking and communication. This guide explains the core concepts you need to understand when building Nostr applications.

## Key Concepts

### Events

Events are the fundamental unit of data in Nostr. Every piece of content - posts, profiles, reactions, etc. - is an event.

```swift
struct NostrEvent {
    let id: String           // SHA256 hash of the serialized event
    let pubkey: String       // Author's public key
    let createdAt: Int64     // Unix timestamp
    let kind: Int            // Event type
    let tags: [[String]]     // Metadata and references
    let content: String      // Event content
    let sig: String          // Schnorr signature
}
```

### Event Kinds

Different event kinds represent different types of content:

```swift
// Common event kinds
let metadata = 0           // User profile metadata
let textNote = 1          // Short text note
let recommendRelay = 2    // Relay recommendation
let contacts = 3          // Contact/follow list
let encryptedDM = 4       // Encrypted direct message
let deletion = 5          // Event deletion request
let repost = 6           // Repost/boost
let reaction = 7         // Reaction (like, emoji)
let badgeAward = 8       // Badge award
let channelCreation = 40 // Public chat channel
let channelMetadata = 41 // Channel metadata
let channelMessage = 42  // Channel message
```

### Keys and Identity

Nostr uses cryptographic key pairs for identity:

```swift
// Generate a new identity
let keyPair = try KeyPair()

// Components
let privateKey = keyPair.privateKey  // Keep secret!
let publicKey = keyPair.publicKey    // Share freely

// Bech32 encoded versions (human-readable)
let nsec = keyPair.nsec  // Private key (starts with "nsec1")
let npub = keyPair.npub  // Public key (starts with "npub1")
```

**Important Security Notes:**
- **Never share your private key (nsec)**
- Store private keys securely using KeychainWrapper
- Consider using separate keys for different purposes

### Relays

Relays are servers that store and transmit events:

```swift
// Connect to relays
let relay = RelayService(url: "wss://relay.example.com")
try await relay.connect()

// Relays have different characteristics:
// - Some are free, some paid
// - Some filter content
// - Some specialize in certain event types
// - Geographic distribution matters for latency
```

### Filters

Filters specify which events you want to receive:

```swift
// Filter for text notes from specific authors
let filter = Filter(
    authors: ["pubkey1", "pubkey2"],
    kinds: [1],
    since: Date().addingTimeInterval(-3600), // Last hour
    limit: 50
)

// Filter for events mentioning you
let mentionFilter = Filter(
    kinds: [1],
    p: [myPubkey],  // Events that reference you
    limit: 20
)

// Filter for replies to a specific event
let replyFilter = Filter(
    kinds: [1],
    e: [eventId],   // Events referencing this event
    limit: 100
)
```

## Tags System

Tags add metadata and create relationships between events:

### Common Tag Types

```swift
// "e" tag - References an event
["e", eventId, relayURL?, marker?]
// marker can be: "reply", "root", "mention"

// "p" tag - References a public key (person)
["p", pubkey, relayURL?, petname?]

// "t" tag - Hashtag
["t", "nostr"]

// "r" tag - Reference (URL, etc.)
["r", "https://example.com"]

// "subject" tag - Subject line (for long-form content)
["subject", "Article Title"]
```

### Creating Tagged Events

```swift
// Reply to an event
let replyEvent = try NostrEvent(
    pubkey: keyPair.publicKey,
    createdAt: Date(),
    kind: 1,
    tags: [
        ["e", originalEventId, "", "root"],
        ["e", replyToEventId, "", "reply"],
        ["p", originalAuthorPubkey]
    ],
    content: "This is my reply"
)

// Mention someone
let mentionEvent = try NostrEvent(
    pubkey: keyPair.publicKey,
    createdAt: Date(),
    kind: 1,
    tags: [
        ["p", mentionedUserPubkey]
    ],
    content: "Hey @user, check this out!"
)
```

## Content Types

### Text Notes (Kind 1)

Basic social media posts:

```swift
let textNote = try NostrEvent(
    pubkey: keyPair.publicKey,
    createdAt: Date(),
    kind: 1,
    tags: [],
    content: "Hello, Nostr! 🎉"
)
```

### Metadata (Kind 0)

User profile information:

```swift
let metadata = ProfileMetadata(
    name: "Alice",
    about: "Nostr enthusiast",
    picture: "https://example.com/avatar.jpg",
    nip05: "alice@example.com",
    banner: "https://example.com/banner.jpg",
    website: "https://alice.example"
)

let metadataEvent = try NostrEvent(
    pubkey: keyPair.publicKey,
    createdAt: Date(),
    kind: 0,
    tags: [],
    content: try JSONEncoder().encode(metadata).toString()
)
```

### Contact List (Kind 3)

Following/contact management:

```swift
let contactList = try NostrEvent(
    pubkey: keyPair.publicKey,
    createdAt: Date(),
    kind: 3,
    tags: [
        ["p", followedPubkey1, "wss://relay1.com", "Alice"],
        ["p", followedPubkey2, "wss://relay2.com", "Bob"]
    ],
    content: "" // Can contain relay list
)
```

### Reactions (Kind 7)

Likes and emoji reactions:

```swift
// Simple like
let like = try NostrEvent(
    pubkey: keyPair.publicKey,
    createdAt: Date(),
    kind: 7,
    tags: [
        ["e", likedEventId],
        ["p", originalAuthorPubkey]
    ],
    content: "+"  // "+" for like, "-" for dislike, or emoji
)

// Emoji reaction
let emojiReaction = try NostrEvent(
    pubkey: keyPair.publicKey,
    createdAt: Date(),
    kind: 7,
    tags: [
        ["e", eventId],
        ["p", authorPubkey]
    ],
    content: "🔥"
)
```

## Subscriptions

Managing real-time data streams:

```swift
// Subscribe to your home feed
func subscribeToHomeFeed(following: [String]) async throws {
    let filter = Filter(
        authors: following,
        kinds: [1, 6, 7], // Notes, reposts, reactions
        since: Date().addingTimeInterval(-86400), // Last 24 hours
        limit: 100
    )
    
    let subscription = try await relayPool.subscribe(filters: [filter])
    
    for await event in await subscription.events {
        switch event.kind {
        case 1:
            handleTextNote(event)
        case 6:
            handleRepost(event)
        case 7:
            handleReaction(event)
        default:
            break
        }
    }
}
```

## Threading and Replies

Understanding event relationships:

```swift
// Parse thread structure
func parseThread(event: NostrEvent) -> ThreadInfo {
    var rootEvent: String?
    var replyTo: String?
    var mentions: [String] = []
    
    for tag in event.tags {
        guard tag.count >= 2 else { continue }
        
        if tag[0] == "e" {
            if tag.count >= 4 {
                switch tag[3] {
                case "root":
                    rootEvent = tag[1]
                case "reply":
                    replyTo = tag[1]
                case "mention":
                    mentions.append(tag[1])
                default:
                    break
                }
            } else {
                // Legacy format - first e tag is root, last is reply
                if rootEvent == nil {
                    rootEvent = tag[1]
                } else {
                    replyTo = tag[1]
                }
            }
        }
    }
    
    return ThreadInfo(root: rootEvent, replyTo: replyTo, mentions: mentions)
}
```

## NIP-05 Verification

Human-readable addresses:

```swift
// Verify NIP-05 identifier
func verifyNIP05(identifier: String, pubkey: String) async throws -> Bool {
    // identifier format: name@domain.com
    let parts = identifier.split(separator: "@")
    guard parts.count == 2 else { return false }
    
    let name = String(parts[0])
    let domain = String(parts[1])
    
    // Fetch /.well-known/nostr.json
    let url = URL(string: "https://\(domain)/.well-known/nostr.json?name=\(name)")!
    let (data, _) = try await URLSession.shared.data(from: url)
    
    struct NIP05Response: Codable {
        let names: [String: String]
        let relays: [String: [String]]?
    }
    
    let response = try JSONDecoder().decode(NIP05Response.self, from: data)
    return response.names[name] == pubkey
}
```

## Best Practices

### 1. Event Validation

Always validate events before processing:

```swift
func validateEvent(_ event: NostrEvent) -> Bool {
    // Check signature
    guard event.verifySignature() else { return false }
    
    // Check timestamp (not too far in future)
    let now = Date().timeIntervalSince1970
    guard Double(event.createdAt) <= now + 900 else { return false }
    
    // Check content length
    guard event.content.count <= 64000 else { return false }
    
    return true
}
```

### 2. Relay Strategy

Use multiple relays for redundancy:

```swift
// Write to multiple relays
let importantRelays = [
    "wss://relay.damus.io",
    "wss://relay.nostr.band",
    "wss://nos.lol"
]

// Read from specialized relays
let searchRelays = [
    "wss://relay.nostr.band"  // Has search capability
]

let paidRelays = [
    "wss://relay.orangepill.dev"  // Better spam filtering
]
```

### 3. Efficient Filtering

Optimize your filters:

```swift
// Bad: Too broad
let badFilter = Filter(kinds: [1])

// Good: Specific and limited
let goodFilter = Filter(
    authors: following,
    kinds: [1],
    since: Date().addingTimeInterval(-3600),
    limit: 50
)
```

### 4. Content Moderation

Implement client-side filtering:

```swift
func shouldDisplayEvent(_ event: NostrEvent) -> Bool {
    // Check mute list
    if mutedPubkeys.contains(event.pubkey) { return false }
    
    // Check content filters
    if containsSpam(event.content) { return false }
    
    // Check Web of Trust
    if !isInWebOfTrust(event.pubkey) { return false }
    
    return true
}
```

## See Also

- [Getting Started](GettingStarted)
- [NIP-47 Wallet Connect](NIP47WalletConnect)
- [Nostr Implementation Possibilities (NIPs)](https://github.com/nostr-protocol/nips)