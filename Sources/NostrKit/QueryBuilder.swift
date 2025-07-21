import Foundation
import CoreNostr

/// A type-safe query builder for constructing NOSTR event filters.
///
/// QueryBuilder provides a fluent API for building complex queries with compile-time safety.
/// It supports all standard NOSTR filter options plus additional convenience methods.
///
/// ## Example
/// ```swift
/// let query = QueryBuilder()
///     .kinds(.textNote, .metadata)
///     .authors(alice, bob)
///     .since(.lastWeek)
///     .limit(50)
///     .build()
/// 
/// let events = await cache.query(filter: query)
/// ```
public struct QueryBuilder: Sendable {
    
    // MARK: - Properties
    
    private var filter: Filter
    
    // MARK: - Initialization
    
    /// Creates a new query builder
    public init() {
        self.filter = Filter()
    }
    
    /// Creates a query builder from an existing filter
    public init(from filter: Filter) {
        self.filter = filter
    }
    
    // MARK: - ID Filtering
    
    /// Filters by specific event IDs
    /// - Parameter ids: Event IDs to match
    /// - Returns: Updated query builder
    public func ids(_ ids: EventID...) -> QueryBuilder {
        self.ids(ids)
    }
    
    /// Filters by specific event IDs
    /// - Parameter ids: Array of event IDs to match
    /// - Returns: Updated query builder
    public func ids(_ ids: [EventID]) -> QueryBuilder {
        var builder = self
        builder.filter.ids = ids
        return builder
    }
    
    /// Filters by specific event ID hex strings
    /// - Parameter ids: Event ID hex strings to match
    /// - Returns: Updated query builder
    public func idStrings(_ ids: String...) -> QueryBuilder {
        self.idStrings(ids)
    }
    
    /// Filters by specific event ID hex strings
    /// - Parameter ids: Array of event ID hex strings to match
    /// - Returns: Updated query builder
    public func idStrings(_ ids: [String]) -> QueryBuilder {
        var builder = self
        builder.filter.ids = ids
        return builder
    }
    
    // MARK: - Author Filtering
    
    /// Filters by specific authors
    /// - Parameter authors: Public keys of authors to match
    /// - Returns: Updated query builder
    public func authors(_ authors: PublicKey...) -> QueryBuilder {
        self.authors(authors)
    }
    
    /// Filters by specific authors
    /// - Parameter authors: Array of public keys of authors to match
    /// - Returns: Updated query builder
    public func authors(_ authors: [PublicKey]) -> QueryBuilder {
        var builder = self
        builder.filter.authors = authors
        return builder
    }
    
    /// Filters by specific author hex strings
    /// - Parameter authors: Author public key hex strings to match
    /// - Returns: Updated query builder
    public func authorStrings(_ authors: String...) -> QueryBuilder {
        self.authorStrings(authors)
    }
    
    /// Filters by specific author hex strings
    /// - Parameter authors: Array of author public key hex strings to match
    /// - Returns: Updated query builder
    public func authorStrings(_ authors: [String]) -> QueryBuilder {
        var builder = self
        builder.filter.authors = authors
        return builder
    }
    
    // MARK: - Kind Filtering
    
    /// Filters by specific event kinds
    /// - Parameter kinds: Event kinds to match
    /// - Returns: Updated query builder
    public func kinds(_ kinds: EventKind...) -> QueryBuilder {
        self.kinds(kinds)
    }
    
    /// Filters by specific event kinds
    /// - Parameter kinds: Array of event kinds to match
    /// - Returns: Updated query builder
    public func kinds(_ kinds: [EventKind]) -> QueryBuilder {
        var builder = self
        builder.filter.kinds = kinds.map { $0.rawValue }
        return builder
    }
    
    /// Filters by specific event kind raw values
    /// - Parameter kinds: Event kind raw values to match
    /// - Returns: Updated query builder
    public func kindValues(_ kinds: Int...) -> QueryBuilder {
        self.kindValues(kinds)
    }
    
    /// Filters by specific event kind raw values
    /// - Parameter kinds: Array of event kind raw values to match
    /// - Returns: Updated query builder
    public func kindValues(_ kinds: [Int]) -> QueryBuilder {
        var builder = self
        builder.filter.kinds = kinds
        return builder
    }
    
    // MARK: - Time Filtering
    
    /// Filters events created since a specific date
    /// - Parameter date: The date to filter from
    /// - Returns: Updated query builder
    public func since(_ date: Date) -> QueryBuilder {
        var builder = self
        builder.filter.since = Int64(date.timeIntervalSince1970)
        return builder
    }
    
    /// Filters events created since a time interval ago
    /// - Parameter interval: Time interval from now
    /// - Returns: Updated query builder
    public func since(_ interval: TimeInterval) -> QueryBuilder {
        since(Date().addingTimeInterval(-abs(interval)))
    }
    
    /// Filters events created since a relative time
    /// - Parameter relative: Relative time specification
    /// - Returns: Updated query builder
    public func since(_ relative: RelativeTime) -> QueryBuilder {
        since(relative.date)
    }
    
    /// Filters events created until a specific date
    /// - Parameter date: The date to filter until
    /// - Returns: Updated query builder
    public func until(_ date: Date) -> QueryBuilder {
        var builder = self
        builder.filter.until = Int64(date.timeIntervalSince1970)
        return builder
    }
    
    /// Filters events created until a time interval ago
    /// - Parameter interval: Time interval from now
    /// - Returns: Updated query builder
    public func until(_ interval: TimeInterval) -> QueryBuilder {
        until(Date().addingTimeInterval(-abs(interval)))
    }
    
    /// Filters events created until a relative time
    /// - Parameter relative: Relative time specification
    /// - Returns: Updated query builder
    public func until(_ relative: RelativeTime) -> QueryBuilder {
        until(relative.date)
    }
    
    /// Filters events within a date range
    /// - Parameters:
    ///   - start: Start date
    ///   - end: End date
    /// - Returns: Updated query builder
    public func between(_ start: Date, and end: Date) -> QueryBuilder {
        self.since(start).until(end)
    }
    
    // MARK: - Tag Filtering
    
    /// Filters by a specific tag
    /// - Parameters:
    ///   - name: Tag name (e.g., "e", "p", "t")
    ///   - values: Values to match for this tag
    /// - Returns: Updated query builder
    public func tag(_ name: String, values: String...) -> QueryBuilder {
        self.tag(name, values: values)
    }
    
    /// Filters by a specific tag
    /// - Parameters:
    ///   - name: Tag name (e.g., "e", "p", "t")
    ///   - values: Array of values to match for this tag
    /// - Returns: Updated query builder
    public func tag(_ name: String, values: [String]) -> QueryBuilder {
        var builder = self
        switch name {
        case "e":
            builder.filter.e = values
        case "p":
            builder.filter.p = values
        default:
            // Other tags are not supported by the current Filter struct
            print("Warning: Tag '\(name)' is not supported by Filter. Only 'e' and 'p' tags are supported.")
        }
        return builder
    }
    
    /// Filters by referenced events
    /// - Parameter eventIds: Event IDs referenced in "e" tags
    /// - Returns: Updated query builder
    public func referencingEvents(_ eventIds: EventID...) -> QueryBuilder {
        self.referencingEvents(eventIds)
    }
    
    /// Filters by referenced events
    /// - Parameter eventIds: Array of event IDs referenced in "e" tags
    /// - Returns: Updated query builder
    public func referencingEvents(_ eventIds: [EventID]) -> QueryBuilder {
        tag("e", values: eventIds)
    }
    
    /// Filters by referenced users
    /// - Parameter pubkeys: Public keys referenced in "p" tags
    /// - Returns: Updated query builder
    public func referencingUsers(_ pubkeys: PublicKey...) -> QueryBuilder {
        self.referencingUsers(pubkeys)
    }
    
    /// Filters by referenced users
    /// - Parameter pubkeys: Array of public keys referenced in "p" tags
    /// - Returns: Updated query builder
    public func referencingUsers(_ pubkeys: [PublicKey]) -> QueryBuilder {
        tag("p", values: pubkeys)
    }
    
    /// Filters by hashtags
    /// - Parameter hashtags: Hashtags to match (without # prefix)
    /// - Returns: Updated query builder
    public func hashtags(_ hashtags: String...) -> QueryBuilder {
        self.hashtags(hashtags)
    }
    
    /// Filters by hashtags
    /// - Parameter hashtags: Array of hashtags to match (without # prefix)
    /// - Returns: Updated query builder
    public func hashtags(_ hashtags: [String]) -> QueryBuilder {
        tag("t", values: hashtags.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) })
    }
    
    // MARK: - Limit
    
    /// Limits the number of results
    /// - Parameter limit: Maximum number of events to return
    /// - Returns: Updated query builder
    public func limit(_ limit: Int) -> QueryBuilder {
        var builder = self
        builder.filter.limit = limit
        return builder
    }
    
    // MARK: - Search (NIP-50)
    
    /// Adds a search query
    /// - Parameter query: The search query
    /// - Returns: Updated query builder
    public func search(_ query: String) -> QueryBuilder {
        var builder = self
        builder.filter.search = query
        return builder
    }
    
    // MARK: - Convenience Methods
    
    /// Filters for text notes only
    /// - Returns: Updated query builder
    public func textNotes() -> QueryBuilder {
        kinds(.textNote)
    }
    
    /// Filters for metadata events only
    /// - Returns: Updated query builder
    public func metadata() -> QueryBuilder {
        kinds(.setMetadata)
    }
    
    /// Filters for follow lists only
    /// - Returns: Updated query builder
    public func followLists() -> QueryBuilder {
        kinds(.followList)
    }
    
    /// Filters for direct messages
    /// - Returns: Updated query builder
    public func directMessages() -> QueryBuilder {
        kinds(.encryptedDirectMessage)
    }
    
    /// Filters for reactions only
    /// - Returns: Updated query builder
    public func reactions() -> QueryBuilder {
        kinds(.reaction)
    }
    
    
    /// Filters for events from the last hour
    /// - Returns: Updated query builder
    public func lastHour() -> QueryBuilder {
        since(.oneHour)
    }
    
    /// Filters for events from today
    /// - Returns: Updated query builder
    public func today() -> QueryBuilder {
        since(.oneDay)
    }
    
    /// Filters for events from this week
    /// - Returns: Updated query builder
    public func thisWeek() -> QueryBuilder {
        since(.oneWeek)
    }
    
    /// Filters for events from this month
    /// - Returns: Updated query builder
    public func thisMonth() -> QueryBuilder {
        since(.oneMonth)
    }
    
    // MARK: - Building
    
    /// Builds the final filter
    /// - Returns: The constructed filter
    public func build() -> Filter {
        filter
    }
}

// MARK: - Relative Time

/// Represents relative time specifications for queries
public enum RelativeTime: Sendable {
    case seconds(Int)
    case minutes(Int)
    case hours(Int)
    case days(Int)
    case weeks(Int)
    case months(Int)
    
    /// Common relative times
    public static let oneMinute = RelativeTime.minutes(1)
    public static let fiveMinutes = RelativeTime.minutes(5)
    public static let tenMinutes = RelativeTime.minutes(10)
    public static let thirtyMinutes = RelativeTime.minutes(30)
    public static let oneHour = RelativeTime.hours(1)
    public static let sixHours = RelativeTime.hours(6)
    public static let twelveHours = RelativeTime.hours(12)
    public static let oneDay = RelativeTime.days(1)
    public static let threeDays = RelativeTime.days(3)
    public static let oneWeek = RelativeTime.weeks(1)
    public static let twoWeeks = RelativeTime.weeks(2)
    public static let oneMonth = RelativeTime.months(1)
    public static let threeMonths = RelativeTime.months(3)
    public static let sixMonths = RelativeTime.months(6)
    public static let oneYear = RelativeTime.months(12)
    
    /// Converts to a date relative to now
    public var date: Date {
        let calendar = Calendar.current
        let now = Date()
        
        switch self {
        case .seconds(let seconds):
            return now.addingTimeInterval(-Double(seconds))
        case .minutes(let minutes):
            return now.addingTimeInterval(-Double(minutes * 60))
        case .hours(let hours):
            return now.addingTimeInterval(-Double(hours * 3600))
        case .days(let days):
            return calendar.date(byAdding: .day, value: -days, to: now) ?? now
        case .weeks(let weeks):
            return calendar.date(byAdding: .weekOfYear, value: -weeks, to: now) ?? now
        case .months(let months):
            return calendar.date(byAdding: .month, value: -months, to: now) ?? now
        }
    }
    
    /// Time interval from now
    public var timeInterval: TimeInterval {
        Date().timeIntervalSince(date)
    }
}

// MARK: - Compound Queries

extension QueryBuilder {
    
    /// Creates a query for replies to a specific event
    /// - Parameter event: The event to find replies to
    /// - Returns: Query builder configured for replies
    public static func repliesTo(_ event: NostrEvent) -> QueryBuilder {
        QueryBuilder()
            .kinds(.textNote)
            .referencingEvents(event.id)
            .tag("e", values: [event.id])
    }
    
    /// Creates a query for replies to multiple events
    /// - Parameter events: The events to find replies to
    /// - Returns: Query builder configured for replies
    public static func repliesToAny(of events: [NostrEvent]) -> QueryBuilder {
        QueryBuilder()
            .kinds(.textNote)
            .referencingEvents(events.map { $0.id })
    }
    
    /// Creates a query for events mentioning a user
    /// - Parameter pubkey: The user's public key
    /// - Returns: Query builder configured for mentions
    public static func mentioning(_ pubkey: PublicKey) -> QueryBuilder {
        QueryBuilder()
            .referencingUsers(pubkey)
    }
    
    /// Creates a query for events by followed users
    /// - Parameter followList: The follow list
    /// - Returns: Query builder configured for followed users' events
    public static func fromFollows(_ followList: NostrFollowList) -> QueryBuilder {
        QueryBuilder()
            .authors(followList.follows.map { $0.pubkey })
    }
    
    /// Creates a query for thread events
    /// - Parameters:
    ///   - rootEvent: The root event of the thread
    ///   - includeRoot: Whether to include the root event
    /// - Returns: Query builder configured for thread events
    public static func thread(rootEvent: NostrEvent, includeRoot: Bool = true) -> QueryBuilder {
        var builder = QueryBuilder()
            .kinds(.textNote)
            .tag("e", values: [rootEvent.id])
        
        if includeRoot {
            builder = builder.ids(rootEvent.id)
        }
        
        return builder
    }
}

// MARK: - EventCache Extension

extension EventCache {
    
    /// Queries events using a query builder
    /// - Parameter builder: The query builder
    /// - Returns: Array of matching events
    public func query(builder: QueryBuilder) async -> [NostrEvent] {
        await query(filter: builder.build())
    }
    
    /// Counts events matching a query
    /// - Parameter builder: The query builder
    /// - Returns: Number of matching events
    public func count(matching builder: QueryBuilder) async -> Int {
        await query(builder: builder).count
    }
    
    /// Checks if any events match a query
    /// - Parameter builder: The query builder
    /// - Returns: Whether any events match
    public func contains(matching builder: QueryBuilder) async -> Bool {
        await count(matching: builder) > 0
    }
}

// MARK: - RelayPool Extension

extension RelayPool {
    
    /// Subscribes using a query builder
    /// - Parameters:
    ///   - builder: The query builder
    ///   - id: Optional subscription ID
    /// - Returns: Pool subscription
    public func subscribe(
        query builder: QueryBuilder,
        id: String? = nil
    ) async throws -> PoolSubscription {
        try await subscribe(filters: [builder.build()], id: id)
    }
    
    /// Subscribes to multiple queries
    /// - Parameters:
    ///   - builders: Array of query builders
    ///   - id: Optional subscription ID
    /// - Returns: Pool subscription
    public func subscribe(
        queries builders: [QueryBuilder],
        id: String? = nil
    ) async throws -> PoolSubscription {
        try await subscribe(filters: builders.map { $0.build() }, id: id)
    }
}