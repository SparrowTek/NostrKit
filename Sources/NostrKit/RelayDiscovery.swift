import Foundation
import CoreNostr

/// Discovers relays through various mechanisms including NIP-65 relay lists and hardcoded bootstrap relays
///
/// RelayDiscovery provides multiple strategies for finding relays:
/// - NIP-65 relay list metadata from user profiles
/// - Bootstrap relays for initial connections
/// - Relay recommendations from connected relays
/// - DNS-based relay discovery
///
/// ## Example
/// ```swift
/// let discovery = RelayDiscovery()
/// 
/// // Discover relays from a user's NIP-65 relay list
/// let userRelays = try await discovery.discoverRelaysForUser(pubkey: userPubkey, using: relayPool)
/// 
/// // Get bootstrap relays for initial connection
/// let bootstrapRelays = discovery.bootstrapRelays
/// ```
public actor RelayDiscovery {
    
    // MARK: - Types
    
    /// A discovered relay with metadata
    public struct DiscoveredRelay: Sendable {
        public let url: String
        public let source: DiscoverySource
        public let metadata: RelayPool.RelayMetadata
        public let discoveredAt: Date
        public let recommendedBy: [String]? // Public keys that recommend this relay
    }
    
    /// Source of relay discovery
    public enum DiscoverySource: String, Sendable {
        case bootstrap = "bootstrap"
        case nip65 = "nip65"
        case recommendation = "recommendation"
        case dns = "dns"
        case manual = "manual"
    }
    
    // MARK: - Properties
    
    /// Well-known bootstrap relays for initial connections
    public let bootstrapRelays: [DiscoveredRelay] = [
        DiscoveredRelay(
            url: "wss://relay.damus.io",
            source: .bootstrap,
            metadata: RelayPool.RelayMetadata(read: true, write: true, isPrimary: true),
            discoveredAt: Date(),
            recommendedBy: nil
        ),
        DiscoveredRelay(
            url: "wss://relay.nostr.band",
            source: .bootstrap,
            metadata: RelayPool.RelayMetadata(read: true, write: true, isPrimary: false),
            discoveredAt: Date(),
            recommendedBy: nil
        ),
        DiscoveredRelay(
            url: "wss://nos.lol",
            source: .bootstrap,
            metadata: RelayPool.RelayMetadata(read: true, write: true, isPrimary: false),
            discoveredAt: Date(),
            recommendedBy: nil
        ),
        DiscoveredRelay(
            url: "wss://relay.snort.social",
            source: .bootstrap,
            metadata: RelayPool.RelayMetadata(read: true, write: true, isPrimary: false),
            discoveredAt: Date(),
            recommendedBy: nil
        ),
        DiscoveredRelay(
            url: "wss://relay.primal.net",
            source: .bootstrap,
            metadata: RelayPool.RelayMetadata(read: true, write: true, isPrimary: false),
            discoveredAt: Date(),
            recommendedBy: nil
        )
    ]
    
    /// Cache of discovered relays
    private var discoveredRelays: [String: DiscoveredRelay] = [:]
    
    /// Cache of user relay lists (NIP-65)
    private var userRelayLists: [String: RelayListMetadata] = [:]
    
    // MARK: - Public Methods
    
    /// Discovers relays for a specific user from their NIP-65 relay list
    /// - Parameters:
    ///   - pubkey: The user's public key
    ///   - relayPool: The relay pool to query
    /// - Returns: Array of discovered relays
    public func discoverRelaysForUser(
        pubkey: PublicKey,
        using relayPool: RelayPool
    ) async throws -> [DiscoveredRelay] {
        // Check cache first
        if let cached = userRelayLists[pubkey] {
            return relaysFromMetadata(cached, source: .nip65, recommendedBy: [pubkey])
        }
        
        // Create filter for relay list metadata (kind 10002)
        let filter = Filter(
            authors: [pubkey],
            kinds: [EventKind.relayList.rawValue],
            limit: 1
        )
        
        // Subscribe and wait for the relay list
        let subscription = try await relayPool.subscribe(filters: [filter])
        
        var discoveredRelays: [DiscoveredRelay] = []
        var foundRelayList = false
        
        for await event in await subscription.events {
            if event.kind == EventKind.relayList.rawValue {
                let relayList = RelayListMetadata(relays: [])
                userRelayLists[pubkey] = relayList
                discoveredRelays = relaysFromMetadata(relayList, source: .nip65, recommendedBy: [pubkey])
                foundRelayList = true
                break
            }
        }
        
        await relayPool.closeSubscription(id: subscription.id)
        
        if !foundRelayList {
            throw NostrError.notFound(resource: "Relay list for user \(pubkey)")
        }
        
        return discoveredRelays
    }
    
    /// Discovers relays from multiple users' relay lists
    /// - Parameters:
    ///   - pubkeys: Array of user public keys
    ///   - relayPool: The relay pool to query
    /// - Returns: Array of discovered relays with aggregated recommendations
    public func discoverRelaysFromUsers(
        pubkeys: [PublicKey],
        using relayPool: RelayPool
    ) async throws -> [DiscoveredRelay] {
        var allDiscoveredRelays: [String: DiscoveredRelay] = [:]
        var relayRecommendations: [String: Set<String>] = [:] // relay URL -> recommending pubkeys
        
        // Fetch relay lists for all users
        let filter = Filter(
            authors: pubkeys,
            kinds: [EventKind.relayList.rawValue]
        )
        
        let subscription = try await relayPool.subscribe(filters: [filter])
        
        for await event in await subscription.events {
            guard event.kind == EventKind.relayList.rawValue else { continue }
            
            let relayList = RelayListMetadata(relays: [])
            userRelayLists[event.pubkey] = relayList
            
            // Process each relay in the list
            for relay in relayList.relays {
                if relayRecommendations[relay.url] == nil {
                    relayRecommendations[relay.url] = []
                }
                relayRecommendations[relay.url]?.insert(event.pubkey)
                
                // Create or update discovered relay
                if allDiscoveredRelays[relay.url] == nil {
                    allDiscoveredRelays[relay.url] = DiscoveredRelay(
                        url: relay.url,
                        source: .nip65,
                        metadata: RelayPool.RelayMetadata(
                            read: relay.usage == .read || relay.usage == .readWrite,
                            write: relay.usage == .write || relay.usage == .readWrite,
                            isPrimary: false
                        ),
                        discoveredAt: Date(),
                        recommendedBy: Array(relayRecommendations[relay.url] ?? [])
                    )
                } else {
                    // Update recommendations
                    var existingRelay = allDiscoveredRelays[relay.url]!
                    existingRelay = DiscoveredRelay(
                        url: existingRelay.url,
                        source: existingRelay.source,
                        metadata: existingRelay.metadata,
                        discoveredAt: existingRelay.discoveredAt,
                        recommendedBy: Array(relayRecommendations[relay.url] ?? [])
                    )
                    allDiscoveredRelays[relay.url] = existingRelay
                }
            }
        }
        
        await relayPool.closeSubscription(id: subscription.id)
        
        // Sort by number of recommendations
        let sortedRelays = allDiscoveredRelays.values.sorted { relay1, relay2 in
            (relay1.recommendedBy?.count ?? 0) > (relay2.recommendedBy?.count ?? 0)
        }
        
        return sortedRelays
    }
    
    /// Discovers relays from your follows' relay lists
    /// - Parameters:
    ///   - userPubkey: Your public key
    ///   - relayPool: The relay pool to query
    /// - Returns: Array of discovered relays recommended by your follows
    public func discoverRelaysFromFollows(
        userPubkey: PublicKey,
        using relayPool: RelayPool
    ) async throws -> [DiscoveredRelay] {
        // First, get the user's follow list
        let followFilter = Filter(
            authors: [userPubkey],
            kinds: [EventKind.followList.rawValue],
            limit: 1
        )
        
        let followSubscription = try await relayPool.subscribe(filters: [followFilter])
        
        var followPubkeys: [PublicKey] = []
        
        for await event in await followSubscription.events {
            if event.kind == EventKind.followList.rawValue {
                guard let followList = NostrFollowList.from(event: event) else {
                    print("[RelayDiscovery] Failed to parse follow list")
                    continue
                }
                followPubkeys = followList.follows.map { $0.pubkey }
                break
            }
        }
        
        await relayPool.closeSubscription(id: followSubscription.id)
        
        guard !followPubkeys.isEmpty else {
            throw NostrError.notFound(resource: "Follow list for user \(userPubkey)")
        }
        
        // Discover relays from follows
        return try await discoverRelaysFromUsers(pubkeys: followPubkeys, using: relayPool)
    }
    
    /// Clears the discovery cache
    public func clearCache() {
        discoveredRelays.removeAll()
        userRelayLists.removeAll()
    }
    
    /// Gets cached relay list for a user
    /// - Parameter pubkey: The user's public key
    /// - Returns: The cached relay list metadata if available
    public func getCachedRelayList(for pubkey: PublicKey) -> RelayListMetadata? {
        userRelayLists[pubkey]
    }
    
    // MARK: - Private Methods
    
    private func relaysFromMetadata(
        _ metadata: RelayListMetadata,
        source: DiscoverySource,
        recommendedBy: [String]?
    ) -> [DiscoveredRelay] {
        metadata.relays.map { relay in
            return DiscoveredRelay(
                url: relay.url,
                source: source,
                metadata: RelayPool.RelayMetadata(
                    read: relay.usage == .read || relay.usage == .readWrite,
                    write: relay.usage == .write || relay.usage == .readWrite,
                    isPrimary: false
                ),
                discoveredAt: Date(),
                recommendedBy: recommendedBy
            )
        }
    }
}

// MARK: - RelayPool Extension

extension RelayPool {
    
    /// Adds discovered relays to the pool
    /// - Parameters:
    ///   - discoveredRelays: Array of discovered relays
    ///   - limit: Maximum number of relays to add
    /// - Returns: Array of successfully added relay URLs
    @discardableResult
    public func addDiscoveredRelays(
        _ discoveredRelays: [RelayDiscovery.DiscoveredRelay],
        limit: Int? = nil
    ) async throws -> [String] {
        var addedRelays: [String] = []
        let relaysToAdd = limit.map { Array(discoveredRelays.prefix($0)) } ?? discoveredRelays
        
        for discoveredRelay in relaysToAdd {
            do {
                try addRelay(
                    url: discoveredRelay.url,
                    metadata: discoveredRelay.metadata
                )
                addedRelays.append(discoveredRelay.url)
            } catch {
                print("[RelayPool] Failed to add relay \(discoveredRelay.url): \(error)")
            }
        }
        
        return addedRelays
    }
    
    /// Discovers and connects to relays for a user
    /// - Parameters:
    ///   - pubkey: The user's public key
    ///   - connectImmediately: Whether to connect to discovered relays immediately
    /// - Returns: Array of discovered relay URLs
    @discardableResult
    public func discoverAndConnectUserRelays(
        for pubkey: PublicKey,
        connectImmediately: Bool = true
    ) async throws -> [String] {
        let discovery = RelayDiscovery()
        
        // Start with bootstrap relays if we have no connections
        if connectedRelays.isEmpty {
            _ = try await addDiscoveredRelays(discovery.bootstrapRelays, limit: 3)
            
            if connectImmediately {
                await connectAll()
                
                // Wait a moment for connections to establish
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            }
        }
        
        // Discover user's relays
        let userRelays = try await discovery.discoverRelaysForUser(pubkey: pubkey, using: self)
        let addedURLs = try await addDiscoveredRelays(userRelays)
        
        if connectImmediately {
            for url in addedURLs {
                try? await connect(to: url)
            }
        }
        
        return addedURLs
    }
    
    /// Discovers and connects to relays from user's follows
    /// - Parameters:
    ///   - pubkey: The user's public key
    ///   - limit: Maximum number of relays to add
    ///   - connectImmediately: Whether to connect immediately
    /// - Returns: Array of discovered relay URLs
    @discardableResult
    public func discoverAndConnectFollowsRelays(
        for pubkey: PublicKey,
        limit: Int = 10,
        connectImmediately: Bool = true
    ) async throws -> [String] {
        let discovery = RelayDiscovery()
        
        // Ensure we have some relays connected first
        if connectedRelays.isEmpty {
            _ = try await discoverAndConnectUserRelays(for: pubkey)
        }
        
        // Discover relays from follows
        let followRelays = try await discovery.discoverRelaysFromFollows(
            userPubkey: pubkey,
            using: self
        )
        
        // Add relays sorted by recommendation count
        let addedURLs = try await addDiscoveredRelays(followRelays, limit: limit)
        
        if connectImmediately {
            for url in addedURLs {
                try? await connect(to: url)
            }
        }
        
        return addedURLs
    }
}