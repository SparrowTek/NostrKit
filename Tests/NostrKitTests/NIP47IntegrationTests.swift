import Testing
import CoreNostr
@testable import NostrKit

@MainActor
@Suite("NIP-47 WalletConnectManager Integration (mocked relays)")
struct NIP47IntegrationTests {
    
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
            methods: [.payInvoice, .makeInvoice, .getBalance, .listTransactions],
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
        
        mockPool.setResponseFactory { request in
            // Only respond to NWC requests
            guard request.kind == EventKind.nwcRequest.rawValue else { return nil }
            return try? NostrEvent.nwcResponse(
                requestId: request.id,
                resultType: "pay_invoice",
                result: [
                    "preimage": AnyCodable("deadbeef"),
                    "fees_paid": AnyCodable(123)
                ],
                clientPubkey: clientKeyPair.publicKey,
                walletSecret: clientKeyPair.privateKey,
                encryption: .nip44
            )
        }
        
        let connection = makeConnections(walletPubkey: walletKeyPair.publicKey, clientSecret: clientKeyPair.privateKey)
        let manager = WalletConnectManager(
            relayPool: mockPool,
            keychain: KeychainWrapper(service: "test.nwc"),
            seedConnections: [connection],
            activeConnectionId: connection.id,
            maxRequestsPerMinute: 10
        )
        
        try await manager.reconnect()
        
        let result = try await manager.payInvoice("lnbc10u1p0placeholder")
        #expect(result.preimage == "deadbeef")
        #expect(result.feesPaid == 123)
        #expect(manager.balance == nil) // payInvoice does not update balance by itself
    }
    
    @Test("Rate limiting prevents rapid repeated requests")
    func testRateLimit() async throws {
        let walletKeyPair = try KeyPair.generate()
        let clientKeyPair = try KeyPair.generate()
        
        let mockPool = MockRelayPool()
        mockPool.setResponseFactory { request in
            try? NostrEvent.nwcResponse(
                requestId: request.id,
                resultType: "pay_invoice",
                result: ["preimage": AnyCodable("p1")],
                clientPubkey: clientKeyPair.publicKey,
                walletSecret: clientKeyPair.privateKey,
                encryption: .nip44
            )
        }
        
        let connection = makeConnections(walletPubkey: walletKeyPair.publicKey, clientSecret: clientKeyPair.privateKey)
        let manager = WalletConnectManager(
            relayPool: mockPool,
            keychain: KeychainWrapper(service: "test.nwc"),
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
}
