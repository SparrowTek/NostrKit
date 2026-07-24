//
//  NIP46BunkerSignerTests.swift
//  NostrKitTests
//
//  Protocol-level tests of the NIP-46 signer ("bunker") side. A hand-rolled
//  client drives the signer over an in-memory relay bus with real NIP-44/04
//  crypto — no sockets, no mocked cryptography.
//

import Testing
import Foundation
import CoreNostr
@testable import NostrKit

@Suite("NIP-46 BunkerSigner")
struct NIP46BunkerSignerTests {

    // MARK: - Harness

    struct Harness {
        let bus: NIP46RelayBus
        let signer: BunkerSigner
        let signerKeyPair: KeyPair
        let userKeyPair: KeyPair
        let client: TestNIP46Client

        var signerPubkey: String { signerKeyPair.publicKey }
        var userPubkey: String { userKeyPair.publicKey }
    }

    /// Builds a started signer + client on a shared bus. `sameKey` collapses
    /// signer/user identities (the common production setup); the default
    /// keeps them distinct so tests catch key-role mixups.
    func makeHarness(
        configuration: BunkerConfiguration? = nil,
        sameKey: Bool = false
    ) async throws -> Harness {
        let bus = NIP46RelayBus()
        let signerKeyPair = try KeyPair.generate()
        let userKeyPair = sameKey ? signerKeyPair : (try KeyPair.generate())

        let signer = BunkerSigner(
            configuration: configuration ?? BunkerConfiguration(relays: ["wss://bus.test"]),
            signerKeys: KeyPairKeyProvider(keyPair: signerKeyPair),
            userKeys: KeyPairKeyProvider(keyPair: userKeyPair),
            sessionStore: nil,
            relayPool: bus
        )
        try await signer.start()

        // The consume loop subscribes asynchronously; wait until it's live so
        // nothing a test sends can race past it.
        #expect(await eventually { await bus.subscriptionCount >= 1 })

        let client = try TestNIP46Client(bus: bus, signerPubkey: signerKeyPair.publicKey)
        return Harness(bus: bus, signer: signer, signerKeyPair: signerKeyPair, userKeyPair: userKeyPair, client: client)
    }

    /// Extracts the secret from a bunker:// URI.
    private func secret(fromBunkerURI uri: String) throws -> String {
        let parsed = try #require(NIP46.BunkerURI(from: uri))
        return try #require(parsed.secret)
    }

    /// Connects the harness client using a freshly issued bunker URI secret.
    @discardableResult
    private func connectClient(_ harness: Harness) async throws -> NIP46.Response {
        let uri = try await harness.signer.makeBunkerURI()
        let secret = try secret(fromBunkerURI: uri)
        let response = try await harness.client.request(
            NIP46.connectRequest(signerPubkey: harness.signerPubkey, secret: secret)
        )
        return try #require(response)
    }

    // MARK: - Bunker URI + connect secrets

    @Test("makeBunkerURI produces a parseable URI with relays and secret")
    func bunkerURIRoundTrip() async throws {
        let harness = try await makeHarness()
        let uri = try await harness.signer.makeBunkerURI()

        let parsed = try #require(NIP46.BunkerURI(from: uri))
        #expect(parsed.signerPubkey == harness.signerPubkey)
        #expect(parsed.relays == ["wss://bus.test"])
        #expect(parsed.secret?.isEmpty == false)
    }

    @Test("connect with a valid secret is acked and creates a session")
    func connectWithValidSecret() async throws {
        let harness = try await makeHarness()
        let response = try await connectClient(harness)

        #expect(response.result == "ack")
        #expect(response.error == nil)

        let sessions = await harness.signer.activeSessions()
        #expect(sessions.count == 1)
        #expect(sessions.first?.clientPubkey == harness.client.keyPair.publicKey)
        // Requested permissions are recorded but never self-granted.
        #expect(sessions.first?.grantedPermissions.isEmpty == true)
    }

    @Test("a connect secret is single-use: reuse is ignored entirely")
    func connectSecretSingleUse() async throws {
        let harness = try await makeHarness()
        let uri = try await harness.signer.makeBunkerURI()
        let secret = try secret(fromBunkerURI: uri)

        let first = try await harness.client.request(
            NIP46.connectRequest(signerPubkey: harness.signerPubkey, secret: secret)
        )
        #expect(first?.result == "ack")

        // A different client replaying the consumed secret gets NO response
        // (spec: ignore attempts with an old secret) and no session.
        let attacker = try TestNIP46Client(bus: harness.bus, signerPubkey: harness.signerPubkey)
        let replay = try await attacker.request(
            NIP46.connectRequest(signerPubkey: harness.signerPubkey, secret: secret),
            timeout: 0.75
        )
        #expect(replay == nil)
        #expect(await harness.signer.activeSessions().count == 1)
    }

    @Test("connect without a secret from an unknown client is unauthorized")
    func connectUnknownClientRejected() async throws {
        let harness = try await makeHarness()
        let response = try await harness.client.request(
            NIP46.connectRequest(signerPubkey: harness.signerPubkey)
        )
        #expect(response?.error == "unauthorized")
        #expect(await harness.signer.activeSessions().isEmpty)
    }

    @Test("a known client may reconnect without a secret under the default policy")
    func knownClientReconnects() async throws {
        let harness = try await makeHarness()
        try await connectClient(harness)

        let reconnect = try await harness.client.request(
            NIP46.connectRequest(signerPubkey: harness.signerPubkey)
        )
        #expect(reconnect?.result == "ack")
        #expect(await harness.signer.activeSessions().count == 1)
    }

    @Test("secretOnly policy refuses even known clients without a secret")
    func secretOnlyPolicy() async throws {
        let harness = try await makeHarness(
            configuration: BunkerConfiguration(relays: ["wss://bus.test"], connectPolicy: .secretOnly)
        )
        try await connectClient(harness)

        let reconnect = try await harness.client.request(
            NIP46.connectRequest(signerPubkey: harness.signerPubkey)
        )
        #expect(reconnect?.error == "unauthorized")
    }

    // MARK: - Auto-answered methods

    @Test("ping is answered with pong")
    func ping() async throws {
        let harness = try await makeHarness()
        let response = try await harness.client.request(NIP46.pingRequest())
        #expect(response?.result == "pong")
    }

    @Test("get_public_key requires a session and returns the USER pubkey, not the signer's")
    func getPublicKey() async throws {
        let harness = try await makeHarness()

        let before = try await harness.client.request(NIP46.getPublicKeyRequest())
        #expect(before?.error == "unauthorized")

        try await connectClient(harness)
        let after = try await harness.client.request(NIP46.getPublicKeyRequest())
        #expect(after?.result == harness.userPubkey)
        #expect(after?.result != harness.signerPubkey)
    }

    @Test("unknown methods get an error response")
    func unknownMethod() async throws {
        let harness = try await makeHarness()
        try await connectClient(harness)

        let response = try await harness.client.request(
            NIP46.Request(methodString: "create_account", params: [])
        )
        #expect(response?.error?.contains("unsupported method") == true)
    }

    // MARK: - sign_event

    @Test("sign_event with a granted permission auto-approves and returns a verifiable event")
    func signEventAutoApproved() async throws {
        let harness = try await makeHarness()
        try await connectClient(harness)
        await harness.signer.setGrantedPermissions(["sign_event:1"], forClient: harness.client.keyPair.publicKey)

        let unsigned = NIP46.UnsignedEvent(kind: 1, content: "Hello from the bunker", tags: [["t", "test"]])
        let response = try await harness.client.request(try NIP46.signEventRequest(event: unsigned))

        let json = try #require(response?.result)
        let signed = try JSONDecoder().decode(NostrEvent.self, from: Data(json.utf8))

        #expect(signed.pubkey == harness.userPubkey)
        #expect(signed.kind == 1)
        #expect(signed.content == "Hello from the bunker")
        #expect(signed.tags == [["t", "test"]])
        #expect(try CoreNostr.verifyEvent(signed))
    }

    @Test("kind-scoped permission does not cover other kinds")
    func kindScopedPermission() async throws {
        let harness = try await makeHarness(
            configuration: BunkerConfiguration(relays: ["wss://bus.test"], approvalTimeout: 0.5)
        )
        try await connectClient(harness)
        await harness.signer.setGrantedPermissions(["sign_event:1"], forClient: harness.client.keyPair.publicKey)

        // Kind 30023 isn't covered → lands in approval, times out → error.
        let unsigned = NIP46.UnsignedEvent(kind: 30023, content: "article", tags: [])
        let response = try await harness.client.request(try NIP46.signEventRequest(event: unsigned))
        #expect(response?.error == "request timed out")
    }

    @Test("sign_event without permission surfaces an approval request; approve completes it")
    func signEventApprovalFlow() async throws {
        let harness = try await makeHarness()
        try await connectClient(harness)

        let events = harness.signer.events
        let unsigned = NIP46.UnsignedEvent(kind: 1, content: "needs approval", tags: [])

        async let responseTask = harness.client.request(try NIP46.signEventRequest(event: unsigned))

        let event = await firstBunkerEvent(from: events) {
            if case .approvalRequired = $0 { return true }
            return false
        }
        guard case .approvalRequired(let approval) = try #require(event) else {
            Issue.record("Expected approvalRequired")
            return
        }

        #expect(approval.method == .signEvent)
        #expect(approval.unsignedEvent?.kind == 1)
        #expect(approval.unsignedEvent?.content == "needs approval")

        try await harness.signer.approve(requestID: approval.id)

        let response = try await responseTask
        let json = try #require(response?.result)
        let signed = try JSONDecoder().decode(NostrEvent.self, from: Data(json.utf8))
        #expect(try CoreNostr.verifyEvent(signed))
    }

    @Test("deny sends the client a rejection error")
    func denyRequest() async throws {
        let harness = try await makeHarness()
        try await connectClient(harness)

        let events = harness.signer.events
        let unsigned = NIP46.UnsignedEvent(kind: 1, content: "to be denied", tags: [])
        async let responseTask = harness.client.request(try NIP46.signEventRequest(event: unsigned))

        let event = await firstBunkerEvent(from: events) {
            if case .approvalRequired = $0 { return true }
            return false
        }
        guard case .approvalRequired(let approval) = try #require(event) else {
            Issue.record("Expected approvalRequired")
            return
        }

        await harness.signer.deny(requestID: approval.id)
        let response = try await responseTask
        #expect(response?.error == "user rejected the request")

        // The id is spent: approving after deny throws unknownRequest.
        await #expect(throws: BunkerSignerError.unknownRequest(approval.id)) {
            try await harness.signer.approve(requestID: approval.id)
        }
    }

    @Test("unanswered approvals time out with an error response")
    func approvalTimeout() async throws {
        let harness = try await makeHarness(
            configuration: BunkerConfiguration(relays: ["wss://bus.test"], approvalTimeout: 0.4)
        )
        try await connectClient(harness)

        let unsigned = NIP46.UnsignedEvent(kind: 1, content: "nobody home", tags: [])
        let response = try await harness.client.request(try NIP46.signEventRequest(event: unsigned))
        #expect(response?.error == "request timed out")
    }

    @Test("malformed sign_event params are rejected, not defaulted")
    func strictSignEventDecoding() async throws {
        let harness = try await makeHarness()
        try await connectClient(harness)

        // Missing `kind` — a lenient signer would default it and sign
        // something the user never saw.
        let request = NIP46.Request(
            method: .signEvent,
            params: [#"{"content":"sneaky","tags":[],"created_at":1700000000}"#]
        )
        let response = try await harness.client.request(request)
        #expect(response?.error?.contains("invalid sign_event params") == true)
    }

    @Test("operations without a session are unauthorized")
    func operationWithoutSession() async throws {
        let harness = try await makeHarness()
        let unsigned = NIP46.UnsignedEvent(kind: 1, content: "no session", tags: [])
        let response = try await harness.client.request(try NIP46.signEventRequest(event: unsigned))
        #expect(response?.error == "unauthorized")
    }

    // MARK: - Encryption operations

    @Test("nip44_encrypt result decrypts with the user key at the third party")
    func nip44EncryptRoundTrip() async throws {
        let harness = try await makeHarness()
        try await connectClient(harness)
        await harness.signer.setGrantedPermissions(
            ["nip44_encrypt", "nip44_decrypt"],
            forClient: harness.client.keyPair.publicKey
        )

        let thirdParty = try KeyPair.generate()
        let encryptResponse = try await harness.client.request(
            NIP46.nip44EncryptRequest(thirdPartyPubkey: thirdParty.publicKey, plaintext: "secret payload")
        )
        let ciphertext = try #require(encryptResponse?.result)

        // The third party can read it — proving it was encrypted user→peer.
        let decrypted = try thirdParty.decryptNIP44(payload: ciphertext, from: harness.userPubkey)
        #expect(decrypted == "secret payload")

        // And the signer decrypts the third party's reply.
        let reply = try thirdParty.encryptNIP44(message: "reply payload", to: harness.userPubkey)
        let decryptResponse = try await harness.client.request(
            NIP46.nip44DecryptRequest(thirdPartyPubkey: thirdParty.publicKey, ciphertext: reply)
        )
        #expect(decryptResponse?.result == "reply payload")
    }

    @Test("invalid third-party pubkey params are rejected")
    func invalidEncryptionParams() async throws {
        let harness = try await makeHarness()
        try await connectClient(harness)

        let response = try await harness.client.request(
            NIP46.nip44EncryptRequest(thirdPartyPubkey: "not-a-pubkey", plaintext: "x")
        )
        #expect(response?.error?.contains("invalid params") == true)
    }

    // MARK: - Legacy NIP-04

    @Test("a NIP-04 request gets a NIP-04 response the legacy client can decrypt")
    func nip04SchemeMatching() async throws {
        let harness = try await makeHarness()
        try await connectClient(harness)

        let ping = NIP46.Request(method: .ping)
        let envelope = try harness.client.makeNIP04RequestEvent(ping)
        let response = try await harness.client.send(rawEvent: envelope, awaitingResponseTo: ping.id)

        #expect(response?.result == "pong")

        // The envelope on the wire must be NIP-04 (the harness decrypts both
        // schemes, so verify the raw ciphertext shape too).
        let published = await harness.bus.published
        let responseEvent = try #require(published.last(where: { event in
            event.tags.contains(["p", harness.client.keyPair.publicKey])
        }))
        #expect(responseEvent.content.contains("?iv="))
    }

    @Test("NIP-04 requests are dropped when legacy support is disabled")
    func nip04Disabled() async throws {
        let harness = try await makeHarness(
            configuration: BunkerConfiguration(relays: ["wss://bus.test"], allowNIP04Requests: false)
        )
        try await connectClient(harness)

        let ping = NIP46.Request(method: .ping)
        let envelope = try harness.client.makeNIP04RequestEvent(ping)
        let response = try await harness.client.send(rawEvent: envelope, awaitingResponseTo: ping.id, timeout: 0.75)
        #expect(response == nil)
    }

    // MARK: - Validation pipeline

    @Test("duplicate deliveries produce exactly one response")
    func duplicateDelivery() async throws {
        let harness = try await makeHarness()
        try await connectClient(harness)

        let publishedBefore = await harness.bus.published.count

        let ping = NIP46.pingRequest()
        let envelope = try NIP46.createRequestEvent(
            request: ping,
            signerPubkey: harness.signerPubkey,
            clientKeyPair: harness.client.keyPair
        )

        await harness.client.send(rawEvent: envelope)
        await harness.client.send(rawEvent: envelope)
        await harness.client.send(rawEvent: envelope)

        #expect(await eventually { await harness.bus.published.count == publishedBefore + 1 })
        // Give any (wrong) extra responses a moment to appear.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await harness.bus.published.count == publishedBefore + 1)
    }

    @Test("stale events are dropped")
    func staleEventDropped() async throws {
        let harness = try await makeHarness()
        try await connectClient(harness)

        let ping = NIP46.Request(method: .ping)
        let data = try JSONEncoder().encode(ping)
        let json = try #require(String(data: data, encoding: .utf8))
        let ciphertext = try harness.client.keyPair.encryptNIP44(message: json, to: harness.signerPubkey)
        let old = NostrEvent(
            pubkey: harness.client.keyPair.publicKey,
            createdAt: Date().addingTimeInterval(-3600),
            kind: EventKind.remoteSigningRequest.rawValue,
            tags: [["p", harness.signerPubkey]],
            content: ciphertext
        )
        let signed = try harness.client.keyPair.signEvent(old)

        let response = try await harness.client.send(rawEvent: signed, awaitingResponseTo: ping.id, timeout: 0.75)
        #expect(response == nil)
    }

    @Test("forged envelopes (bad signature) are dropped")
    func forgedEnvelopeDropped() async throws {
        let harness = try await makeHarness()
        try await connectClient(harness)

        let ping = NIP46.Request(method: .ping)
        let valid = try NIP46.createRequestEvent(
            request: ping,
            signerPubkey: harness.signerPubkey,
            clientKeyPair: harness.client.keyPair
        )
        let forged = try NostrEvent(
            id: valid.id,
            pubkey: valid.pubkey,
            createdAt: valid.createdAt,
            kind: valid.kind,
            tags: valid.tags,
            content: valid.content,
            sig: String(repeating: "0", count: 128)
        )

        let response = try await harness.client.send(rawEvent: forged, awaitingResponseTo: ping.id, timeout: 0.75)
        #expect(response == nil)
    }

    // MARK: - nostrconnect flow

    @Test("connect(toClient:) answers with the URI secret and grants the requested permissions")
    func nostrconnectFlow() async throws {
        let harness = try await makeHarness()

        let clientKeyPair = try KeyPair.generate()
        let uri = NIP46.NostrConnectURI(
            clientPubkey: clientKeyPair.publicKey,
            relays: ["wss://bus.test"],
            secret: "s3cr3t-string",
            permissions: "sign_event:1,nip44_encrypt",
            name: "TestClient"
        )

        let subscription = try await harness.bus.walletSubscribe(
            filters: [Filter(kinds: [EventKind.remoteSigningRequest.rawValue], p: [clientKeyPair.publicKey])],
            id: nil
        )

        let session = try await harness.signer.connect(toClient: uri.toString())
        #expect(session.name == "TestClient")
        #expect(Set(session.grantedPermissions) == Set(["sign_event:1", "nip44_encrypt"]))

        // The client receives a connect response echoing the secret.
        let response: NIP46.Response? = await withTaskGroup(of: NIP46.Response?.self) { group in
            group.addTask {
                for await event in subscription.events {
                    if let parsed = try? NIP46.parseResponseEvent(
                        event: event,
                        clientSecret: clientKeyPair.privateKey,
                        signerPubkey: harness.signerPubkey
                    ) {
                        return parsed
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        #expect(response?.result == "s3cr3t-string")

        // The granted permission is live: sign_event:1 auto-approves.
        let client = TestNIP46Client(existing: clientKeyPair, bus: harness.bus, signerPubkey: harness.signerPubkey)
        let unsigned = NIP46.UnsignedEvent(kind: 1, content: "post-nostrconnect", tags: [])
        let signResponse = try await client.request(try NIP46.signEventRequest(event: unsigned))
        #expect(signResponse?.result != nil)
    }

    @Test("connect(toClient:) rejects malformed URIs")
    func nostrconnectRejectsMalformed() async throws {
        let harness = try await makeHarness()
        await #expect(throws: BunkerSignerError.invalidNostrConnectURI) {
            try await harness.signer.connect(toClient: "nostrconnect://not-a-valid-uri")
        }
    }

    // MARK: - Response publish failure

    @Test("publish failure is surfaced as responsePublishFailed")
    func publishFailureSurfaced() async throws {
        let harness = try await makeHarness(
            configuration: BunkerConfiguration(relays: ["wss://bus.test"], responsePublishAttempts: 1)
        )
        try await connectClient(harness)

        let events = harness.signer.events
        await harness.bus.setPublishShouldFail(true)

        try await harness.client.send(NIP46.pingRequest())

        let event = await firstBunkerEvent(from: events) {
            if case .responsePublishFailed = $0 { return true }
            return false
        }
        #expect(event != nil)
    }

    // MARK: - Session persistence

    @Test("sessions round-trip through the store and survive a restart")
    func sessionPersistence() async throws {
        let bus = NIP46RelayBus()
        let signerKeyPair = try KeyPair.generate()
        let store = InMemoryBunkerSessionStore()
        let configuration = BunkerConfiguration(relays: ["wss://bus.test"])
        let provider = KeyPairKeyProvider(keyPair: signerKeyPair)

        let first = BunkerSigner(
            configuration: configuration,
            signerKeys: provider,
            sessionStore: store,
            relayPool: bus
        )
        try await first.start()
        #expect(await eventually { await bus.subscriptionCount >= 1 })

        let client = try TestNIP46Client(bus: bus, signerPubkey: signerKeyPair.publicKey)
        let uri = try await first.makeBunkerURI()
        let parsedSecret = try #require(NIP46.BunkerURI(from: uri)?.secret)
        _ = try await client.request(NIP46.connectRequest(signerPubkey: signerKeyPair.publicKey, secret: parsedSecret))
        await first.stop()

        let second = BunkerSigner(
            configuration: configuration,
            signerKeys: provider,
            sessionStore: store,
            relayPool: bus
        )
        try await second.start()
        #expect(await eventually { await bus.subscriptionCount >= 1 })

        // The reconnecting known client is recognized without a secret.
        let reconnect = try await client.request(NIP46.connectRequest(signerPubkey: signerKeyPair.publicKey))
        #expect(reconnect?.result == "ack")
        await second.stop()
    }
}
