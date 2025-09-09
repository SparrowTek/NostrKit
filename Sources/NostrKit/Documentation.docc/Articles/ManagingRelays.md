# Managing Relays

Learn how to effectively manage relay connections in your NOSTR application.

## Overview

Relays are the backbone of the NOSTR network. They store and forward events between clients. Managing relay connections effectively is crucial for building a responsive and reliable NOSTR application. This guide covers everything you need to know about relay management in NostrKit.

## Understanding Relays

### What Are Relays?

Relays are WebSocket servers that:
- Accept events from clients
- Store events (temporarily or permanently)
- Forward events to subscribed clients
- Filter events based on client queries

Each relay operates independently with its own:
- Storage policies
- Rate limits
- Content moderation rules
- Supported NIPs

### Relay Categories

**Public Relays**
- Open to everyone
- Free to use
- May have rate limits
- Examples: relay.damus.io, nos.lol

**Private Relays**
- Require authentication
- May charge fees
- Often have better performance
- Examples: nostr.wine, relay.nostr.com.au

**Specialized Relays**
- Focus on specific content types
- Geographic or language-specific
- Community-run relays
- Backup/archive relays

## Using RelayPool

The `RelayPool` class is your primary interface for managing multiple relay connections:

### Basic Setup

```swift
import NostrKit

// Create a relay pool with default configuration
let relayPool = RelayPool()

// Or with custom configuration
let config = RelayPoolConfiguration(
    maxRelaysPerPool: 10,
    connectionTimeout: 5.0,
    defaultRelayMetadata: RelayPool.RelayMetadata(
        read: true,
        write: true
    )
)
let customPool = RelayPool(configuration: config)
```

### Adding Relays

```swift
// Add a single relay
try await relayPool.addRelay(url: "wss://relay.damus.io")

// Add relay with metadata
try await relayPool.addRelay(
    url: "wss://relay.nostr.band",
    metadata: RelayPool.RelayMetadata(
        read: true,
        write: false,  // Read-only relay
        isPrimary: false,
        supportedNips: [1, 2, 9, 11, 12, 15, 16, 20, 22]
    )
)

// Add multiple relays
let relayURLs = [
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.snort.social",
    "wss://nostr.wine"
]

for url in relayURLs {
    try await relayPool.addRelay(url: url)
}
```

### Connecting to Relays

```swift
// Connect to all added relays
try await relayPool.connectAll()

// Connect to specific relay
try await relayPool.connect(to: "wss://relay.damus.io")

// Connect with retry logic
try await relayPool.connectAll(withRetry: true, maxAttempts: 3)
```

### Monitoring Connection Status

```swift
// Set up delegate for status updates
class RelayMonitor: RelayPoolDelegate {
    func relayPool(
        _ pool: RelayPool,
        didChangeStatus status: RelayConnectionStatus,
        for url: String
    ) {
        switch status {
        case .connecting:
            print("Connecting to \(url)")
        case .connected:
            print("Connected to \(url)")
        case .disconnected(let error):
            print("Disconnected from \(url): \(error?.localizedDescription ?? "Unknown")")
        case .reconnecting(attempt: let attempt):
            print("Reconnecting to \(url) (attempt \(attempt))")
        }
    }
    
    func relayPool(
        _ pool: RelayPool,
        didReceiveEvent event: NostrEvent,
        from url: String
    ) {
        print("Received event \(event.id) from \(url)")
    }
}

let monitor = RelayMonitor()
await relayPool.setDelegate(monitor)

// Get current status
let statuses = await relayPool.connectionStatuses()
for (url, status) in statuses {
    print("\(url): \(status)")
}
```

## Connection Resilience

### Automatic Reconnection

NostrKit automatically handles reconnection with exponential backoff:

```swift
let config = RelayPoolConfiguration(
    reconnectStrategy: .exponentialBackoff(
        initialDelay: 1.0,      // Start with 1 second
        maxDelay: 60.0,         // Cap at 60 seconds
        multiplier: 2.0,        // Double each time
        jitter: 0.3             // Add 30% randomness
    ),
    maxReconnectAttempts: 10
)

let resilientPool = RelayPool(configuration: config)
```

### Circuit Breaker Pattern

Protect against repeatedly failing relays:

```swift
let resilientService = ResilientRelayService(
    baseURL: "wss://relay.example.com",
    configuration: ResilienceConfiguration(
        circuitBreakerThreshold: 3,      // Open after 3 failures
        circuitBreakerResetTime: 30.0,   // Try again after 30 seconds
        circuitBreakerSuccessThreshold: 2 // Need 2 successes to close
    )
)

// Monitor circuit state
resilientService.onCircuitStateChange = { state in
    switch state {
    case .closed:
        print("Circuit closed - relay operational")
    case .open:
        print("Circuit open - relay unavailable")
    case .halfOpen:
        print("Circuit half-open - testing relay")
    }
}
```

### Connection Health Monitoring

```swift
class HealthMonitor {
    let relayPool: RelayPool
    private var healthChecks: [String: RelayHealth] = [:]
    
    struct RelayHealth {
        var responseTime: TimeInterval
        var successRate: Double
        var lastSeen: Date
        var errorCount: Int
    }
    
    func startMonitoring() {
        Task {
            while true {
                await checkAllRelays()
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
            }
        }
    }
    
    func checkAllRelays() async {
        let relays = await relayPool.connectedRelays()
        
        for relay in relays {
            let startTime = Date()
            
            do {
                // Send ping or small request
                let testEvent = try CoreNostr.createTextNote(
                    keyPair: testKeyPair,
                    content: "ping"
                )
                
                let results = await relayPool.publish(testEvent, to: [relay])
                
                let responseTime = Date().timeIntervalSince(startTime)
                
                // Update health metrics
                updateHealth(for: relay, responseTime: responseTime, success: true)
            } catch {
                updateHealth(for: relay, responseTime: nil, success: false)
            }
        }
    }
    
    func updateHealth(for relay: String, responseTime: TimeInterval?, success: Bool) {
        var health = healthChecks[relay] ?? RelayHealth(
            responseTime: 0,
            successRate: 1.0,
            lastSeen: Date(),
            errorCount: 0
        )
        
        if success {
            health.responseTime = responseTime ?? 0
            health.lastSeen = Date()
            health.successRate = (health.successRate * 0.9) + 0.1 // Weighted average
        } else {
            health.errorCount += 1
            health.successRate = health.successRate * 0.9 // Decay
        }
        
        healthChecks[relay] = health
        
        // Take action on unhealthy relays
        if health.successRate < 0.5 || health.errorCount > 10 {
            Task {
                await relayPool.disconnect(from: relay)
                print("Disconnected unhealthy relay: \(relay)")
            }
        }
    }
}
```

## Load Balancing

### Round-Robin Strategy

```swift
let config = RelayPoolConfiguration(
    loadBalancingStrategy: .roundRobin
)

let pool = RelayPool(configuration: config)

// Events will be distributed evenly across relays
for i in 0..<100 {
    let event = try CoreNostr.createTextNote(
        keyPair: keyPair,
        content: "Message \(i)"
    )
    await pool.publish(event) // Automatically load balanced
}
```

### Weighted Distribution

```swift
class WeightedRelayPool: RelayPool {
    private var relayWeights: [String: Double] = [:]
    
    func setWeight(_ weight: Double, for relay: String) {
        relayWeights[relay] = weight
    }
    
    override func selectRelaysForPublish() async -> [String] {
        let connected = await connectedRelays()
        
        // Sort by weight and select proportionally
        return connected.sorted { relay1, relay2 in
            (relayWeights[relay1] ?? 1.0) > (relayWeights[relay2] ?? 1.0)
        }
    }
}

// Usage
let weightedPool = WeightedRelayPool()
await weightedPool.setWeight(3.0, for: "wss://relay.damus.io") // Prefer this relay
await weightedPool.setWeight(1.0, for: "wss://nos.lol")
await weightedPool.setWeight(0.5, for: "wss://backup.relay.com") // Use less frequently
```

### Geographic Distribution

```swift
struct GeographicRelay {
    let url: String
    let region: Region
    let latency: TimeInterval
    
    enum Region {
        case northAmerica
        case europe
        case asia
        case southAmerica
        case africa
        case oceania
    }
}

class GeographicRelayPool {
    private var relaysByRegion: [GeographicRelay.Region: [GeographicRelay]] = [:]
    
    func addRelay(_ relay: GeographicRelay) {
        relaysByRegion[relay.region, default: []].append(relay)
    }
    
    func selectOptimalRelays(for userRegion: GeographicRelay.Region) -> [String] {
        var selected: [String] = []
        
        // Prioritize user's region
        if let regional = relaysByRegion[userRegion] {
            selected.append(contentsOf: regional.map { $0.url })
        }
        
        // Add one relay from each other region for redundancy
        for (region, relays) in relaysByRegion where region != userRegion {
            if let fastest = relays.min(by: { $0.latency < $1.latency }) {
                selected.append(fastest.url)
            }
        }
        
        return selected
    }
}
```

## Relay Discovery

### NIP-65 Relay Discovery

```swift
let discovery = RelayDiscovery(relayPool: relayPool)

// Discover relays for a specific user
let userRelays = try await discovery.discoverRelays(for: userPubkey)
print("User prefers: \(userRelays)")

// Add discovered relays to pool
for relayURL in userRelays {
    try await relayPool.addRelay(url: relayURL)
}

// Bootstrap from well-known relays
let bootstrapRelays = try await discovery.fetchBootstrapRelays()
for relay in bootstrapRelays {
    try await relayPool.addRelay(
        url: relay.url,
        metadata: RelayPool.RelayMetadata(
            read: relay.read,
            write: relay.write
        )
    )
}
```

### Relay Information (NIP-11)

```swift
struct RelayInfo {
    let name: String
    let description: String
    let pubkey: String?
    let contact: String?
    let supportedNips: [Int]
    let software: String?
    let version: String?
    let limitation: Limitations?
    
    struct Limitations {
        let maxMessageLength: Int?
        let maxSubscriptions: Int?
        let maxFilters: Int?
        let authRequired: Bool
        let paymentRequired: Bool
    }
}

func fetchRelayInfo(url: String) async throws -> RelayInfo {
    // Convert wss:// to https://
    let httpURL = url.replacingOccurrences(of: "wss://", with: "https://")
    
    let (data, _) = try await URLSession.shared.data(
        from: URL(string: httpURL)!,
        delegate: nil
    )
    
    return try JSONDecoder().decode(RelayInfo.self, from: data)
}

// Check relay capabilities before using
let info = try await fetchRelayInfo(url: "wss://relay.example.com")
if info.supportedNips.contains(50) { // NIP-50: Search
    // This relay supports search
    print("Relay supports search functionality")
}
```

## Publishing Strategies

### Blast to All Relays

```swift
// Publish to all connected relays
let event = try CoreNostr.createTextNote(
    keyPair: keyPair,
    content: "Important announcement!"
)

let results = await relayPool.publish(event)

print("Published to \(results.successes.count) relays")
print("Failed on \(results.failures.count) relays")

for failure in results.failures {
    print("Failed on \(failure.relay): \(failure.error)")
}
```

### Selective Publishing

```swift
// Publish only to specific relays
let writeRelays = await relayPool.relays(where: { $0.metadata.write })

let results = await relayPool.publish(
    event,
    to: writeRelays.map { $0.url }
)

// Publish to primary relays first, then others
let primaryRelays = await relayPool.relays(where: { $0.metadata.isPrimary })
let primaryResults = await relayPool.publish(event, to: primaryRelays.map { $0.url })

if primaryResults.successes.isEmpty {
    // Fallback to all relays if primary publish failed
    await relayPool.publish(event)
}
```

### Staged Publishing

```swift
class StagedPublisher {
    let relayPool: RelayPool
    
    func publishWithConfirmation(_ event: NostrEvent) async throws {
        // Stage 1: Publish to fast, reliable relays
        let tier1Relays = ["wss://relay.damus.io", "wss://nos.lol"]
        let tier1Results = await relayPool.publish(event, to: tier1Relays)
        
        guard !tier1Results.successes.isEmpty else {
            throw PublishError.tier1Failed
        }
        
        // Stage 2: Wait for confirmation
        let confirmed = await waitForConfirmation(event.id, from: tier1Relays, timeout: 5.0)
        
        guard confirmed else {
            throw PublishError.confirmationTimeout
        }
        
        // Stage 3: Broadcast to remaining relays
        let allRelays = await relayPool.connectedRelays()
        let remainingRelays = allRelays.filter { !tier1Relays.contains($0) }
        
        await relayPool.publish(event, to: remainingRelays)
    }
    
    func waitForConfirmation(
        _ eventId: EventID,
        from relays: [String],
        timeout: TimeInterval
    ) async -> Bool {
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            // Query for the event
            let filter = Filter(ids: [eventId])
            let results = await relayPool.query(filter: filter, from: relays)
            
            if !results.isEmpty {
                return true
            }
            
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        
        return false
    }
}
```

## Best Practices

### 1. Relay Selection

- Start with 3-5 well-known, reliable relays
- Add user-specific relays based on their relay list (NIP-65)
- Consider geographic distribution for global reach
- Monitor relay performance and rotate underperforming ones

### 2. Connection Management

- Implement proper error handling and retry logic
- Use connection pooling to avoid overwhelming relays
- Respect relay rate limits and connection limits
- Close idle connections to save resources

### 3. Redundancy

- Always publish to multiple relays for redundancy
- Subscribe from multiple relays to avoid missing events
- Implement fallback strategies for critical operations
- Cache events locally for offline resilience

### 4. Performance

- Batch operations when possible
- Use filters effectively to reduce bandwidth
- Implement local caching to reduce relay queries
- Monitor and optimize based on metrics

### 5. Security

- Validate relay SSL certificates
- Be cautious with relays requiring authentication
- Never send private keys to relays
- Verify event signatures from untrusted relays

## Troubleshooting

### Common Issues

**Connection Timeouts**
```swift
// Increase timeout for slow relays
let config = RelayPoolConfiguration(
    connectionTimeout: 10.0 // 10 seconds instead of default 5
)
```

**Rate Limiting**
```swift
// Implement rate limiting on client side
class RateLimitedPool: RelayPool {
    private let rateLimiter = RateLimiter(maxRequests: 10, per: .seconds(1))
    
    override func publish(_ event: NostrEvent) async -> PublishResults {
        await rateLimiter.wait()
        return await super.publish(event)
    }
}
```

**WebSocket Errors**
```swift
// Handle specific WebSocket errors
func handleWebSocketError(_ error: Error, for relay: String) {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .cannotConnectToHost:
            print("Cannot connect to \(relay)")
        case .networkConnectionLost:
            print("Network connection lost")
        case .notConnectedToInternet:
            print("No internet connection")
        default:
            print("URL error: \(urlError)")
        }
    }
}
```

## Summary

Effective relay management is crucial for building robust NOSTR applications. NostrKit provides powerful tools for:

- Managing multiple relay connections
- Handling connection failures gracefully
- Implementing sophisticated publishing strategies
- Monitoring relay health and performance
- Discovering and evaluating new relays

By following the patterns and best practices in this guide, you can build NOSTR applications that are resilient, performant, and provide a great user experience even in the face of network issues and relay failures.