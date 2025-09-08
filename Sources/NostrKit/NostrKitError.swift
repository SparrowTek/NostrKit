import Foundation
import CoreNostr

/// Main error type for NostrKit operations
public enum NostrKitError: LocalizedError, Sendable {
    
    // MARK: - Connection Errors
    case connectionFailed(url: String, underlying: Error?)
    case connectionTimeout(url: String)
    case invalidURL(String)
    case notConnected
    case alreadyConnected
    case maxReconnectAttemptsReached(attempts: Int)
    
    // MARK: - Authentication Errors
    case authenticationRequired(relay: String)
    case authenticationFailed(relay: String, reason: String)
    case authChallengeExpired
    case invalidAuthResponse
    
    // MARK: - Subscription Errors
    case subscriptionFailed(id: String, reason: String)
    case subscriptionClosed(id: String, reason: String)
    case subscriptionNotFound(id: String)
    case tooManySubscriptions(limit: Int)
    case invalidFilter(reason: String)
    
    // MARK: - Publishing Errors
    case publishFailed(eventId: EventID, message: String)
    case eventRejected(eventId: EventID, reason: String)
    case rateLimited(retryAfter: TimeInterval?)
    case eventTooLarge(size: Int, limit: Int)
    
    // MARK: - Relay Pool Errors
    case noAvailableRelays
    case allRelaysFailed(errors: [String: Error])
    case insufficientRelayConnections(required: Int, connected: Int)
    
    // MARK: - Key Management Errors
    case keyNotFound(identity: String)
    case keyGenerationFailed(reason: String)
    case keyStorageFaile(reason: String)
    case biometricAuthenticationFailed
    case secureEnclaveNotAvailable
    
    // MARK: - Encoding/Decoding Errors
    case encodingFailed(type: String, underlying: Error?)
    case decodingFailed(type: String, underlying: Error?)
    case invalidMessageFormat(details: String)
    
    // MARK: - Network Errors
    case networkUnavailable
    case dnsLookupFailed(host: String)
    case sslHandshakeFailed(details: String)
    case certificatePinningFailed(expected: String, received: String)
    
    // MARK: - Protocol Errors
    case unsupportedNIP(nip: Int, relay: String)
    case protocolViolation(details: String)
    case invalidEventSignature(eventId: EventID)
    case invalidEventStructure(reason: String)
    
    // MARK: - Resource Errors
    case memoryPressure
    case diskSpaceInsufficient
    case quotaExceeded(type: String, limit: Int)
    
    // MARK: - LocalizedError
    
    public var errorDescription: String? {
        switch self {
        // Connection
        case .connectionFailed(let url, let error):
            return "Failed to connect to \(url): \(error?.localizedDescription ?? "Unknown error")"
        case .connectionTimeout(let url):
            return "Connection to \(url) timed out"
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .notConnected:
            return "Not connected to relay"
        case .alreadyConnected:
            return "Already connected to relay"
        case .maxReconnectAttemptsReached(let attempts):
            return "Maximum reconnection attempts reached (\(attempts))"
            
        // Authentication
        case .authenticationRequired(let relay):
            return "Authentication required for \(relay)"
        case .authenticationFailed(let relay, let reason):
            return "Authentication failed for \(relay): \(reason)"
        case .authChallengeExpired:
            return "Authentication challenge has expired"
        case .invalidAuthResponse:
            return "Invalid authentication response"
            
        // Subscription
        case .subscriptionFailed(let id, let reason):
            return "Subscription '\(id)' failed: \(reason)"
        case .subscriptionClosed(let id, let reason):
            return "Subscription '\(id)' was closed: \(reason)"
        case .subscriptionNotFound(let id):
            return "Subscription '\(id)' not found"
        case .tooManySubscriptions(let limit):
            return "Too many subscriptions (limit: \(limit))"
        case .invalidFilter(let reason):
            return "Invalid filter: \(reason)"
            
        // Publishing
        case .publishFailed(let eventId, let message):
            return "Failed to publish event \(eventId): \(message)"
        case .eventRejected(let eventId, let reason):
            return "Event \(eventId) was rejected: \(reason)"
        case .rateLimited(let retryAfter):
            if let retry = retryAfter {
                return "Rate limited. Retry after \(Int(retry)) seconds"
            }
            return "Rate limited"
        case .eventTooLarge(let size, let limit):
            return "Event too large (\(size) bytes, limit: \(limit))"
            
        // Relay Pool
        case .noAvailableRelays:
            return "No available relays"
        case .allRelaysFailed(let errors):
            return "All relays failed: \(errors.map { "\($0.key): \($0.value)" }.joined(separator: ", "))"
        case .insufficientRelayConnections(let required, let connected):
            return "Insufficient relay connections (required: \(required), connected: \(connected))"
            
        // Key Management
        case .keyNotFound(let identity):
            return "Key not found for identity: \(identity)"
        case .keyGenerationFailed(let reason):
            return "Key generation failed: \(reason)"
        case .keyStorageFaile(let reason):
            return "Key storage failed: \(reason)"
        case .biometricAuthenticationFailed:
            return "Biometric authentication failed"
        case .secureEnclaveNotAvailable:
            return "Secure Enclave is not available on this device"
            
        // Encoding/Decoding
        case .encodingFailed(let type, let error):
            return "Failed to encode \(type): \(error?.localizedDescription ?? "Unknown error")"
        case .decodingFailed(let type, let error):
            return "Failed to decode \(type): \(error?.localizedDescription ?? "Unknown error")"
        case .invalidMessageFormat(let details):
            return "Invalid message format: \(details)"
            
        // Network
        case .networkUnavailable:
            return "Network connection is unavailable"
        case .dnsLookupFailed(let host):
            return "DNS lookup failed for \(host)"
        case .sslHandshakeFailed(let details):
            return "SSL handshake failed: \(details)"
        case .certificatePinningFailed(let expected, let received):
            return "Certificate pinning failed. Expected: \(expected), Received: \(received)"
            
        // Protocol
        case .unsupportedNIP(let nip, let relay):
            return "NIP-\(nip) is not supported by \(relay)"
        case .protocolViolation(let details):
            return "Protocol violation: \(details)"
        case .invalidEventSignature(let eventId):
            return "Invalid signature for event: \(eventId)"
        case .invalidEventStructure(let reason):
            return "Invalid event structure: \(reason)"
            
        // Resources
        case .memoryPressure:
            return "Memory pressure detected"
        case .diskSpaceInsufficient:
            return "Insufficient disk space"
        case .quotaExceeded(let type, let limit):
            return "\(type) quota exceeded (limit: \(limit))"
        }
    }
    
    public var failureReason: String? {
        errorDescription
    }
    
    public var recoverySuggestion: String? {
        switch self {
        case .connectionFailed, .connectionTimeout:
            return "Check your internet connection and try again"
        case .invalidURL:
            return "Verify the relay URL is correct"
        case .notConnected:
            return "Connect to a relay first"
        case .alreadyConnected:
            return "Disconnect before reconnecting"
        case .maxReconnectAttemptsReached:
            return "Try connecting manually or check relay status"
            
        case .authenticationRequired:
            return "Provide authentication credentials"
        case .authenticationFailed:
            return "Check your credentials and try again"
        case .authChallengeExpired:
            return "Request a new authentication challenge"
            
        case .subscriptionFailed, .invalidFilter:
            return "Check filter parameters and try again"
        case .tooManySubscriptions:
            return "Close some subscriptions before creating new ones"
            
        case .rateLimited(let retryAfter):
            if let retry = retryAfter {
                return "Wait \(Int(retry)) seconds before retrying"
            }
            return "Wait before retrying"
        case .eventTooLarge:
            return "Reduce the size of your event content"
            
        case .noAvailableRelays:
            return "Add relay URLs to your configuration"
        case .insufficientRelayConnections:
            return "Connect to more relays"
            
        case .keyNotFound:
            return "Generate or import a key first"
        case .biometricAuthenticationFailed:
            return "Try again or use passcode"
        case .secureEnclaveNotAvailable:
            return "Use standard keychain storage instead"
            
        case .networkUnavailable:
            return "Check your internet connection"
        case .certificatePinningFailed:
            return "This may indicate a security issue. Proceed with caution"
            
        case .memoryPressure:
            return "Close other apps to free up memory"
        case .diskSpaceInsufficient:
            return "Free up storage space on your device"
            
        default:
            return nil
        }
    }
    
    // MARK: - Error Categories
    
    /// Whether this error is recoverable through retry
    public var isRecoverable: Bool {
        switch self {
        case .connectionFailed, .connectionTimeout, .rateLimited, .networkUnavailable:
            return true
        case .invalidURL, .invalidEventSignature, .invalidEventStructure, .protocolViolation:
            return false
        case .authenticationFailed, .biometricAuthenticationFailed:
            return true
        default:
            return false
        }
    }
    
    /// Whether this error requires user intervention
    public var requiresUserIntervention: Bool {
        switch self {
        case .authenticationRequired, .biometricAuthenticationFailed, .keyNotFound:
            return true
        case .invalidURL, .secureEnclaveNotAvailable:
            return true
        case .diskSpaceInsufficient, .memoryPressure:
            return true
        default:
            return false
        }
    }
    
    /// Suggested retry delay in seconds
    public var suggestedRetryDelay: TimeInterval? {
        switch self {
        case .rateLimited(let retryAfter):
            return retryAfter
        case .connectionFailed, .connectionTimeout:
            return 5.0
        case .networkUnavailable:
            return 10.0
        default:
            return nil
        }
    }
}

// MARK: - Error Context

/// Additional context for errors
public struct ErrorContext: Sendable {
    public let timestamp: Date
    public let relay: String?
    public let operation: String
    public let additionalInfo: [String: String]
    
    public init(
        relay: String? = nil,
        operation: String,
        additionalInfo: [String: String] = [:]
    ) {
        self.timestamp = Date()
        self.relay = relay
        self.operation = operation
        self.additionalInfo = additionalInfo
    }
}

// MARK: - Error Reporter

/// Protocol for custom error reporting
public protocol ErrorReporter: Actor {
    func report(error: NostrKitError, context: ErrorContext) async
}

/// Default console error reporter
public actor ConsoleErrorReporter: ErrorReporter {
    public init() {}
    
    public func report(error: NostrKitError, context: ErrorContext) async {
        print("[NostrKit Error] \(context.timestamp)")
        print("  Operation: \(context.operation)")
        if let relay = context.relay {
            print("  Relay: \(relay)")
        }
        print("  Error: \(error.localizedDescription)")
        if !context.additionalInfo.isEmpty {
            print("  Context: \(context.additionalInfo)")
        }
        if let suggestion = error.recoverySuggestion {
            print("  Suggestion: \(suggestion)")
        }
    }
}

// MARK: - Contextual Error

/// A combination of NostrKitError and ErrorContext
public struct ContextualError: Error {
    public let error: NostrKitError
    public let context: ErrorContext
    
    public init(error: NostrKitError, context: ErrorContext) {
        self.error = error
        self.context = context
    }
}

// MARK: - Result Extensions

public extension Result where Failure == NostrKitError {
    /// Maps a Result to include error context
    func withContext(
        relay: String? = nil,
        operation: String
    ) -> Result<Success, ContextualError> {
        mapError { error in
            ContextualError(
                error: error,
                context: ErrorContext(relay: relay, operation: operation)
            )
        }
    }
}

// MARK: - Error Conversion

extension NostrKitError {
    /// Creates a NostrKitError from a CoreNostr error
    public init(from nostrError: NostrError) {
        switch nostrError {
        case .invalidPublicKey, .invalidPrivateKey:
            self = .keyGenerationFailed(reason: nostrError.localizedDescription)
        case .invalidSignature:
            self = .invalidEventSignature(eventId: "unknown")
        default:
            self = .protocolViolation(details: nostrError.localizedDescription)
        }
    }
    
    /// Creates a NostrKitError from a URLError
    public init(from urlError: URLError) {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost:
            self = .networkUnavailable
        case .timedOut:
            self = .connectionTimeout(url: urlError.failingURL?.absoluteString ?? "unknown")
        case .cannotFindHost, .dnsLookupFailed:
            self = .dnsLookupFailed(host: urlError.failingURL?.host ?? "unknown")
        case .secureConnectionFailed:
            self = .sslHandshakeFailed(details: urlError.localizedDescription)
        default:
            self = .connectionFailed(
                url: urlError.failingURL?.absoluteString ?? "unknown",
                underlying: urlError
            )
        }
    }
}