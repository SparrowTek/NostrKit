import Foundation
import OSLog

/// Type-safe logging metadata
public struct LogMetadata: Sendable {
    private let values: [String: String]
    
    public init(_ dictionary: [String: Any] = [:]) {
        self.values = dictionary.mapValues { String(describing: $0) }
    }
    
    public init(_ values: [String: String]) {
        self.values = values
    }
    
    public var dictionary: [String: String] {
        values
    }
}

/// Centralized logging configuration for NostrKit
public actor LoggingConfiguration {
    
    // MARK: - Singleton
    
    public static let shared = LoggingConfiguration()
    
    // MARK: - Properties
    
    private var isEnabled = true
    private var logLevel: OSLogType = .default
    private var categories: Set<LogCategory> = Set(LogCategory.allCases)
    private var sensitiveDataRedaction = true
    private var performanceSampling: Double = 1.0 // 100% by default
    private var customHandlers: [LogHandler] = []
    
    // MARK: - Configuration
    
    /// Enables or disables all logging
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }
    
    /// Sets the minimum log level
    public func setLogLevel(_ level: OSLogType) {
        logLevel = level
    }
    
    /// Enables specific log categories
    public func enableCategories(_ categories: Set<LogCategory>) {
        self.categories = categories
    }
    
    /// Enables or disables sensitive data redaction
    public func setSensitiveDataRedaction(_ enabled: Bool) {
        sensitiveDataRedaction = enabled
    }
    
    /// Sets performance logging sampling rate (0.0 to 1.0)
    public func setPerformanceSampling(_ rate: Double) {
        performanceSampling = min(max(rate, 0.0), 1.0)
    }
    
    /// Adds a custom log handler
    public func addHandler(_ handler: LogHandler) {
        customHandlers.append(handler)
    }
    
    /// Removes all custom handlers
    public func clearHandlers() {
        customHandlers.removeAll()
    }
    
    // MARK: - Internal Methods
    
    func shouldLog(category: LogCategory, level: OSLogType) -> Bool {
        guard isEnabled else { return false }
        guard categories.contains(category) else { return false }
        return level.rawValue >= logLevel.rawValue
    }
    
    func shouldSamplePerformance() -> Bool {
        Double.random(in: 0...1) <= performanceSampling
    }
    
    func processLog(category: LogCategory, level: OSLogType, message: String, metadata: LogMetadata?) async {
        for handler in customHandlers {
            await handler.handle(
                category: category,
                level: level,
                message: message,
                metadata: metadata
            )
        }
    }
    
    var redactSensitiveData: Bool {
        sensitiveDataRedaction
    }
}

/// Log categories for different components
public enum LogCategory: String, CaseIterable, Sendable {
    case connection = "Connection"
    case relay = "Relay"
    case subscription = "Subscription"
    case event = "Event"
    case crypto = "Crypto"
    case keystore = "KeyStore"
    case pool = "Pool"
    case nwc = "NWC"
    case performance = "Performance"
    case error = "Error"
    case debug = "Debug"
}

/// Protocol for custom log handlers
public protocol LogHandler: Actor {
    func handle(
        category: LogCategory,
        level: OSLogType,
        message: String,
        metadata: LogMetadata?
    ) async
}

/// NostrKit Logger wrapper
public struct NostrKitLogger: Sendable {
    private let logger: Logger
    private let category: LogCategory
    
    init(category: LogCategory) {
        self.category = category
        self.logger = Logger(subsystem: "com.nostrkit", category: category.rawValue)
    }
    
    // MARK: - Logging Methods
    
    public func debug(_ message: String, metadata: LogMetadata? = nil) {
        Task {
            await log(level: .debug, message: message, metadata: metadata)
        }
    }
    
    public func info(_ message: String, metadata: LogMetadata? = nil) {
        Task {
            await log(level: .info, message: message, metadata: metadata)
        }
    }
    
    public func notice(_ message: String, metadata: LogMetadata? = nil) {
        Task {
            await log(level: .default, message: message, metadata: metadata)
        }
    }
    
    public func warning(_ message: String, metadata: LogMetadata? = nil) {
        Task {
            await log(level: .error, message: message, metadata: metadata)
        }
    }
    
    public func error(_ message: String, error: Error? = nil, metadata: LogMetadata? = nil) {
        Task {
            var enrichedValues = metadata?.dictionary ?? [:]
            if let error = error {
                enrichedValues["error"] = String(describing: error)
            }
            let enrichedMetadata = LogMetadata(enrichedValues)
            await log(level: .fault, message: message, metadata: enrichedMetadata)
        }
    }
    
    // MARK: - Performance Logging
    
    public func performance<T>(
        _ operation: String,
        metadata: LogMetadata? = nil,
        block: () async throws -> T
    ) async rethrows -> T {
        let shouldSample = await LoggingConfiguration.shared.shouldSamplePerformance()
        
        if shouldSample {
            let start = Date()
            defer {
                let duration = Date().timeIntervalSince(start)
                var perfValues = metadata?.dictionary ?? [:]
                perfValues["duration_ms"] = String(Int(duration * 1000))
                perfValues["operation"] = operation
                let perfMetadata = LogMetadata(perfValues)
                
                Task {
                    await log(
                        level: .debug,
                        message: "Performance: \(operation) took \(Int(duration * 1000))ms",
                        metadata: perfMetadata
                    )
                }
            }
            return try await block()
        } else {
            return try await block()
        }
    }
    
    // MARK: - Private Methods
    
    private func log(level: OSLogType, message: String, metadata: LogMetadata?) async {
        let config = LoggingConfiguration.shared
        
        guard await config.shouldLog(category: category, level: level) else {
            return
        }
        
        // Process with custom handlers
        await config.processLog(
            category: category,
            level: level,
            message: message,
            metadata: metadata
        )
        
        // Log to OSLog
        let redact = await config.redactSensitiveData
        
        if let metadata = metadata {
            let metadataString = metadata.dictionary.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            
            if redact {
                logger.log(level: level, "\(message, privacy: .public) [\(metadataString, privacy: .private)]")
            } else {
                logger.log(level: level, "\(message) [\(metadataString)]")
            }
        } else {
            logger.log(level: level, "\(message, privacy: .public)")
        }
    }
}

// MARK: - Global Loggers

public let connectionLogger = NostrKitLogger(category: .connection)
public let relayLogger = NostrKitLogger(category: .relay)
public let subscriptionLogger = NostrKitLogger(category: .subscription)
public let eventLogger = NostrKitLogger(category: .event)
public let cryptoLogger = NostrKitLogger(category: .crypto)
public let keystoreLogger = NostrKitLogger(category: .keystore)
public let poolLogger = NostrKitLogger(category: .pool)
public let nwcLogger = NostrKitLogger(category: .nwc)
public let performanceLogger = NostrKitLogger(category: .performance)
public let errorLogger = NostrKitLogger(category: .error)
public let debugLogger = NostrKitLogger(category: .debug)

// MARK: - Example Handlers

/// File-based log handler for debugging
public actor FileLogHandler: LogHandler {
    private let fileURL: URL
    private let dateFormatter: ISO8601DateFormatter
    
    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.dateFormatter = ISO8601DateFormatter()
    }
    
    public func handle(
        category: LogCategory,
        level: OSLogType,
        message: String,
        metadata: LogMetadata?
    ) async {
        let timestamp = dateFormatter.string(from: Date())
        let levelString = levelDescription(level)
        
        var logLine = "[\(timestamp)] [\(levelString)] [\(category.rawValue)] \(message)"
        
        if let metadata = metadata {
            let metadataString = metadata.dictionary.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            logLine += " | \(metadataString)"
        }
        
        logLine += "\n"
        
        do {
            if let data = logLine.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: fileURL)
                }
            }
        } catch {
            // Silently fail - we don't want logging to crash the app
        }
    }
    
    private func levelDescription(_ level: OSLogType) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .default: return "NOTICE"
        case .error: return "WARNING"
        case .fault: return "ERROR"
        default: return "UNKNOWN"
        }
    }
}

/// Analytics log handler for metrics collection
public actor AnalyticsLogHandler: LogHandler {
    public typealias AnalyticsCallback = @Sendable (String, LogMetadata) async -> Void
    
    private let callback: AnalyticsCallback
    
    public init(callback: @escaping AnalyticsCallback) {
        self.callback = callback
    }
    
    public func handle(
        category: LogCategory,
        level: OSLogType,
        message: String,
        metadata: LogMetadata?
    ) async {
        // Only track errors and performance metrics
        guard level == .fault || category == .performance else {
            return
        }
        
        var analyticsValues: [String: String] = [
            "category": category.rawValue,
            "level": String(levelValue(level)),
            "message": message,
            "timestamp": String(Date().timeIntervalSince1970)
        ]
        
        if let metadata = metadata {
            analyticsValues.merge(metadata.dictionary) { _, new in new }
        }
        
        let analyticsData = LogMetadata(analyticsValues)
        await callback("nostrkit_log", analyticsData)
    }
    
    private func levelValue(_ level: OSLogType) -> Int {
        switch level {
        case .debug: return 0
        case .info: return 1
        case .default: return 2
        case .error: return 3
        case .fault: return 4
        default: return -1
        }
    }
}

// MARK: - Convenience Extensions

public extension NostrKitLogger {
    /// Logs entry and exit of a function with timing
    func trace<T>(
        _ function: String = #function,
        file: String = #file,
        line: Int = #line,
        block: () async throws -> T
    ) async rethrows -> T {
        let metadataValues: [String: String] = [
            "function": function,
            "file": URL(fileURLWithPath: file).lastPathComponent,
            "line": String(line)
        ]
        let metadata = LogMetadata(metadataValues)
        
        debug("→ Entering \(function)", metadata: metadata)
        
        let start = Date()
        defer {
            var exitValues = metadataValues
            let duration = Date().timeIntervalSince(start)
            exitValues["duration_ms"] = String(Int(duration * 1000))
            let exitMetadata = LogMetadata(exitValues)
            debug("← Exiting \(function) (\(Int(duration * 1000))ms)", metadata: exitMetadata)
        }
        
        return try await block()
    }
    
    /// Logs a value with redaction support
    func value<T: Sendable>(_ label: String, _ value: T, sensitive: Bool = false) {
        Task {
            let config = LoggingConfiguration.shared
            let redact = await config.redactSensitiveData
            
            if sensitive && redact {
                debug("\(label): [REDACTED]")
            } else {
                debug("\(label): \(String(describing: value))")
            }
        }
    }
}

// MARK: - Usage Examples

/*
// Configure logging at app startup
Task {
    let config = LoggingConfiguration.shared
    
    // Set log level
    await config.setLogLevel(.debug)
    
    // Enable only specific categories
    await config.enableCategories([.connection, .error, .performance])
    
    // Add file logging
    let logFile = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("nostrkit.log")
    await config.addHandler(FileLogHandler(fileURL: logFile))
    
    // Add analytics
    await config.addHandler(AnalyticsLogHandler { event, data in
        // Send to analytics service
        print("Analytics: \(event) - \(data.dictionary)")
    })
    
    // Set performance sampling to 10%
    await config.setPerformanceSampling(0.1)
}

// Use in code
connectionLogger.info("Connecting to relay", metadata: LogMetadata(["url": "wss://relay.example.com"]))

await performanceLogger.performance("fetchEvents") {
    // Expensive operation
    try await fetchEvents()
}

errorLogger.error("Failed to connect", error: connectionError, metadata: LogMetadata(["relay": relayURL]))
*/
