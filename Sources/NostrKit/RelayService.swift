//
//  RelayService.swift
//  
//
//  Created by Thomas Rademaker on 6/18/24.
//

import Foundation

public typealias WebSocketStream = AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>

class SocketStream: AsyncSequence {
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

        task.receive(completionHandler: { [weak self] result in
            guard let continuation = self?.continuation else {
                return
            }

            do {
                let message = try result.get()
                continuation.yield(message)
                self?.waitForNextValue()
            } catch {
                continuation.finish(throwing: error)
            }
        })
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

public enum RelayServiceError: Error {
    case badURL
}

public class RelayService {
    private var streams: [SocketStream] = []
    
    public func connectToSocket(_ url: URL?) throws(RelayServiceError) {
        guard let url else { throw .badURL }
        let socketConnection = URLSession.shared.webSocketTask(with: url)
        let socketStream = SocketStream(task: socketConnection)
        streams.append(socketStream)
    }
    
    public func sendRequest() async throws {
//        let parameters = RequestParameters(kinds: [.contacts], authors: ["d1b7815978659167f4f127ce69511096516c4e696503c9c921014867915c7721"], limit: 1)
//        let request = Request(messageType: .req, signature: "214F1FDE-683C-4078-B453-A35C3294E846", parameters: parameters)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

//        if let jsonData = try? encoder.encode(request),
//           let jsonString = String(data: jsonData, encoding: .utf8) {
//            print(jsonString)
//        }
//        URLSessionWebSocketTask.Message
        
//        guard let json = try? encoder.encode(request), let jsonString = String(data: json, encoding: .utf8) else { return }
//        
//        
//        try await socketConnection.send(URLSessionWebSocketTask.Message.string(jsonString))

    }
    
    public func listen() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for stream in streams {
                group.addTask {
                    for try await message in stream {
                        // handle incoming messages
                        print("MESSAGE: \(message)")
                    }
                }
            }
            try await group.waitForAll()
        }
//        for stream in streams {
//            for try await message in stream {
//                // handle incoming messages
//                print("MESSAGE: \(message)")
//            }
//        }
    }
}
