import Testing
import Foundation
import CoreNostr
@testable import NostrKit

@MainActor
@Suite("NIP-47 WalletConnectManager Integration (mocked relays)")
struct NIP47IntegrationTests {
    
    actor InMemoryWalletStorage: WalletStorage {
        private var store: [String: Data] = [:]
        
        func store(_ data: Data, forKey key: String) async throws {
            self.store[key] = data
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
    
    private func makeConnections(walletPubkey: String, clientSecret: String) -> WalletConnectManager.WalletConnection {
        let uri = NWCConnectionURI(
            walletPubkey: walletPubkey,
            relays: ["wss://relay.test"],
            secret: clientSecret
        )
        
        var connection = WalletConnectManager.WalletConnection(
            uri: uri,
            alias: "Test Wallet"
        )
        
        connection.capabilities = NWCInfo(
            methods: [.payInvoice, .multiPayInvoice, .makeInvoice, .getBalance, .listTransactions],
            notifications: [.paymentReceived],
            encryptionSchemes: [.nip44]
        )
        return connection
    }
    
    @Test("Happy path payInvoice handles response and decrypts payload")
    func testPayInvoiceHappyPath() async throws {
        let walletKeyPair = try KeyPair.generate()
        let clientKeyPair = try KeyPair.generate()
        
        let mockPool = MockRelayPool()
        let storage = InMemoryWalletStorage()
        
        await mockPool.setResponseFactory { request in
            // Only respond to NWC requests
            guard request.kind == EventKind.nwcRequest.rawValue else { return nil }
            return try? NostrEvent.nwcResponse(
                requestId: request.id,
                resultType: "pay_invoice",
                result: [
                    "preimage": AnyCodable("deadbeef"),
                    "fees_paid": AnyCodable(Int64(123))
                ],
                clientPubkey: clientKeyPair.publicKey,
                walletSecret: walletKeyPair.privateKey,
                encryption: .nip44
            )
        }
        
        let connection = makeConnections(walletPubkey: walletKeyPair.publicKey, clientSecret: clientKeyPair.privateKey)
        let manager = WalletConnectManager(
            relayPool: mockPool,
            keychain: storage,
            seedConnections: [connection],
            activeConnectionId: connection.id,
            maxRequestsPerMinute: 10
        )
        
        try await manager.reconnect()
        
        let result = try await manager.payInvoice("lnbc10u1p0placeholder")
        #expect(result.preimage == "deadbeef")
        #expect(result.feesPaid == 123)
        #expect(manager.balance == nil) // payInvoice does not update balance by itself

        // The request must carry a NIP-47 expiration tag matching the wait window,
        // so the wallet ignores requests the client already timed out on.
        let published = await mockPool.publishedEvents
        let expirationTag = published.first?.tags.first { $0.count >= 2 && $0[0] == "expiration" }
        #expect(expirationTag != nil, "Requests must carry an expiration tag")
        if let value = expirationTag?[1], let timestamp = TimeInterval(value) {
            let secondsFromNow = timestamp - Date().timeIntervalSince1970
            #expect(secondsFromNow > 30 && secondsFromNow < 120,
                    "Expiration should match the 60s response-wait window")
        }
    }
    
    @Test("listTransactions skips un-decodable transactions gracefully")
    func testListTransactionsSkipsBadEntries() async throws {
        let walletKeyPair = try KeyPair.generate()
        let clientKeyPair = try KeyPair.generate()

        let mockPool = MockRelayPool()
        let storage = InMemoryWalletStorage()

        await mockPool.setResponseFactory { request in
            guard request.kind == EventKind.nwcRequest.rawValue else { return nil }

            let validTx: [String: Any] = [
                "type": "incoming",
                "state": "settled",
                "payment_hash": "abc123",
                "amount": 50000,
                "created_at": 1693876973
            ]

            // Malformed: missing required non-optional fields (amount, created_at)
            let malformedTx: [String: Any] = [
                "type": "incoming",
                "payment_hash": "def456"
            ]

            return try? NostrEvent.nwcResponse(
                requestId: request.id,
                resultType: "list_transactions",
                result: [
                    "transactions": AnyCodable([validTx, malformedTx] as [[String: Any]])
                ],
                clientPubkey: clientKeyPair.publicKey,
                walletSecret: walletKeyPair.privateKey,
                encryption: .nip44
            )
        }

        let connection = makeConnections(walletPubkey: walletKeyPair.publicKey, clientSecret: clientKeyPair.privateKey)
        let manager = WalletConnectManager(
            relayPool: mockPool,
            keychain: storage,
            seedConnections: [connection],
            activeConnectionId: connection.id,
            maxRequestsPerMinute: 10
        )

        try await manager.reconnect()

        let transactions = try await manager.listTransactions()
        #expect(transactions.count == 1)
        #expect(transactions[0].paymentHash == "abc123")
        #expect(transactions[0].amount == 50000)
    }

    @Test("Rate limiting prevents rapid repeated requests")
    func testRateLimit() async throws {
        let walletKeyPair = try KeyPair.generate()
        let clientKeyPair = try KeyPair.generate()
        
        let mockPool = MockRelayPool()
        let storage = InMemoryWalletStorage()
        await mockPool.setResponseFactory { request in
            try? NostrEvent.nwcResponse(
                requestId: request.id,
                resultType: "pay_invoice",
                result: ["preimage": AnyCodable("p1")],
                clientPubkey: clientKeyPair.publicKey,
                walletSecret: walletKeyPair.privateKey,
                encryption: .nip44
            )
        }
        
        let connection = makeConnections(walletPubkey: walletKeyPair.publicKey, clientSecret: clientKeyPair.privateKey)
        let manager = WalletConnectManager(
            relayPool: mockPool,
            keychain: storage,
            seedConnections: [connection],
            activeConnectionId: connection.id,
            maxRequestsPerMinute: 1
        )
        
        try await manager.reconnect()
        
        _ = try await manager.payInvoice("lnbc10u1p0placeholder")

        await #expect(throws: NWCError.self) {
            _ = try await manager.payInvoice("lnbc10u1p0placeholder")
        }
    }

    @Test("multiPayInvoice returns partial results at the deadline instead of hanging")
    func testMultiPayPartialResponses() async throws {
        let walletKeyPair = try KeyPair.generate()
        let clientKeyPair = try KeyPair.generate()

        let mockPool = MockRelayPool()
        let storage = InMemoryWalletStorage()

        // The wallet answers only ONE of the two invoices in the batch.
        await mockPool.setResponseFactory { request in
            guard request.kind == EventKind.nwcRequest.rawValue else { return nil }
            return try? NostrEvent.nwcResponse(
                requestId: request.id,
                resultType: "multi_pay_invoice",
                result: ["preimage": AnyCodable("aaaa")],
                clientPubkey: clientKeyPair.publicKey,
                walletSecret: walletKeyPair.privateKey,
                encryption: .nip44
            )
        }

        let connection = makeConnections(walletPubkey: walletKeyPair.publicKey, clientSecret: clientKeyPair.privateKey)
        let manager = WalletConnectManager(
            relayPool: mockPool,
            keychain: storage,
            seedConnections: [connection],
            activeConnectionId: connection.id,
            maxRequestsPerMinute: 10
        )
        manager.batchResponseTimeoutNanoseconds = 300_000_000 // 0.3s deadline for the test

        try await manager.reconnect()

        let start = Date()
        let results = try await manager.multiPayInvoice([
            WalletConnectManager.BatchInvoice(id: "a", invoice: "lnbc1"),
            WalletConnectManager.BatchInvoice(id: "b", invoice: "lnbc2")
        ])
        let elapsed = Date().timeIntervalSince(start)

        #expect(results.count == 1, "The one response that arrived must be surfaced")
        #expect(results.first?.isSuccess == true)
        #expect(elapsed < 5.0, "Batch collection must end at the deadline, not hang")
    }

    @Test("Notification subscription listens to exactly one kind and doesn't leak on reconnect")
    func testNotificationSubscriptionKindAndNoLeak() async throws {
        let walletKeyPair = try KeyPair.generate()
        let clientKeyPair = try KeyPair.generate()

        let mockPool = MockRelayPool()
        let storage = InMemoryWalletStorage()

        let connection = makeConnections(walletPubkey: walletKeyPair.publicKey, clientSecret: clientKeyPair.privateKey)
        let manager = WalletConnectManager(
            relayPool: mockPool,
            keychain: storage,
            seedConnections: [connection],
            activeConnectionId: connection.id,
            maxRequestsPerMinute: 10
        )

        try await manager.reconnect()
        try await manager.reconnect()

        // Stale notification subscriptions must be closed on re-subscribe.
        let count = await mockPool.activeSubscriptionCount()
        #expect(count == 1, "Repeated reconnects must not leak notification subscriptions")

        // A nip44-capable wallet publishes each notification as both kind 23197
        // (nip44) and 23196 (nip04 legacy); listening to both would double-fire.
        let filters = await mockPool.activeSubscriptionFilters().flatMap { $0 }
        let notificationFilter = filters.first { ($0.kinds ?? []).contains(EventKind.nwcNotification.rawValue) }
        #expect(notificationFilter != nil)
        #expect(notificationFilter?.kinds == [EventKind.nwcNotification.rawValue],
                "Must subscribe to the nip44 notification kind only")
    }

    @Test("payInvoice skips junk response events and accepts the authentic one")
    func testPayInvoiceSkipsForgedResponses() async throws {
        let walletKeyPair = try KeyPair.generate()
        let clientKeyPair = try KeyPair.generate()

        let mockPool = MockRelayPool()
        let storage = InMemoryWalletStorage()

        // First deliver a forged response: right pubkey/kind/e-tag, but no valid
        // signature and undecryptable content. The real, signed response follows.
        await mockPool.setResponseFactory { request in
            guard request.kind == EventKind.nwcRequest.rawValue else { return nil }

            let real = try? NostrEvent.nwcResponse(
                requestId: request.id,
                resultType: "pay_invoice",
                result: ["preimage": AnyCodable("realpreimage")],
                clientPubkey: clientKeyPair.publicKey,
                walletSecret: walletKeyPair.privateKey,
                encryption: .nip44
            )
            if let real {
                Task {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    await mockPool.yieldToMatchingSubscriptions(real)
                }
            }

            // Unsigned junk that a malicious relay could inject
            return NostrEvent(
                pubkey: walletKeyPair.publicKey,
                createdAt: Date(),
                kind: EventKind.nwcResponse.rawValue,
                tags: [["p", clientKeyPair.publicKey], ["e", request.id]],
                content: "not-a-valid-ciphertext"
            )
        }

        let connection = makeConnections(walletPubkey: walletKeyPair.publicKey, clientSecret: clientKeyPair.privateKey)
        let manager = WalletConnectManager(
            relayPool: mockPool,
            keychain: storage,
            seedConnections: [connection],
            activeConnectionId: connection.id,
            maxRequestsPerMinute: 10
        )

        try await manager.reconnect()

        let result = try await manager.payInvoice("lnbc10u1p0placeholder")
        #expect(result.preimage == "realpreimage", "The forged event must be skipped, not returned or fatal")
    }

    @Test("Notifications carry payment details and refresh state without consuming rate-limit tokens")
    func testNotificationPayloadAndTokenFreeRefresh() async throws {
        let walletKeyPair = try KeyPair.generate()
        let clientKeyPair = try KeyPair.generate()

        let mockPool = MockRelayPool()
        let storage = InMemoryWalletStorage()

        // A wallet mock that decrypts each request and answers by method.
        await mockPool.setResponseFactory { request in
            guard request.kind == EventKind.nwcRequest.rawValue,
                  let content = try? request.decryptNWCContent(
                    with: walletKeyPair.privateKey,
                    peerPubkey: clientKeyPair.publicKey
                  ),
                  let decoded = try? JSONDecoder().decode(NWCRequest.self, from: Data(content.utf8)) else {
                return nil
            }

            switch decoded.method {
            case .payInvoice:
                return try? NostrEvent.nwcResponse(
                    requestId: request.id,
                    resultType: "pay_invoice",
                    result: ["preimage": AnyCodable("p1")],
                    clientPubkey: clientKeyPair.publicKey,
                    walletSecret: walletKeyPair.privateKey,
                    encryption: .nip44
                )
            case .getBalance:
                return try? NostrEvent.nwcResponse(
                    requestId: request.id,
                    resultType: "get_balance",
                    result: ["balance": AnyCodable(Int64(42_000))],
                    clientPubkey: clientKeyPair.publicKey,
                    walletSecret: walletKeyPair.privateKey,
                    encryption: .nip44
                )
            case .listTransactions:
                let tx: [String: Any] = [
                    "type": "incoming",
                    "amount": 2_500,
                    "created_at": 1_700_000_000,
                    "payment_hash": "hash-1"
                ]
                return try? NostrEvent.nwcResponse(
                    requestId: request.id,
                    resultType: "list_transactions",
                    result: ["transactions": AnyCodable([tx] as [[String: Any]])],
                    clientPubkey: clientKeyPair.publicKey,
                    walletSecret: walletKeyPair.privateKey,
                    encryption: .nip44
                )
            default:
                return nil
            }
        }

        let connection = makeConnections(walletPubkey: walletKeyPair.publicKey, clientSecret: clientKeyPair.privateKey)
        let manager = WalletConnectManager(
            relayPool: mockPool,
            keychain: storage,
            seedConnections: [connection],
            activeConnectionId: connection.id,
            maxRequestsPerMinute: 1 // a single token for the whole test
        )

        try await manager.reconnect()

        // Consume the only rate-limit token with a user-initiated payment.
        _ = try await manager.payInvoice("lnbc10u1p0placeholder")

        // Subscribe to wallet events before the notification arrives.
        let stream = manager.events
        let eventTask = Task { () -> NWCEvent? in
            for await event in stream { return event }
            return nil
        }

        // Wallet publishes a payment_received notification (kind 23197).
        let notificationEvent = try NostrEvent.nwcNotification(
            type: .paymentReceived,
            notification: [
                "type": AnyCodable("incoming"),
                "amount": AnyCodable(Int64(2_500)),
                "payment_hash": AnyCodable("hash-1"),
                "preimage": AnyCodable("pre-1"),
                "settled_at": AnyCodable(Int64(1_700_000_100))
            ],
            clientPubkey: clientKeyPair.publicKey,
            walletSecret: walletKeyPair.privateKey,
            encryption: .nip44
        )
        await mockPool.yieldToMatchingSubscriptions(notificationEvent)

        // Await the broadcast event, bounded so a regression can't hang the suite.
        let received = await withTaskGroup(of: NWCEvent?.self) { group in
            group.addTask { await eventTask.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        eventTask.cancel()

        guard case .paymentReceived(let payment) = received else {
            Issue.record("Expected a paymentReceived event, got \(String(describing: received))")
            return
        }

        // The event carries the notification payload.
        #expect(payment.type == .incoming)
        #expect(payment.amount == 2_500)
        #expect(payment.paymentHash == "hash-1")
        #expect(payment.preimage == "pre-1")
        #expect(payment.settledAt == Date(timeIntervalSince1970: 1_700_000_100))

        // State was refreshed even though the rate limiter is empty —
        // notification refreshes must not consume user-facing tokens.
        #expect(manager.balance == 42_000)
        #expect(manager.recentTransactions.count == 1)

        // User-initiated calls are still rate limited.
        await #expect(throws: NWCError.self) {
            _ = try await manager.getBalance()
        }
    }

    @Test("connect adopts a re-paired URI with a rotated secret for the same wallet")
    func testConnectAdoptsRotatedSecret() async throws {
        let walletKeyPair = try KeyPair.generate()
        let oldClientKeyPair = try KeyPair.generate()
        let newClientKeyPair = try KeyPair.generate()

        let mockPool = MockRelayPool()
        let storage = InMemoryWalletStorage()

        // Serve a signed info event so capability fetching succeeds quickly.
        let infoEvent = try NostrEvent.nwcInfo(
            methods: [.payInvoice, .getBalance],
            notifications: [],
            encryptionSchemes: [.nip44],
            pubkey: walletKeyPair.publicKey,
            privkey: walletKeyPair.privateKey
        )
        await mockPool.setMockEvents([infoEvent])

        let connection = makeConnections(walletPubkey: walletKeyPair.publicKey, clientSecret: oldClientKeyPair.privateKey)
        let manager = WalletConnectManager(
            relayPool: mockPool,
            keychain: storage,
            seedConnections: [connection],
            activeConnectionId: connection.id,
            maxRequestsPerMinute: 10
        )

        let rotatedURI = "nostr+walletconnect://\(walletKeyPair.publicKey)?relay=wss://relay.test&secret=\(newClientKeyPair.privateKey)"
        try await manager.connect(uri: rotatedURI)

        #expect(manager.connections.count == 1, "Re-pairing must not duplicate the connection")
        #expect(manager.activeConnection?.uri.secret == newClientKeyPair.privateKey,
                "The rotated secret from the fresh URI must replace the stale one")
        #expect(manager.activeConnection?.capabilities?.methods.contains(.getBalance) == true)
    }
}
