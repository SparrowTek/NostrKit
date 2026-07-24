//
//  RelayPoolResilienceTests.swift
//  NostrKitTests
//
//  Pool behavior under connection churn, driven through scripted
//  RelayConnection doubles: reconnects must re-establish subscriptions,
//  intentional disconnects must stay down, and server-side CLOSED must be
//  retried (with NIP-42 auth when demanded).
//

import Testing
import Foundation
import CoreNostr
@testable import NostrKit

/// A scripted `RelayConnection` that records what the pool asks of it and
/// lets tests drop connections / emit relay messages on demand. Mirrors
/// `RelayService`'s stream semantics: each `connect()` mints a fresh
/// messages stream; dropping the connection finishes it.
actor ScriptedRelayConnection: NostrKit.RelayConnection {
    nonisolated let url: String

    private(set) var isConnected = false
    private(set) var connectCallCount = 0
    private(set) var subscribeCalls: [(id: String, filters: [Filter])] = []
    private(set) var closedSubscriptionIDs: [String] = []
    private(set) var publishedEvents: [NostrEvent] = []
    private(set) var sentAuthEvents: [NostrEvent] = []

    var connectShouldFail = false
    private var authenticator: (@Sendable (AuthChallenge) async throws -> AuthResponse)?
    private var continuation: AsyncStream<RelayMessage>.Continuation?
    private var _messages: AsyncStream<RelayMessage>

    init(url: String) {
        self.url = url
        let (stream, continuation) = AsyncStream<RelayMessage>.makeStream()
        self._messages = stream
        self.continuation = continuation
    }

    var messages: AsyncStream<RelayMessage> { _messages }

    var authenticationStatus: AuthenticationStatus { .notAuthenticated }

    func connect() async throws {
        if connectShouldFail {
            throw RelayError.notConnected
        }
        connectCallCount += 1
        if continuation == nil {
            let (stream, continuation) = AsyncStream<RelayMessage>.makeStream()
            self._messages = stream
            self.continuation = continuation
        }
        isConnected = true
    }

    func disconnect() async {
        isConnected = false
        continuation?.finish()
        continuation = nil
    }

    func publishEvent(_ event: NostrEvent) async throws {
        guard isConnected else { throw RelayError.notConnected }
        publishedEvents.append(event)
    }

    func subscribe(id: String, filters: [Filter]) async throws {
        guard isConnected else { throw RelayError.notConnected }
        subscribeCalls.append((id: id, filters: filters))
    }

    func closeSubscription(id: String) async throws {
        closedSubscriptionIDs.append(id)
    }

    func sendAuth(_ event: NostrEvent) async throws {
        sentAuthEvents.append(event)
    }

    func setAuthenticator(_ handler: (@Sendable (AuthChallenge) async throws -> AuthResponse)?) {
        authenticator = handler
    }

    var hasAuthenticator: Bool { authenticator != nil }

    // MARK: - Scripting

    /// Simulates the remote end dropping the connection: the messages stream
    /// finishes, exactly as when a socket dies.
    func dropConnection() {
        isConnected = false
        continuation?.finish()
        continuation = nil
    }

    /// Emits a relay message into the current connection's stream.
    func emit(_ message: RelayMessage) {
        continuation?.yield(message)
    }

    func setConnectShouldFail(_ shouldFail: Bool) {
        connectShouldFail = shouldFail
    }
}

@Suite("RelayPool Resilience")
struct RelayPoolResilienceTests {

    /// A pool with fast backoff so reconnect behavior is observable in
    /// test-scale time.
    private func makePool() -> NostrKit.RelayPool {
        NostrKit.RelayPool(configuration: NostrKit.RelayPool.Configuration(
            initialReconnectDelay: 0.05,
            maxReconnectDelay: 0.2,
            backoffMultiplier: 1.0
        ))
    }

    /// NIP-11 fetches go to this unroutable localhost port and fail fast.
    private let relayURL = "wss://127.0.0.1:1"

    @Test("subscriptions are re-established after a connection drop")
    func resubscribeAfterReconnect() async throws {
        let pool = makePool()
        let connection = ScriptedRelayConnection(url: relayURL)
        try await pool.addRelay(url: relayURL, connection: connection)
        try await pool.connect(to: relayURL)

        _ = try await pool.subscribe(filters: [Filter(kinds: [24133])], id: "bunker-sub")
        #expect(await connection.subscribeCalls.count == 1)

        // The socket dies. The pool must reconnect AND re-REQ the
        // subscription — a bunker that silently loses its subscription is
        // deaf forever.
        await connection.dropConnection()

        #expect(await eventually(timeout: 3) {
            await connection.subscribeCalls.count >= 2
        })
        let calls = await connection.subscribeCalls
        #expect(calls.allSatisfy { $0.id == "bunker-sub" })
        #expect(await connection.connectCallCount >= 2)
    }

    @Test("an intentional disconnect stays down — no auto-reconnect resurrection")
    func intentionalDisconnectStaysDown() async throws {
        let pool = makePool()
        let connection = ScriptedRelayConnection(url: relayURL)
        try await pool.addRelay(url: relayURL, connection: connection)
        try await pool.connect(to: relayURL)
        #expect(await connection.connectCallCount == 1)

        await pool.disconnect(from: relayURL)

        // Give several backoff periods a chance to (wrongly) fire.
        try await Task.sleep(for: .milliseconds(400))
        #expect(await connection.connectCallCount == 1)
        #expect(await pool.getRelay(relayURL)?.state == .disconnected)

        // An explicit connect re-arms everything.
        try await pool.connect(to: relayURL)
        #expect(await connection.connectCallCount == 2)
    }

    @Test("subscribing while offline succeeds and attaches when the relay connects")
    func attachPendingSubscription() async throws {
        let pool = makePool()
        let connection = ScriptedRelayConnection(url: relayURL)
        try await pool.addRelay(url: relayURL, connection: connection)

        // No relay connected yet — a bunker starting in airplane mode.
        let subscription = try await pool.subscribe(filters: [Filter(kinds: [24133])], id: "offline-sub")
        #expect(subscription.id == "offline-sub")
        #expect(await connection.subscribeCalls.isEmpty)

        try await pool.connect(to: relayURL)
        #expect(await eventually {
            await connection.subscribeCalls.contains { $0.id == "offline-sub" }
        })
    }

    @Test("a server-side CLOSED triggers a bounded resubscribe")
    func closedTriggersResubscribe() async throws {
        let pool = makePool()
        let connection = ScriptedRelayConnection(url: relayURL)
        try await pool.addRelay(url: relayURL, connection: connection)
        try await pool.connect(to: relayURL)

        _ = try await pool.subscribe(filters: [Filter(kinds: [24133])], id: "closable")
        #expect(await connection.subscribeCalls.count == 1)

        await connection.emit(.closed(subscriptionId: "closable", message: "server restarting"))

        #expect(await eventually(timeout: 3) {
            await connection.subscribeCalls.count >= 2
        })
    }

    @Test("auth-required CLOSED without an authenticator is not retried")
    func authRequiredWithoutAuthenticator() async throws {
        let pool = makePool()
        let connection = ScriptedRelayConnection(url: relayURL)
        try await pool.addRelay(url: relayURL, connection: connection)
        try await pool.connect(to: relayURL)

        _ = try await pool.subscribe(filters: [Filter(kinds: [24133])], id: "auth-sub")
        #expect(await connection.subscribeCalls.count == 1)

        await connection.emit(.closed(subscriptionId: "auth-sub", message: "auth-required: subscribe to this kind"))

        try await Task.sleep(for: .seconds(1.5))
        #expect(await connection.subscribeCalls.count == 1)
    }

    @Test("auth-required CLOSED with an authenticator waits for auth then resubscribes")
    func authRequiredWithAuthenticator() async throws {
        let pool = makePool()
        let keyPair = try KeyPair.generate()
        await pool.setAuthenticator(keyPair: keyPair)

        let connection = ScriptedRelayConnection(url: relayURL)
        try await pool.addRelay(url: relayURL, connection: connection)
        try await pool.connect(to: relayURL)

        // connect(to:) must have propagated the authenticator.
        #expect(await connection.hasAuthenticator)

        _ = try await pool.subscribe(filters: [Filter(kinds: [24133])], id: "auth-sub")
        #expect(await connection.subscribeCalls.count == 1)

        await connection.emit(.closed(subscriptionId: "auth-sub", message: "auth-required: subscribe to this kind"))

        #expect(await eventually(timeout: 3) {
            await connection.subscribeCalls.count >= 2
        })
    }

    @Test("repeated CLOSED gives up after the retry budget instead of looping forever")
    func closedRetryBudget() async throws {
        let pool = makePool()
        let connection = ScriptedRelayConnection(url: relayURL)
        try await pool.addRelay(url: relayURL, connection: connection)
        try await pool.connect(to: relayURL)

        _ = try await pool.subscribe(filters: [Filter(kinds: [24133])], id: "stubborn")

        // The relay closes the subscription every time we re-REQ it.
        for _ in 0..<6 {
            await connection.emit(.closed(subscriptionId: "stubborn", message: "not welcome"))
            try await Task.sleep(for: .milliseconds(400))
        }

        // 1 initial + at most 3 retries.
        let calls = await connection.subscribeCalls.count
        #expect(calls <= 4, "expected bounded retries, got \(calls) REQs")
    }

    @Test("reconnect after drop also re-arms the authenticator on the fresh connection")
    func reconnectKeepsAuthenticator() async throws {
        let pool = makePool()
        let keyPair = try KeyPair.generate()
        await pool.setAuthenticator(keyPair: keyPair)

        let connection = ScriptedRelayConnection(url: relayURL)
        try await pool.addRelay(url: relayURL, connection: connection)
        try await pool.connect(to: relayURL)
        #expect(await connection.hasAuthenticator)

        await connection.dropConnection()
        #expect(await eventually(timeout: 3) {
            await connection.connectCallCount >= 2
        })
        #expect(await connection.hasAuthenticator)
    }
}
