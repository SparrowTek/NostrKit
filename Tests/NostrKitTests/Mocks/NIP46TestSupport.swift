//
//  NIP46TestSupport.swift
//  NostrKitTests
//
//  Shared infrastructure for NIP-46 signer/client tests: an in-memory relay
//  bus both sides ride on, and a hand-rolled test client for protocol-level
//  signer tests.
//

import Foundation
import CoreNostr
@testable import NostrKit

/// An in-memory "relay" implementing `WalletRelayPool`.
///
/// Published events are delivered to every live subscription whose filters
/// match (kind, authors, p-tags) — so a `BunkerSigner` and a
/// `RemoteSignerManager` sharing one bus exchange real, fully-encrypted
/// NIP-46 traffic with no sockets involved.
actor NIP46RelayBus: WalletRelayPool {

    private struct ActiveSubscription {
        let id: String
        let filters: [Filter]
        let continuation: AsyncStream<NostrEvent>.Continuation
    }

    private var relays: Set<String> = []
    private var connected = false
    private var subscriptions: [String: ActiveSubscription] = [:]
    private var publishShouldFail = false

    /// Every event `publish` accepted, in order.
    private(set) var published: [NostrEvent] = []

    var hasConnectedRelay: Bool { connected && !relays.isEmpty }

    func addRelay(url: String) async throws {
        relays.insert(url)
    }

    func connectAll() async {
        connected = true
    }

    func disconnectAll() async {
        connected = false
        for subscription in subscriptions.values {
            subscription.continuation.finish()
        }
        subscriptions.removeAll()
    }

    func publish(_ event: NostrEvent) async -> [NostrKit.RelayPool.PublishResult] {
        guard !publishShouldFail else {
            return [NostrKit.RelayPool.PublishResult(relay: "wss://bus.test", success: false, message: "forced failure", error: nil)]
        }
        published.append(event)
        deliver(event)
        return [NostrKit.RelayPool.PublishResult(relay: "wss://bus.test", success: true, message: nil, error: nil)]
    }

    func walletSubscribe(filters: [Filter], id: String?) async throws -> WalletSubscription {
        let subscriptionID = id ?? UUID().uuidString
        let (stream, continuation) = AsyncStream<NostrEvent>.makeStream()
        subscriptions[subscriptionID] = ActiveSubscription(id: subscriptionID, filters: filters, continuation: continuation)
        return WalletSubscription(id: subscriptionID, events: stream)
    }

    func closeSubscription(id: String) async {
        subscriptions.removeValue(forKey: id)?.continuation.finish()
    }

    // MARK: - Test Controls

    /// Delivers an event to matching subscriptions WITHOUT recording it in
    /// `published` — represents traffic arriving from elsewhere on the relay.
    func injectIncoming(_ event: NostrEvent) {
        deliver(event)
    }

    func setPublishShouldFail(_ shouldFail: Bool) {
        publishShouldFail = shouldFail
    }

    var subscriptionCount: Int { subscriptions.count }

    // MARK: - Matching

    private func deliver(_ event: NostrEvent) {
        for subscription in subscriptions.values where matches(event, filters: subscription.filters) {
            subscription.continuation.yield(event)
        }
    }

    private func matches(_ event: NostrEvent, filters: [Filter]) -> Bool {
        filters.contains { filter in
            if let kinds = filter.kinds, !kinds.contains(event.kind) { return false }
            if let authors = filter.authors, !authors.contains(event.pubkey) { return false }
            if let pTags = filter.p {
                let tagged = event.tags.filter { $0.count >= 2 && $0[0] == "p" }.map { $0[1] }
                guard pTags.contains(where: { tagged.contains($0) }) else { return false }
            }
            // `since` is deliberately ignored: freshness is the signer's own
            // validation concern, and tests craft stale events to prove it.
            return true
        }
    }
}

/// A minimal NIP-46 client for driving `BunkerSigner` directly in tests.
///
/// Uses CoreNostr's client-half helpers (real NIP-44 crypto) so the signer is
/// exercised exactly as a production client would.
struct TestNIP46Client {
    let keyPair: KeyPair
    let bus: NIP46RelayBus
    let signerPubkey: String

    init(bus: NIP46RelayBus, signerPubkey: String) throws {
        self.keyPair = try KeyPair.generate()
        self.bus = bus
        self.signerPubkey = signerPubkey
    }

    /// Builds a client around an existing key pair (nostrconnect tests).
    init(existing keyPair: KeyPair, bus: NIP46RelayBus, signerPubkey: String) {
        self.keyPair = keyPair
        self.bus = bus
        self.signerPubkey = signerPubkey
    }

    /// Sends a request envelope (NIP-44 encrypted) to the signer.
    func send(_ request: NIP46.Request) async throws {
        let event = try NIP46.createRequestEvent(
            request: request,
            signerPubkey: signerPubkey,
            clientKeyPair: keyPair
        )
        await bus.injectIncoming(event)
    }

    /// Sends a raw pre-built envelope (for stale/forged/legacy variants).
    func send(rawEvent: NostrEvent) async {
        await bus.injectIncoming(rawEvent)
    }

    /// Builds a NIP-04-encrypted request envelope, as legacy clients do.
    func makeNIP04RequestEvent(_ request: NIP46.Request) throws -> NostrEvent {
        let data = try JSONEncoder().encode(request)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NIP46.NIP46Error.serializationFailed
        }
        let ciphertext = try keyPair.encrypt(message: json, to: signerPubkey)
        let event = NostrEvent(
            pubkey: keyPair.publicKey,
            createdAt: Date(),
            kind: EventKind.remoteSigningRequest.rawValue,
            tags: [["p", signerPubkey]],
            content: ciphertext
        )
        return try keyPair.signEvent(event)
    }

    /// Sends `request` and returns the signer's response, or nil on timeout.
    /// The response subscription is live before the request goes out.
    func request(_ request: NIP46.Request, timeout: TimeInterval = 5) async throws -> NIP46.Response? {
        let subscription = try await bus.walletSubscribe(
            filters: [Filter(kinds: [EventKind.remoteSigningRequest.rawValue], p: [keyPair.publicKey])],
            id: nil
        )
        try await send(request)
        let response = await awaitResponse(id: request.id, on: subscription, timeout: timeout)
        await bus.closeSubscription(id: subscription.id)
        return response
    }

    /// Sends a raw envelope and returns the signer's response to `requestID`,
    /// or nil if none arrives before the timeout.
    func send(rawEvent: NostrEvent, awaitingResponseTo requestID: String, timeout: TimeInterval = 5) async throws -> NIP46.Response? {
        let subscription = try await bus.walletSubscribe(
            filters: [Filter(kinds: [EventKind.remoteSigningRequest.rawValue], p: [keyPair.publicKey])],
            id: nil
        )
        await bus.injectIncoming(rawEvent)
        let response = await awaitResponse(id: requestID, on: subscription, timeout: timeout)
        await bus.closeSubscription(id: subscription.id)
        return response
    }

    /// Decrypts a response envelope regardless of scheme.
    func decryptResponse(_ event: NostrEvent) throws -> NIP46.Response {
        let plaintext: String
        if event.content.contains("?iv=") {
            plaintext = try keyPair.decrypt(message: event.content, from: event.pubkey)
        } else {
            plaintext = try keyPair.decryptNIP44(payload: event.content, from: event.pubkey)
        }
        guard let data = plaintext.data(using: .utf8) else {
            throw NIP46.NIP46Error.invalidResponse
        }
        return try JSONDecoder().decode(NIP46.Response.self, from: data)
    }

    private func awaitResponse(id: String, on subscription: WalletSubscription, timeout: TimeInterval) async -> NIP46.Response? {
        await withTaskGroup(of: NIP46.Response?.self) { group in
            group.addTask {
                for await event in subscription.events {
                    guard let response = try? decryptResponse(event) else { continue }
                    if response.id == id { return response }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Polls `condition` until it holds or `timeout` elapses.
func eventually(timeout: TimeInterval = 2, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return await condition()
}

/// Awaits the first event from `stream` matching `predicate`, or nil on timeout.
func firstBunkerEvent(
    from stream: AsyncStream<BunkerSignerEvent>,
    timeout: TimeInterval = 5,
    where predicate: @escaping @Sendable (BunkerSignerEvent) -> Bool
) async -> BunkerSignerEvent? {
    await withTaskGroup(of: BunkerSignerEvent?.self) { group in
        group.addTask {
            for await event in stream where predicate(event) {
                return event
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(timeout))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
