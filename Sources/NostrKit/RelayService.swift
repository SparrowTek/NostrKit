import Foundation

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
            waitForNextValue()
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

    func cancel() async throws {
        task.cancel(with: .goingAway, reason: nil)
        continuation?.finish()
    }
}

/// Errors that can occur when using RelayService.
public enum RelayServiceError: Error, Sendable {
    /// The provided URL is invalid or nil.
    case badURL
}

/// Service for managing WebSocket connections to NOSTR relays.
///
/// RelayService provides functionality to connect to multiple NOSTR relays,
/// send requests, and listen for incoming messages. It handles the WebSocket
/// connections using URLSession and provides an async/await interface.
///
/// ## Example Usage
/// ```swift
/// let service = RelayService()
/// try service.connectToSocket(URL(string: "wss://relay.nostr.com"))
/// 
/// // Send a request
/// try await service.sendRequest()
/// 
/// // Listen for messages
/// try await service.listen()
/// ```
///
/// - Note: This service maintains multiple concurrent WebSocket connections
///         and processes messages from all connected relays.
public actor RelayService {
    /// Array of active WebSocket streams.
    private var streams: [SocketStream] = []
    
    /// Connects to a NOSTR relay via WebSocket.
    ///
    /// Creates a new WebSocket connection to the specified relay URL and
    /// adds it to the list of managed streams. The connection will remain
    /// open until explicitly closed or an error occurs.
    ///
    /// - Parameter url: The WebSocket URL of the NOSTR relay (must use ws:// or wss://)
    /// - Throws: ``RelayServiceError/badURL`` if the URL is nil or invalid
    public func connectToSocket(_ url: URL?) throws(RelayServiceError) {
        guard let url else { throw .badURL }
        let socketConnection = URLSession.shared.webSocketTask(with: url)
        let socketStream = SocketStream(task: socketConnection)
        streams.append(socketStream)
    }
    
    /// Sends a request to all connected relays.
    ///
    /// This method is currently a placeholder for sending NOSTR protocol
    /// messages to connected relays. Implementation should encode the request
    /// according to the NOSTR protocol specification and send it to all
    /// active WebSocket connections.
    ///
    /// ## TODO
    /// - Implement proper NOSTR message encoding
    /// - Add parameters for different request types
    /// - Handle sending to specific relays vs all relays
    ///
    /// - Throws: Any errors from the WebSocket send operation
    public func sendRequest() async throws {
        // TODO: Implement request sending logic
        // Example structure:
        // let parameters = RequestParameters(kinds: [.contacts], authors: ["..."], limit: 1)
        // let request = Request(messageType: .req, signature: "...", parameters: parameters)
        // 
        // for stream in streams {
        //     try await stream.send(message)
        // }
    }
    
    /// Listens for messages from all connected relays.
    ///
    /// This method creates concurrent tasks to listen for messages from each
    /// connected relay. Messages are processed as they arrive from any relay.
    /// The method will continue listening until all connections are closed
    /// or an error occurs.
    ///
    /// ## Message Handling
    /// Currently, messages are printed to the console. In a production
    /// implementation, messages should be:
    /// - Parsed according to NOSTR protocol
    /// - Validated for signatures
    /// - Dispatched to appropriate handlers
    ///
    /// ## Example
    /// ```swift
    /// let service = RelayService()
    /// try service.connectToSocket(relayURL)
    /// 
    /// // Listen for messages in a Task
    /// Task {
    ///     try await service.listen()
    /// }
    /// ```
    ///
    /// - Throws: Any errors from the WebSocket receive operations
    /// - Note: This method blocks until all streams are closed
    public func listen() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for stream in streams {
                group.addTask {
                    for try await message in stream {
                        // TODO: Implement proper message handling
                        // - Parse NOSTR protocol messages
                        // - Validate signatures
                        // - Dispatch to handlers
                        print("MESSAGE: \(message)")
                    }
                }
            }
            try await group.waitForAll()
        }
    }
}
