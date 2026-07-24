//
//  BunkerSignerModels.swift
//  NostrKit
//
//  NIP-46: Nostr Remote Signing — signer ("bunker") side supporting types.
//

import Foundation
import CoreNostr

// MARK: - Key Provider

/// Cryptographic operations a NIP-46 signer needs from an identity.
///
/// `BunkerSigner` never sees a private key — it asks a provider to perform
/// operations. Apps keep keys wherever they like (Keychain, Secure Enclave,
/// hardware) and conform their key service to this protocol.
///
/// A bunker uses up to two providers:
/// - **signer keys** encrypt/decrypt the NIP-46 envelope (kind 24133 events)
///   and sign responses.
/// - **user keys** sign `sign_event` payloads and perform the third-party
///   `nip04_*`/`nip44_*` operations, and answer `get_public_key`.
///
/// They MAY be the same identity (the common setup), but a distinct signer
/// keypair avoids p-tagging your real identity on relay traffic.
public protocol NIP46KeyProvider: Sendable {
    /// The hex public key of this identity.
    func publicKey() async throws -> String

    /// Signs the event (filling `id` and `sig`).
    func signEvent(_ event: NostrEvent) async throws -> NostrEvent

    /// NIP-04 encrypts `plaintext` to `peerPublicKey`.
    func nip04Encrypt(plaintext: String, peerPublicKey: String) async throws -> String

    /// NIP-04 decrypts `ciphertext` from `peerPublicKey`.
    func nip04Decrypt(ciphertext: String, peerPublicKey: String) async throws -> String

    /// NIP-44 encrypts `plaintext` to `peerPublicKey`.
    func nip44Encrypt(plaintext: String, peerPublicKey: String) async throws -> String

    /// NIP-44 decrypts `ciphertext` from `peerPublicKey`.
    func nip44Decrypt(ciphertext: String, peerPublicKey: String) async throws -> String
}

/// A `NIP46KeyProvider` backed by an in-memory `KeyPair`.
///
/// Convenient for tests and simple setups. Production signers holding user
/// keys in the Keychain should conform their own key service instead so the
/// key material never lives in a long-lived Swift value.
public struct KeyPairKeyProvider: NIP46KeyProvider {
    private let keyPair: KeyPair

    public init(keyPair: KeyPair) {
        self.keyPair = keyPair
    }

    public func publicKey() async throws -> String {
        keyPair.publicKey
    }

    public func signEvent(_ event: NostrEvent) async throws -> NostrEvent {
        try keyPair.signEvent(event)
    }

    public func nip04Encrypt(plaintext: String, peerPublicKey: String) async throws -> String {
        try keyPair.encrypt(message: plaintext, to: peerPublicKey)
    }

    public func nip04Decrypt(ciphertext: String, peerPublicKey: String) async throws -> String {
        try keyPair.decrypt(message: ciphertext, from: peerPublicKey)
    }

    public func nip44Encrypt(plaintext: String, peerPublicKey: String) async throws -> String {
        try keyPair.encryptNIP44(message: plaintext, to: peerPublicKey)
    }

    public func nip44Decrypt(ciphertext: String, peerPublicKey: String) async throws -> String {
        try keyPair.decryptNIP44(payload: ciphertext, from: peerPublicKey)
    }
}

// MARK: - Encryption Scheme

/// The encryption scheme carried by a NIP-46 envelope.
///
/// The current spec is NIP-44; NIP-04 remains in the wild from older clients.
/// A signer answers in the scheme the request used, so legacy clients can
/// decrypt their responses.
public enum NIP46EncryptionScheme: String, Codable, Sendable {
    case nip44
    case nip04

    /// NIP-04 payloads always carry a `?iv=` suffix; NIP-44 payloads are
    /// plain base64 (which can never contain `?`). This makes discrimination
    /// a cheap string check instead of a trial decrypt.
    public static func detect(fromCiphertext content: String) -> NIP46EncryptionScheme {
        content.contains("?iv=") ? .nip04 : .nip44
    }
}

// MARK: - Client Sessions

/// A client application connected to the bunker.
public struct BunkerClientSession: Codable, Sendable, Identifiable, Equatable {
    public var id: String { clientPubkey }

    /// The client's ephemeral public key (hex) used for NIP-46 transport.
    public let clientPubkey: String

    /// Permissions the user granted this client (raw `method[:kind]` strings,
    /// e.g. `"sign_event:1"`, `"nip44_encrypt"`). Only granted permissions
    /// auto-approve; everything else prompts.
    public var grantedPermissions: [String]

    /// Permissions the client asked for (from `connect` params or a
    /// `nostrconnect://` URI). Kept separate from granted so a client can
    /// never grant itself anything.
    public var requestedPermissions: [String]

    /// Client display name, when known (nostrconnect metadata).
    public var name: String?

    /// Client canonical URL, when known.
    public var url: String?

    /// When the client first connected.
    public let connectedAt: Date

    /// Last time the client sent a valid request.
    public var lastActivityAt: Date

    /// The encryption scheme the client most recently used; responses follow it.
    public var preferredScheme: NIP46EncryptionScheme

    public init(
        clientPubkey: String,
        grantedPermissions: [String] = [],
        requestedPermissions: [String] = [],
        name: String? = nil,
        url: String? = nil,
        connectedAt: Date = Date(),
        lastActivityAt: Date = Date(),
        preferredScheme: NIP46EncryptionScheme = .nip44
    ) {
        self.clientPubkey = clientPubkey
        self.grantedPermissions = grantedPermissions
        self.requestedPermissions = requestedPermissions
        self.name = name
        self.url = url
        self.connectedAt = connectedAt
        self.lastActivityAt = lastActivityAt
        self.preferredScheme = preferredScheme
    }

    /// Whether the granted permissions cover `method` (and, for
    /// `sign_event`, the specific event kind).
    public func hasPermission(for method: NIP46.Method, eventKind: Int? = nil) -> Bool {
        switch method {
        case .signEvent:
            if grantedPermissions.contains("sign_event") { return true }
            guard let eventKind else { return false }
            return grantedPermissions.contains("sign_event:\(eventKind)")
        default:
            return grantedPermissions.contains(method.rawValue)
        }
    }
}

/// Persistence for bunker client sessions.
///
/// The bunker keeps sessions in memory and writes through on every change;
/// supply a store backed by your app's persistence so connected clients
/// survive restarts.
public protocol BunkerSessionStore: Sendable {
    func loadSessions() async throws -> [BunkerClientSession]
    func saveSessions(_ sessions: [BunkerClientSession]) async throws
}

/// Ephemeral session store; sessions vanish with the process. Default when no
/// store is supplied.
public actor InMemoryBunkerSessionStore: BunkerSessionStore {
    private var sessions: [BunkerClientSession] = []

    public init() {}

    public func loadSessions() async throws -> [BunkerClientSession] {
        sessions
    }

    public func saveSessions(_ sessions: [BunkerClientSession]) async throws {
        self.sessions = sessions
    }
}

// MARK: - Approval

/// A request awaiting the user's approve/deny decision.
public struct BunkerApprovalRequest: Sendable, Identifiable {
    /// The NIP-46 request id — pass to `BunkerSigner.approve(requestID:)`
    /// or `deny(requestID:)`.
    public let id: String

    /// Requesting client's transport pubkey.
    public let clientPubkey: String

    /// Display name of the client, when known.
    public let clientName: String?

    /// The operation being requested.
    public let method: NIP46.Method

    /// Raw positional parameters from the request.
    public let params: [String]

    /// When the request arrived.
    public let receivedAt: Date

    /// The parsed event to sign — populated only for `sign_event`, so
    /// approval UI can show kind/content/tags without re-parsing.
    public let unsignedEvent: NIP46.UnsignedEvent?
}

// MARK: - Signer Events

/// Events the bunker surfaces to the app (approval prompts, connections,
/// request outcomes). Consume via `BunkerSigner.events`.
public enum BunkerSignerEvent: Sendable {
    /// A new client established a session.
    case clientConnected(BunkerClientSession)

    /// A known client re-established its session.
    case clientReconnected(BunkerClientSession)

    /// A request needs the user's decision. Respond with
    /// `approve(requestID:)` or `deny(requestID:)` before the approval
    /// timeout, or the request auto-denies.
    case approvalRequired(BunkerApprovalRequest)

    /// A request was performed and its response published.
    case requestCompleted(requestID: String, clientPubkey: String, method: NIP46.Method)

    /// The user denied a request.
    case requestDenied(requestID: String, clientPubkey: String)

    /// A pending request hit the approval timeout and was denied.
    case requestTimedOut(BunkerApprovalRequest)

    /// An approved request failed while executing.
    case requestFailed(requestID: String, clientPubkey: String, reason: String)

    /// A response could not be published to any relay after retries. The
    /// client will treat the request as timed out.
    case responsePublishFailed(requestID: String, clientPubkey: String)
}

// MARK: - Configuration

/// Behavior knobs for `BunkerSigner`.
public struct BunkerConfiguration: Sendable {
    /// How `connect` requests are authorized.
    public enum ConnectPolicy: Sendable, Equatable {
        /// Accept a valid unused secret from an issued bunker URI, or a
        /// reconnect from a client with a stored session. Default — matches
        /// how real clients behave (they may re-`connect` on every launch
        /// without re-presenting the secret).
        case secretOrKnownClient

        /// Only a valid unused secret is accepted; even known clients must
        /// present one.
        case secretOnly

        /// Accept every connect. Testing only — never ship this.
        case acceptAny
    }

    /// Relay URLs the bunker listens on.
    public var relays: [String]

    /// Seconds an approval prompt may sit unanswered before the request is
    /// auto-denied with a timeout error.
    public var approvalTimeout: TimeInterval

    /// Maximum age (seconds) of an incoming request event. Older events are
    /// replays or relay backlog and are dropped.
    public var maxEventAge: TimeInterval

    /// Tolerated clock skew (seconds) for events dated in the future.
    public var maxClockSkew: TimeInterval

    /// Whether NIP-04-encrypted requests from legacy clients are accepted.
    public var allowNIP04Requests: Bool

    /// When true, requests covered by a session's granted permissions are
    /// performed without prompting.
    public var autoApproveGrantedPermissions: Bool

    /// When true, `get_public_key` requires an established session; when
    /// false anyone who can reach the signer pubkey learns the user pubkey.
    public var requireSessionForPublicKey: Bool

    /// Connect authorization policy.
    public var connectPolicy: ConnectPolicy

    /// Total attempts to publish a response before reporting failure.
    public var responsePublishAttempts: Int

    public init(
        relays: [String],
        approvalTimeout: TimeInterval = 60,
        maxEventAge: TimeInterval = 300,
        maxClockSkew: TimeInterval = 60,
        allowNIP04Requests: Bool = true,
        autoApproveGrantedPermissions: Bool = true,
        requireSessionForPublicKey: Bool = true,
        connectPolicy: ConnectPolicy = .secretOrKnownClient,
        responsePublishAttempts: Int = 3
    ) {
        self.relays = relays
        self.approvalTimeout = approvalTimeout
        self.maxEventAge = maxEventAge
        self.maxClockSkew = maxClockSkew
        self.allowNIP04Requests = allowNIP04Requests
        self.autoApproveGrantedPermissions = autoApproveGrantedPermissions
        self.requireSessionForPublicKey = requireSessionForPublicKey
        self.connectPolicy = connectPolicy
        self.responsePublishAttempts = responsePublishAttempts
    }
}

// MARK: - Errors

/// Errors thrown by `BunkerSigner`'s public API.
public enum BunkerSignerError: Error, LocalizedError, Sendable, Equatable {
    case notRunning
    case noRelaysConfigured
    case unknownRequest(String)
    case invalidNostrConnectURI
    case serializationFailed
    case publishFailed

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            return "The bunker signer is not running"
        case .noRelaysConfigured:
            return "No relays configured for the bunker signer"
        case .unknownRequest(let id):
            return "No pending request with id \(id)"
        case .invalidNostrConnectURI:
            return "Invalid nostrconnect:// URI"
        case .serializationFailed:
            return "Failed to serialize NIP-46 payload"
        case .publishFailed:
            return "Failed to publish response to any relay"
        }
    }
}

// MARK: - Bounded ID Set

/// Insertion-ordered string set with a size cap: oldest members are evicted
/// first. Used for replay-protection windows (event ids, request ids,
/// consumed secrets) that must not grow without bound in long-lived signers.
struct BoundedIDSet: Sendable {
    private var members: Set<String> = []
    private var order: [String] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Inserts `id`. Returns `true` when it was not already present.
    /// Eviction trims in batches so array compaction amortizes.
    @discardableResult
    mutating func insert(_ id: String) -> Bool {
        guard members.insert(id).inserted else { return false }
        order.append(id)
        if order.count > capacity + 256 {
            let overflow = order.count - capacity
            for evicted in order.prefix(overflow) {
                members.remove(evicted)
            }
            order.removeFirst(overflow)
        }
        return true
    }

    func contains(_ id: String) -> Bool {
        members.contains(id)
    }
}
