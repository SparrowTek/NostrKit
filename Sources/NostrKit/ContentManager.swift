import Foundation
import CoreNostr

/// Manages content operations in NOSTR including threads, reactions, reposts, and long-form content.
///
/// ContentManager provides comprehensive content management including:
/// - Thread reconstruction (NIP-10)
/// - Long-form content (NIP-23)
/// - Reactions (NIP-25)
/// - Reposts (NIP-18)
/// - Content search (NIP-50)
///
/// ## Example
/// ```swift
/// let contentManager = ContentManager(relayPool: relayPool, cache: eventCache)
/// 
/// // Reconstruct a thread
/// let thread = try await contentManager.reconstructThread(for: eventId)
/// 
/// // Get reactions for an event
/// let reactions = try await contentManager.fetchReactions(for: eventId)
/// 
/// // Create a reaction
/// try await contentManager.react(to: eventId, with: "❤️", using: "main")
/// ```
public actor ContentManager {
    
    // MARK: - Types
    
    /// Thread structure for NIP-10
    public struct Thread: Sendable {
        public let rootEvent: NostrEvent
        public let replies: [ThreadReply]
        public let mentions: [NostrEvent]
        
        public struct ThreadReply: Sendable {
            public let event: NostrEvent
            public let depth: Int
            public let parentId: EventID?
            public let rootId: EventID
            public let replies: [ThreadReply]
            
            public init(
                event: NostrEvent,
                depth: Int,
                parentId: EventID? = nil,
                rootId: EventID,
                replies: [ThreadReply] = []
            ) {
                self.event = event
                self.depth = depth
                self.parentId = parentId
                self.rootId = rootId
                self.replies = replies
            }
        }
        
        public init(
            rootEvent: NostrEvent,
            replies: [ThreadReply] = [],
            mentions: [NostrEvent] = []
        ) {
            self.rootEvent = rootEvent
            self.replies = replies
            self.mentions = mentions
        }
        
        /// Total number of replies in the thread
        public var replyCount: Int {
            countReplies(in: replies)
        }
        
        private func countReplies(in replies: [ThreadReply]) -> Int {
            replies.reduce(0) { total, reply in
                total + 1 + countReplies(in: reply.replies)
            }
        }
    }
    
    /// Event tags for NIP-10
    public enum EventTagType: String, Sendable {
        case root = "root"
        case reply = "reply"
        case mention = "mention"
    }
    
    /// Long-form content article (NIP-23)
    public struct Article: Sendable {
        public let id: EventID
        public let author: PublicKey
        public let title: String
        public let summary: String?
        public let content: String
        public let image: String?
        public let publishedAt: Date
        public let tags: [String]
        public let isDraft: Bool
        
        public init(
            id: EventID,
            author: PublicKey,
            title: String,
            summary: String? = nil,
            content: String,
            image: String? = nil,
            publishedAt: Date,
            tags: [String] = [],
            isDraft: Bool = false
        ) {
            self.id = id
            self.author = author
            self.title = title
            self.summary = summary
            self.content = content
            self.image = image
            self.publishedAt = publishedAt
            self.tags = tags
            self.isDraft = isDraft
        }
        
        /// Creates an article from a long-form content event
        public init?(from event: NostrEvent) {
            guard event.kind == 30023 else { return nil }
            
            self.id = event.id
            self.author = event.pubkey
            self.content = event.content
            self.publishedAt = Date(timeIntervalSince1970: TimeInterval(event.createdAt))
            
            // Extract metadata from tags
            var title: String?
            var summary: String?
            var image: String?
            var tags: [String] = []
            var isDraft = false
            
            for tag in event.tags {
                guard tag.count >= 2 else { continue }
                
                switch tag[0] {
                case "title":
                    title = tag[1]
                case "summary":
                    summary = tag[1]
                case "image":
                    image = tag[1]
                case "t":
                    tags.append(tag[1])
                case "published_at":
                    // Could parse custom published date if needed
                    break
                case "d":
                    // Identifier tag
                    break
                case "draft":
                    isDraft = true
                default:
                    break
                }
            }
            
            guard let articleTitle = title else { return nil }
            
            self.title = articleTitle
            self.summary = summary
            self.image = image
            self.tags = tags
            self.isDraft = isDraft
        }
    }
    
    /// Reaction to an event (NIP-25)
    public struct Reaction: Sendable {
        public let id: EventID
        public let reactor: PublicKey
        public let targetEventId: EventID
        public let content: String
        public let createdAt: Date
        
        public init(
            id: EventID,
            reactor: PublicKey,
            targetEventId: EventID,
            content: String,
            createdAt: Date
        ) {
            self.id = id
            self.reactor = reactor
            self.targetEventId = targetEventId
            self.content = content
            self.createdAt = createdAt
        }
        
        /// Creates a reaction from an event
        public init?(from event: NostrEvent) {
            guard event.kind == 7 else { return nil }
            
            // Find the event being reacted to
            guard let eTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" }) else {
                return nil
            }
            
            self.id = event.id
            self.reactor = event.pubkey
            self.targetEventId = eTag[1]
            self.content = event.content
            self.createdAt = Date(timeIntervalSince1970: TimeInterval(event.createdAt))
        }
        
        /// Whether this is a positive reaction
        public var isPositive: Bool {
            let positive = ["❤️", "💜", "🤙", "👍", "🔥", "+", "1", "👌", "💯", "🚀"]
            return positive.contains(content)
        }
    }
    
    /// Aggregated reactions for an event
    public struct ReactionSummary: Sendable {
        public let eventId: EventID
        public let reactions: [String: Int] // reaction -> count
        public let totalCount: Int
        public let userReaction: String? // Current user's reaction if any
        
        public init(
            eventId: EventID,
            reactions: [String: Int],
            userReaction: String? = nil
        ) {
            self.eventId = eventId
            self.reactions = reactions
            self.totalCount = reactions.values.reduce(0, +)
            self.userReaction = userReaction
        }
    }
    
    /// Repost of an event (NIP-18)
    public struct Repost: Sendable {
        public let id: EventID
        public let reposter: PublicKey
        public let originalEvent: NostrEvent
        public let comment: String?
        public let createdAt: Date
        
        public init(
            id: EventID,
            reposter: PublicKey,
            originalEvent: NostrEvent,
            comment: String? = nil,
            createdAt: Date
        ) {
            self.id = id
            self.reposter = reposter
            self.originalEvent = originalEvent
            self.comment = comment
            self.createdAt = createdAt
        }
    }
    
    // MARK: - Properties
    
    private let relayPool: RelayPool
    private let eventCache: EventCache
    private let keyStore: SecureKeyStore?
    private var threadCache: [EventID: Thread] = [:]
    private var reactionCache: [EventID: ReactionSummary] = [:]
    private let cacheExpiration: TimeInterval = 300 // 5 minutes
    
    // MARK: - Initialization
    
    public init(
        relayPool: RelayPool,
        eventCache: EventCache,
        keyStore: SecureKeyStore? = nil
    ) {
        self.relayPool = relayPool
        self.eventCache = eventCache
        self.keyStore = keyStore
    }
    
    // MARK: - Thread Reconstruction (NIP-10)
    
    /// Reconstructs a thread from a root event
    /// - Parameters:
    ///   - eventId: The root event ID
    ///   - maxDepth: Maximum depth to traverse
    /// - Returns: The reconstructed thread
    public func reconstructThread(
        for eventId: EventID,
        maxDepth: Int = 10
    ) async throws -> Thread {
        // Check cache
        if let cached = threadCache[eventId] {
            return cached
        }
        
        // Fetch root event
        guard let rootEvent = try await fetchEvent(eventId) else {
            throw NostrError.notFound(resource: "Root event \(eventId)")
        }
        
        // Create filter for all replies
        let filter = Filter(
            kinds: [1], // Text notes
            e: [eventId]
        )
        
        // Subscribe to get all related events
        let events = try await relayPool.subscribe(
            filters: [filter],
            timeout: 5.0
        )
        
        // Build thread structure
        let thread = try buildThread(
            rootEvent: rootEvent,
            allEvents: events,
            maxDepth: maxDepth
        )
        
        // Cache result
        threadCache[eventId] = thread
        
        return thread
    }
    
    /// Creates a reply to an event
    /// - Parameters:
    ///   - eventId: The event to reply to
    ///   - content: Reply content
    ///   - rootId: Optional root event ID (for deep threads)
    ///   - mentions: Additional mentions
    ///   - identity: Identity to use for signing
    /// - Returns: The reply event
    @discardableResult
    public func reply(
        to eventId: EventID,
        content: String,
        rootId: EventID? = nil,
        mentions: [PublicKey] = [],
        using identity: String
    ) async throws -> NostrEvent {
        guard let keyStore = keyStore else {
            throw NostrError.configurationError(message: "KeyStore required for replies")
        }
        
        let keyPair = try await keyStore.retrieve(identity: identity)
        
        // Fetch the event we're replying to
        guard let parentEvent = try await fetchEvent(eventId) else {
            throw NostrError.notFound(resource: "Parent event \(eventId)")
        }
        
        // Build tags according to NIP-10
        var tags: [[String]] = []
        
        // Determine root event
        let actualRootId: EventID
        if let rootId = rootId {
            actualRootId = rootId
        } else if let rootTag = parentEvent.tags.first(where: { 
            $0.count >= 2 && $0[0] == "e" && $0.count >= 4 && $0[3] == "root" 
        }) {
            actualRootId = rootTag[1]
        } else {
            // Parent is the root
            actualRootId = eventId
        }
        
        // Add root tag
        if actualRootId != eventId {
            tags.append(["e", actualRootId, "", "root"])
        }
        
        // Add reply tag
        tags.append(["e", eventId, "", "reply"])
        
        // Add author mention
        tags.append(["p", parentEvent.pubkey])
        
        // Add additional mentions
        for mention in mentions {
            tags.append(["p", mention])
        }
        
        // Create reply event
        var event = NostrEvent(
            pubkey: keyPair.publicKey,
            createdAt: Date(),
            kind: 1,
            tags: tags,
            content: content
        )
        
        event = try keyPair.signEvent(event)
        
        // Publish to relays
        try await relayPool.publish(event: event)
        
        // Cache in event cache
        try? await eventCache.store(event)
        
        return event
    }
    
    // MARK: - Long-form Content (NIP-23)
    
    /// Fetches articles by an author
    /// - Parameters:
    ///   - author: The author's public key
    ///   - limit: Maximum number of articles
    /// - Returns: Array of articles
    public func fetchArticles(
        by author: PublicKey,
        limit: Int = 50
    ) async throws -> [Article] {
        let filter = Filter(
            authors: [author],
            kinds: [30023], // Long-form content
            limit: limit
        )
        
        let events = try await relayPool.subscribe(
            filters: [filter],
            timeout: 5.0
        )
        
        return events.compactMap { Article(from: $0) }
            .sorted { $0.publishedAt > $1.publishedAt }
    }
    
    /// Creates or updates an article
    /// - Parameters:
    ///   - title: Article title
    ///   - content: Article content (markdown)
    ///   - summary: Optional summary
    ///   - image: Optional header image URL
    ///   - tags: Content tags
    ///   - isDraft: Whether this is a draft
    ///   - identifier: Optional identifier for updates
    ///   - identity: Identity to use for signing
    /// - Returns: The article event
    @discardableResult
    public func publishArticle(
        title: String,
        content: String,
        summary: String? = nil,
        image: String? = nil,
        tags: [String] = [],
        isDraft: Bool = false,
        identifier: String? = nil,
        using identity: String
    ) async throws -> NostrEvent {
        guard let keyStore = keyStore else {
            throw NostrError.configurationError(message: "KeyStore required for publishing")
        }
        
        let keyPair = try await keyStore.retrieve(identity: identity)
        
        // Build tags
        var eventTags: [[String]] = []
        
        // Add d-tag (identifier) for replaceability
        let d = identifier ?? UUID().uuidString
        eventTags.append(["d", d])
        
        // Add metadata tags
        eventTags.append(["title", title])
        
        if let summary = summary {
            eventTags.append(["summary", summary])
        }
        
        if let image = image {
            eventTags.append(["image", image])
        }
        
        // Add content tags
        for tag in tags {
            eventTags.append(["t", tag])
        }
        
        // Add published timestamp
        eventTags.append(["published_at", String(Int(Date().timeIntervalSince1970))])
        
        // Add draft tag if needed
        if isDraft {
            eventTags.append(["draft"])
        }
        
        // Create article event
        var event = NostrEvent(
            pubkey: keyPair.publicKey,
            createdAt: Date(),
            kind: 30023,
            tags: eventTags,
            content: content
        )
        
        event = try keyPair.signEvent(event)
        
        // Publish to relays
        try await relayPool.publish(event: event)
        
        return event
    }
    
    // MARK: - Reactions (NIP-25)
    
    /// Fetches reactions for an event
    /// - Parameters:
    ///   - eventId: The event ID
    ///   - forceRefresh: Whether to bypass cache
    /// - Returns: Reaction summary
    public func fetchReactions(
        for eventId: EventID,
        forceRefresh: Bool = false
    ) async throws -> ReactionSummary {
        // Check cache
        if !forceRefresh, let cached = reactionCache[eventId] {
            return cached
        }
        
        // Create filter for reactions
        let filter = Filter(
            kinds: [7], // Reaction events
            e: [eventId]
        )
        
        // Subscribe to get reactions
        let events = try await relayPool.subscribe(
            filters: [filter],
            timeout: 3.0
        )
        
        // Aggregate reactions
        var reactions: [String: Int] = [:]
        var userReaction: String?
        
        // Get current user's pubkey if available
        let currentUserPubkey = try? await getCurrentUserPubkey()
        
        for event in events {
            guard let reaction = Reaction(from: event) else { continue }
            
            reactions[reaction.content, default: 0] += 1
            
            if let currentUser = currentUserPubkey,
               reaction.reactor == currentUser {
                userReaction = reaction.content
            }
        }
        
        let summary = ReactionSummary(
            eventId: eventId,
            reactions: reactions,
            userReaction: userReaction
        )
        
        // Cache result
        reactionCache[eventId] = summary
        
        return summary
    }
    
    /// Creates a reaction to an event
    /// - Parameters:
    ///   - eventId: The event to react to
    ///   - reaction: The reaction (emoji or text)
    ///   - identity: Identity to use for signing
    /// - Returns: The reaction event
    @discardableResult
    public func react(
        to eventId: EventID,
        with reaction: String,
        using identity: String
    ) async throws -> NostrEvent {
        guard let keyStore = keyStore else {
            throw NostrError.configurationError(message: "KeyStore required for reactions")
        }
        
        let keyPair = try await keyStore.retrieve(identity: identity)
        
        // Fetch the event we're reacting to
        guard let targetEvent = try await fetchEvent(eventId) else {
            throw NostrError.notFound(resource: "Target event \(eventId)")
        }
        
        // Build tags
        var tags: [[String]] = []
        
        // Add event reference
        tags.append(["e", eventId])
        
        // Add author reference
        tags.append(["p", targetEvent.pubkey])
        
        // Create reaction event
        var event = NostrEvent(
            pubkey: keyPair.publicKey,
            createdAt: Date(),
            kind: 7,
            tags: tags,
            content: reaction
        )
        
        event = try keyPair.signEvent(event)
        
        // Publish to relays
        try await relayPool.publish(event: event)
        
        // Update cache
        if let cached = reactionCache[eventId] {
            var updatedReactions = cached.reactions
            updatedReactions[reaction, default: 0] += 1
            
            reactionCache[eventId] = ReactionSummary(
                eventId: eventId,
                reactions: updatedReactions,
                userReaction: reaction
            )
        }
        
        return event
    }
    
    // MARK: - Reposts (NIP-18)
    
    /// Creates a repost of an event
    /// - Parameters:
    ///   - eventId: The event to repost
    ///   - comment: Optional comment
    ///   - identity: Identity to use for signing
    /// - Returns: The repost event
    @discardableResult
    public func repost(
        _ eventId: EventID,
        comment: String? = nil,
        using identity: String
    ) async throws -> NostrEvent {
        guard let keyStore = keyStore else {
            throw NostrError.configurationError(message: "KeyStore required for reposts")
        }
        
        let keyPair = try await keyStore.retrieve(identity: identity)
        
        // Fetch the event we're reposting
        guard let originalEvent = try await fetchEvent(eventId) else {
            throw NostrError.notFound(resource: "Original event \(eventId)")
        }
        
        // Build tags
        var tags: [[String]] = []
        
        // Add event reference
        tags.append(["e", eventId, "", ""])
        
        // Add author reference
        tags.append(["p", originalEvent.pubkey])
        
        // Create content
        let content: String
        if let comment = comment {
            // Quote repost with comment
            content = comment
        } else {
            // Simple repost - include original event as JSON
            content = try originalEvent.jsonString()
        }
        
        // Create repost event
        var event = NostrEvent(
            pubkey: keyPair.publicKey,
            createdAt: Date(),
            kind: comment != nil ? 1 : 6, // Kind 1 for quote, 6 for simple repost
            tags: tags,
            content: content
        )
        
        event = try keyPair.signEvent(event)
        
        // Publish to relays
        try await relayPool.publish(event: event)
        
        return event
    }
    
    // MARK: - Content Search (NIP-50)
    
    /// Searches for content
    /// - Parameters:
    ///   - query: Search query
    ///   - kinds: Event kinds to search
    ///   - authors: Authors to filter by
    ///   - since: Start time
    ///   - until: End time
    ///   - limit: Maximum results
    /// - Returns: Array of matching events
    public func search(
        query: String,
        kinds: [Int]? = nil,
        authors: [PublicKey]? = nil,
        since: Date? = nil,
        until: Date? = nil,
        limit: Int = 100
    ) async throws -> [NostrEvent] {
        // Build filter with search extension
        let filter = Filter(
            authors: authors,
            kinds: kinds ?? [1, 30023], // Default to text notes and articles
            since: since,
            until: until,
            limit: limit,
            search: query
        )
        
        // Subscribe to search-capable relays
        let events = try await relayPool.subscribe(
            filters: [filter],
            timeout: 10.0
        )
        
        return events.sorted { $0.createdAt > $1.createdAt }
    }
    
    // MARK: - Private Methods
    
    private func fetchEvent(_ eventId: EventID) async throws -> NostrEvent? {
        // Check cache first
        let cachedFilter = Filter(ids: [eventId], limit: 1)
        let cached = await eventCache.query(filter: cachedFilter)
        if let event = cached.first {
            return event
        }
        
        // Fetch from relays
        let filter = Filter(
            ids: [eventId],
            limit: 1
        )
        
        let events = try await relayPool.subscribe(
            filters: [filter],
            timeout: 3.0
        )
        
        if let event = events.first {
            try? await eventCache.store(event)
            return event
        }
        
        return nil
    }
    
    private func buildThread(
        rootEvent: NostrEvent,
        allEvents: [NostrEvent],
        maxDepth: Int
    ) throws -> Thread {
        var eventMap: [EventID: NostrEvent] = [rootEvent.id: rootEvent]
        var childrenMap: [EventID: [NostrEvent]] = [:]
        var mentions: [NostrEvent] = []
        
        // Build event map and children map
        for event in allEvents {
            eventMap[event.id] = event
            
            // Find parent
            if let replyTag = event.tags.first(where: { 
                $0.count >= 4 && $0[0] == "e" && $0[3] == "reply" 
            }) {
                let parentId = replyTag[1]
                childrenMap[parentId, default: []].append(event)
            } else if let eTag = event.tags.first(where: { 
                $0.count >= 2 && $0[0] == "e" 
            }) {
                // Legacy format - assume it's a reply to the referenced event
                let parentId = eTag[1]
                if parentId == rootEvent.id {
                    childrenMap[parentId, default: []].append(event)
                } else {
                    mentions.append(event)
                }
            }
        }
        
        // Build thread structure recursively
        func buildReplies(
            for eventId: EventID,
            depth: Int,
            rootId: EventID,
            parentId: EventID? = nil
        ) -> [Thread.ThreadReply] {
            guard depth < maxDepth else { return [] }
            
            let children = childrenMap[eventId] ?? []
            
            return children.compactMap { child in
                let replies = buildReplies(
                    for: child.id,
                    depth: depth + 1,
                    rootId: rootId,
                    parentId: eventId
                )
                
                return Thread.ThreadReply(
                    event: child,
                    depth: depth,
                    parentId: parentId,
                    rootId: rootId,
                    replies: replies
                )
            }.sorted { $0.event.createdAt < $1.event.createdAt }
        }
        
        let replies = buildReplies(
            for: rootEvent.id,
            depth: 1,
            rootId: rootEvent.id
        )
        
        return Thread(
            rootEvent: rootEvent,
            replies: replies,
            mentions: mentions
        )
    }
    
    private func getCurrentUserPubkey() async throws -> PublicKey? {
        guard let keyStore = keyStore else { return nil }
        
        // Try to get the main identity
        let identities = try await keyStore.listIdentities()
        return identities.first?.id
    }
}

// MARK: - Content Formatting Extensions

extension ContentManager {
    
    /// Parses mentions from content (NIP-27)
    /// - Parameter content: The content to parse
    /// - Returns: Array of mention positions and pubkeys
    public func parseMentions(
        in content: String
    ) -> [(range: Range<String.Index>, pubkey: PublicKey)] {
        var mentions: [(Range<String.Index>, PublicKey)] = []
        
        // Regex for nostr:npub1... mentions
        let pattern = #"nostr:(npub1[a-z0-9]+)"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return mentions
        }
        
        let nsString = content as NSString
        let matches = regex.matches(
            in: content,
            range: NSRange(location: 0, length: nsString.length)
        )
        
        for match in matches {
            if let range = Range(match.range, in: content),
               let npubRange = Range(match.range(at: 1), in: content) {
                let npub = String(content[npubRange])
                // TODO: Decode npub to hex pubkey
                // For now, use the npub as-is
                mentions.append((range, npub))
            }
        }
        
        return mentions
    }
    
    /// Formats content with proper mention links
    /// - Parameters:
    ///   - content: Raw content
    ///   - mentions: Mention tags from the event
    /// - Returns: Formatted content
    public func formatContent(
        _ content: String,
        mentions: [[String]]
    ) -> String {
        var formatted = content
        
        // Replace #[index] mentions with proper format
        let pattern = #"#\[(\d+)\]"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return formatted
        }
        
        let nsString = formatted as NSString
        let matches = regex.matches(
            in: formatted,
            range: NSRange(location: 0, length: nsString.length)
        )
        
        // Process matches in reverse order to maintain indices
        for match in matches.reversed() {
            if let indexRange = Range(match.range(at: 1), in: formatted),
               let index = Int(formatted[indexRange]),
               index < mentions.count,
               mentions[index].count >= 2,
               mentions[index][0] == "p" {
                
                let pubkey = mentions[index][1]
                let replacement = "@\(String(pubkey.prefix(8)))..."
                
                if let range = Range(match.range, in: formatted) {
                    formatted.replaceSubrange(range, with: replacement)
                }
            }
        }
        
        return formatted
    }
}