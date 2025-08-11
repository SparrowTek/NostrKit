import Foundation
import CoreNostr

/// An asynchronous stream of WebSocket messages.
///
/// This type alias simplifies working with WebSocket message streams
/// by providing a convenient way to iterate over incoming messages.
public typealias WebSocketStream = AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>

/// An async sequence wrapper for WebSocket connections.
///
/// SocketStream provides an AsyncSequence interface for WebSocket connections,
/// allowing you to use async/await patterns to handle incoming messages.
/// It automatically manages the WebSocket task lifecycle and message reception.
///
/// - Note: This class is marked as @unchecked Sendable because URLSessionWebSocketTask
///         is not Sendable, but we ensure thread-safe access internally.
class SocketStream: AsyncSequence, @unchecked Sendable {
    typealias AsyncIterator = WebSocketStream.Iterator
    typealias Element = URLSessionWebSocketTask.Message

    private var continuation: WebSocketStream.Continuation?
    private let task: URLSessionWebSocketTask
    
    private lazy var stream: WebSocketStream = {
        return WebSocketStream { continuation in
            self.continuation = continuation
            Task {
                self.waitForNextValue()
            }
        }
    }()

    private func waitForNextValue() {
        guard task.closeCode == .invalid else {
            continuation?.finish()
            return
        }
        
        task.receive { [weak self] result in
            guard let self, let continuation else { return }
            
            do {
                let message = try result.get()
                continuation.yield(message)
                waitForNextValue()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    init(task: URLSessionWebSocketTask) {
        self.task = task
        task.resume()
    }

    deinit {
        continuation?.finish()
    }

    func makeAsyncIterator() -> AsyncIterator {
        return stream.makeAsyncIterator()
    }
    
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await task.send(message)
    }

    func cancel() async throws {
        task.cancel(with: .goingAway, reason: nil)
        continuation?.finish()
    }
}

/// Errors that can occur when using RelayService.
public enum RelayServiceError: Error, Sendable {
    /// The provided URL is invalid
    case invalidURL(String)
    /// Connection failed
    case connectionFailed(Error)
    /// Message encoding failed
    case encodingFailed(Error)
    /// Message decoding failed
    case decodingFailed(Error)
    /// Authentication required but no authenticator provided
    case authenticationRequired
    /// Not connected to relay
    case notConnected
}

/// Service for managing a WebSocket connection to a single NOSTR relay.
///
/// RelayService provides functionality to connect to a NOSTR relay,
/// send and receive messages, and handle authentication (NIP-42).
///
/// ## Example Usage
/// ```swift
/// let relay = RelayService(url: "wss://relay.damus.io")
/// 
/// // Set up authentication if needed
/// relay.authenticator = { challenge in
///     return try await AuthResponse.create(for: challenge, using: keyPair)
/// }
/// 
/// // Connect to relay
/// try await relay.connect()
/// 
/// // Send an event
/// let event = try CoreNostr.createTextNote(content: "Hello!", keyPair: keyPair)
/// try await relay.publishEvent(event)
/// 
/// // Subscribe to events
/// try await relay.subscribe(id: "sub1", filters: [Filter(kinds: [.textNote])])
/// 
/// // Listen for messages
/// for await message in relay.messages {
///     switch message {
///     case .event(let subId, let event):
///         print("Received event on subscription \(subId)")
///     default:
///         break
///     }
/// }
/// ```
public actor RelayService {
    
    // MARK: - Properties
    
    /// The relay URL
    public let url: String
    
    /// The WebSocket stream for this relay
    private var stream: SocketStream?
    
    /// Current authentication status
    private var authStatus: AuthenticationStatus = .notAuthenticated
    
    /// Authentication handler for NIP-42
    public var authenticator: ((AuthChallenge) async throws -> AuthResponse)?
    
    /// Continuation for the message stream
    private var messageContinuation: AsyncStream<RelayMessage>.Continuation?
    
    /// Stream of incoming relay messages
    public let messages: AsyncStream<RelayMessage>
    
    /// Whether the relay is currently connected
    public var isConnected: Bool {
        stream != nil
    }
    
    /// Statistics for monitoring performance
    private var droppedMessageCount: Int = 0
    private var totalMessagesReceived: Int = 0
    
    /// Returns statistics about the relay connection
    public var statistics: (received: Int, dropped: Int) {
        (totalMessagesReceived, droppedMessageCount)
    }
    
    // MARK: - Initialization
    
    /// Creates a new relay service for the specified URL
    /// - Parameters:
    ///   - url: The WebSocket URL of the relay
    ///   - bufferSize: Maximum number of messages to buffer (default: 100)
    public init(url: String, bufferSize: Int = 100) {
        self.url = url
        
        var continuation: AsyncStream<RelayMessage>.Continuation?
        self.messages = AsyncStream(bufferingPolicy: .bufferingNewest(bufferSize)) { cont in
            continuation = cont
        }
        self.messageContinuation = continuation
    }
    
    // MARK: - Connection Management
    
    /// Connects to the relay
    /// - Throws: RelayServiceError if connection fails
    public func connect() async throws {
        guard !isConnected else { return }
        
        guard let wsURL = URL(string: url),
              wsURL.scheme == "ws" || wsURL.scheme == "wss" else {
            throw RelayServiceError.invalidURL(url)
        }
        
        let task = URLSession.shared.webSocketTask(with: wsURL)
        let socketStream = SocketStream(task: task)
        self.stream = socketStream
        
        // Start listening for messages
        Task {
            await listenForMessages()
        }
    }
    
    /// Disconnects from the relay
    public func disconnect() async {
        if let stream = stream {
            try? await stream.cancel()
            self.stream = nil
        }
        messageContinuation?.finish()
        messageContinuation = nil
        authStatus = .notAuthenticated
    }
    
    // MARK: - Message Sending
    
    /// Publishes an event to the relay
    /// - Parameter event: The event to publish
    /// - Throws: RelayServiceError if not connected or encoding fails
    public func publishEvent(_ event: NostrEvent) async throws {
        let message = ClientMessage.event(event)
        try await sendMessage(message)
    }
    
    /// Subscribes to events matching the specified filters
    /// - Parameters:
    ///   - id: The subscription ID
    ///   - filters: Array of filters for the subscription
    /// - Throws: RelayServiceError if not connected or encoding fails
    public func subscribe(id: String, filters: [Filter]) async throws {
        let message = ClientMessage.req(subscriptionId: id, filters: filters)
        try await sendMessage(message)
    }
    
    /// Closes a subscription
    /// - Parameter id: The subscription ID to close
    /// - Throws: RelayServiceError if not connected or encoding fails
    public func closeSubscription(id: String) async throws {
        let message = ClientMessage.close(subscriptionId: id)
        try await sendMessage(message)
    }
    
    /// Sends an authentication response
    /// - Parameter event: The auth event (kind 22242)
    /// - Throws: RelayServiceError if not connected or encoding fails
    public func sendAuth(_ event: NostrEvent) async throws {
        let message = ClientMessage.event(event)
        try await sendMessage(message)
    }
    
    // MARK: - Private Methods
    
    private func sendMessage(_ message: ClientMessage) async throws {
        guard let stream = stream else {
            throw RelayServiceError.notConnected
        }
        
        do {
            let jsonString = try message.encode()
            try await stream.send(.string(jsonString))
        } catch {
            throw RelayServiceError.encodingFailed(error)
        }
    }
    
    private func listenForMessages() async {
        guard let stream = stream else { return }
        
        do {
            for try await message in stream {
                await handleWebSocketMessage(message)
            }
        } catch {
            print("[RelayService] WebSocket error: \(error)")
            messageContinuation?.finish()
        }
        
        // Connection closed
        self.stream = nil
        messageContinuation?.finish()
    }
    
    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) async {
        switch message {
        case .string(let text):
            do {
                let relayMessage = try RelayMessage.decode(from: text)
                totalMessagesReceived += 1
                
                // Handle authentication challenges
                if case .auth(let challenge) = relayMessage {
                    await handleAuthChallenge(challenge)
                }
                
                // Yield to stream - AsyncStream with bufferingNewest will drop old messages if buffer is full
                let result = messageContinuation?.yield(relayMessage)
                if result == .dropped {
                    droppedMessageCount += 1
                }
                
            } catch {
                print("[RelayService] Failed to decode message: \(error)")
            }
            
        case .data(let data):
            print("[RelayService] Received unexpected binary data: \(data.count) bytes")
            
        @unknown default:
            print("[RelayService] Received unknown message type")
        }
    }
    
    private func handleAuthChallenge(_ challenge: String) async {
        guard let authenticator = authenticator else {
            print("[RelayService] Received auth challenge but no authenticator set")
            authStatus = .authenticationRequired(challenge: AuthChallenge(challenge: challenge, relayURL: url))
            return
        }
        
        authStatus = .authenticating
        
        do {
            let authChallenge = AuthChallenge(challenge: challenge, relayURL: url)
            let authResponse = try await authenticator(authChallenge)
            try await sendAuth(authResponse.event)
            authStatus = .authenticated(since: Date())
        } catch {
            print("[RelayService] Authentication failed: \(error)")
            authStatus = .failed(reason: error.localizedDescription)
        }
    }
}

// MARK: - NIP-42 Authentication Support

extension RelayService {
    
    /// Creates an authenticator closure for use with RelayService
    /// - Parameter keyPair: The key pair to use for authentication
    /// - Returns: An authenticator closure
    public static func authenticator(using keyPair: KeyPair) -> (AuthChallenge) async throws -> AuthResponse {
        return { challenge in
            try CoreNostr.authenticate(challenge: challenge, keyPair: keyPair)
        }
    }
    
    /// Current authentication status
    public var authenticationStatus: AuthenticationStatus {
        authStatus
    }
    
    /// Manually triggers authentication if supported by the relay
    /// - Throws: RelayServiceError if no authenticator is set
    public func authenticate() async throws {
        guard authenticator != nil else {
            throw RelayServiceError.authenticationRequired
        }
        
        // Some relays send AUTH immediately on connection
        // Others require a request that triggers AUTH
        // For now, we'll wait for the relay to send AUTH
    }
}
