import Foundation
import CoreNostr

/// A cache for storing and retrieving NOSTR events with configurable persistence options.
///
/// EventCache provides efficient storage and retrieval of events with support for:
/// - In-memory caching with LRU eviction
/// - Optional disk persistence
/// - Event deduplication
/// - Query optimization
/// - Automatic expiration of old events
///
/// ## Example
/// ```swift
/// let cache = EventCache(configuration: .persistent(directory: cacheDirectory))
/// 
/// // Store an event
/// try await cache.store(event)
/// 
/// // Retrieve events by ID
/// if let event = await cache.event(id: eventId) {
///     print("Found event: \(event.content)")
/// }
/// 
/// // Query events
/// let textNotes = await cache.query(filter: Filter(kinds: [.textNote], limit: 50))
/// ```
public actor EventCache {
    
    // MARK: - Types
    
    /// Configuration for the event cache
    public struct Configuration: Sendable {
        /// Maximum number of events to keep in memory
        public let maxMemoryEvents: Int
        
        /// Maximum age of events before they're considered stale
        public let maxEventAge: TimeInterval
        
        /// Persistence mode
        public let persistence: PersistenceMode
        
        /// Whether to automatically clean up expired events
        public let autoCleanup: Bool
        
        /// Cleanup interval in seconds
        public let cleanupInterval: TimeInterval
        
        /// Creates a memory-only cache configuration
        public static func memory(maxEvents: Int = 10_000) -> Configuration {
            Configuration(
                maxMemoryEvents: maxEvents,
                maxEventAge: 86400 * 30, // 30 days
                persistence: .memory,
                autoCleanup: true,
                cleanupInterval: 3600 // 1 hour
            )
        }
        
        /// Creates a persistent cache configuration
        public static func persistent(
            directory: URL,
            maxMemoryEvents: Int = 5_000,
            maxDiskSize: Int64 = 100_000_000 // 100MB
        ) -> Configuration {
            Configuration(
                maxMemoryEvents: maxMemoryEvents,
                maxEventAge: 86400 * 90, // 90 days
                persistence: .disk(directory: directory, maxSize: maxDiskSize),
                autoCleanup: true,
                cleanupInterval: 3600 // 1 hour
            )
        }
        
        public init(
            maxMemoryEvents: Int,
            maxEventAge: TimeInterval,
            persistence: PersistenceMode,
            autoCleanup: Bool,
            cleanupInterval: TimeInterval
        ) {
            self.maxMemoryEvents = maxMemoryEvents
            self.maxEventAge = maxEventAge
            self.persistence = persistence
            self.autoCleanup = autoCleanup
            self.cleanupInterval = cleanupInterval
        }
    }
    
    /// Persistence mode for the cache
    public enum PersistenceMode: Sendable {
        case memory
        case disk(directory: URL, maxSize: Int64)
    }
    
    /// Statistics about the cache
    public struct Statistics: Sendable {
        public let totalEvents: Int
        public let memoryEvents: Int
        public let diskEvents: Int
        public let cacheHits: Int
        public let cacheMisses: Int
        public let diskSize: Int64
        public let oldestEventDate: Date?
        public let newestEventDate: Date?
    }
    
    // MARK: - Properties
    
    private let configuration: Configuration
    
    /// In-memory event storage with LRU eviction
    private var memoryCache: [String: CachedEvent] = [:]
    
    /// Order of event IDs for LRU eviction
    private var lruOrder: [String] = []
    
    /// Event indices for efficient querying
    private var authorIndex: [String: Set<String>] = [:] // author -> event IDs
    private var kindIndex: [Int: Set<String>] = [:] // kind -> event IDs
    private var tagIndex: [String: [String: Set<String>]] = [:] // tag name -> tag value -> event IDs
    private var timestampIndex: [(Date, String)] = [] // (timestamp, event ID) sorted by timestamp
    
    /// Disk storage
    private let diskStorage: DiskEventStorage?
    
    /// Cache statistics
    private var stats = CacheStats()
    
    /// Cleanup timer
    private var cleanupTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    /// Creates a new event cache with the specified configuration
    public init(configuration: Configuration = .memory()) {
        self.configuration = configuration
        
        // Initialize disk storage if needed
        switch configuration.persistence {
        case .memory:
            self.diskStorage = nil
        case .disk(let directory, let maxSize):
            self.diskStorage = DiskEventStorage(directory: directory, maxSize: maxSize)
        }
        
        // Start cleanup task if enabled
        if configuration.autoCleanup {
            Task {
                await startCleanupTask()
            }
        }
    }
    
    deinit {
        cleanupTask?.cancel()
    }
    
    // MARK: - Event Storage
    
    /// Stores an event in the cache
    /// - Parameter event: The event to store
    /// - Returns: Whether the event was newly stored (false if it was already cached)
    @discardableResult
    public func store(_ event: NostrEvent) async throws -> Bool {
        let eventId = event.id
        
        // Check if already cached
        if memoryCache[eventId] != nil {
            stats.cacheHits += 1
            updateLRU(eventId: eventId)
            return false
        }
        
        // Check disk storage
        if let diskStorage = diskStorage,
           try await diskStorage.contains(eventId: eventId) {
            // Load from disk to memory
            if let diskEvent = try await diskStorage.load(eventId: eventId) {
                addToMemoryCache(diskEvent)
                stats.cacheHits += 1
                return false
            }
        }
        
        stats.cacheMisses += 1
        
        // Validate event
        guard try await validateEvent(event) else {
            throw NostrError.invalidEvent(reason: .invalidContent)
        }
        
        // Create cached event
        let cachedEvent = CachedEvent(
            event: event,
            receivedAt: Date(),
            relays: []
        )
        
        // Add to memory cache
        addToMemoryCache(cachedEvent)
        
        // Add to disk storage if configured
        if let diskStorage = diskStorage {
            try await diskStorage.store(cachedEvent)
        }
        
        // Update indices
        updateIndices(for: event, add: true)
        
        return true
    }
    
    /// Stores multiple events efficiently
    /// - Parameter events: Array of events to store
    /// - Returns: Number of newly stored events
    @discardableResult
    public func storeMany(_ events: [NostrEvent]) async throws -> Int {
        var newEvents = 0
        
        for event in events {
            if try await store(event) {
                newEvents += 1
            }
        }
        
        return newEvents
    }
    
    // MARK: - Event Retrieval
    
    /// Retrieves an event by ID
    /// - Parameter id: The event ID
    /// - Returns: The event if found
    public func event(id: EventID) async -> NostrEvent? {
        await eventById(id)
    }
    
    /// Retrieves an event by ID string
    /// - Parameter id: The event ID as hex string
    /// - Returns: The event if found
    private func eventById(_ id: String) async -> NostrEvent? {
        // Check memory cache
        if let cached = memoryCache[id] {
            stats.cacheHits += 1
            updateLRU(eventId: id)
            return cached.event
        }
        
        // Check disk storage
        if let diskStorage = diskStorage {
            if let cached = try? await diskStorage.load(eventId: id) {
                stats.cacheHits += 1
                addToMemoryCache(cached)
                return cached.event
            }
        }
        
        stats.cacheMisses += 1
        return nil
    }
    
    /// Queries events matching a filter
    /// - Parameter filter: The filter to match events against
    /// - Returns: Array of matching events
    public func query(filter: Filter) async -> [NostrEvent] {
        var matchingIds = Set<String>()
        
        // Start with all events if no specific filters
        if filter.ids == nil && filter.authors == nil && filter.kinds == nil && filter.e == nil && filter.p == nil {
            matchingIds = Set(memoryCache.keys)
            
            // Add disk events if available
            if let diskStorage = diskStorage {
                if let diskIds = try? await diskStorage.allEventIds() {
                    matchingIds.formUnion(diskIds)
                }
            }
        } else {
            // Use indices for efficient filtering
            var candidateSets: [Set<String>] = []
            
            // Filter by IDs
            if let ids = filter.ids {
                candidateSets.append(Set(ids))
            }
            
            // Filter by authors
            if let authors = filter.authors {
                let authorMatches = authors.flatMap { authorIndex[$0] ?? [] }
                candidateSets.append(Set(authorMatches))
            }
            
            // Filter by kinds
            if let kinds = filter.kinds {
                let kindMatches = kinds.flatMap { kindIndex[$0] ?? [] }
                candidateSets.append(Set(kindMatches))
            }
            
            // Filter by e tags
            if let eTags = filter.e {
                let tagMatches = eTags.flatMap { tagIndex["e"]?[$0] ?? [] }
                if !tagMatches.isEmpty {
                    candidateSets.append(Set(tagMatches))
                }
            }
            
            // Filter by p tags
            if let pTags = filter.p {
                let tagMatches = pTags.flatMap { tagIndex["p"]?[$0] ?? [] }
                if !tagMatches.isEmpty {
                    candidateSets.append(Set(tagMatches))
                }
            }
            
            // Intersect all candidate sets
            if !candidateSets.isEmpty {
                matchingIds = candidateSets.reduce(candidateSets[0]) { $0.intersection($1) }
            }
        }
        
        // Load events and apply remaining filters
        var events: [NostrEvent] = []
        
        for eventId in matchingIds {
            if let event = await eventById(eventId) {
                // Apply time filters
                if let since = filter.since, event.createdAt < since {
                    continue
                }
                if let until = filter.until, event.createdAt > until {
                    continue
                }
                
                // Apply additional filter checks
                if matchesFilter(event: event, filter: filter) {
                    events.append(event)
                }
            }
        }
        
        // Sort by timestamp (newest first)
        events.sort { $0.createdAt > $1.createdAt }
        
        // Apply limit
        if let limit = filter.limit, limit > 0 {
            events = Array(events.prefix(limit))
        }
        
        return events
    }
    
    /// Gets events by author
    /// - Parameters:
    ///   - author: The author's public key
    ///   - kinds: Optional event kinds to filter by
    ///   - limit: Maximum number of events to return
    /// - Returns: Array of events from the author
    public func eventsByAuthor(
        _ author: PublicKey,
        kinds: [EventKind]? = nil,
        limit: Int? = nil
    ) async -> [NostrEvent] {
        var filter = Filter(authors: [author])
        filter.kinds = kinds?.map { $0.rawValue }
        filter.limit = limit
        
        return await query(filter: filter)
    }
    
    // MARK: - Event Deletion
    
    /// Removes an event from the cache
    /// - Parameter id: The event ID to remove
    /// - Returns: Whether an event was removed
    @discardableResult
    public func remove(id: EventID) async -> Bool {
        await removeById(id)
    }
    
    /// Removes an event from the cache
    /// - Parameter id: The event ID hex string to remove
    /// - Returns: Whether an event was removed
    @discardableResult
    private func removeById(_ id: String) async -> Bool {
        guard let cached = memoryCache.removeValue(forKey: id) else {
            // Try disk storage
            if let diskStorage {
                return (try? await diskStorage.delete(eventId: id)) ?? false
            }
            return false
        }
        
        // Update indices
        updateIndices(for: cached.event, add: false)
        
        // Remove from LRU
        lruOrder.removeAll { $0 == id }
        
        // Remove from disk
        if let diskStorage {
            _ = try? await diskStorage.delete(eventId: id)
        }
        
        return true
    }
    
    /// Processes event deletions according to NIP-09
    /// - Parameter deletionEvent: The deletion event (kind 5)
    public func processDeletion(_ deletionEvent: NostrEvent) async {
        guard deletionEvent.kind == EventKind.deletion.rawValue else { return }
        
        // Get event IDs to delete
        let eventIds = deletionEvent.tags
            .filter { $0.first == "e" && $0.count >= 2 }
            .map { $0[1] }
        
        // Only delete events from the same author
        for eventId in eventIds {
            if let event = await event(id: eventId),
               event.pubkey == deletionEvent.pubkey {
                await remove(id: eventId)
            }
        }
    }
    
    // MARK: - Cache Management
    
    /// Clears all events from the cache
    public func clear() async {
        memoryCache.removeAll()
        lruOrder.removeAll()
        authorIndex.removeAll()
        kindIndex.removeAll()
        tagIndex.removeAll()
        timestampIndex.removeAll()
        
        if let diskStorage = diskStorage {
            try? await diskStorage.clear()
        }
        
        stats = CacheStats()
    }
    
    /// Gets current cache statistics
    public func statistics() async -> Statistics {
        let diskEvents = diskStorage != nil ? (try? await diskStorage!.count()) ?? 0 : 0
        let diskSize = diskStorage != nil ? (try? await diskStorage!.size()) ?? 0 : 0
        
        let oldestDate = timestampIndex.first?.0
        let newestDate = timestampIndex.last?.0
        
        return Statistics(
            totalEvents: memoryCache.count + diskEvents,
            memoryEvents: memoryCache.count,
            diskEvents: diskEvents,
            cacheHits: stats.cacheHits,
            cacheMisses: stats.cacheMisses,
            diskSize: diskSize,
            oldestEventDate: oldestDate,
            newestEventDate: newestDate
        )
    }
    
    // MARK: - Private Methods
    
    private func matchesFilter(event: NostrEvent, filter: Filter) -> Bool {
        // Check IDs
        if let ids = filter.ids, !ids.contains(event.id) {
            return false
        }
        
        // Check authors
        if let authors = filter.authors, !authors.contains(event.pubkey) {
            return false
        }
        
        // Check kinds
        if let kinds = filter.kinds, !kinds.contains(event.kind) {
            return false
        }
        
        // Check e tags
        if let eTags = filter.e {
            let eventETags = event.tags.filter { $0.count >= 2 && $0[0] == "e" }.map { $0[1] }
            if !eTags.contains(where: { eventETags.contains($0) }) {
                return false
            }
        }
        
        // Check p tags
        if let pTags = filter.p {
            let eventPTags = event.tags.filter { $0.count >= 2 && $0[0] == "p" }.map { $0[1] }
            if !pTags.contains(where: { eventPTags.contains($0) }) {
                return false
            }
        }
        
        return true
    }
    
    private func addToMemoryCache(_ cached: CachedEvent) {
        let eventId = cached.event.id
        
        // Check memory limit
        if memoryCache.count >= configuration.maxMemoryEvents {
            evictOldestFromMemory()
        }
        
        memoryCache[eventId] = cached
        lruOrder.append(eventId)
    }
    
    private func updateLRU(eventId: String) {
        // Move to end of LRU order
        lruOrder.removeAll { $0 == eventId }
        lruOrder.append(eventId)
    }
    
    private func evictOldestFromMemory() {
        guard let oldestId = lruOrder.first else { return }
        
        lruOrder.removeFirst()
        
        if let cached = memoryCache.removeValue(forKey: oldestId) {
            updateIndices(for: cached.event, add: false)
        }
    }
    
    private func updateIndices(for event: NostrEvent, add: Bool) {
        let eventId = event.id
        
        // Author index
        if add {
            authorIndex[event.pubkey, default: []].insert(eventId)
        } else {
            authorIndex[event.pubkey]?.remove(eventId)
            if authorIndex[event.pubkey]?.isEmpty == true {
                authorIndex.removeValue(forKey: event.pubkey)
            }
        }
        
        // Kind index
        if add {
            kindIndex[event.kind, default: []].insert(eventId)
        } else {
            kindIndex[event.kind]?.remove(eventId)
            if kindIndex[event.kind]?.isEmpty == true {
                kindIndex.removeValue(forKey: event.kind)
            }
        }
        
        // Tag index
        for tag in event.tags {
            guard tag.count >= 2 else { continue }
            let tagName = tag[0]
            let tagValue = tag[1]
            
            if add {
                if tagIndex[tagName] == nil {
                    tagIndex[tagName] = [:]
                }
                tagIndex[tagName]?[tagValue, default: []].insert(eventId)
            } else {
                tagIndex[tagName]?[tagValue]?.remove(eventId)
                if tagIndex[tagName]?[tagValue]?.isEmpty == true {
                    tagIndex[tagName]?.removeValue(forKey: tagValue)
                }
                if tagIndex[tagName]?.isEmpty == true {
                    tagIndex.removeValue(forKey: tagName)
                }
            }
        }
        
        // Timestamp index
        if add {
            let eventDate = Date(timeIntervalSince1970: TimeInterval(event.createdAt))
            let entry = (eventDate, eventId)
            let insertIndex = timestampIndex.firstIndex { $0.0 > eventDate } ?? timestampIndex.count
            timestampIndex.insert(entry, at: insertIndex)
        } else {
            timestampIndex.removeAll { $0.1 == eventId }
        }
    }
    
    private func validateEvent(_ event: NostrEvent) async throws -> Bool {
        // Basic validation is done by CoreNostr
        // Additional validation can be added here
        
        // Check event age
        let eventDate = Date(timeIntervalSince1970: TimeInterval(event.createdAt))
        let age = Date().timeIntervalSince(eventDate)
        if age > configuration.maxEventAge {
            return false
        }
        
        // Verify event
        return try CoreNostr.verifyEvent(event)
    }
    
    private func startCleanupTask() {
        cleanupTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(configuration.cleanupInterval * 1_000_000_000))
                await performCleanup()
            }
        }
    }
    
    private func performCleanup() async {
        let cutoffDate = Date().addingTimeInterval(-configuration.maxEventAge)
        
        // Find expired events
        var expiredIds: [String] = []
        for (timestamp, eventId) in timestampIndex {
            if timestamp < cutoffDate {
                expiredIds.append(eventId)
            } else {
                break // Timestamp index is sorted
            }
        }
        
        // Remove expired events
        for eventId in expiredIds {
            await remove(id: eventId)
        }
        
        // Clean up disk storage
        if let diskStorage = diskStorage {
            try? await diskStorage.cleanup(maxAge: configuration.maxEventAge)
        }
    }
}

// MARK: - Supporting Types

/// A cached event with metadata
private struct CachedEvent: Sendable {
    let event: NostrEvent
    let receivedAt: Date
    var relays: Set<String>
}

/// Cache statistics
private struct CacheStats {
    var cacheHits: Int = 0
    var cacheMisses: Int = 0
}

// MARK: - Disk Storage

/// Handles disk persistence for events
private actor DiskEventStorage {
    private let directory: URL
    private let maxSize: Int64
    private let fileManager = FileManager.default
    
    init(directory: URL, maxSize: Int64) {
        self.directory = directory
        self.maxSize = maxSize
        
        // Create directory if needed
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    
    func store(_ cached: CachedEvent) async throws {
        let eventId = cached.event.id
        let fileURL = directory.appendingPathComponent("\(eventId).json")
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cached.event)
        
        try data.write(to: fileURL)
    }
    
    func load(eventId: String) async throws -> CachedEvent? {
        let fileURL = directory.appendingPathComponent("\(eventId).json")
        
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(NostrEvent.self, from: data)
        
        // Get file creation date
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let receivedAt = attributes[.creationDate] as? Date ?? Date()
        
        return CachedEvent(
            event: event,
            receivedAt: receivedAt,
            relays: []
        )
    }
    
    func delete(eventId: String) async throws -> Bool {
        let fileURL = directory.appendingPathComponent("\(eventId).json")
        
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return false
        }
        
        try fileManager.removeItem(at: fileURL)
        return true
    }
    
    func contains(eventId: String) async throws -> Bool {
        let fileURL = directory.appendingPathComponent("\(eventId).json")
        return fileManager.fileExists(atPath: fileURL.path)
    }
    
    func allEventIds() async throws -> [String] {
        let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        
        return contents.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            return url.deletingPathExtension().lastPathComponent
        }
    }
    
    func count() async throws -> Int {
        try await allEventIds().count
    }
    
    func size() async throws -> Int64 {
        let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        
        var totalSize: Int64 = 0
        for url in contents {
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
            totalSize += Int64(resourceValues.fileSize ?? 0)
        }
        
        return totalSize
    }
    
    func clear() async throws {
        let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        
        for url in contents {
            try fileManager.removeItem(at: url)
        }
    }
    
    func cleanup(maxAge: TimeInterval) async throws {
        let cutoffDate = Date().addingTimeInterval(-maxAge)
        let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
        
        for url in contents {
            let resourceValues = try url.resourceValues(forKeys: [.creationDateKey])
            if let creationDate = resourceValues.creationDate, creationDate < cutoffDate {
                try fileManager.removeItem(at: url)
            }
        }
        
        // Also check total size
        let currentSize = try await size()
        if currentSize > maxSize {
            // Remove oldest files until under limit
            let sortedContents = try contents.sorted { url1, url2 in
                let date1 = try url1.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date()
                let date2 = try url2.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date()
                return date1 < date2
            }
            
            var removedSize: Int64 = 0
            for url in sortedContents {
                if currentSize - removedSize <= maxSize {
                    break
                }
                
                let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
                let fileSize = Int64(resourceValues.fileSize ?? 0)
                
                try fileManager.removeItem(at: url)
                removedSize += fileSize
            }
        }
    }
}
