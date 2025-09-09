# Performance Optimization

Optimize your NOSTR application for speed, efficiency, and battery life.

## Overview

Building performant NOSTR applications requires careful attention to network usage, memory management, and battery consumption. This guide covers advanced techniques for optimizing NostrKit applications on iOS and macOS.

## Network Optimization

### Connection Pooling

```swift
class OptimizedRelayPool: RelayPool {
    private let maxConcurrentConnections = 5
    private let connectionQueue = DispatchQueue(label: "relay.connections", attributes: .concurrent)
    private var activeConnections = Set<String>()
    
    override func connectAll() async throws {
        let relays = await getRelays()
        
        // Connect in batches to avoid overwhelming the system
        for batch in relays.chunked(into: maxConcurrentConnections) {
            await withTaskGroup(of: Void.self) { group in
                for relay in batch {
                    group.addTask {
                        try? await self.connect(to: relay)
                    }
                }
            }
        }
    }
    
    func optimizeConnections() async {
        // Disconnect from poorly performing relays
        let metrics = await getConnectionMetrics()
        
        for (relay, metric) in metrics {
            if metric.errorRate > 0.5 || metric.averageLatency > 2000 {
                await disconnect(from: relay)
                print("Disconnected from poor performing relay: \\(relay)")
            }
        }
        
        // Ensure minimum connections
        let connected = await connectedRelays()
        if connected.count < 3 {
            await connectToBackupRelays()
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
```

### Request Batching

```swift
actor BatchedRequestManager {
    private var pendingRequests: [RequestBatch] = []
    private let batchSize = 10
    private let batchDelay: TimeInterval = 0.1
    private var batchTask: Task<Void, Never>?
    
    struct RequestBatch {
        let filter: Filter
        let completion: (Result<[NostrEvent], Error>) -> Void
    }
    
    func request(filter: Filter) async throws -> [NostrEvent] {
        return try await withCheckedThrowingContinuation { continuation in
            let batch = RequestBatch(filter: filter) { result in
                continuation.resume(with: result)
            }
            
            pendingRequests.append(batch)
            
            if batchTask == nil {
                batchTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(batchDelay * 1_000_000_000))
                    await processBatch()
                    batchTask = nil
                }
            }
        }
    }
    
    private func processBatch() async {
        let requests = pendingRequests
        pendingRequests.removeAll()
        
        // Combine similar filters
        let combinedFilter = combineFilters(requests.map { $0.filter })
        
        do {
            let events = try await fetchEvents(with: combinedFilter)
            
            // Distribute results to original requests
            for request in requests {
                let filtered = events.filter { event in
                    matchesFilter(event, request.filter)
                }
                request.completion(.success(filtered))
            }
        } catch {
            for request in requests {
                request.completion(.failure(error))
            }
        }
    }
    
    private func combineFilters(_ filters: [Filter]) -> Filter {
        // Combine multiple filters into one efficient filter
        var combined = Filter()
        
        for filter in filters {
            combined.kinds = Array(Set((combined.kinds ?? []) + (filter.kinds ?? [])))
            combined.authors = Array(Set((combined.authors ?? []) + (filter.authors ?? [])))
            // Combine other fields...
        }
        
        return combined
    }
}
```

### Compression

```swift
extension RelayService {
    func enableCompression() {
        // Enable WebSocket compression
        webSocketTask?.sendPing { error in
            if error == nil {
                // Compression negotiated successfully
            }
        }
    }
    
    func compressLargeEvents(_ event: NostrEvent) -> NostrEvent {
        guard event.content.count > 1000 else { return event }
        
        // For large content, consider using references
        if let compressedContent = compress(event.content) {
            var modifiedEvent = event
            modifiedEvent.tags.append(["compressed", "gzip"])
            modifiedEvent.content = compressedContent.base64EncodedString()
            return modifiedEvent
        }
        
        return event
    }
    
    private func compress(_ string: String) -> Data? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? (data as NSData).compressed(using: .gzip) as Data
    }
}
```

## Memory Management

### Event Cache Optimization

```swift
class OptimizedEventCache: EventCache {
    private let memoryWarningObserver: NSObjectProtocol
    private var memoryPressure = false
    
    override init(memoryLimit: Int = 10_000) {
        // Monitor memory warnings
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        }
        
        super.init(memoryLimit: memoryLimit)
    }
    
    private func handleMemoryWarning() {
        memoryPressure = true
        
        // Aggressively clear cache
        Task {
            await clearOldEvents(keepRatio: 0.2) // Keep only 20%
        }
    }
    
    func optimizedQuery(filter: Filter) -> [NostrEvent] {
        if memoryPressure {
            // Return limited results under memory pressure
            return Array(query(filter: filter).prefix(20))
        }
        
        return query(filter: filter)
    }
    
    @discardableResult
    func clearOldEvents(keepRatio: Double) async -> Int {
        let currentCount = await eventCount()
        let targetCount = Int(Double(currentCount) * keepRatio)
        
        if currentCount <= targetCount {
            return 0
        }
        
        // Remove oldest events
        let events = await getAllEvents()
        let sorted = events.sorted { $0.createdAt > $1.createdAt }
        let toRemove = sorted.suffix(currentCount - targetCount)
        
        var removed = 0
        for event in toRemove {
            await remove(eventId: event.id)
            removed += 1
        }
        
        memoryPressure = false
        return removed
    }
}
```

### Image Memory Management

```swift
class ImageMemoryManager {
    private let imageCache = NSCache<NSString, UIImage>()
    private let thumbnailCache = NSCache<NSString, UIImage>()
    
    init() {
        // Configure cache limits
        imageCache.countLimit = 100
        imageCache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
        
        thumbnailCache.countLimit = 500
        thumbnailCache.totalCostLimit = 20 * 1024 * 1024 // 20 MB
    }
    
    func cachedImage(for url: URL, size: CGSize? = nil) async -> UIImage? {
        let key = cacheKey(for: url, size: size)
        
        // Check appropriate cache
        if let size = size {
            if let thumbnail = thumbnailCache.object(forKey: key as NSString) {
                return thumbnail
            }
        } else {
            if let fullImage = imageCache.object(forKey: key as NSString) {
                return fullImage
            }
        }
        
        // Download and cache
        return await downloadAndCache(url: url, size: size)
    }
    
    private func downloadAndCache(url: URL, size: CGSize?) async -> UIImage? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard var image = UIImage(data: data) else { return nil }
            
            if let size = size {
                // Create thumbnail
                image = await image.thumbnail(targetSize: size)
                thumbnailCache.setObject(
                    image,
                    forKey: cacheKey(for: url, size: size) as NSString,
                    cost: Int(size.width * size.height * 4)
                )
            } else {
                // Cache full image
                imageCache.setObject(
                    image,
                    forKey: cacheKey(for: url, size: nil) as NSString,
                    cost: data.count
                )
            }
            
            return image
        } catch {
            return nil
        }
    }
    
    private func cacheKey(for url: URL, size: CGSize?) -> String {
        if let size = size {
            return "\\(url.absoluteString)_\\(Int(size.width))x\\(Int(size.height))"
        }
        return url.absoluteString
    }
}

extension UIImage {
    func thumbnail(targetSize: CGSize) async -> UIImage {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let renderer = UIGraphicsImageRenderer(size: targetSize)
                let thumbnail = renderer.image { _ in
                    self.draw(in: CGRect(origin: .zero, size: targetSize))
                }
                continuation.resume(returning: thumbnail)
            }
        }
    }
}
```

## Battery Optimization

### Background Task Management

```swift
class BackgroundTaskManager {
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    func performBackgroundSync() {
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
        
        Task {
            await syncInBackground()
            endBackgroundTask()
        }
    }
    
    private func syncInBackground() async {
        // Perform minimal essential tasks only
        let essentialFilters = [
            Filter(kinds: [.encryptedDirectMessage], limit: 10),
            Filter(kinds: [.textNote], authors: followingList, limit: 20)
        ]
        
        do {
            for filter in essentialFilters {
                let events = try await relayPool.query(filter: filter)
                await cache.store(events)
            }
        } catch {
            print("Background sync failed: \\(error)")
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
```

### Adaptive Quality of Service

```swift
class AdaptiveQoSManager {
    enum PowerState {
        case normal
        case lowPower
        case veryLowPower
    }
    
    @Published private(set) var currentState: PowerState = .normal
    private var batteryLevel: Float = 1.0
    private var isLowPowerMode = false
    
    init() {
        observeBatteryState()
        observeLowPowerMode()
    }
    
    private func observeBatteryState() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePowerState()
        }
    }
    
    private func observeLowPowerMode() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePowerState()
        }
    }
    
    private func updatePowerState() {
        batteryLevel = UIDevice.current.batteryLevel
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        
        if isLowPowerMode || batteryLevel < 0.1 {
            currentState = .veryLowPower
        } else if batteryLevel < 0.3 {
            currentState = .lowPower
        } else {
            currentState = .normal
        }
    }
    
    func adaptedConfiguration() -> RelayPoolConfiguration {
        switch currentState {
        case .normal:
            return RelayPoolConfiguration(
                maxRelaysPerPool: 10,
                connectionTimeout: 5.0,
                subscriptionBatchSize: 100
            )
            
        case .lowPower:
            return RelayPoolConfiguration(
                maxRelaysPerPool: 5,
                connectionTimeout: 3.0,
                subscriptionBatchSize: 50
            )
            
        case .veryLowPower:
            return RelayPoolConfiguration(
                maxRelaysPerPool: 2,
                connectionTimeout: 2.0,
                subscriptionBatchSize: 20
            )
        }
    }
    
    func shouldFetchImages() -> Bool {
        return currentState == .normal
    }
    
    func pollingInterval() -> TimeInterval {
        switch currentState {
        case .normal: return 30
        case .lowPower: return 60
        case .veryLowPower: return 120
        }
    }
}
```

## UI Performance

### List Optimization

```swift
struct OptimizedEventList: View {
    @StateObject private var viewModel = EventListViewModel()
    
    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(viewModel.events) { event in
                    OptimizedEventRow(event: event)
                        .id(event.id)
                        .listRowInsets(EdgeInsets())
                        .onAppear {
                            viewModel.eventAppeared(event)
                        }
                        .onDisappear {
                            viewModel.eventDisappeared(event)
                        }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
        }
    }
}

struct OptimizedEventRow: View {
    let event: NostrEvent
    @State private var isVisible = false
    
    var body: some View {
        Group {
            if isVisible {
                FullEventView(event: event)
            } else {
                PlaceholderEventView(height: estimatedHeight)
                    .onAppear {
                        // Delay rendering for smooth scrolling
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isVisible = true
                        }
                    }
            }
        }
    }
    
    var estimatedHeight: CGFloat {
        // Estimate based on content length
        let lines = event.content.count / 50
        return CGFloat(100 + (lines * 20))
    }
}

@MainActor
class EventListViewModel: ObservableObject {
    @Published var events: [NostrEvent] = []
    private var visibleEvents = Set<EventID>()
    private var prefetchTask: Task<Void, Never>?
    
    func eventAppeared(_ event: NostrEvent) {
        visibleEvents.insert(event.id)
        
        // Prefetch profiles for visible events
        Task {
            await prefetchProfiles(for: event)
        }
        
        // Check if we need to load more
        if let lastEvent = events.last,
           event.id == lastEvent.id {
            loadMore()
        }
    }
    
    func eventDisappeared(_ event: NostrEvent) {
        visibleEvents.remove(event.id)
    }
    
    private func prefetchProfiles(for event: NostrEvent) async {
        // Prefetch author profile
        _ = try? await profileManager.fetchProfile(pubkey: event.pubkey)
        
        // Prefetch mentioned profiles
        let mentionedPubkeys = extractMentions(from: event)
        for pubkey in mentionedPubkeys.prefix(5) { // Limit prefetch
            _ = try? await profileManager.fetchProfile(pubkey: pubkey)
        }
    }
    
    private func loadMore() {
        guard prefetchTask == nil else { return }
        
        prefetchTask = Task {
            defer { prefetchTask = nil }
            
            // Load next batch
            let newEvents = try? await fetchNextBatch()
            if let newEvents = newEvents {
                await MainActor.run {
                    self.events.append(contentsOf: newEvents)
                }
            }
        }
    }
}
```

### Async Image Loading

```swift
struct OptimizedAsyncImage: View {
    let url: URL?
    let size: CGSize
    @State private var phase = ImagePhase.empty
    @State private var loadTask: Task<Void, Never>?
    
    enum ImagePhase {
        case empty
        case loading
        case success(UIImage)
        case failure
    }
    
    var body: some View {
        Group {
            switch phase {
            case .empty, .loading:
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: size.width, height: size.height)
                    .onAppear {
                        loadImage()
                    }
                    .onDisappear {
                        loadTask?.cancel()
                    }
                
            case .success(let image):
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                
            case .failure:
                Image(systemName: "photo")
                    .foregroundColor(.gray)
                    .frame(width: size.width, height: size.height)
            }
        }
    }
    
    private func loadImage() {
        guard let url = url else {
            phase = .failure
            return
        }
        
        phase = .loading
        
        loadTask = Task {
            // Check if we should load images (battery/network)
            guard AdaptiveQoSManager.shared.shouldFetchImages() else {
                await MainActor.run {
                    phase = .failure
                }
                return
            }
            
            if let image = await ImageMemoryManager.shared.cachedImage(for: url, size: size) {
                await MainActor.run {
                    phase = .success(image)
                }
            } else {
                await MainActor.run {
                    phase = .failure
                }
            }
        }
    }
}
```

## Profiling and Monitoring

### Performance Metrics

```swift
class PerformanceMonitor {
    static let shared = PerformanceMonitor()
    
    private var metrics: [String: Metric] = [:]
    
    struct Metric {
        var count: Int = 0
        var totalTime: TimeInterval = 0
        var minTime: TimeInterval = .infinity
        var maxTime: TimeInterval = 0
        
        var averageTime: TimeInterval {
            count > 0 ? totalTime / Double(count) : 0
        }
    }
    
    func measure<T>(_ label: String, block: () async throws -> T) async rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            recordMetric(label: label, time: elapsed)
        }
        
        return try await block()
    }
    
    private func recordMetric(label: String, time: TimeInterval) {
        var metric = metrics[label] ?? Metric()
        metric.count += 1
        metric.totalTime += time
        metric.minTime = min(metric.minTime, time)
        metric.maxTime = max(metric.maxTime, time)
        metrics[label] = metric
        
        // Log slow operations
        if time > 1.0 {
            print("⚠️ Slow operation: \\(label) took \\(String(format: "%.2f", time))s")
        }
    }
    
    func report() -> String {
        var report = "Performance Report:\\n"
        report += "==================\\n"
        
        for (label, metric) in metrics.sorted(by: { $0.value.totalTime > $1.value.totalTime }) {
            report += String(format: "%@: avg=%.3fs, min=%.3fs, max=%.3fs, count=%d\\n",
                           label,
                           metric.averageTime,
                           metric.minTime,
                           metric.maxTime,
                           metric.count)
        }
        
        return report
    }
}

// Usage
let events = await PerformanceMonitor.shared.measure("fetch_events") {
    try await relayPool.query(filter: filter)
}
```

### Memory Profiling

```swift
class MemoryProfiler {
    static func currentMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1024.0 / 1024.0 : 0
    }
    
    static func logMemoryUsage(_ label: String) {
        let usage = currentMemoryUsage()
        print("📊 Memory [\\(label)]: \\(String(format: "%.1f", usage)) MB")
    }
}
```

## Best Practices

### 1. Lazy Loading
- Load content on demand
- Prefetch intelligently based on user behavior
- Cancel unnecessary requests

### 2. Caching Strategy
- Cache frequently accessed data
- Implement TTL for cache entries
- Clear cache on memory warnings

### 3. Network Efficiency
- Batch similar requests
- Use compression for large payloads
- Implement retry with exponential backoff

### 4. Battery Conservation
- Reduce polling frequency on low battery
- Defer non-essential tasks
- Use system notifications for updates

### 5. UI Responsiveness
- Perform heavy operations off the main thread
- Use placeholder content while loading
- Implement progressive disclosure

## Summary

Optimizing NostrKit applications requires attention to:

- Network efficiency through batching and compression
- Memory management with intelligent caching
- Battery optimization with adaptive behavior
- UI performance through lazy loading and virtualization
- Continuous monitoring and profiling

By implementing these techniques, you can build NOSTR applications that are fast, efficient, and provide excellent user experience even under challenging conditions.