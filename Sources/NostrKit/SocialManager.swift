import Foundation
import CoreNostr

/// Manages social features in NOSTR including zaps, communities, and notifications.
///
/// SocialManager provides comprehensive social interaction features including:
/// - Lightning Zaps (NIP-57)
/// - Communities/Groups (NIP-29/NIP-72)
/// - Notifications for mentions (NIP-27)
/// - User status updates (NIP-38)
///
/// ## Example
/// ```swift
/// let socialManager = SocialManager(relayPool: relayPool, profileManager: profileManager)
/// 
/// // Send a zap
/// let zapRequest = try await socialManager.createZapRequest(
///     to: recipientPubkey,
///     amount: 1000,
///     comment: "Great post!",
///     using: "main"
/// )
/// 
/// // Join a community
/// try await socialManager.joinCommunity(
///     communityId,
///     using: "main"
/// )
/// 
/// // Check notifications
/// let notifications = try await socialManager.fetchNotifications(
///     for: "main",
///     since: lastChecked
/// )
/// ```
public actor SocialManager {
    
    // MARK: - Types
    
    /// Lightning Zap request (NIP-57)
    public struct ZapRequest: Sendable {
        public let id: EventID
        public let recipient: PublicKey
        public let amount: Int64 // millisatoshis
        public let comment: String?
        public let relays: [String]
        public let event: NostrEvent
        public let lnurl: String
        
        public init(
            id: EventID,
            recipient: PublicKey,
            amount: Int64,
            comment: String? = nil,
            relays: [String],
            event: NostrEvent,
            lnurl: String
        ) {
            self.id = id
            self.recipient = recipient
            self.amount = amount
            self.comment = comment
            self.relays = relays
            self.event = event
            self.lnurl = lnurl
        }
    }
    
    /// Zap receipt
    public struct ZapReceipt: Sendable {
        public let id: EventID
        public let zapRequest: ZapRequest
        public let preimage: String?
        public let bolt11: String
        public let paidAt: Date
        
        public init(
            id: EventID,
            zapRequest: ZapRequest,
            preimage: String? = nil,
            bolt11: String,
            paidAt: Date
        ) {
            self.id = id
            self.zapRequest = zapRequest
            self.preimage = preimage
            self.bolt11 = bolt11
            self.paidAt = paidAt
        }
        
        /// Creates a zap receipt from an event
        public init?(from event: NostrEvent) {
            guard event.kind == 9735 else { return nil }
            
            // Extract zap request from tags
            guard let descriptionTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "description" }),
                  let zapRequestJson = descriptionTag[1].data(using: .utf8),
                  let zapRequestEvent = try? JSONDecoder().decode(NostrEvent.self, from: zapRequestJson),
                  zapRequestEvent.kind == 9734 else {
                return nil
            }
            
            // Extract bolt11 invoice
            guard let bolt11Tag = event.tags.first(where: { $0.count >= 2 && $0[0] == "bolt11" }) else {
                return nil
            }
            
            self.id = event.id
            self.bolt11 = bolt11Tag[1]
            self.paidAt = Date(timeIntervalSince1970: TimeInterval(event.createdAt))
            
            // Extract preimage if available
            self.preimage = event.tags.first(where: { $0.count >= 2 && $0[0] == "preimage" })?[1]
            
            // Parse zap request details
            let recipient = zapRequestEvent.tags.first(where: { $0.count >= 2 && $0[0] == "p" })?[1] ?? ""
            let amount = zapRequestEvent.tags.first(where: { $0.count >= 2 && $0[0] == "amount" }).flatMap { Int64($0[1]) } ?? 0
            let relays = zapRequestEvent.tags.first(where: { $0.count >= 2 && $0[0] == "relays" })?.dropFirst().map { String($0) } ?? []
            
            self.zapRequest = ZapRequest(
                id: zapRequestEvent.id,
                recipient: recipient,
                amount: amount,
                comment: zapRequestEvent.content.isEmpty ? nil : zapRequestEvent.content,
                relays: Array(relays),
                event: zapRequestEvent,
                lnurl: "" // Would need to be extracted from recipient's profile
            )
        }
    }
    
    /// Community/Group (NIP-29/NIP-72)
    public struct Community: Sendable {
        public let id: String
        public let name: String
        public let description: String?
        public let picture: String?
        public let moderators: Set<PublicKey>
        public let rules: [String]
        public let createdAt: Date
        public let relay: String?
        
        public init(
            id: String,
            name: String,
            description: String? = nil,
            picture: String? = nil,
            moderators: Set<PublicKey> = [],
            rules: [String] = [],
            createdAt: Date = Date(),
            relay: String? = nil
        ) {
            self.id = id
            self.name = name
            self.description = description
            self.picture = picture
            self.moderators = moderators
            self.rules = rules
            self.createdAt = createdAt
            self.relay = relay
        }
        
        /// Creates a community from a community definition event
        public init?(from event: NostrEvent) {
            guard event.kind == 34550 else { return nil }
            
            // Extract d-tag for community ID
            guard let dTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "d" }) else {
                return nil
            }
            
            self.id = dTag[1]
            self.createdAt = Date(timeIntervalSince1970: TimeInterval(event.createdAt))
            
            // Parse JSON metadata
            if let data = event.content.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.name = json["name"] as? String ?? ""
                self.description = json["description"] as? String
                self.picture = json["picture"] as? String
                self.rules = json["rules"] as? [String] ?? []
            } else {
                self.name = ""
                self.description = nil
                self.picture = nil
                self.rules = []
            }
            
            // Extract moderators from tags
            self.moderators = Set(event.tags.compactMap { tag in
                tag.count >= 3 && tag[0] == "p" && tag[2] == "moderator" ? tag[1] : nil
            })
            
            // Extract relay hint
            self.relay = event.tags.first(where: { $0.count >= 2 && $0[0] == "relay" })?[1]
        }
    }
    
    /// Notification types
    public enum NotificationType: String, CaseIterable, Sendable {
        case mention = "mention"
        case reply = "reply"
        case reaction = "reaction"
        case repost = "repost"
        case zap = "zap"
        case follow = "follow"
        case unfollow = "unfollow"
        case dm = "dm"
    }
    
    /// Notification
    public struct Notification: Sendable {
        public let id: String
        public let type: NotificationType
        public let event: NostrEvent
        public let relatedEvent: NostrEvent?
        public let actor: PublicKey
        public let createdAt: Date
        public let isRead: Bool
        
        public init(
            id: String,
            type: NotificationType,
            event: NostrEvent,
            relatedEvent: NostrEvent? = nil,
            actor: PublicKey,
            createdAt: Date,
            isRead: Bool = false
        ) {
            self.id = id
            self.type = type
            self.event = event
            self.relatedEvent = relatedEvent
            self.actor = actor
            self.createdAt = createdAt
            self.isRead = isRead
        }
    }
    
    /// User status (NIP-38)
    public struct UserStatus: Sendable {
        public let pubkey: PublicKey
        public let status: StatusType
        public let content: String?
        public let linkUrl: String?
        public let expiresAt: Date?
        public let createdAt: Date
        
        public enum StatusType: String, CaseIterable, Sendable {
            case general = "general"
            case music = "music"
            case video = "video"
            case gaming = "gaming"
            case working = "working"
            case traveling = "traveling"
            case eating = "eating"
            case custom = "custom"
        }
        
        public init(
            pubkey: PublicKey,
            status: StatusType,
            content: String? = nil,
            linkUrl: String? = nil,
            expiresAt: Date? = nil,
            createdAt: Date = Date()
        ) {
            self.pubkey = pubkey
            self.status = status
            self.content = content
            self.linkUrl = linkUrl
            self.expiresAt = expiresAt
            self.createdAt = createdAt
        }
    }
    
    // MARK: - Properties
    
    private let relayPool: RelayPool
    private let profileManager: ProfileManager
    private let eventCache: EventCache
    private let keyStore: SecureKeyStore?
    private var notificationCache: [PublicKey: [Notification]] = [:]
    private var zapCache: [EventID: [ZapReceipt]] = [:]
    private var communityCache: [String: Community] = [:]
    private var statusCache: [PublicKey: UserStatus] = [:]
    
    // MARK: - Initialization
    
    public init(
        relayPool: RelayPool,
        profileManager: ProfileManager,
        eventCache: EventCache,
        keyStore: SecureKeyStore? = nil
    ) {
        self.relayPool = relayPool
        self.profileManager = profileManager
        self.eventCache = eventCache
        self.keyStore = keyStore
    }
    
    // MARK: - Lightning Zaps (NIP-57)
    
    /// Creates a zap request
    /// - Parameters:
    ///   - recipient: The recipient's public key
    ///   - amount: Amount in millisatoshis
    ///   - comment: Optional comment
    ///   - eventId: Optional event to zap
    ///   - identity: Identity to use for signing
    /// - Returns: The zap request
    public func createZapRequest(
        to recipient: PublicKey,
        amount: Int64,
        comment: String? = nil,
        eventId: EventID? = nil,
        using identity: String
    ) async throws -> ZapRequest {
        guard let keyStore = keyStore else {
            throw NostrError.configurationError(message: "KeyStore required for zaps")
        }
        
        let keyPair = try await keyStore.retrieve(identity: identity)
        
        // Fetch recipient's profile to get LNURL
        let profile = try await profileManager.fetchProfile(pubkey: recipient)
        
        // Get LNURL from profile
        let lnurl: String
        if let lud16 = profile.lud16 {
            // Lightning address
            lnurl = try await fetchLNURLFromAddress(lud16)
        } else if let lud06 = profile.lud06 {
            // Direct LNURL
            lnurl = lud06
        } else {
            throw NostrError.validationError(
                field: "lnurl",
                reason: "Recipient has no Lightning address"
            )
        }
        
        // Build zap request tags
        var tags: [[String]] = []
        
        // Recipient
        tags.append(["p", recipient])
        
        // Amount
        tags.append(["amount", String(amount)])
        
        // Event reference if zapping an event
        if let eventId = eventId {
            tags.append(["e", eventId])
        }
        
        // Relays
        let relays = await relayPool.connectedRelays.map { $0.url }
        tags.append(["relays"] + relays)
        
        // Lnurl
        tags.append(["lnurl", lnurl])
        
        // Create zap request event (kind 9734)
        var event = NostrEvent(
            pubkey: keyPair.publicKey,
            createdAt: Date(),
            kind: 9734,
            tags: tags,
            content: comment ?? ""
        )
        
        event = try keyPair.signEvent(event)
        
        return ZapRequest(
            id: event.id,
            recipient: recipient,
            amount: amount,
            comment: comment,
            relays: relays,
            event: event,
            lnurl: lnurl
        )
    }
    
    /// Fetches zap receipts for an event or user
    /// - Parameters:
    ///   - eventId: Optional event ID to get zaps for
    ///   - pubkey: Optional pubkey to get zaps for
    ///   - since: Optional start date
    /// - Returns: Array of zap receipts
    public func fetchZapReceipts(
        for eventId: EventID? = nil,
        pubkey: PublicKey? = nil,
        since: Date? = nil
    ) async throws -> [ZapReceipt] {
        // Check cache for event zaps
        if let eventId = eventId, let cached = zapCache[eventId] {
            return cached
        }
        
        // Build filter
        let filter = Filter(
            kinds: [9735], // Zap receipts
            since: since,
            e: eventId.map { [$0] },
            p: pubkey.map { [$0] }
        )
        
        // Subscribe to get zap receipts
        let events = try await relayPool.subscribe(
            filters: [filter],
            timeout: 5.0
        )
        
        // Parse receipts
        let receipts = events.compactMap { ZapReceipt(from: $0) }
            .sorted { $0.paidAt > $1.paidAt }
        
        // Cache if for specific event
        if let eventId = eventId {
            zapCache[eventId] = receipts
        }
        
        return receipts
    }
    
    /// Gets total zap amount for an event or user
    /// - Parameters:
    ///   - eventId: Optional event ID
    ///   - pubkey: Optional pubkey
    /// - Returns: Total amount in millisatoshis
    public func getTotalZapAmount(
        for eventId: EventID? = nil,
        pubkey: PublicKey? = nil
    ) async throws -> Int64 {
        let receipts = try await fetchZapReceipts(
            for: eventId,
            pubkey: pubkey
        )
        
        return receipts.reduce(0) { total, receipt in
            total + receipt.zapRequest.amount
        }
    }
    
    // MARK: - Communities (NIP-29/NIP-72)
    
    /// Fetches a community
    /// - Parameter communityId: The community ID
    /// - Returns: The community
    public func fetchCommunity(_ communityId: String) async throws -> Community {
        // Check cache
        if let cached = communityCache[communityId] {
            return cached
        }
        
        // Create filter for community definition
        let filter = Filter(
            kinds: [34550], // Community definition
            limit: 1
            // TODO: Need to handle d-tags differently
        )
        
        // Subscribe to get community
        let events = try await relayPool.subscribe(
            filters: [filter],
            timeout: 5.0
        )
        
        guard let event = events.first,
              let community = Community(from: event) else {
            throw NostrError.notFound(resource: "Community \(communityId)")
        }
        
        // Cache result
        communityCache[communityId] = community
        
        return community
    }
    
    /// Joins a community
    /// - Parameters:
    ///   - communityId: The community ID
    ///   - identity: Identity to use
    public func joinCommunity(
        _ communityId: String,
        using identity: String
    ) async throws {
        guard let keyStore = keyStore else {
            throw NostrError.configurationError(message: "KeyStore required for joining communities")
        }
        
        let keyPair = try await keyStore.retrieve(identity: identity)
        
        // Create community join request (kind 30001)
        var event = NostrEvent(
            pubkey: keyPair.publicKey,
            createdAt: Date(),
            kind: 30001,
            tags: [
                ["d", "communities"],
                ["a", "34550:\(communityId)"]
            ],
            content: ""
        )
        
        event = try keyPair.signEvent(event)
        
        // Publish to relays
        try await relayPool.publish(event: event)
    }
    
    /// Posts to a community
    /// - Parameters:
    ///   - content: Post content
    ///   - communityId: The community ID
    ///   - identity: Identity to use
    /// - Returns: The post event
    @discardableResult
    public func postToCommunity(
        content: String,
        communityId: String,
        using identity: String
    ) async throws -> NostrEvent {
        guard let keyStore = keyStore else {
            throw NostrError.configurationError(message: "KeyStore required for posting")
        }
        
        let keyPair = try await keyStore.retrieve(identity: identity)
        
        // Fetch community to get relay hint
        let community = try await fetchCommunity(communityId)
        
        // Create community post (kind 1 with community tag)
        var tags: [[String]] = [
            ["a", "34550:\(communityId)"]
        ]
        
        // Add relay hint if available
        if let relay = community.relay {
            tags.append(["relay", relay])
        }
        
        var event = NostrEvent(
            pubkey: keyPair.publicKey,
            createdAt: Date(),
            kind: 1,
            tags: tags,
            content: content
        )
        
        event = try keyPair.signEvent(event)
        
        // Publish to relays (preferably the community relay)
        if let relay = community.relay {
            try await relayPool.publish(event: event, to: [relay])
        } else {
            try await relayPool.publish(event: event)
        }
        
        return event
    }
    
    // MARK: - Notifications (NIP-27)
    
    /// Fetches notifications for a user
    /// - Parameters:
    ///   - identity: Identity to get notifications for
    ///   - types: Notification types to fetch (nil for all)
    ///   - since: Start date
    ///   - unreadOnly: Whether to fetch only unread
    /// - Returns: Array of notifications
    public func fetchNotifications(
        for identity: String,
        types: [NotificationType]? = nil,
        since: Date? = nil,
        unreadOnly: Bool = false
    ) async throws -> [Notification] {
        guard let keyStore = keyStore else {
            throw NostrError.configurationError(message: "KeyStore required for notifications")
        }
        
        let keyPair = try await keyStore.retrieve(identity: identity)
        let pubkey = keyPair.publicKey
        
        // Check cache
        if let cached = notificationCache[pubkey] {
            var filtered = cached
            
            if let types = types {
                filtered = filtered.filter { types.contains($0.type) }
            }
            
            if let since = since {
                filtered = filtered.filter { $0.createdAt >= since }
            }
            
            if unreadOnly {
                filtered = filtered.filter { !$0.isRead }
            }
            
            return filtered
        }
        
        // Build filters for different notification types
        var filters: [Filter] = []
        
        // Mentions and replies
        filters.append(Filter(
            kinds: [1], // Text notes
            since: since,
            p: [pubkey]
        ))
        
        // Reactions
        filters.append(Filter(
            kinds: [7], // Reactions
            since: since,
            p: [pubkey]
        ))
        
        // Reposts
        filters.append(Filter(
            kinds: [6], // Reposts
            since: since,
            p: [pubkey]
        ))
        
        // Zaps
        filters.append(Filter(
            kinds: [9735], // Zap receipts
            since: since,
            p: [pubkey]
        ))
        
        // Contact list updates (follows)
        filters.append(Filter(
            kinds: [3], // Contact lists
            since: since,
            p: [pubkey]
        ))
        
        // Subscribe to get all notification events
        let events = try await relayPool.subscribe(
            filters: filters,
            timeout: 5.0
        )
        
        // Parse notifications
        var notifications: [Notification] = []
        
        for event in events {
            guard let notification = try await parseNotification(
                from: event,
                for: pubkey
            ) else { continue }
            
            notifications.append(notification)
        }
        
        // Sort by date
        notifications.sort { $0.createdAt > $1.createdAt }
        
        // Cache results
        notificationCache[pubkey] = notifications
        
        // Apply filters
        if let types = types {
            notifications = notifications.filter { types.contains($0.type) }
        }
        
        if unreadOnly {
            notifications = notifications.filter { !$0.isRead }
        }
        
        return notifications
    }
    
    /// Marks notifications as read
    /// - Parameter notificationIds: IDs of notifications to mark as read
    public func markNotificationsAsRead(_ notificationIds: [String]) async {
        for (pubkey, notifications) in notificationCache {
            let updated = notifications.map { notification in
                if notificationIds.contains(notification.id) {
                    return Notification(
                        id: notification.id,
                        type: notification.type,
                        event: notification.event,
                        relatedEvent: notification.relatedEvent,
                        actor: notification.actor,
                        createdAt: notification.createdAt,
                        isRead: true
                    )
                }
                return notification
            }
            notificationCache[pubkey] = updated
        }
    }
    
    // MARK: - User Status (NIP-38)
    
    /// Updates user status
    /// - Parameters:
    ///   - status: Status type
    ///   - content: Status content
    ///   - linkUrl: Optional link URL
    ///   - expiresIn: Optional expiration duration
    ///   - identity: Identity to use
    /// - Returns: The status event
    @discardableResult
    public func updateStatus(
        _ status: UserStatus.StatusType,
        content: String? = nil,
        linkUrl: String? = nil,
        expiresIn: TimeInterval? = nil,
        using identity: String
    ) async throws -> NostrEvent {
        guard let keyStore = keyStore else {
            throw NostrError.configurationError(message: "KeyStore required for status updates")
        }
        
        let keyPair = try await keyStore.retrieve(identity: identity)
        
        // Build tags
        var tags: [[String]] = [
            ["d", status.rawValue]
        ]
        
        if let linkUrl = linkUrl {
            tags.append(["r", linkUrl])
        }
        
        if let expiresIn = expiresIn {
            let expirationTime = Date().addingTimeInterval(expiresIn)
            tags.append(["expiration", String(Int(expirationTime.timeIntervalSince1970))])
        }
        
        // Create status event (kind 30315)
        var event = NostrEvent(
            pubkey: keyPair.publicKey,
            createdAt: Date(),
            kind: 30315,
            tags: tags,
            content: content ?? ""
        )
        
        event = try keyPair.signEvent(event)
        
        // Publish to relays
        try await relayPool.publish(event: event)
        
        // Update cache
        let userStatus = UserStatus(
            pubkey: keyPair.publicKey,
            status: status,
            content: content,
            linkUrl: linkUrl,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) }
        )
        statusCache[keyPair.publicKey] = userStatus
        
        return event
    }
    
    /// Fetches user status
    /// - Parameter pubkey: The user's public key
    /// - Returns: The user's current status
    public func fetchStatus(for pubkey: PublicKey) async throws -> UserStatus? {
        // Check cache
        if let cached = statusCache[pubkey] {
            // Check if expired
            if let expiresAt = cached.expiresAt, expiresAt < Date() {
                statusCache.removeValue(forKey: pubkey)
            } else {
                return cached
            }
        }
        
        // Create filter for status events
        let filter = Filter(
            authors: [pubkey],
            kinds: [30315], // User status
            limit: 10 // Get multiple to find the most recent valid one
        )
        
        // Subscribe to get status
        let events = try await relayPool.subscribe(
            filters: [filter],
            timeout: 3.0
        )
        
        // Find most recent non-expired status
        for event in events.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard let status = parseUserStatus(from: event) else { continue }
            
            // Check if expired
            if let expiresAt = status.expiresAt, expiresAt < Date() {
                continue
            }
            
            // Cache and return
            statusCache[pubkey] = status
            return status
        }
        
        return nil
    }
    
    // MARK: - Private Methods
    
    private func fetchLNURLFromAddress(_ address: String) async throws -> String {
        let parts = address.split(separator: "@")
        guard parts.count == 2 else {
            throw NostrError.validationError(
                field: "address",
                reason: "Invalid Lightning address format"
            )
        }
        
        let user = String(parts[0])
        let domain = String(parts[1])
        
        let url = URL(string: "https://\(domain)/.well-known/lnurlp/\(user)")!
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let callback = json["callback"] as? String else {
            throw NostrError.validationError(
                field: "lnurl",
                reason: "Invalid LNURL response"
            )
        }
        
        return callback
    }
    
    private func parseNotification(
        from event: NostrEvent,
        for pubkey: PublicKey
    ) async throws -> Notification? {
        let id = "\(event.id):\(pubkey)"
        
        switch event.kind {
        case 1: // Text note - check for mention or reply
            if event.tags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == pubkey }) {
                // Check if it's a reply
                let isReply = event.tags.contains(where: { $0.count >= 2 && $0[0] == "e" })
                
                return Notification(
                    id: id,
                    type: isReply ? .reply : .mention,
                    event: event,
                    actor: event.pubkey,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(event.createdAt))
                )
            }
            
        case 3: // Contact list - check for follow
            if event.tags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == pubkey }) {
                return Notification(
                    id: id,
                    type: .follow,
                    event: event,
                    actor: event.pubkey,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(event.createdAt))
                )
            }
            
        case 6: // Repost
            return Notification(
                id: id,
                type: .repost,
                event: event,
                actor: event.pubkey,
                createdAt: Date(timeIntervalSince1970: TimeInterval(event.createdAt))
            )
            
        case 7: // Reaction
            return Notification(
                id: id,
                type: .reaction,
                event: event,
                actor: event.pubkey,
                createdAt: Date(timeIntervalSince1970: TimeInterval(event.createdAt))
            )
            
        case 9735: // Zap receipt
            if let zapReceipt = ZapReceipt(from: event) {
                return Notification(
                    id: id,
                    type: .zap,
                    event: event,
                    actor: zapReceipt.zapRequest.event.pubkey,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(event.createdAt))
                )
            }
            
        default:
            break
        }
        
        return nil
    }
    
    private func parseUserStatus(from event: NostrEvent) -> UserStatus? {
        guard event.kind == 30315 else { return nil }
        
        // Extract status type from d-tag
        guard let dTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "d" }),
              let statusType = UserStatus.StatusType(rawValue: dTag[1]) else {
            return nil
        }
        
        // Extract link URL
        let linkUrl = event.tags.first(where: { $0.count >= 2 && $0[0] == "r" })?[1]
        
        // Extract expiration
        let expiresAt = event.tags.first(where: { $0.count >= 2 && $0[0] == "expiration" })
            .flatMap { Int($0[1]) }
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        
        return UserStatus(
            pubkey: event.pubkey,
            status: statusType,
            content: event.content.isEmpty ? nil : event.content,
            linkUrl: linkUrl,
            expiresAt: expiresAt,
            createdAt: Date(timeIntervalSince1970: TimeInterval(event.createdAt))
        )
    }
}