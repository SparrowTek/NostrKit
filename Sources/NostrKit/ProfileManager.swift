import Foundation
import CoreNostr

/// Manages user profiles and metadata in NOSTR.
///
/// ProfileManager provides comprehensive profile management including:
/// - Profile metadata storage and retrieval
/// - NIP-05 verification
/// - Profile badges (NIP-58)
/// - Contact list management
/// - Mute/block lists (NIP-51)
///
/// ## Example
/// ```swift
/// let profileManager = ProfileManager(relayPool: relayPool, cache: eventCache)
/// 
/// // Fetch a user's profile
/// let profile = try await profileManager.fetchProfile(pubkey: pubkey)
/// 
/// // Update your own profile
/// try await profileManager.updateProfile(
///     name: "Alice",
///     about: "NOSTR enthusiast",
///     picture: "https://example.com/avatar.jpg"
/// )
/// 
/// // Verify NIP-05 identifier
/// let isVerified = try await profileManager.verifyNIP05(
///     identifier: "alice@nostr.example.com",
///     pubkey: pubkey
/// )
/// ```
public actor ProfileManager {
    
    // MARK: - Types
    
    /// User profile metadata (NIP-01)
    public struct Profile: Codable, Sendable {
        public let pubkey: PublicKey
        public let name: String?
        public let displayName: String?
        public let about: String?
        public let picture: String?
        public let banner: String?
        public let website: String?
        public let lud06: String? // LNURL
        public let lud16: String? // Lightning Address
        public let nip05: String? // NIP-05 identifier
        public let bot: Bool?
        public let lastUpdated: Date
        public let relays: [String]? // Recommended relays
        
        // Additional fields
        public var additionalFields: [String: String]
        
        public init(
            pubkey: PublicKey,
            name: String? = nil,
            displayName: String? = nil,
            about: String? = nil,
            picture: String? = nil,
            banner: String? = nil,
            website: String? = nil,
            lud06: String? = nil,
            lud16: String? = nil,
            nip05: String? = nil,
            bot: Bool? = nil,
            lastUpdated: Date = Date(),
            relays: [String]? = nil,
            additionalFields: [String: String] = [:]
        ) {
            self.pubkey = pubkey
            self.name = name
            self.displayName = displayName
            self.about = about
            self.picture = picture
            self.banner = banner
            self.website = website
            self.lud06 = lud06
            self.lud16 = lud16
            self.nip05 = nip05
            self.bot = bot
            self.lastUpdated = lastUpdated
            self.relays = relays
            self.additionalFields = additionalFields
        }
        
        /// Creates a profile from a metadata event
        public init?(from event: NostrEvent) {
            guard event.kind == 0 else { return nil }
            
            self.pubkey = event.pubkey
            self.lastUpdated = Date(timeIntervalSince1970: TimeInterval(event.createdAt))
            
            // Parse JSON content
            guard let data = event.content.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.name = nil
                self.displayName = nil
                self.about = nil
                self.picture = nil
                self.banner = nil
                self.website = nil
                self.lud06 = nil
                self.lud16 = nil
                self.nip05 = nil
                self.bot = nil
                self.relays = nil
                self.additionalFields = [:]
                return
            }
            
            self.name = json["name"] as? String
            self.displayName = json["display_name"] as? String
            self.about = json["about"] as? String
            self.picture = json["picture"] as? String
            self.banner = json["banner"] as? String
            self.website = json["website"] as? String
            self.lud06 = json["lud06"] as? String
            self.lud16 = json["lud16"] as? String
            self.nip05 = json["nip05"] as? String
            self.bot = json["bot"] as? Bool
            self.relays = json["relays"] as? [String]
            
            // Collect additional fields
            var additional: [String: String] = [:]
            let knownFields = Set(["name", "display_name", "about", "picture", "banner", 
                                  "website", "lud06", "lud16", "nip05", "bot", "relays"])
            for (key, value) in json where !knownFields.contains(key) {
                if let stringValue = value as? String {
                    additional[key] = stringValue
                }
            }
            self.additionalFields = additional
        }
        
        /// Converts the profile to JSON for event content
        public func toJSON() throws -> String {
            var json: [String: Any] = [:]
            
            if let name = name { json["name"] = name }
            if let displayName = displayName { json["display_name"] = displayName }
            if let about = about { json["about"] = about }
            if let picture = picture { json["picture"] = picture }
            if let banner = banner { json["banner"] = banner }
            if let website = website { json["website"] = website }
            if let lud06 = lud06 { json["lud06"] = lud06 }
            if let lud16 = lud16 { json["lud16"] = lud16 }
            if let nip05 = nip05 { json["nip05"] = nip05 }
            if let bot = bot { json["bot"] = bot }
            if let relays = relays { json["relays"] = relays }
            
            // Add additional fields
            for (key, value) in additionalFields {
                json[key] = value
            }
            
            let data = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
            guard let string = String(data: data, encoding: .utf8) else {
                throw NostrError.serializationError(type: "Profile", reason: "Failed to encode JSON")
            }
            
            return string
        }
        
        /// Display name with fallback to name or shortened pubkey
        public var displayNameOrFallback: String {
            if let displayName = displayName, !displayName.isEmpty {
                return displayName
            }
            if let name = name, !name.isEmpty {
                return name
            }
            // Return shortened pubkey
            return String(pubkey.prefix(8)) + "..."
        }
    }
    
    /// NIP-05 verification result
    public struct NIP05Verification: Sendable {
        public let identifier: String
        public let pubkey: PublicKey
        public let relays: [String]?
        public let verified: Bool
        public let verifiedAt: Date
        
        public init(
            identifier: String,
            pubkey: PublicKey,
            relays: [String]? = nil,
            verified: Bool,
            verifiedAt: Date = Date()
        ) {
            self.identifier = identifier
            self.pubkey = pubkey
            self.relays = relays
            self.verified = verified
            self.verifiedAt = verifiedAt
        }
    }
    
    /// Contact list (NIP-02)
    public struct ContactList: Sendable {
        public let pubkey: PublicKey
        public let contacts: Set<PublicKey>
        public let relayList: [String: RelayUsage]
        public let lastUpdated: Date
        
        public struct RelayUsage: Codable, Sendable {
            public let read: Bool
            public let write: Bool
            
            public init(read: Bool = true, write: Bool = true) {
                self.read = read
                self.write = write
            }
        }
        
        public init(
            pubkey: PublicKey,
            contacts: Set<PublicKey> = [],
            relayList: [String: RelayUsage] = [:],
            lastUpdated: Date = Date()
        ) {
            self.pubkey = pubkey
            self.contacts = contacts
            self.relayList = relayList
            self.lastUpdated = lastUpdated
        }
        
        /// Creates a contact list from an event
        public init?(from event: NostrEvent) {
            guard event.kind == 3 else { return nil }
            
            self.pubkey = event.pubkey
            self.lastUpdated = Date(timeIntervalSince1970: TimeInterval(event.createdAt))
            
            // Extract contacts from tags
            var contacts = Set<PublicKey>()
            for tag in event.tags {
                if tag.count >= 2 && tag[0] == "p" {
                    contacts.insert(tag[1])
                }
            }
            self.contacts = contacts
            
            // Parse relay list from content
            if let data = event.content.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Bool]] {
                var relayList: [String: RelayUsage] = [:]
                for (relay, usage) in json {
                    relayList[relay] = RelayUsage(
                        read: usage["read"] ?? true,
                        write: usage["write"] ?? true
                    )
                }
                self.relayList = relayList
            } else {
                self.relayList = [:]
            }
        }
    }
    
    /// List types for NIP-51
    public enum ListType: String, CaseIterable, Sendable {
        case mute = "mute"
        case pin = "pin"
        case bookmark = "bookmark"
        case communities = "communities"
        case publicChats = "public_chats"
        case blockedRelays = "blocked_relays"
        case searchRelays = "search_relays"
        case interests = "interests"
        case emojis = "emojis"
        
        var eventKind: Int {
            switch self {
            case .mute, .pin:
                return 10000
            case .bookmark:
                return 10001
            case .communities:
                return 10004
            case .publicChats:
                return 10005
            case .blockedRelays:
                return 10006
            case .searchRelays:
                return 10007
            case .interests:
                return 10015
            case .emojis:
                return 10030
            }
        }
    }
    
    /// User list (NIP-51)
    public struct UserList: Sendable {
        public let type: ListType
        public let pubkey: PublicKey
        public let name: String?
        public let items: [ListItem]
        public let encrypted: Bool
        public let lastUpdated: Date
        
        public enum ListItem: Sendable {
            case pubkey(PublicKey, relay: String?, petname: String?)
            case event(EventID, relay: String?)
            case hashtag(String)
            case relay(String)
            case word(String)
            case emoji(shortcode: String, url: String)
            case community(id: String, relay: String?)
        }
        
        public init(
            type: ListType,
            pubkey: PublicKey,
            name: String? = nil,
            items: [ListItem] = [],
            encrypted: Bool = false,
            lastUpdated: Date = Date()
        ) {
            self.type = type
            self.pubkey = pubkey
            self.name = name
            self.items = items
            self.encrypted = encrypted
            self.lastUpdated = lastUpdated
        }
    }
    
    // MARK: - Properties
    
    private let relayPool: RelayPool
    private let eventCache: EventCache
    private let keyStore: SecureKeyStore?
    private var profileCache: [PublicKey: Profile] = [:]
    private var nip05Cache: [String: NIP05Verification] = [:]
    private var contactListCache: [PublicKey: ContactList] = [:]
    private var userListsCache: [PublicKey: [ListType: UserList]] = [:]
    private let cacheExpiration: TimeInterval = 3600 // 1 hour
    
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
    
    // MARK: - Profile Management
    
    /// Fetches a user's profile
    /// - Parameters:
    ///   - pubkey: The user's public key
    ///   - forceRefresh: Whether to bypass cache
    /// - Returns: The user's profile
    public func fetchProfile(
        pubkey: PublicKey,
        forceRefresh: Bool = false
    ) async throws -> Profile {
        // Check cache first
        if !forceRefresh,
           let cached = profileCache[pubkey],
           cached.lastUpdated.timeIntervalSinceNow > -cacheExpiration {
            return cached
        }
        
        // Create filter for metadata events
        let filter = Filter(
            authors: [pubkey],
            kinds: [0],
            limit: 1
        )
        
        // Subscribe to relays
        let events = try await relayPool.subscribe(
            filters: [filter],
            timeout: 5.0
        )
        
        // Find the most recent metadata event
        let metadataEvent = events
            .filter { $0.kind == 0 }
            .sorted { $0.createdAt > $1.createdAt }
            .first
        
        if let event = metadataEvent,
           let profile = Profile(from: event) {
            profileCache[pubkey] = profile
            return profile
        }
        
        // Return empty profile if not found
        let emptyProfile = Profile(pubkey: pubkey)
        profileCache[pubkey] = emptyProfile
        return emptyProfile
    }
    
    /// Updates the current user's profile
    /// - Parameters:
    ///   - name: Username
    ///   - displayName: Display name
    ///   - about: Bio/description
    ///   - picture: Avatar URL
    ///   - banner: Banner image URL
    ///   - website: Website URL
    ///   - lud06: LNURL
    ///   - lud16: Lightning address
    ///   - nip05: NIP-05 identifier
    ///   - bot: Whether this is a bot account
    ///   - identity: Identity to use for signing
    /// - Returns: The profile event
    @discardableResult
    public func updateProfile(
        name: String? = nil,
        displayName: String? = nil,
        about: String? = nil,
        picture: String? = nil,
        banner: String? = nil,
        website: String? = nil,
        lud06: String? = nil,
        lud16: String? = nil,
        nip05: String? = nil,
        bot: Bool? = nil,
        additionalFields: [String: String] = [:],
        using identity: String
    ) async throws -> NostrEvent {
        guard let keyStore = keyStore else {
            throw NostrError.configurationError(message: "KeyStore required for profile updates")
        }
        
        let keyPair = try await keyStore.retrieve(identity: identity)
        
        // Create profile
        let profile = Profile(
            pubkey: keyPair.publicKey,
            name: name,
            displayName: displayName,
            about: about,
            picture: picture,
            banner: banner,
            website: website,
            lud06: lud06,
            lud16: lud16,
            nip05: nip05,
            bot: bot,
            additionalFields: additionalFields
        )
        
        // Create metadata event
        var event = NostrEvent(
            pubkey: keyPair.publicKey,
            createdAt: Date(),
            kind: 0,
            tags: [],
            content: try profile.toJSON()
        )
        
        event = try keyPair.signEvent(event)
        
        // Publish to relays
        try await relayPool.publish(event: event)
        
        // Update cache
        profileCache[keyPair.publicKey] = profile
        
        return event
    }
    
    // MARK: - NIP-05 Verification
    
    /// Verifies a NIP-05 identifier
    /// - Parameters:
    ///   - identifier: The NIP-05 identifier (e.g., "alice@example.com")
    ///   - pubkey: The public key to verify
    ///   - forceRefresh: Whether to bypass cache
    /// - Returns: Verification result
    public func verifyNIP05(
        identifier: String,
        pubkey: PublicKey,
        forceRefresh: Bool = false
    ) async throws -> NIP05Verification {
        let cacheKey = "\(identifier):\(pubkey)"
        
        // Check cache
        if !forceRefresh,
           let cached = nip05Cache[cacheKey],
           cached.verifiedAt.timeIntervalSinceNow > -cacheExpiration {
            return cached
        }
        
        // Parse identifier
        let parts = identifier.split(separator: "@")
        guard parts.count == 2 else {
            throw NostrError.validationError(
                field: "identifier",
                reason: "Invalid NIP-05 format"
            )
        }
        
        let name = String(parts[0])
        let domain = String(parts[1])
        
        // Build URL
        let url = URL(string: "https://\(domain)/.well-known/nostr.json?name=\(name)")!
        
        // Fetch JSON
        let (data, _) = try await URLSession.shared.data(from: url)
        
        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let names = json["names"] as? [String: String],
              let returnedPubkey = names[name] else {
            let verification = NIP05Verification(
                identifier: identifier,
                pubkey: pubkey,
                verified: false
            )
            nip05Cache[cacheKey] = verification
            return verification
        }
        
        // Check if pubkey matches
        let verified = returnedPubkey.lowercased() == pubkey.lowercased()
        
        // Extract relays if present
        let relays = (json["relays"] as? [String: [String]])?[pubkey]
        
        let verification = NIP05Verification(
            identifier: identifier,
            pubkey: pubkey,
            relays: relays,
            verified: verified
        )
        
        nip05Cache[cacheKey] = verification
        return verification
    }
    
    // MARK: - Contact List Management
    
    /// Fetches a user's contact list
    /// - Parameters:
    ///   - pubkey: The user's public key
    ///   - forceRefresh: Whether to bypass cache
    /// - Returns: The contact list
    public func fetchContactList(
        pubkey: PublicKey,
        forceRefresh: Bool = false
    ) async throws -> ContactList {
        // Check cache
        if !forceRefresh,
           let cached = contactListCache[pubkey],
           cached.lastUpdated.timeIntervalSinceNow > -cacheExpiration {
            return cached
        }
        
        // Create filter for contact list events
        let filter = Filter(
            authors: [pubkey],
            kinds: [3],
            limit: 1
        )
        
        // Subscribe to relays
        let events = try await relayPool.subscribe(
            filters: [filter],
            timeout: 5.0
        )
        
        // Find the most recent contact list
        let contactEvent = events
            .filter { $0.kind == 3 }
            .sorted { $0.createdAt > $1.createdAt }
            .first
        
        if let event = contactEvent,
           let contactList = ContactList(from: event) {
            contactListCache[pubkey] = contactList
            return contactList
        }
        
        // Return empty contact list if not found
        let emptyList = ContactList(pubkey: pubkey)
        contactListCache[pubkey] = emptyList
        return emptyList
    }
    
    /// Updates the current user's contact list
    /// - Parameters:
    ///   - contacts: Set of public keys to follow
    ///   - relayList: Relay usage preferences
    ///   - identity: Identity to use for signing
    /// - Returns: The contact list event
    @discardableResult
    public func updateContactList(
        contacts: Set<PublicKey>,
        relayList: [String: ContactList.RelayUsage] = [:],
        using identity: String
    ) async throws -> NostrEvent {
        guard let keyStore = keyStore else {
            throw NostrError.configurationError(message: "KeyStore required for contact list updates")
        }
        
        let keyPair = try await keyStore.retrieve(identity: identity)
        
        // Create tags for contacts
        let tags = contacts.map { pubkey in
            ["p", pubkey]
        }
        
        // Create relay list content
        var relayJson: [String: [String: Bool]] = [:]
        for (relay, usage) in relayList {
            relayJson[relay] = [
                "read": usage.read,
                "write": usage.write
            ]
        }
        
        let content: String
        if !relayJson.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: relayJson, options: .sortedKeys)
            content = String(data: data, encoding: .utf8) ?? ""
        } else {
            content = ""
        }
        
        // Create contact list event
        var event = NostrEvent(
            pubkey: keyPair.publicKey,
            createdAt: Date(),
            kind: 3,
            tags: tags,
            content: content
        )
        
        event = try keyPair.signEvent(event)
        
        // Publish to relays
        try await relayPool.publish(event: event)
        
        // Update cache
        let contactList = ContactList(
            pubkey: keyPair.publicKey,
            contacts: contacts,
            relayList: relayList
        )
        contactListCache[keyPair.publicKey] = contactList
        
        return event
    }
    
    // MARK: - User Lists (NIP-51)
    
    /// Fetches user lists
    /// - Parameters:
    ///   - pubkey: The user's public key
    ///   - types: List types to fetch (nil for all)
    ///   - forceRefresh: Whether to bypass cache
    /// - Returns: Dictionary of list types to lists
    public func fetchUserLists(
        pubkey: PublicKey,
        types: [ListType]? = nil,
        forceRefresh: Bool = false
    ) async throws -> [ListType: UserList] {
        // Check cache
        if !forceRefresh,
           let cached = userListsCache[pubkey] {
            if let types = types {
                return cached.filter { types.contains($0.key) }
            }
            return cached
        }
        
        // Determine kinds to fetch
        let kinds: [Int]
        if let types = types {
            kinds = Array(Set(types.map { $0.eventKind }))
        } else {
            kinds = Array(Set(ListType.allCases.map { $0.eventKind }))
        }
        
        // Create filter
        let filter = Filter(
            authors: [pubkey],
            kinds: kinds
        )
        
        // Subscribe to relays
        let events = try await relayPool.subscribe(
            filters: [filter],
            timeout: 5.0
        )
        
        // Parse lists
        var lists: [ListType: UserList] = [:]
        
        for listType in ListType.allCases {
            guard kinds.contains(listType.eventKind) else { continue }
            
            // Find most recent event for this list type
            let event = events
                .filter { $0.kind == listType.eventKind }
                .sorted { $0.createdAt > $1.createdAt }
                .first
            
            if let event = event {
                let list = try parseUserList(from: event, type: listType)
                lists[listType] = list
            }
        }
        
        // Update cache
        userListsCache[pubkey] = lists
        
        return lists
    }
    
    /// Updates a user list
    /// - Parameters:
    ///   - type: The list type
    ///   - items: List items
    ///   - name: Optional list name
    ///   - encrypted: Whether to encrypt the list
    ///   - identity: Identity to use for signing
    /// - Returns: The list event
    @discardableResult
    public func updateUserList(
        type: ListType,
        items: [UserList.ListItem],
        name: String? = nil,
        encrypted: Bool = false,
        using identity: String
    ) async throws -> NostrEvent {
        guard let keyStore = keyStore else {
            throw NostrError.configurationError(message: "KeyStore required for list updates")
        }
        
        let keyPair = try await keyStore.retrieve(identity: identity)
        
        // Create tags
        var tags: [[String]] = []
        
        // Add d-tag for replaceable lists
        if type.eventKind >= 30000 {
            tags.append(["d", type.rawValue])
        }
        
        // Add name tag if provided
        if let name = name {
            tags.append(["name", name])
        }
        
        // Add items as tags
        for item in items {
            switch item {
            case .pubkey(let pubkey, let relay, let petname):
                var tag = ["p", pubkey]
                if let relay = relay { tag.append(relay) }
                if let petname = petname { tag.append(petname) }
                tags.append(tag)
                
            case .event(let eventId, let relay):
                var tag = ["e", eventId]
                if let relay = relay { tag.append(relay) }
                tags.append(tag)
                
            case .hashtag(let hashtag):
                tags.append(["t", hashtag])
                
            case .relay(let relay):
                tags.append(["r", relay])
                
            case .word(let word):
                tags.append(["word", word])
                
            case .emoji(let shortcode, let url):
                tags.append(["emoji", shortcode, url])
                
            case .community(let id, let relay):
                var tag = ["a", id]
                if let relay = relay { tag.append(relay) }
                tags.append(tag)
            }
        }
        
        // Create content (empty for now, could be used for encrypted lists)
        let content = ""
        
        // Create event
        var event = NostrEvent(
            pubkey: keyPair.publicKey,
            createdAt: Date(),
            kind: type.eventKind,
            tags: tags,
            content: content
        )
        
        event = try keyPair.signEvent(event)
        
        // Publish to relays
        try await relayPool.publish(event: event)
        
        // Update cache
        let userList = UserList(
            type: type,
            pubkey: keyPair.publicKey,
            name: name,
            items: items,
            encrypted: encrypted
        )
        
        if userListsCache[keyPair.publicKey] == nil {
            userListsCache[keyPair.publicKey] = [:]
        }
        userListsCache[keyPair.publicKey]![type] = userList
        
        return event
    }
    
    // MARK: - Convenience Methods
    
    /// Checks if a user is muted
    /// - Parameters:
    ///   - pubkey: The pubkey to check
    ///   - by: The user doing the muting
    /// - Returns: Whether the user is muted
    public func isMuted(
        _ pubkey: PublicKey,
        by mutedBy: PublicKey
    ) async throws -> Bool {
        let lists = try await fetchUserLists(
            pubkey: mutedBy,
            types: [.mute]
        )
        
        guard let muteList = lists[.mute] else { return false }
        
        return muteList.items.contains { item in
            if case .pubkey(let mutedPubkey, _, _) = item {
                return mutedPubkey == pubkey
            }
            return false
        }
    }
    
    /// Adds a user to the mute list
    /// - Parameters:
    ///   - pubkey: The pubkey to mute
    ///   - identity: Identity to use for signing
    public func mute(
        _ pubkey: PublicKey,
        using identity: String
    ) async throws {
        guard let keyStore = keyStore else {
            throw NostrError.configurationError(message: "KeyStore required for muting")
        }
        
        let keyPair = try await keyStore.retrieve(identity: identity)
        
        // Get current mute list
        let lists = try await fetchUserLists(
            pubkey: keyPair.publicKey,
            types: [.mute]
        )
        
        var items = lists[.mute]?.items ?? []
        
        // Add if not already muted
        let alreadyMuted = items.contains { item in
            if case .pubkey(let mutedPubkey, _, _) = item {
                return mutedPubkey == pubkey
            }
            return false
        }
        
        if !alreadyMuted {
            items.append(.pubkey(pubkey, relay: nil, petname: nil))
            try await updateUserList(
                type: .mute,
                items: items,
                using: identity
            )
        }
    }
    
    /// Removes a user from the mute list
    /// - Parameters:
    ///   - pubkey: The pubkey to unmute
    ///   - identity: Identity to use for signing
    public func unmute(
        _ pubkey: PublicKey,
        using identity: String
    ) async throws {
        guard let keyStore = keyStore else {
            throw NostrError.configurationError(message: "KeyStore required for unmuting")
        }
        
        let keyPair = try await keyStore.retrieve(identity: identity)
        
        // Get current mute list
        let lists = try await fetchUserLists(
            pubkey: keyPair.publicKey,
            types: [.mute]
        )
        
        var items = lists[.mute]?.items ?? []
        
        // Remove from list
        items.removeAll { item in
            if case .pubkey(let mutedPubkey, _, _) = item {
                return mutedPubkey == pubkey
            }
            return false
        }
        
        try await updateUserList(
            type: .mute,
            items: items,
            using: identity
        )
    }
    
    // MARK: - Private Methods
    
    private func parseUserList(
        from event: NostrEvent,
        type: ListType
    ) throws -> UserList {
        var items: [UserList.ListItem] = []
        var name: String?
        
        for tag in event.tags {
            guard tag.count >= 2 else { continue }
            
            switch tag[0] {
            case "p":
                let pubkey = tag[1]
                let relay = tag.count > 2 ? tag[2] : nil
                let petname = tag.count > 3 ? tag[3] : nil
                items.append(.pubkey(pubkey, relay: relay, petname: petname))
                
            case "e":
                let eventId = tag[1]
                let relay = tag.count > 2 ? tag[2] : nil
                items.append(.event(eventId, relay: relay))
                
            case "t":
                items.append(.hashtag(tag[1]))
                
            case "r":
                items.append(.relay(tag[1]))
                
            case "word":
                items.append(.word(tag[1]))
                
            case "emoji":
                if tag.count >= 3 {
                    items.append(.emoji(shortcode: tag[1], url: tag[2]))
                }
                
            case "a":
                let id = tag[1]
                let relay = tag.count > 2 ? tag[2] : nil
                items.append(.community(id: id, relay: relay))
                
            case "name":
                name = tag[1]
                
            default:
                break
            }
        }
        
        return UserList(
            type: type,
            pubkey: event.pubkey,
            name: name,
            items: items,
            encrypted: false, // TODO: Implement encrypted lists
            lastUpdated: Date(timeIntervalSince1970: TimeInterval(event.createdAt))
        )
    }
}

// MARK: - Profile Badges (NIP-58)

extension ProfileManager {
    
    /// Badge definition
    public struct Badge: Sendable {
        public let id: String
        public let name: String
        public let description: String?
        public let image: String?
        public let thumbImage: String?
        
        public init(
            id: String,
            name: String,
            description: String? = nil,
            image: String? = nil,
            thumbImage: String? = nil
        ) {
            self.id = id
            self.name = name
            self.description = description
            self.image = image
            self.thumbImage = thumbImage
        }
    }
    
    /// Badge award
    public struct BadgeAward: Sendable {
        public let badge: Badge
        public let awardedTo: PublicKey
        public let awardedBy: PublicKey
        public let awardedAt: Date
        
        public init(
            badge: Badge,
            awardedTo: PublicKey,
            awardedBy: PublicKey,
            awardedAt: Date = Date()
        ) {
            self.badge = badge
            self.awardedTo = awardedTo
            self.awardedBy = awardedBy
            self.awardedAt = awardedAt
        }
    }
    
    /// Fetches badges for a user
    /// - Parameter pubkey: The user's public key
    /// - Returns: Array of badge awards
    public func fetchBadges(for pubkey: PublicKey) async throws -> [BadgeAward] {
        // Create filter for badge awards (kind 8)
        let filter = Filter(
            kinds: [8],
            p: [pubkey]
        )
        
        // Subscribe to relays
        let events = try await relayPool.subscribe(
            filters: [filter],
            timeout: 5.0
        )
        
        var awards: [BadgeAward] = []
        
        for event in events {
            // Extract badge definition reference
            guard let badgeTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "a" }),
                  let pTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == pubkey }) else {
                continue
            }
            
            let badgeId = badgeTag[1]
            
            // TODO: Fetch badge definition event (kind 30009)
            // For now, create a simple badge
            let badge = Badge(
                id: badgeId,
                name: "Badge"
            )
            
            let award = BadgeAward(
                badge: badge,
                awardedTo: pubkey,
                awardedBy: event.pubkey,
                awardedAt: Date(timeIntervalSince1970: TimeInterval(event.createdAt))
            )
            
            awards.append(award)
        }
        
        return awards
    }
}