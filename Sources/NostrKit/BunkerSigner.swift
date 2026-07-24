//
//  BunkerSigner.swift
//  NostrKit
//
//  NIP-46: Nostr Remote Signing — the signer ("bunker") side.
//  https://github.com/nostr-protocol/nips/blob/master/46.md
//

import Foundation
import CoreNostr

/// A NIP-46 remote signer ("bunker").
///
/// `BunkerSigner` is the counterpart to ``RemoteSignerManager``: where that
/// class lets an app *ask* a remote signer for signatures, this actor *is*
/// the remote signer. It listens for kind 24133 requests on the configured
/// relays, validates and decrypts them, auto-answers protocol plumbing
/// (`connect`, `ping`, `get_public_key`), and routes signing/encryption
/// operations through an approval flow the host app drives.
///
/// ## Responsibilities split
/// - **This actor**: transport, protocol correctness, replay protection,
///   secret lifecycle, sessions/permissions, response encryption.
/// - **The host app**: key custody (via ``NIP46KeyProvider``), the approval
///   UI (consume ``events``, call ``approve(requestID:)``/``deny(requestID:)``),
///   and session persistence (via ``BunkerSessionStore``).
///
/// ## Example
/// ```swift
/// let signer = BunkerSigner(
///     configuration: BunkerConfiguration(relays: ["wss://relay.nsec.app"]),
///     signerKeys: myKeyService
/// )
/// try await signer.start()
///
/// let uri = try await signer.makeBunkerURI() // show as QR code
///
/// for await event in signer.events {
///     if case .approvalRequired(let request) = event {
///         // present UI, then:
///         try await signer.approve(requestID: request.id)
///     }
/// }
/// ```
public actor BunkerSigner {

    // MARK: - Dependencies

    /// Behavior configuration.
    public let configuration: BunkerConfiguration

    private let signerKeys: any NIP46KeyProvider
    private let userKeys: any NIP46KeyProvider
    private let sessionStore: any BunkerSessionStore
    private let pool: any WalletRelayPool

    /// Set when the pool is a concrete `RelayPool`, so NIP-42 auth can be
    /// installed with the signer identity.
    private let concretePool: RelayPool?

    // MARK: - State

    private var running = false
    private var consumeTask: Task<Void, Never>?
    private var requestSubscriptionID: String?

    private var sessions: [String: BunkerClientSession] = [:]

    /// Secrets embedded in issued bunker URIs, awaiting their single use.
    private var issuedSecrets: Set<String> = []

    /// Secrets already consumed by a successful connect. Per spec, further
    /// connect attempts with these are ignored outright.
    private var consumedSecrets = BoundedIDSet(capacity: 512)

    /// Replay protection across subscription restarts (the pool-level
    /// dedup window is bounded too, so both layers matter for a signer
    /// that runs for days).
    private var processedEventIDs = BoundedIDSet(capacity: 2048)
    private var processedRequestIDs = BoundedIDSet(capacity: 2048)

    private struct PendingApproval: Sendable {
        let request: BunkerApprovalRequest
        let scheme: NIP46EncryptionScheme
    }

    private var pendingApprovals: [String: PendingApproval] = [:]
    private var approvalTimeoutTasks: [String: Task<Void, Never>] = [:]

    private let eventSubject = AsyncStream<BunkerSignerEvent>.makeStream()

    /// Stream of signer events for the host app (single consumer).
    public nonisolated var events: AsyncStream<BunkerSignerEvent> {
        eventSubject.stream
    }

    // MARK: - Initialization

    /// Creates a bunker signer.
    ///
    /// - Parameters:
    ///   - configuration: Relays and behavior knobs.
    ///   - signerKeys: Identity that encrypts/signs the NIP-46 transport.
    ///   - userKeys: Identity that signs `sign_event` payloads and performs
    ///     third-party encryption. Defaults to `signerKeys` (the common
    ///     same-key setup).
    ///   - sessionStore: Persistence for client sessions. Defaults to
    ///     in-memory (sessions lost on restart).
    ///   - pool: The relay pool to ride on. A dedicated pool is created by
    ///     default; pass your own to share connections.
    public init(
        configuration: BunkerConfiguration,
        signerKeys: any NIP46KeyProvider,
        userKeys: (any NIP46KeyProvider)? = nil,
        sessionStore: (any BunkerSessionStore)? = nil,
        pool: RelayPool = RelayPool()
    ) {
        self.configuration = configuration
        self.signerKeys = signerKeys
        self.userKeys = userKeys ?? signerKeys
        self.sessionStore = sessionStore ?? InMemoryBunkerSessionStore()
        self.pool = pool
        self.concretePool = pool
    }

    /// Test seam: run the signer over any `WalletRelayPool` conformance
    /// (e.g. an in-memory relay bus).
    init(
        configuration: BunkerConfiguration,
        signerKeys: any NIP46KeyProvider,
        userKeys: (any NIP46KeyProvider)? = nil,
        sessionStore: (any BunkerSessionStore)? = nil,
        relayPool: any WalletRelayPool
    ) {
        self.configuration = configuration
        self.signerKeys = signerKeys
        self.userKeys = userKeys ?? signerKeys
        self.sessionStore = sessionStore ?? InMemoryBunkerSessionStore()
        self.pool = relayPool
        self.concretePool = relayPool as? RelayPool
    }

    deinit {
        // All state touched here is Sendable, so a nonisolated deinit may
        // read it (`isolated deinit` would need a macOS 15.4 floor).
        consumeTask?.cancel()
        for task in approvalTimeoutTasks.values {
            task.cancel()
        }
        eventSubject.continuation.finish()
    }

    // MARK: - Lifecycle

    /// Starts the bunker: loads stored sessions, connects to the configured
    /// relays, installs NIP-42 auth with the signer identity, and begins
    /// listening for requests.
    ///
    /// Safe to call while offline — the subscription attaches as relays come
    /// up and survives reconnects.
    public func start() async throws {
        guard !running else { return }
        guard !configuration.relays.isEmpty else {
            throw BunkerSignerError.noRelaysConfigured
        }

        let signerPubkey = try await signerKeys.publicKey()

        if let stored = try? await sessionStore.loadSessions() {
            sessions = Dictionary(stored.map { ($0.clientPubkey, $0) }, uniquingKeysWith: { _, newest in newest })
        }

        await installAuthenticator()

        for relay in configuration.relays {
            do {
                try await pool.addRelay(url: relay)
            } catch {
                nip46Logger.warning("Skipping invalid bunker relay \(relay): \(error.localizedDescription)")
            }
        }
        await pool.connectAll()

        running = true
        startConsumeLoop(signerPubkey: signerPubkey)

        nip46Logger.info("Bunker signer started", metadata: LogMetadata([
            "signer": signerPubkey.prefix(8).description,
            "relays": String(configuration.relays.count),
            "sessions": String(sessions.count)
        ]))
    }

    /// Stops the bunker: pending approvals are denied with an error response
    /// (so clients fail fast instead of timing out), the subscription closes,
    /// and relays disconnect.
    public func stop() async {
        guard running else { return }
        running = false

        consumeTask?.cancel()
        consumeTask = nil

        for task in approvalTimeoutTasks.values {
            task.cancel()
        }
        approvalTimeoutTasks.removeAll()

        // Answer before tearing the relays down.
        let pending = pendingApprovals
        pendingApprovals.removeAll()
        for (id, approval) in pending {
            await sendResponse(
                .failure(id: id, error: "signer stopped"),
                to: approval.request.clientPubkey,
                scheme: approval.scheme
            )
        }

        if let requestSubscriptionID {
            await pool.closeSubscription(id: requestSubscriptionID)
            self.requestSubscriptionID = nil
        }

        await pool.disconnectAll()
        nip46Logger.info("Bunker signer stopped")
    }

    // MARK: - Connection URIs

    /// Issues a `bunker://` URI containing a fresh single-use secret.
    ///
    /// Display it as a QR code / copyable string. The embedded secret
    /// authorizes exactly one successful `connect`; further attempts reusing
    /// it are ignored per spec. Call again for each new client you want to
    /// let in.
    public func makeBunkerURI() async throws -> String {
        let signerPubkey = try await signerKeys.publicKey()
        let secret = Self.generateSecret()
        issuedSecrets.insert(secret)

        var components = URLComponents()
        components.scheme = "bunker"
        components.host = signerPubkey
        components.queryItems = configuration.relays.map { URLQueryItem(name: "relay", value: $0) }
            + [URLQueryItem(name: "secret", value: secret)]

        guard let uri = components.string else {
            throw BunkerSignerError.serializationFailed
        }
        return uri
    }

    /// Revokes every issued-but-unused bunker URI secret.
    public func revokeIssuedSecrets() {
        issuedSecrets.removeAll()
    }

    /// Connects to a client that presented a `nostrconnect://` URI (the
    /// client-initiated flow: the user scanned/pasted the client's QR code
    /// into the bunker app).
    ///
    /// Calling this IS the user's consent: the URI's requested permissions
    /// are granted to the session. Present the URI's metadata (name, url,
    /// perms) in your UI and only call this after the user confirms.
    ///
    /// - Returns: The established session.
    @discardableResult
    public func connect(toClient uriString: String) async throws -> BunkerClientSession {
        guard running else { throw BunkerSignerError.notRunning }
        guard let uri = NIP46.NostrConnectURI(from: uriString) else {
            throw BunkerSignerError.invalidNostrConnectURI
        }

        // Listen where the client listens.
        for relay in uri.relays {
            do {
                try await pool.addRelay(url: relay)
            } catch {
                nip46Logger.warning("Skipping invalid nostrconnect relay \(relay): \(error.localizedDescription)")
            }
        }
        await pool.connectAll()

        let permissions = uri.permissions.map { NIP46.parsePermissions($0).map { $0.toString() } } ?? []
        var session = BunkerClientSession(
            clientPubkey: uri.clientPubkey,
            grantedPermissions: permissions,
            requestedPermissions: permissions,
            name: uri.name,
            url: uri.url
        )
        if let existing = sessions[uri.clientPubkey] {
            session.grantedPermissions = Array(Set(existing.grantedPermissions + permissions))
        }
        sessions[uri.clientPubkey] = session
        await persistSessions()

        // Spec: the signer sends a `connect` *response* whose result is the
        // URI secret; the client validates the echo. There is no request, so
        // the response id is fresh.
        await sendResponse(
            .success(id: UUID().uuidString, result: uri.secret),
            to: uri.clientPubkey,
            scheme: .nip44
        )

        emit(.clientConnected(session))
        return session
    }

    // MARK: - Approval Decisions

    /// Approves a pending request: the operation is performed and its
    /// response published to the client.
    ///
    /// - Throws: ``BunkerSignerError/unknownRequest(_:)`` if the id is not
    ///   pending (already decided, timed out, or never existed). Operation
    ///   failures are reported to the client and surfaced via ``events``,
    ///   not thrown.
    public func approve(requestID: String) async throws {
        guard let pending = pendingApprovals.removeValue(forKey: requestID) else {
            throw BunkerSignerError.unknownRequest(requestID)
        }
        cancelApprovalTimeout(for: requestID)
        await perform(pending.request, scheme: pending.scheme)
    }

    /// Denies a pending request; the client receives an error response.
    /// Unknown ids are ignored (the request may have just timed out).
    public func deny(requestID: String) async {
        guard let pending = pendingApprovals.removeValue(forKey: requestID) else { return }
        cancelApprovalTimeout(for: requestID)
        await sendResponse(
            .failure(id: requestID, error: "user rejected the request"),
            to: pending.request.clientPubkey,
            scheme: pending.scheme
        )
        emit(.requestDenied(requestID: requestID, clientPubkey: pending.request.clientPubkey))
    }

    // MARK: - Session Management

    /// All connected client sessions, most recently active first.
    public func activeSessions() -> [BunkerClientSession] {
        sessions.values.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// Replaces the granted permissions for a client.
    public func setGrantedPermissions(_ permissions: [String], forClient clientPubkey: String) async {
        guard var session = sessions[clientPubkey] else { return }
        session.grantedPermissions = permissions
        sessions[clientPubkey] = session
        await persistSessions()
    }

    /// Removes a client session. The client's future requests are refused
    /// until it connects again.
    public func revokeSession(clientPubkey: String) async {
        guard sessions.removeValue(forKey: clientPubkey) != nil else { return }
        await persistSessions()
    }

    // MARK: - Consume Loop

    private func startConsumeLoop(signerPubkey: String) {
        // The weak-self dance is deliberate: holding the actor strongly
        // across the for-await would keep it alive (and un-deinit-able)
        // forever. Strong references are scoped to single suspension points,
        // so dropping the last external reference deallocates the signer and
        // `isolated deinit` cancels this task, ending the iteration.
        consumeTask = Task { [weak self, maxEventAge = configuration.maxEventAge] in
            while true {
                let stream: AsyncStream<NostrEvent>?
                if let self {
                    guard await self.running else { return }
                    stream = await self.openRequestStream(signerPubkey: signerPubkey, maxEventAge: maxEventAge)
                } else {
                    return
                }

                if let stream {
                    for await event in stream {
                        guard let self else { return }
                        guard await self.running else { return }
                        await self.handleIncoming(event)
                    }
                    // The stream ended normally (subscription closed under a
                    // pool teardown). Re-establish almost immediately — every
                    // tick of delay here is a window where client requests
                    // vanish. The tiny sleep only guards against a hot loop
                    // on a pathological pool.
                    guard let self, await self.running else { return }
                    try? await Task.sleep(for: .milliseconds(100))
                } else {
                    // The subscribe itself failed; back off before retrying.
                    guard let self, await self.running else { return }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private func openRequestStream(signerPubkey: String, maxEventAge: TimeInterval) async -> AsyncStream<NostrEvent>? {
        do {
            let filter = Filter(
                kinds: [EventKind.remoteSigningRequest.rawValue],
                since: Date().addingTimeInterval(-maxEventAge),
                p: [signerPubkey]
            )
            let subscriptionID = "nip46-" + String(signerPubkey.prefix(12))
            let subscription = try await pool.walletSubscribe(filters: [filter], id: subscriptionID)
            requestSubscriptionID = subscription.id
            return subscription.events
        } catch {
            nip46Logger.warning("Bunker request subscription failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Request Pipeline

    private func handleIncoming(_ event: NostrEvent) async {
        // 1. Right kind, addressed to us (filter should guarantee both, but
        //    relays are not to be trusted on either).
        guard event.kind == EventKind.remoteSigningRequest.rawValue else { return }

        // 2. Authentic: reject forged envelopes before any crypto.
        guard (try? CoreNostr.verifyEvent(event)) == true else { return }

        // 3. Fresh: stale events are relay backlog or replays.
        let age = Date().timeIntervalSince1970 - Double(event.createdAt)
        guard age < configuration.maxEventAge, age > -configuration.maxClockSkew else { return }

        // 4. Not a duplicate delivery.
        guard processedEventIDs.insert(event.id) else { return }

        // 5. Decrypt with the signer identity, honoring the request's scheme.
        let scheme = NIP46EncryptionScheme.detect(fromCiphertext: event.content)
        if scheme == .nip04 && !configuration.allowNIP04Requests { return }

        let clientPubkey = event.pubkey
        let plaintext: String
        do {
            switch scheme {
            case .nip44:
                plaintext = try await signerKeys.nip44Decrypt(ciphertext: event.content, peerPublicKey: clientPubkey)
            case .nip04:
                plaintext = try await signerKeys.nip04Decrypt(ciphertext: event.content, peerPublicKey: clientPubkey)
            }
        } catch {
            // An envelope we can't read: encrypted to someone else, or noise.
            return
        }

        // 6. Decode the JSON-RPC request. No id → nothing to respond to.
        guard let data = plaintext.data(using: .utf8),
              let request = try? JSONDecoder().decode(NIP46.Request.self, from: data) else {
            nip46Logger.warning("Undecodable NIP-46 request from \(clientPubkey.prefix(8))")
            return
        }

        // 7. Request-id replay protection (bounded window).
        guard processedRequestIDs.insert(request.id) else { return }

        touchSession(clientPubkey, scheme: scheme)

        guard let method = NIP46.Method(rawValue: request.method) else {
            await sendResponse(
                .failure(id: request.id, error: "unsupported method: \(request.method)"),
                to: clientPubkey,
                scheme: scheme
            )
            return
        }

        switch method {
        case .connect:
            await handleConnect(request, from: clientPubkey, scheme: scheme)
        case .getPublicKey:
            await handleGetPublicKey(request, from: clientPubkey, scheme: scheme)
        case .ping:
            await sendResponse(.success(id: request.id, result: "pong"), to: clientPubkey, scheme: scheme)
        case .signEvent, .nip04Encrypt, .nip04Decrypt, .nip44Encrypt, .nip44Decrypt:
            await handleOperation(request, method: method, from: clientPubkey, scheme: scheme)
        }
    }

    // MARK: - Method Handlers

    private func handleConnect(_ request: NIP46.Request, from clientPubkey: String, scheme: NIP46EncryptionScheme) async {
        let secret: String? = request.params.count > 1 && !request.params[1].isEmpty ? request.params[1] : nil

        // Spec: attempts reusing an already-consumed secret are ignored —
        // no response at all.
        if let secret, consumedSecrets.contains(secret) {
            nip46Logger.info("Ignoring connect reusing a consumed secret from \(clientPubkey.prefix(8))")
            return
        }

        let hasValidSecret = secret.map { issuedSecrets.contains($0) } ?? false
        let isKnownClient = sessions[clientPubkey] != nil

        let accepted: Bool
        switch configuration.connectPolicy {
        case .acceptAny:
            accepted = true
        case .secretOnly:
            accepted = hasValidSecret
        case .secretOrKnownClient:
            accepted = hasValidSecret || isKnownClient
        }

        guard accepted else {
            await sendResponse(.failure(id: request.id, error: "unauthorized"), to: clientPubkey, scheme: scheme)
            return
        }

        if let secret, hasValidSecret {
            issuedSecrets.remove(secret)
            consumedSecrets.insert(secret)
        }

        let requested: [String] = request.params.count > 2
            ? NIP46.parsePermissions(request.params[2]).map { $0.toString() }
            : []

        if var existing = sessions[clientPubkey] {
            existing.lastActivityAt = Date()
            existing.preferredScheme = scheme
            if !requested.isEmpty {
                existing.requestedPermissions = requested
            }
            sessions[clientPubkey] = existing
            await persistSessions()
            emit(.clientReconnected(existing))
        } else {
            // Requested permissions are recorded, NOT granted — a client
            // cannot grant itself anything. The user grants via
            // `setGrantedPermissions` (or per-request approval).
            let session = BunkerClientSession(
                clientPubkey: clientPubkey,
                grantedPermissions: [],
                requestedPermissions: requested,
                preferredScheme: scheme
            )
            sessions[clientPubkey] = session
            await persistSessions()
            emit(.clientConnected(session))
        }

        await sendResponse(.success(id: request.id, result: "ack"), to: clientPubkey, scheme: scheme)
    }

    private func handleGetPublicKey(_ request: NIP46.Request, from clientPubkey: String, scheme: NIP46EncryptionScheme) async {
        if configuration.requireSessionForPublicKey && sessions[clientPubkey] == nil {
            await sendResponse(.failure(id: request.id, error: "unauthorized"), to: clientPubkey, scheme: scheme)
            return
        }

        do {
            let userPubkey = try await userKeys.publicKey()
            await sendResponse(.success(id: request.id, result: userPubkey), to: clientPubkey, scheme: scheme)
        } catch {
            await sendResponse(.failure(id: request.id, error: "internal error"), to: clientPubkey, scheme: scheme)
        }
    }

    private func handleOperation(_ request: NIP46.Request, method: NIP46.Method, from clientPubkey: String, scheme: NIP46EncryptionScheme) async {
        guard let session = sessions[clientPubkey] else {
            await sendResponse(.failure(id: request.id, error: "unauthorized"), to: clientPubkey, scheme: scheme)
            return
        }

        // Validate parameters STRICTLY before anything touches user keys —
        // a signer that fills in defaults for malformed requests can be
        // tricked into signing something the user never saw.
        var unsignedEvent: NIP46.UnsignedEvent?
        if method == .signEvent {
            guard let json = request.params.first,
                  let data = json.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(NIP46.UnsignedEvent.self, from: data) else {
                await sendResponse(
                    .failure(id: request.id, error: "invalid sign_event params: expected {kind, content, tags, created_at}"),
                    to: clientPubkey,
                    scheme: scheme
                )
                return
            }
            unsignedEvent = decoded
        } else {
            guard request.params.count >= 2, Self.isHex64(request.params[0]) else {
                await sendResponse(
                    .failure(id: request.id, error: "invalid params: expected [pubkey, payload]"),
                    to: clientPubkey,
                    scheme: scheme
                )
                return
            }
        }

        let approval = BunkerApprovalRequest(
            id: request.id,
            clientPubkey: clientPubkey,
            clientName: session.name,
            method: method,
            params: request.params,
            receivedAt: Date(),
            unsignedEvent: unsignedEvent
        )

        if configuration.autoApproveGrantedPermissions,
           session.hasPermission(for: method, eventKind: unsignedEvent?.kind) {
            await perform(approval, scheme: scheme)
            return
        }

        pendingApprovals[request.id] = PendingApproval(request: approval, scheme: scheme)
        startApprovalTimeout(for: request.id)
        emit(.approvalRequired(approval))
    }

    // MARK: - Operation Execution

    private func perform(_ request: BunkerApprovalRequest, scheme: NIP46EncryptionScheme) async {
        do {
            let result: String
            switch request.method {
            case .signEvent:
                result = try await performSignEvent(request)
            case .nip04Encrypt, .nip04Decrypt, .nip44Encrypt, .nip44Decrypt:
                guard request.params.count >= 2 else {
                    throw BunkerSignerError.unknownRequest(request.id)
                }
                let peer = request.params[0]
                let payload = request.params[1]
                switch request.method {
                case .nip04Encrypt:
                    result = try await userKeys.nip04Encrypt(plaintext: payload, peerPublicKey: peer)
                case .nip04Decrypt:
                    result = try await userKeys.nip04Decrypt(ciphertext: payload, peerPublicKey: peer)
                case .nip44Encrypt:
                    result = try await userKeys.nip44Encrypt(plaintext: payload, peerPublicKey: peer)
                default:
                    result = try await userKeys.nip44Decrypt(ciphertext: payload, peerPublicKey: peer)
                }
            case .connect, .getPublicKey, .ping:
                // Never queued for approval; unreachable by construction.
                throw BunkerSignerError.unknownRequest(request.id)
            }

            touchSession(request.clientPubkey, scheme: scheme)
            await sendResponse(.success(id: request.id, result: result), to: request.clientPubkey, scheme: scheme)
            emit(.requestCompleted(requestID: request.id, clientPubkey: request.clientPubkey, method: request.method))
        } catch {
            await sendResponse(.failure(id: request.id, error: "operation failed"), to: request.clientPubkey, scheme: scheme)
            emit(.requestFailed(requestID: request.id, clientPubkey: request.clientPubkey, reason: error.localizedDescription))
        }
    }

    private func performSignEvent(_ request: BunkerApprovalRequest) async throws -> String {
        guard let unsigned = request.unsignedEvent else {
            throw BunkerSignerError.unknownRequest(request.id)
        }

        let userPubkey = try await userKeys.publicKey()
        let event = NostrEvent(
            pubkey: userPubkey,
            createdAt: Date(timeIntervalSince1970: TimeInterval(unsigned.created_at)),
            kind: unsigned.kind,
            tags: unsigned.tags,
            content: unsigned.content
        )
        let signed = try await userKeys.signEvent(event)

        let data = try JSONEncoder().encode(signed)
        guard let json = String(data: data, encoding: .utf8) else {
            throw BunkerSignerError.serializationFailed
        }
        return json
    }

    // MARK: - Responses

    private func sendResponse(_ response: NIP46.Response, to clientPubkey: String, scheme: NIP46EncryptionScheme) async {
        do {
            let data = try JSONEncoder().encode(response)
            guard let json = String(data: data, encoding: .utf8) else {
                throw BunkerSignerError.serializationFailed
            }

            let ciphertext: String
            switch scheme {
            case .nip44:
                ciphertext = try await signerKeys.nip44Encrypt(plaintext: json, peerPublicKey: clientPubkey)
            case .nip04:
                ciphertext = try await signerKeys.nip04Encrypt(plaintext: json, peerPublicKey: clientPubkey)
            }

            let signerPubkey = try await signerKeys.publicKey()
            let unsigned = NostrEvent(
                pubkey: signerPubkey,
                createdAt: Date(),
                kind: EventKind.remoteSigningRequest.rawValue,
                tags: [["p", clientPubkey]],
                content: ciphertext
            )
            let event = try await signerKeys.signEvent(unsigned)

            try await publishWithRetry(event)
        } catch {
            nip46Logger.error("Failed to send NIP-46 response", error: error)
            emit(.responsePublishFailed(requestID: response.id, clientPubkey: clientPubkey))
        }
    }

    private func publishWithRetry(_ event: NostrEvent) async throws {
        let attempts = max(1, configuration.responsePublishAttempts)
        for attempt in 1...attempts {
            let results = await pool.publish(event)
            if results.contains(where: { $0.success }) { return }
            if attempt < attempts {
                try? await Task.sleep(for: .seconds(Double(attempt)))
            }
        }
        throw BunkerSignerError.publishFailed
    }

    // MARK: - Approval Timeouts

    private func startApprovalTimeout(for requestID: String) {
        approvalTimeoutTasks[requestID] = Task { [weak self, timeout = configuration.approvalTimeout] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.timeoutApproval(requestID)
        }
    }

    private func cancelApprovalTimeout(for requestID: String) {
        approvalTimeoutTasks.removeValue(forKey: requestID)?.cancel()
    }

    private func timeoutApproval(_ requestID: String) async {
        approvalTimeoutTasks.removeValue(forKey: requestID)
        guard let pending = pendingApprovals.removeValue(forKey: requestID) else { return }
        await sendResponse(
            .failure(id: requestID, error: "request timed out"),
            to: pending.request.clientPubkey,
            scheme: pending.scheme
        )
        emit(.requestTimedOut(pending.request))
    }

    // MARK: - Helpers

    private func touchSession(_ clientPubkey: String, scheme: NIP46EncryptionScheme) {
        guard var session = sessions[clientPubkey] else { return }
        session.lastActivityAt = Date()
        session.preferredScheme = scheme
        sessions[clientPubkey] = session
    }

    private func persistSessions() async {
        do {
            try await sessionStore.saveSessions(Array(sessions.values))
        } catch {
            nip46Logger.error("Failed to persist bunker sessions", error: error)
        }
    }

    /// Answers relay AUTH challenges with the signer identity. Several
    /// NIP-46 relays gate kind-24133 REQs behind NIP-42.
    private func installAuthenticator() async {
        guard let concretePool else { return }
        let signerKeys = self.signerKeys
        await concretePool.setAuthenticator { challenge in
            let unsigned = NostrEvent(
                pubkey: try await signerKeys.publicKey(),
                kind: EventKind.clientAuthentication.rawValue,
                tags: [
                    ["relay", challenge.relayURL],
                    ["challenge", challenge.challenge]
                ],
                content: ""
            )
            let signed = try await signerKeys.signEvent(unsigned)
            guard let response = AuthResponse(event: signed, challenge: challenge) else {
                throw AuthenticationError.signingFailed
            }
            return response
        }
    }

    private func emit(_ event: BunkerSignerEvent) {
        eventSubject.continuation.yield(event)
    }

    private static func generateSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    private static func isHex64(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }
}
