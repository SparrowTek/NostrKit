import Foundation
import CoreNostr

/// Configuration for network resilience features
public struct ResilienceConfiguration: Sendable {
    /// Initial reconnection delay in seconds
    public let initialDelay: TimeInterval
    
    /// Maximum reconnection delay in seconds
    public let maxDelay: TimeInterval
    
    /// Multiplier for exponential backoff
    public let backoffMultiplier: Double
    
    /// Jitter factor (0.0 to 1.0) for randomizing delays
    public let jitterFactor: Double
    
    /// Maximum number of reconnection attempts
    public let maxAttempts: Int
    
    /// Heartbeat interval in seconds
    public let heartbeatInterval: TimeInterval
    
    /// Heartbeat timeout in seconds
    public let heartbeatTimeout: TimeInterval
    
    /// Whether to automatically resubscribe after reconnection
    public let autoResubscribe: Bool
    
    public init(
        initialDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 60.0,
        backoffMultiplier: Double = 2.0,
        jitterFactor: Double = 0.3,
        maxAttempts: Int = 10,
        heartbeatInterval: TimeInterval = 30.0,
        heartbeatTimeout: TimeInterval = 10.0,
        autoResubscribe: Bool = true
    ) {
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.backoffMultiplier = backoffMultiplier
        self.jitterFactor = jitterFactor
        self.maxAttempts = maxAttempts
        self.heartbeatInterval = heartbeatInterval
        self.heartbeatTimeout = heartbeatTimeout
        self.autoResubscribe = autoResubscribe
    }
    
    /// Default configuration with reasonable values
    public static let `default` = ResilienceConfiguration()
    
    /// Aggressive configuration for unreliable networks
    public static let aggressive = ResilienceConfiguration(
        initialDelay: 0.5,
        maxDelay: 30.0,
        backoffMultiplier: 1.5,
        jitterFactor: 0.5,
        maxAttempts: 20,
        heartbeatInterval: 20.0,
        heartbeatTimeout: 5.0,
        autoResubscribe: true
    )
    
    /// Conservative configuration for stable networks
    public static let conservative = ResilienceConfiguration(
        initialDelay: 2.0,
        maxDelay: 120.0,
        backoffMultiplier: 3.0,
        jitterFactor: 0.2,
        maxAttempts: 5,
        heartbeatInterval: 60.0,
        heartbeatTimeout: 15.0,
        autoResubscribe: true
    )
}

/// Manages exponential backoff with jitter for reconnection attempts
public actor BackoffManager {
    private let config: ResilienceConfiguration
    private var attemptCount: Int = 0
    private var currentDelay: TimeInterval
    
    public init(config: ResilienceConfiguration) {
        self.config = config
        self.currentDelay = config.initialDelay
    }
    
    /// Calculates the next delay with exponential backoff and jitter
    public func nextDelay() -> TimeInterval? {
        guard attemptCount < config.maxAttempts else {
            return nil // Max attempts reached
        }
        
        attemptCount += 1
        
        // Calculate base delay with exponential backoff
        let baseDelay = min(
            currentDelay * pow(config.backoffMultiplier, Double(attemptCount - 1)),
            config.maxDelay
        )
        
        // Add jitter
        let jitterRange = baseDelay * config.jitterFactor
        let jitter = Double.random(in: -jitterRange...jitterRange)
        let delayWithJitter = max(0.1, baseDelay + jitter)
        
        currentDelay = baseDelay
        
        return delayWithJitter
    }
    
    /// Resets the backoff state
    public func reset() {
        attemptCount = 0
        currentDelay = config.initialDelay
    }
    
    /// Returns the current attempt count
    public var attempts: Int {
        attemptCount
    }
    
    /// Returns whether max attempts have been reached
    public var isExhausted: Bool {
        attemptCount >= config.maxAttempts
    }
}

/// Manages heartbeat/ping-pong for connection health monitoring
public actor HeartbeatManager {
    private let config: ResilienceConfiguration
    private var pingTask: Task<Void, Never>?
    private var lastPongReceived: Date?
    private var isMonitoring = false
    
    /// Callback when heartbeat timeout is detected
    public var onTimeout: (() async -> Void)?
    
    public init(config: ResilienceConfiguration) {
        self.config = config
    }
    
    /// Sets the timeout handler
    public func setTimeoutHandler(_ handler: @escaping () async -> Void) {
        onTimeout = handler
    }
    
    /// Starts heartbeat monitoring
    public func start(
        sendPing: @escaping () async throws -> Void,
        checkConnection: @escaping () async -> Bool
    ) {
        guard !isMonitoring else { return }
        isMonitoring = true
        lastPongReceived = Date()
        
        pingTask = Task {
            while !Task.isCancelled && isMonitoring {
                do {
                    try await Task.sleep(for: .seconds(config.heartbeatInterval))
                    
                    guard isMonitoring else { break }
                    
                    // Check if we've received a pong recently
                    if let lastPong = lastPongReceived {
                        let timeSinceLastPong = Date().timeIntervalSince(lastPong)
                        if timeSinceLastPong > config.heartbeatTimeout + config.heartbeatInterval {
                            // Heartbeat timeout detected
                            await onTimeout?()
                            break
                        }
                    }
                    
                    // Send ping
                    if await checkConnection() {
                        try await sendPing()
                    } else {
                        break
                    }
                    
                } catch {
                    // Error sending ping, connection might be broken
                    if isMonitoring {
                        await onTimeout?()
                    }
                    break
                }
            }
        }
    }
    
    /// Records that a pong was received
    public func recordPong() {
        lastPongReceived = Date()
    }
    
    /// Stops heartbeat monitoring
    public func stop() {
        isMonitoring = false
        pingTask?.cancel()
        pingTask = nil
        lastPongReceived = nil
    }
    
    /// Returns the time since last pong
    public var timeSinceLastPong: TimeInterval? {
        guard let lastPong = lastPongReceived else { return nil }
        return Date().timeIntervalSince(lastPong)
    }
}

/// Manages subscription state for automatic resubscription
public actor SubscriptionStateManager {
    public struct SubscriptionInfo: Sendable {
        let filters: [Filter]
        let timestamp: Date
    }
    
    private var activeSubscriptions: [String: SubscriptionInfo] = [:]
    
    /// Records a subscription
    public func recordSubscription(id: String, filters: [Filter]) {
        activeSubscriptions[id] = SubscriptionInfo(filters: filters, timestamp: Date())
    }
    
    /// Removes a subscription
    public func removeSubscription(id: String) {
        activeSubscriptions.removeValue(forKey: id)
    }
    
    /// Returns all active subscriptions
    public func getAllSubscriptions() -> [(id: String, filters: [Filter], timestamp: Date)] {
        activeSubscriptions.map { (id, value) in
            (id: id, filters: value.filters, timestamp: value.timestamp)
        }
    }
    
    /// Clears all subscriptions
    public func clearAll() {
        activeSubscriptions.removeAll()
    }
    
    /// Returns the count of active subscriptions
    public var count: Int {
        activeSubscriptions.count
    }
    
    /// Prunes subscriptions older than the specified age
    public func pruneOldSubscriptions(olderThan age: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-age)
        activeSubscriptions = activeSubscriptions.filter { _, value in
            value.timestamp > cutoff
        }
    }
}

/// Connection state for relay connections
public enum ConnectionState: Sendable {
    case disconnected
    case connecting(attempt: Int)
    case connected(since: Date)
    case reconnecting(attempt: Int, nextRetry: Date)
    case failed(reason: String)
    
    public var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

/// Statistics for connection resilience
public struct ResilienceStatistics: Sendable {
    public let totalReconnections: Int
    public let successfulReconnections: Int
    public let failedReconnections: Int
    public let totalHeartbeatsSent: Int
    public let totalHeartbeatsReceived: Int
    public let averageReconnectionTime: TimeInterval?
    public let lastDisconnection: Date?
    public let lastReconnection: Date?
    public let currentUptime: TimeInterval?
    
    public init(
        totalReconnections: Int = 0,
        successfulReconnections: Int = 0,
        failedReconnections: Int = 0,
        totalHeartbeatsSent: Int = 0,
        totalHeartbeatsReceived: Int = 0,
        averageReconnectionTime: TimeInterval? = nil,
        lastDisconnection: Date? = nil,
        lastReconnection: Date? = nil,
        currentUptime: TimeInterval? = nil
    ) {
        self.totalReconnections = totalReconnections
        self.successfulReconnections = successfulReconnections
        self.failedReconnections = failedReconnections
        self.totalHeartbeatsSent = totalHeartbeatsSent
        self.totalHeartbeatsReceived = totalHeartbeatsReceived
        self.averageReconnectionTime = averageReconnectionTime
        self.lastDisconnection = lastDisconnection
        self.lastReconnection = lastReconnection
        self.currentUptime = currentUptime
    }
}