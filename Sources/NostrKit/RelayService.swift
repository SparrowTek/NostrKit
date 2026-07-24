import Foundation
import CoreNostr
import Synchronization

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
/// All stored properties are immutable after `init`. The continuation is
/// assigned exactly once via `AsyncStream`'s synchronous init closure, so the
/// type is genuinely thread-safe without any `@unchecked Sendable` escape
/// hatch — the receive loop runs on URLSession's delegate queue and only
/// touches `Sendable` state (`continuation` and `task`).
final class SocketStream: AsyncSequence, Sendable {
    typealias AsyncIterator = WebSocketStream.Iterator
    typealias Element = URLSessionWebSocketTask.Message

    private let stream: WebSocketStream
    private let continuation: WebSocketStream.Continuation
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        // AsyncStream's build closure runs synchronously during this call,
        // so the IUO is guaranteed to be assigned before we read it.
        var cont: WebSocketStream.Continuation!
        self.stream = WebSocketStream { cont = $0 }
        self.continuation = cont
        self.task = task
        task.resume()
        receiveNext()
    }

    deinit {
        continuation.finish()
    }

    func makeAsyncIterator() -> AsyncIterator {
        return stream.makeAsyncIterator()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await task.send(message)
    }

    /// Sends a WebSocket ping frame. The handler receives `nil` once the pong
    /// arrives, or the underlying error if the socket is dead or the handshake
    /// never completed. URLSession guarantees the handler fires exactly once —
    /// including with an error when the task is cancelled mid-ping — which is
    /// what makes ping usable both as a connect confirmation and a keepalive.
    func ping(_ handler: @escaping @Sendable (Error?) -> Void) {
        task.sendPing { error in
            handler(error)
        }
    }

    func cancel() async throws {
        task.cancel(with: .goingAway, reason: nil)
        continuation.finish()
    }

    private func receiveNext() {
        guard task.closeCode == .invalid else {
            continuation.finish()
            return
        }

        task.receive { [weak self] result in
            guard let self else { return }
            do {
                let message = try result.get()
                self.continuation.yield(message)
                self.receiveNext()
            } catch {
                self.continuation.finish(throwing: error)
            }
        }
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

    /// Buffer size for the message stream, captured so `connect()` can rebuild
    /// the stream after a prior `disconnect()` with the same policy.
    private let bufferSize: Int

    /// How long `connect()` waits for the WebSocket handshake + first pong
    /// before giving up. Bounded by our own ping race, not URLRequest's
    /// `timeoutInterval` — that timer also governs idle reads and would kill
    /// a quiet relay connection between messages.
    private let connectTimeout: TimeInterval

    /// Interval between keepalive pings. NAT/firewall state and half-dead TCP
    /// connections are invisible to a socket that only ever reads: without
    /// traffic the connection can silently die and `receive` hangs until the
    /// OS-level timeout (minutes). A failed ping tears the connection down so
    /// consumers see the stream finish and can reconnect promptly.
    /// Set `0` to disable.
    private let pingInterval: TimeInterval

    /// How long a single keepalive ping may take before counting as failed.
    private let pingTimeout: TimeInterval = 10

    /// The WebSocket stream for this relay
    private var stream: SocketStream?

    /// True while a `connect()` handshake is in flight, so concurrent callers
    /// coalesce onto the one dial instead of racing a second socket.
    private var isConnecting = false

    /// Handle to the listener Task, tracked so `disconnect()` can cancel it
    /// instead of letting it leak for the process lifetime.
    private var listenerTask: Task<Void, Never>?

    /// Handle to the keepalive Task for the current connection.
    private var keepaliveTask: Task<Void, Never>?

    /// Current authentication status
    private var authStatus: AuthenticationStatus = .notAuthenticated

    /// Authentication handler for NIP-42
    public var authenticator: ((AuthChallenge) async throws -> AuthResponse)?

    /// Sets the NIP-42 authentication handler.
    ///
    /// Actor-isolated stored properties can't be assigned from outside the
    /// actor, so this is the only way callers (including RelayPool) can
    /// install an authenticator.
    public func setAuthenticator(_ handler: (@Sendable (AuthChallenge) async throws -> AuthResponse)?) {
        authenticator = handler
    }

    /// Continuation for the message stream. `disconnect()` finishes it (so
    /// consumers see the for-await terminate and can react to the drop), and
    /// `connect()` rebuilds it together with `_messages` so a reconnect can
    /// start delivering messages on a fresh stream. Callers must therefore
    /// re-read `messages` after each `connect()` — the previous stream is
    /// terminal once `disconnect()` ran.
    private var messageContinuation: AsyncStream<RelayMessage>.Continuation?

    /// Backing storage for the public ``messages`` stream. Reassigned each
    /// time ``connect()`` builds a new stream after a prior disconnect.
    private var _messages: AsyncStream<RelayMessage>

    /// Stream of incoming relay messages.
    ///
    /// Each call to ``connect()`` produces a fresh stream once the previous
    /// connection has been torn down via ``disconnect()``. Re-read this
    /// property after reconnecting; the prior stream is finished and no new
    /// values will arrive on it.
    public var messages: AsyncStream<RelayMessage> {
        _messages
    }

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
    ///   - connectTimeout: Seconds to wait for the handshake before `connect()` throws (default: 10)
    ///   - pingInterval: Seconds between keepalive pings; `0` disables keepalive (default: 25)
    public init(
        url: String,
        bufferSize: Int = 100,
        connectTimeout: TimeInterval = 10,
        pingInterval: TimeInterval = 25
    ) {
        self.url = url
        self.bufferSize = bufferSize
        self.connectTimeout = connectTimeout
        self.pingInterval = pingInterval

        var continuation: AsyncStream<RelayMessage>.Continuation!
        self._messages = AsyncStream(bufferingPolicy: .bufferingNewest(bufferSize)) { cont in
            continuation = cont
        }
        self.messageContinuation = continuation
    }
    
    // MARK: - Connection Management
    
    /// Connects to the relay and confirms the socket is actually open.
    ///
    /// The WebSocket task is confirmed with a ping round-trip before this
    /// method returns, so a successful `connect()` means a live connection —
    /// not just a dial that may still fail. Concurrent callers coalesce onto
    /// the in-flight handshake.
    ///
    /// - Throws: RelayServiceError if the connection cannot be established
    ///   within the configured `connectTimeout`.
    public func connect() async throws {
        guard !isConnected else { return }

        // Another caller is mid-handshake: wait for that dial to resolve
        // rather than racing a second socket for the same relay.
        if isConnecting {
            try await waitForInFlightConnect()
            return
        }

        guard let wsURL = URL(string: url),
              wsURL.scheme == "ws" || wsURL.scheme == "wss" else {
            throw RelayServiceError.invalidURL(url)
        }

        isConnecting = true
        defer { isConnecting = false }

        let task = URLSession.shared.webSocketTask(with: wsURL)
        let socketStream = SocketStream(task: task)

        // Confirm the handshake with a ping round-trip. Without this the
        // socket "connects" optimistically and callers (like RelayPool's
        // health tracking) treat a dead relay as healthy until the first
        // send fails.
        do {
            try await Self.awaitPong(from: socketStream, timeout: connectTimeout)
        } catch {
            try? await socketStream.cancel()
            throw error
        }

        // If a previous `disconnect()` finished the message stream, rebuild
        // both `_messages` and `messageContinuation` so this connection has
        // a fresh, live stream. Without this, a successful reconnect would
        // never deliver messages — the continuation is nil and the stream
        // has already terminated.
        if messageContinuation == nil {
            var continuation: AsyncStream<RelayMessage>.Continuation!
            self._messages = AsyncStream(bufferingPolicy: .bufferingNewest(bufferSize)) { cont in
                continuation = cont
            }
            self.messageContinuation = continuation
        }

        self.stream = socketStream

        // Start listening for messages — store the handle so `disconnect()`
        // can cancel it rather than leaking the task.
        listenerTask = Task { [weak self] in
            await self?.listenForMessages()
        }

        startKeepalive()
    }

    /// Waits for an in-flight `connect()` on this service to resolve, then
    /// mirrors its outcome: returns if it produced a live connection, throws
    /// otherwise. Polling keeps this reentrancy-safe on the actor.
    private func waitForInFlightConnect() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = Duration.seconds(connectTimeout + 1)

        while clock.now - start < deadline {
            if isConnected { return }
            if !isConnecting {
                throw RelayServiceError.notConnected
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw RelayServiceError.connectionFailed(RelayError.timeout)
    }

    /// Races a ping round-trip against a timeout on the given socket.
    ///
    /// Exactly one outcome wins: the `Mutex` claim guarantees a single
    /// continuation resume even though the pong handler and the timeout can
    /// fire concurrently. On timeout the socket is cancelled, which forces
    /// URLSession to fail the pending ping handler — nothing leaks.
    private static func awaitPong(from socket: SocketStream, timeout: TimeInterval) async throws {
        let claimed = Mutex(false)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let claim: @Sendable () -> Bool = {
                claimed.withLock { alreadyClaimed in
                    if alreadyClaimed { return false }
                    alreadyClaimed = true
                    return true
                }
            }

            socket.ping { error in
                guard claim() else { return }
                if let error {
                    continuation.resume(throwing: RelayServiceError.connectionFailed(error))
                } else {
                    continuation.resume()
                }
            }

            Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard claim() else { return }
                // Claiming before cancelling means the ping handler that fires
                // on cancellation is already a no-op.
                try? await socket.cancel()
                continuation.resume(throwing: RelayServiceError.connectionFailed(RelayError.timeout))
            }
        }
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        keepaliveTask?.cancel()
        guard pingInterval > 0 else { return }

        keepaliveTask = Task { [weak self, pingInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pingInterval))
                guard !Task.isCancelled, let self else { return }
                guard await self.sendKeepalivePing() else {
                    await self.keepaliveDidFail()
                    return
                }
            }
        }
    }

    /// Sends one keepalive ping. Returns false if the pong doesn't arrive
    /// within `pingTimeout` or the socket reports an error.
    private func sendKeepalivePing() async -> Bool {
        guard let stream else { return false }
        do {
            try await Self.awaitPong(from: stream, timeout: pingTimeout)
            return true
        } catch {
            return false
        }
    }

    /// A keepalive ping failed: the connection is dead even if the OS hasn't
    /// noticed yet. Cancel the socket so the listener loop finishes the
    /// message stream — consumers observe the termination and reconnect.
    private func keepaliveDidFail() async {
        guard let stream else { return }
        relayLogger.warning("Keepalive ping failed for \(url) — tearing down connection")
        try? await stream.cancel()
    }

    /// Disconnects from the relay
    public func disconnect() async {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        listenerTask?.cancel()
        listenerTask = nil
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
            relayLogger.warning("WebSocket error on \(url): \(error)")
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
                if case .dropped = result {
                    droppedMessageCount += 1
                }
                
            } catch {
                relayLogger.warning("Failed to decode message from \(url): \(error)")
            }

        case .data(let data):
            relayLogger.debug("Received unexpected binary data from \(url): \(data.count) bytes")

        @unknown default:
            relayLogger.debug("Received unknown message type from \(url)")
        }
    }
    
    private func handleAuthChallenge(_ challenge: String) async {
        guard let authenticator = authenticator else {
            relayLogger.warning("Received auth challenge from \(url) but no authenticator set")
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
            relayLogger.error("Authentication failed for \(url)", error: error)
            authStatus = .failed(reason: error.localizedDescription)
        }
    }
}

// MARK: - RelayConnection

/// The per-relay connection surface RelayPool drives.
///
/// `RelayService` is the production conformance; tests inject scripted
/// connections to exercise the pool's reconnect/resubscribe behavior without
/// sockets. Keep this protocol in lockstep with what the pool actually needs —
/// it is deliberately narrower than `RelayService`'s full API.
protocol RelayConnection: Actor {
    nonisolated var url: String { get }
    var messages: AsyncStream<RelayMessage> { get }
    var isConnected: Bool { get }
    var authenticationStatus: AuthenticationStatus { get }
    func connect() async throws
    func disconnect() async
    func publishEvent(_ event: NostrEvent) async throws
    func subscribe(id: String, filters: [Filter]) async throws
    func closeSubscription(id: String) async throws
    func sendAuth(_ event: NostrEvent) async throws
    func setAuthenticator(_ handler: (@Sendable (AuthChallenge) async throws -> AuthResponse)?)
}

extension RelayService: RelayConnection {}

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
