# Getting Started with Nostr Wallet Connect

Integrate Lightning payments into your iOS app using the NIP-47 Nostr Wallet Connect protocol.

## Overview

Nostr Wallet Connect (NWC) enables your app to interact with Lightning wallets without managing private keys or running Lightning nodes. This guide walks you through setting up wallet connections and making your first payment.

### What You'll Learn

- How NWC works under the hood
- Setting up `WalletConnectManager`
- Connecting to a Lightning wallet
- Making payments and checking balances
- Best practices for production apps

## Understanding NWC

NWC uses encrypted Nostr events to communicate between your app and a Lightning wallet service. The protocol consists of:

- **Connection URI**: Contains the wallet's public key, relay URL, and a shared secret
- **Encrypted Events**: All communication uses NIP-44 encryption (or NIP-04 for legacy wallets)
- **Request/Response**: Async communication through Nostr relays

```
nostr+walletconnect://[wallet-pubkey]?relay=[relay-url]&secret=[shared-secret]
```

### Supported Operations

NWC supports these wallet operations (NIP-47):

| Method | Description |
|--------|-------------|
| `pay_invoice` | Pay a Lightning invoice |
| `make_invoice` | Create an invoice to receive payments |
| `get_balance` | Query wallet balance |
| `list_transactions` | Get transaction history |
| `pay_keysend` | Send payment directly to a node |
| `lookup_invoice` | Check invoice status |
| `get_info` | Get wallet/node information |
| `multi_pay_invoice` | Pay multiple invoices in batch |
| `multi_pay_keysend` | Send multiple keysends in batch |

## Setting Up WalletConnectManager

### Basic Setup

Add `WalletConnectManager` to your SwiftUI app:

```swift
import SwiftUI
import NostrKit

@main
struct MyApp: App {
    @StateObject private var walletManager = WalletConnectManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(walletManager)
        }
    }
}
```

### Configuration Options

Customize the manager with rate limiting:

```swift
// Limit to 30 requests per minute (default)
let walletManager = WalletConnectManager(maxRequestsPerMinute: 30)

// Higher limit for power users
let powerUserManager = WalletConnectManager(maxRequestsPerMinute: 60)
```

## Connecting to a Wallet

### Parse and Connect

Connect using a NWC URI from your wallet provider:

```swift
struct ConnectWalletView: View {
    @EnvironmentObject var walletManager: WalletConnectManager
    @State private var connectionURI = ""
    @State private var isConnecting = false
    @State private var error: Error?
    
    var body: some View {
        VStack(spacing: 20) {
            TextField("Paste NWC URI", text: $connectionURI)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
            
            Button("Connect Wallet") {
                Task { await connect() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(connectionURI.isEmpty || isConnecting)
            
            if isConnecting {
                ProgressView("Connecting...")
            }
            
            if let error = error {
                Text(error.localizedDescription)
                    .foregroundColor(.red)
            }
        }
        .padding()
    }
    
    func connect() async {
        isConnecting = true
        error = nil
        
        do {
            try await walletManager.connect(
                uri: connectionURI,
                alias: "My Lightning Wallet"
            )
            // Success! Wallet is now connected
        } catch {
            self.error = error
        }
        
        isConnecting = false
    }
}
```

### Connection State

Monitor connection status in your UI:

```swift
struct ConnectionStatusView: View {
    @EnvironmentObject var walletManager: WalletConnectManager
    
    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
            
            Text(statusText)
                .font(.subheadline)
        }
    }
    
    var statusColor: Color {
        switch walletManager.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        case .failed: return .red
        }
    }
    
    var statusText: String {
        switch walletManager.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .disconnected: return "Disconnected"
        case .failed(let error): return "Error: \(error.localizedDescription)"
        }
    }
}
```

## Making Payments

### Pay an Invoice

```swift
func payInvoice(_ invoice: String) async throws {
    let result = try await walletManager.payInvoice(invoice)
    
    print("Payment successful!")
    print("Preimage: \(result.preimage)")
    
    if let fees = result.feesPaid {
        print("Fees paid: \(fees) millisats")
    }
}
```

### Check Balance

```swift
func checkBalance() async throws -> Int64 {
    let balanceMillisats = try await walletManager.getBalance()
    let balanceSats = balanceMillisats / 1000
    print("Balance: \(balanceSats) sats")
    return balanceMillisats
}
```

### Create an Invoice

```swift
func createInvoice(amountSats: Int64, memo: String) async throws -> String {
    let amountMillisats = amountSats * 1000
    
    let invoice = try await walletManager.makeInvoice(
        amount: amountMillisats,
        description: memo,
        expiry: 3600 // 1 hour
    )
    
    return invoice
}
```

### Send Keysend

Send a payment without an invoice:

```swift
func sendKeysend(to nodePubkey: String, amountSats: Int64) async throws {
    let result = try await walletManager.payKeysend(
        amount: amountSats * 1000,
        pubkey: nodePubkey
    )
    
    print("Keysend successful! Preimage: \(result.preimage)")
}
```

## Checking Wallet Capabilities

Not all wallets support all methods. Check before calling:

```swift
// Check individual methods
if walletManager.supportsMethod(.payInvoice) {
    // Show payment UI
}

if walletManager.supportsMethod(.makeInvoice) {
    // Show receive UI
}

if walletManager.supportsMethod(.getBalance) {
    // Show balance widget
}

// Check for notifications support
if walletManager.supportsNotifications {
    // Wallet will notify about incoming payments
}

// Check preferred encryption
let encryption = walletManager.preferredEncryption
// .nip44 (recommended) or .nip04 (legacy)
```

## Managing Multiple Wallets

### Store Multiple Connections

```swift
// Connect multiple wallets
try await walletManager.connect(uri: albyURI, alias: "Alby")
try await walletManager.connect(uri: mutinyURI, alias: "Mutiny")

// List all connections
for connection in walletManager.connections {
    print("\(connection.alias ?? "Unnamed"): \(connection.id)")
}

// Switch active wallet
try await walletManager.switchConnection(to: connection)

// Remove a wallet
await walletManager.removeConnection(connection)
```

### Display Wallet Picker

```swift
struct WalletPickerView: View {
    @EnvironmentObject var walletManager: WalletConnectManager
    
    var body: some View {
        List(walletManager.connections) { connection in
            HStack {
                VStack(alignment: .leading) {
                    Text(connection.alias ?? "Lightning Wallet")
                        .font(.headline)
                    Text(String(connection.uri.walletPubkey.prefix(16)) + "...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if connection.id == walletManager.activeConnection?.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                Task {
                    try? await walletManager.switchConnection(to: connection)
                }
            }
        }
    }
}
```

## Automatic Reconnection

WalletConnectManager includes automatic reconnection with exponential backoff:

```swift
// Enable/disable auto-reconnection (enabled by default)
walletManager.setAutoReconnect(enabled: true)

// Manually trigger reconnection
try await walletManager.reconnect()

// Cancel pending reconnection attempts
walletManager.cancelReconnection()

// Handle connection loss (called automatically)
walletManager.handleConnectionLost()
```

The reconnection strategy:
- Base delay: 1 second
- Maximum delay: 5 minutes
- Maximum attempts: 10
- Includes jitter to prevent thundering herd

## Best Practices

### 1. Always Check Connection State

```swift
guard case .connected = walletManager.connectionState else {
    throw MyError.walletNotConnected
}
```

### 2. Handle Rate Limiting

```swift
do {
    let result = try await walletManager.payInvoice(invoice)
} catch let error as NWCError where error.code == .rateLimited {
    // Wait and retry
    try await Task.sleep(nanoseconds: 60_000_000_000)
    // Retry...
}
```

### 3. Verify Amounts Before Payment

```swift
// Check balance before large payments
let balance = try await walletManager.getBalance()
let invoiceAmount: Int64 = 100_000_000 // 100k sats

guard balance >= invoiceAmount else {
    throw MyError.insufficientBalance
}
```

### 4. Use Confirmation for Large Amounts

```swift
func payWithConfirmation(_ invoice: String, amount: Int64) async throws {
    if amount > 10_000_000 { // > 10k sats
        // Show confirmation dialog
        guard await showConfirmation(amount: amount) else {
            return
        }
    }
    
    try await walletManager.payInvoice(invoice)
}
```

## Where to Get NWC URIs

Users can get NWC connection URIs from these wallet providers:

| Wallet | Type | URL |
|--------|------|-----|
| Alby | Browser extension | [getalby.com](https://getalby.com) |
| Mutiny | Self-custodial | [mutinywallet.com](https://mutinywallet.com) |
| Umbrel | Node | [umbrel.com](https://umbrel.com) |
| Start9 | Node | [start9.com](https://start9.com) |

## Next Steps

- Learn about <doc:HandlingPaymentErrors> for robust error handling
- Explore ``WalletConnectManager`` API reference
- See the NIP-47 specification for protocol details

## See Also

- ``WalletConnectManager``
- ``NWCConnectionURI``
- ``NWCError``
- ``PaymentResult``
