//
//  NIP46RoundTripTests.swift
//  NostrKitTests
//
//  Full client ↔ signer round trips: NostrKit's RemoteSignerManager (client
//  side) talking to NostrKit's BunkerSigner (signer side) over an in-memory
//  relay bus, with real NIP-44 encryption in both directions. If these pass,
//  the two halves of the package interoperate by construction.
//

import Testing
import Foundation
import CoreNostr
@testable import NostrKit

@MainActor
@Suite("NIP-46 Round Trips (client ↔ signer)")
struct NIP46RoundTripTests {

    actor InMemoryWalletStorage: WalletStorage {
        private var store: [String: Data] = [:]

        func store(_ data: Data, forKey key: String) async throws {
            store[key] = data
        }

        func load(key: String) async throws -> Data {
            guard let data = store[key] else {
                throw NostrError.notFound(resource: key)
            }
            return data
        }

        func remove(key: String) async throws {
            store.removeValue(forKey: key)
        }
    }

    struct Harness {
        let bus: NIP46RelayBus
        let signer: BunkerSigner
        let manager: RemoteSignerManager
        let userKeyPair: KeyPair
        let signerKeyPair: KeyPair
    }

    /// Builds a started signer and a fresh manager sharing one bus.
    func makeHarness(configuration: BunkerConfiguration? = nil) async throws -> Harness {
        let bus = NIP46RelayBus()
        let signerKeyPair = try KeyPair.generate()
        let userKeyPair = try KeyPair.generate()

        let signer = BunkerSigner(
            configuration: configuration ?? BunkerConfiguration(relays: ["wss://bus.test"]),
            signerKeys: KeyPairKeyProvider(keyPair: signerKeyPair),
            userKeys: KeyPairKeyProvider(keyPair: userKeyPair),
            sessionStore: nil,
            relayPool: bus
        )
        try await signer.start()
        #expect(await eventually { await bus.subscriptionCount >= 1 })

        let manager = RemoteSignerManager(relayPool: bus, keychain: InMemoryWalletStorage())
        return Harness(bus: bus, signer: signer, manager: manager, userKeyPair: userKeyPair, signerKeyPair: signerKeyPair)
    }

    /// Connects the manager to the signer via a freshly issued bunker URI.
    func connect(_ harness: Harness) async throws {
        let uri = try await harness.signer.makeBunkerURI()
        try await harness.manager.connect(bunkerURI: uri, alias: "Round Trip")
    }

    // MARK: - Tests

    @Test("bunker:// connect handshake completes and learns the user pubkey")
    func bunkerConnectFlow() async throws {
        let harness = try await makeHarness()
        try await connect(harness)

        #expect(harness.manager.connectionState == .connected)
        // The manager must report the USER identity, not the signer transport key.
        #expect(harness.manager.userPublicKey == harness.userKeyPair.publicKey)
        #expect(harness.manager.userPublicKey != harness.signerKeyPair.publicKey)

        let signerSessions = await harness.signer.activeSessions()
        #expect(signerSessions.count == 1)
    }

    @Test("ping round-trips")
    func pingRoundTrip() async throws {
        let harness = try await makeHarness()
        try await connect(harness)
        #expect(try await harness.manager.ping())
    }

    @Test("signEvent round-trips through user approval and verifies")
    func signEventWithApproval() async throws {
        let harness = try await makeHarness()
        let signerEvents = harness.signer.events
        try await connect(harness)

        // Approve the sign request when it surfaces, like the app UI would.
        let signer = harness.signer
        let approver = Task {
            let event = await firstBunkerEvent(from: signerEvents) {
                if case .approvalRequired = $0 { return true }
                return false
            }
            if case .approvalRequired(let approval) = event {
                try? await signer.approve(requestID: approval.id)
            }
        }

        let unsigned = NIP46.UnsignedEvent(kind: 1, content: "signed via round trip", tags: [["t", "roundtrip"]])
        let signed = try await harness.manager.signEvent(unsigned)
        await approver.value

        #expect(signed.pubkey == harness.userKeyPair.publicKey)
        #expect(signed.content == "signed via round trip")
        #expect(signed.kind == 1)
        #expect(try CoreNostr.verifyEvent(signed))
    }

    @Test("signEvent with a pre-granted permission needs no approval")
    func signEventAutoApproved() async throws {
        let harness = try await makeHarness()
        try await connect(harness)

        let clientPubkey = try #require(await harness.signer.activeSessions().first?.clientPubkey)
        await harness.signer.setGrantedPermissions(["sign_event:1"], forClient: clientPubkey)

        let unsigned = NIP46.UnsignedEvent(kind: 1, content: "auto", tags: [])
        let signed = try await harness.manager.signEvent(unsigned)
        #expect(try CoreNostr.verifyEvent(signed))
    }

    @Test("a denied request throws on the client side")
    func denialPropagates() async throws {
        let harness = try await makeHarness()
        let signerEvents = harness.signer.events
        try await connect(harness)

        let signer = harness.signer
        let denier = Task {
            let event = await firstBunkerEvent(from: signerEvents) {
                if case .approvalRequired = $0 { return true }
                return false
            }
            if case .approvalRequired(let approval) = event {
                await signer.deny(requestID: approval.id)
            }
        }

        let unsigned = NIP46.UnsignedEvent(kind: 1, content: "should be denied", tags: [])
        await #expect(throws: (any Error).self) {
            _ = try await harness.manager.signEvent(unsigned)
        }
        await denier.value
    }

    @Test("nip44 encryption round-trips: manager encrypts, third party reads")
    func nip44RoundTrip() async throws {
        let harness = try await makeHarness()
        try await connect(harness)

        let clientPubkey = try #require(await harness.signer.activeSessions().first?.clientPubkey)
        await harness.signer.setGrantedPermissions(["nip44_encrypt", "nip44_decrypt"], forClient: clientPubkey)

        let thirdParty = try KeyPair.generate()
        let ciphertext = try await harness.manager.nip44Encrypt(
            plaintext: "round trip payload",
            recipientPubkey: thirdParty.publicKey
        )
        let read = try thirdParty.decryptNIP44(payload: ciphertext, from: harness.userKeyPair.publicKey)
        #expect(read == "round trip payload")

        let reply = try thirdParty.encryptNIP44(message: "the reply", to: harness.userKeyPair.publicKey)
        let plaintext = try await harness.manager.nip44Decrypt(ciphertext: reply, senderPubkey: thirdParty.publicKey)
        #expect(plaintext == "the reply")
    }

    @Test("nostrconnect flow: signer connects to the client's URI and the secret is validated")
    func nostrconnectFlow() async throws {
        let harness = try await makeHarness()

        let uri = try harness.manager.createNostrConnectURI(
            relays: ["wss://bus.test"],
            permissions: [NIP46.Permission(method: .signEvent, kind: 1)],
            name: "RoundTripApp"
        )

        let subscriptionsBefore = await harness.bus.subscriptionCount
        async let waiting: Void = harness.manager.waitForConnection(uri: uri, timeout: 10)

        // Let the manager's connect-response subscription go live before the
        // signer answers.
        #expect(await eventually { await harness.bus.subscriptionCount > subscriptionsBefore })

        let session = try await harness.signer.connect(toClient: uri.toString())
        #expect(session.name == "RoundTripApp")
        #expect(session.grantedPermissions == ["sign_event:1"])

        try await waiting
        #expect(harness.manager.connectionState == .connected)
        #expect(harness.manager.userPublicKey == harness.userKeyPair.publicKey)

        // The granted kind-1 permission is live end-to-end.
        let signed = try await harness.manager.signEvent(
            NIP46.UnsignedEvent(kind: 1, content: "post-nostrconnect", tags: [])
        )
        #expect(try CoreNostr.verifyEvent(signed))
    }

    @Test("nostrconnect hijack fails: an attacker acking without the secret is ignored")
    func nostrconnectHijackRejected() async throws {
        let harness = try await makeHarness()

        let uri = try harness.manager.createNostrConnectURI(
            relays: ["wss://bus.test"],
            name: "HijackTarget"
        )

        let subscriptionsBefore = await harness.bus.subscriptionCount
        let manager = harness.manager
        let waitTask = Task {
            try await manager.waitForConnection(uri: uri, timeout: 1.5)
        }
        #expect(await eventually { await harness.bus.subscriptionCount > subscriptionsBefore })

        // The attacker saw the QR (it's on screen!) but not the secret's
        // required echo — it responds with a bare "ack" hoping to be adopted
        // as the signer.
        let attacker = try KeyPair.generate()
        let ack = NIP46.Response.success(id: UUID().uuidString, result: "ack")
        let payload = try JSONEncoder().encode(ack)
        let json = try #require(String(data: payload, encoding: .utf8))
        let ciphertext = try attacker.encryptNIP44(message: json, to: uri.clientPubkey)
        let event = NostrEvent(
            pubkey: attacker.publicKey,
            createdAt: Date(),
            kind: EventKind.remoteSigningRequest.rawValue,
            tags: [["p", uri.clientPubkey]],
            content: ciphertext
        )
        await harness.bus.injectIncoming(try attacker.signEvent(event))

        await #expect(throws: (any Error).self) {
            try await waitTask.value
        }
        #expect(harness.manager.userPublicKey == nil)
    }

    @Test("requests fail fast when the connection drops, and reconnect() restores service")
    func reconnectRestoresService() async throws {
        let harness = try await makeHarness()
        try await connect(harness)
        #expect(harness.manager.connectionState == .connected)

        // Tear the transport down under the manager. The standing response
        // subscription's stream finishes → connection-lost handling runs.
        await harness.bus.disconnectAll()
        #expect(await eventually {
            await MainActor.run { harness.manager.connectionState != .connected }
        })

        // Reconnect and verify service is restored end-to-end. Wait for the
        // signer's consume loop to re-subscribe first — the bus retains no
        // backlog, so a ping published before the signer listens again is
        // gone forever (as on a real relay without stored ephemeral events).
        await harness.bus.connectAll()
        #expect(await eventually { await harness.bus.subscriptionCount >= 1 })
        try await harness.manager.reconnect()
        #expect(harness.manager.connectionState == .connected)
        #expect(try await harness.manager.ping())
    }
}
