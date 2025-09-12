# Integrating Nostr Wallet Connect (NIP-47)

Learn how to integrate Lightning wallet functionality into your Nostr app using NIP-47.

## Overview

Nostr Wallet Connect (NIP-47) enables seamless integration between Nostr clients and Lightning wallets. This tutorial will guide you through connecting to a wallet service, managing connections, and performing Lightning transactions.

### What You'll Learn

- How to connect to a Lightning wallet using NWC
- Managing wallet connections securely
- Performing Lightning payments
- Handling payment notifications
- Best practices for wallet integration

## Prerequisites

Before starting, ensure you have:
- NostrKit integrated into your iOS app
- Basic understanding of Lightning Network concepts
- A NWC-compatible wallet (such as Alby, Mutiny, or similar)

## Setting Up Wallet Connect

### Step 1: Create the Manager

First, create an instance of `WalletConnectManager` in your app. This is typically done at the app level or in a view model that persists throughout the user session.

```swift
import NostrKit
import SwiftUI

@MainActor
class AppViewModel: ObservableObject {
    let walletManager = WalletConnectManager()
    
    init() {
        // Manager automatically loads saved connections
    }
}
```

### Step 2: Obtain a Wallet Connection URI

Users need to obtain a connection URI from their wallet provider. This usually involves:

1. Opening their Lightning wallet app or web interface
2. Navigating to the NWC/Nostr Wallet Connect section
3. Creating a new connection with desired permissions
4. Copying the generated `nostr+walletconnect://` URI

The URI contains:
- Wallet service public key
- Relay URLs for communication
- Secret key for encryption
- Optional lightning address (lud16)

### Step 3: Connect to the Wallet

```swift
func connectWallet(uri: String, alias: String? = nil) async {
    do {
        try await walletManager.connect(uri: uri, alias: alias)
        print("Successfully connected to wallet")
        
        // Check wallet capabilities
        if let connection = walletManager.activeConnection,
           let capabilities = connection.capabilities {
            print("Supported methods: \(capabilities.methods)")
            print("Notifications: \(capabilities.notifications)")
        }
    } catch {
        print("Failed to connect: \(error)")
    }
}
```

## Managing Connections

### Storing Multiple Wallets

Users can store multiple wallet connections and switch between them:

```swift
// View all stored connections
var connections: [WalletConnectManager.WalletConnection] {
    walletManager.connections
}

// Switch to a different wallet
func switchWallet(to connection: WalletConnectManager.WalletConnection) async {
    do {
        try await walletManager.switchConnection(to: connection)
    } catch {
        print("Failed to switch wallet: \(error)")
    }
}

// Remove a wallet connection
func removeWallet(_ connection: WalletConnectManager.WalletConnection) async {
    await walletManager.removeConnection(connection)
}
```

### Connection States

Monitor the connection state to update your UI:

```swift
struct WalletStatusView: View {
    @ObservedObject var walletManager: WalletConnectManager
    
    var body: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
            
            Text(statusText)
        }
    }
    
    var statusIcon: String {
        switch walletManager.connectionState {
        case .connected:
            return "checkmark.circle.fill"
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .disconnected:
            return "xmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        }
    }
    
    var statusColor: Color {
        switch walletManager.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .gray
        case .failed:
            return .red
        }
    }
    
    var statusText: String {
        switch walletManager.connectionState {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .disconnected:
            return "Not Connected"
        case .failed(let error):
            return "Error: \(error.localizedDescription)"
        }
    }
}
```

## Performing Transactions

### Paying Lightning Invoices

```swift
func payInvoice(_ invoice: String) async {
    guard walletManager.activeConnection != nil else {
        print("No active wallet connection")
        return
    }
    
    do {
        // Show loading state
        let result = try await walletManager.payInvoice(invoice)
        
        print("Payment successful!")
        print("Preimage: \(result.preimage)")
        if let fees = result.feesPaid {
            print("Fees paid: \(fees) millisats")
        }
        
        // Update UI with success
    } catch let error as NWCError {
        // Handle NWC-specific errors
        switch error.code {
        case .insufficientBalance:
            print("Insufficient balance")
        case .paymentFailed:
            print("Payment failed: \(error.message)")
        case .rateLimited:
            print("Rate limited - try again later")
        default:
            print("Error: \(error.message)")
        }
    } catch {
        print("Unexpected error: \(error)")
    }
}
```

### Creating Invoices

```swift
func createInvoice(amount: Int64, description: String) async {
    do {
        let invoice = try await walletManager.makeInvoice(
            amount: amount,
            description: description,
            expiry: 3600 // 1 hour
        )
        
        // Display invoice to user for payment
        print("Invoice created: \(invoice)")
        
        // You might want to display this as a QR code
        showQRCode(for: invoice)
    } catch {
        print("Failed to create invoice: \(error)")
    }
}
```

### Checking Balance

```swift
func refreshBalance() async {
    do {
        let balanceMillisats = try await walletManager.getBalance()
        
        // Convert to sats for display
        let balanceSats = balanceMillisats / 1000
        print("Balance: \(balanceSats) sats")
        
        // Update UI
    } catch {
        print("Failed to get balance: \(error)")
    }
}
```

### Transaction History

```swift
func loadRecentTransactions() async {
    do {
        let transactions = try await walletManager.listTransactions(
            from: Date().addingTimeInterval(-7 * 24 * 60 * 60), // Last 7 days
            limit: 50
        )
        
        for transaction in transactions {
            print("Transaction: \(transaction.type.rawValue)")
            print("Amount: \(transaction.amount) millisats")
            print("State: \(transaction.state?.rawValue ?? "unknown")")
            
            if let invoice = transaction.invoice {
                print("Invoice: \(invoice)")
            }
        }
    } catch {
        print("Failed to load transactions: \(error)")
    }
}
```

## Handling Notifications

The wallet manager automatically subscribes to payment notifications when connected. You can observe changes:

```swift
struct WalletView: View {
    @ObservedObject var walletManager: WalletConnectManager
    
    var body: some View {
        VStack {
            // Balance updates automatically
            if let balance = walletManager.balance {
                Text("Balance: \(balance / 1000) sats")
            }
            
            // Recent transactions update automatically
            List(walletManager.recentTransactions, id: \.paymentHash) { transaction in
                TransactionRow(transaction: transaction)
            }
        }
        .onReceive(walletManager.$balance) { newBalance in
            if newBalance != nil {
                // Balance updated - possibly from a notification
                print("Balance updated via notification")
            }
        }
    }
}
```

## SwiftUI Integration

### Complete Example View

```swift
struct WalletConnectView: View {
    @StateObject private var walletManager = WalletConnectManager()
    @State private var connectionURI = ""
    @State private var showingConnectSheet = false
    @State private var invoiceToPay = ""
    @State private var isProcessing = false
    
    var body: some View {
        NavigationView {
            VStack {
                // Connection Status
                WalletStatusView(walletManager: walletManager)
                    .padding()
                
                if walletManager.activeConnection != nil {
                    // Wallet is connected
                    connectedView
                } else {
                    // No wallet connected
                    disconnectedView
                }
            }
            .navigationTitle("Lightning Wallet")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Settings") {
                        // Show wallet management
                    }
                }
            }
            .sheet(isPresented: $showingConnectSheet) {
                connectWalletSheet
            }
        }
    }
    
    @ViewBuilder
    var connectedView: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Balance Card
                VStack {
                    Text("Balance")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let balance = walletManager.balance {
                        Text("\(balance / 1000) sats")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                    } else {
                        ProgressView()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(12)
                
                // Pay Invoice
                VStack(alignment: .leading) {
                    Text("Pay Invoice")
                        .font(.headline)
                    
                    HStack {
                        TextField("Lightning invoice", text: $invoiceToPay)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        
                        Button("Pay") {
                            Task {
                                await payInvoice()
                            }
                        }
                        .disabled(invoiceToPay.isEmpty || isProcessing)
                    }
                }
                
                // Recent Transactions
                VStack(alignment: .leading) {
                    Text("Recent Transactions")
                        .font(.headline)
                    
                    ForEach(walletManager.recentTransactions, id: \.paymentHash) { transaction in
                        TransactionRow(transaction: transaction)
                    }
                }
                
                Spacer()
            }
            .padding()
        }
        .task {
            // Load initial data
            await loadWalletData()
        }
    }
    
    @ViewBuilder
    var disconnectedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "bolt.slash.circle")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No Wallet Connected")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Connect a Lightning wallet to send and receive payments")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Button("Connect Wallet") {
                showingConnectSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
    
    @ViewBuilder
    var connectWalletSheet: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Paste your wallet connection URI")
                    .font(.headline)
                
                Text("Get this from your Lightning wallet's Nostr Wallet Connect settings")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextEditor(text: $connectionURI)
                    .frame(height: 100)
                    .padding(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2))
                    )
                
                Button("Connect") {
                    Task {
                        await connectWallet()
                        showingConnectSheet = false
                    }
                }
                .frame(maxWidth: .infinity)
                .disabled(connectionURI.isEmpty || isProcessing)
                
                Spacer()
            }
            .padding()
            .navigationTitle("Connect Wallet")
            .navigationBarItems(
                leading: Button("Cancel") {
                    showingConnectSheet = false
                }
            )
        }
    }
    
    func connectWallet() async {
        isProcessing = true
        defer { isProcessing = false }
        
        do {
            try await walletManager.connect(uri: connectionURI)
            connectionURI = ""
        } catch {
            // Show error alert
            print("Connection failed: \(error)")
        }
    }
    
    func payInvoice() async {
        isProcessing = true
        defer { isProcessing = false }
        
        do {
            let result = try await walletManager.payInvoice(invoiceToPay)
            invoiceToPay = ""
            // Show success
            print("Payment successful: \(result.preimage)")
        } catch {
            // Show error
            print("Payment failed: \(error)")
        }
    }
    
    func loadWalletData() async {
        do {
            _ = try await walletManager.getBalance()
            _ = try await walletManager.listTransactions(limit: 10)
        } catch {
            print("Failed to load wallet data: \(error)")
        }
    }
}

struct TransactionRow: View {
    let transaction: NWCTransaction
    
    var body: some View {
        HStack {
            Image(systemName: transaction.type == .incoming ? "arrow.down.circle" : "arrow.up.circle")
                .foregroundColor(transaction.type == .incoming ? .green : .orange)
            
            VStack(alignment: .leading) {
                Text("\(transaction.amount / 1000) sats")
                    .font(.headline)
                
                if let description = transaction.description {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            if let state = transaction.state {
                Text(state.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(stateColor(for: state).opacity(0.2))
                    .foregroundColor(stateColor(for: state))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 4)
    }
    
    func stateColor(for state: NWCTransactionState) -> Color {
        switch state {
        case .settled:
            return .green
        case .pending:
            return .orange
        case .failed:
            return .red
        case .expired:
            return .gray
        }
    }
}
```

## Security Best Practices

### 1. Secure Storage

Connection URIs contain sensitive keys and are automatically stored in the iOS Keychain:

```swift
// The manager handles this automatically, but you can add biometric protection
func connectWithBiometrics(uri: String) async {
    // Future enhancement: Add biometric authentication
    // for accessing wallet connections
}
```

### 2. Permission Management

Always verify wallet capabilities before attempting operations:

```swift
func canPayInvoices() -> Bool {
    return walletManager.supportsMethod(.payInvoice)
}

func canCreateInvoices() -> Bool {
    return walletManager.supportsMethod(.makeInvoice)
}
```

### 3. Error Handling

Implement comprehensive error handling:

```swift
enum WalletError: LocalizedError {
    case notConnected
    case unsupportedOperation
    case insufficientBalance
    
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "No wallet connected"
        case .unsupportedOperation:
            return "This wallet doesn't support this operation"
        case .insufficientBalance:
            return "Insufficient balance for this payment"
        }
    }
}
```

### 4. Rate Limiting

Respect wallet service rate limits:

```swift
class RateLimiter {
    private var lastRequestTime: Date?
    private let minimumInterval: TimeInterval = 1.0
    
    func shouldAllowRequest() -> Bool {
        guard let last = lastRequestTime else {
            lastRequestTime = Date()
            return true
        }
        
        let elapsed = Date().timeIntervalSince(last)
        if elapsed >= minimumInterval {
            lastRequestTime = Date()
            return true
        }
        
        return false
    }
}
```

## Testing

### Mock Wallet for Development

Create a mock wallet manager for SwiftUI previews and testing:

```swift
class MockWalletConnectManager: WalletConnectManager {
    override init() {
        super.init()
        
        // Set up mock data
        Task { @MainActor in
            connectionState = .connected
            balance = 100_000_000 // 100k sats
            
            recentTransactions = [
                NWCTransaction(
                    type: .incoming,
                    state: .settled,
                    paymentHash: "mock1",
                    amount: 10_000_000,
                    createdAt: Date().timeIntervalSince1970
                ),
                NWCTransaction(
                    type: .outgoing,
                    state: .settled,
                    paymentHash: "mock2",
                    amount: 5_000_000,
                    createdAt: Date().timeIntervalSince1970 - 3600
                )
            ]
        }
    }
    
    override func payInvoice(_ invoice: String, amount: Int64? = nil) async throws -> PaymentResult {
        // Simulate payment
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return PaymentResult(
            preimage: "mock_preimage_\(UUID().uuidString)",
            feesPaid: 100,
            paymentHash: "mock_hash"
        )
    }
}

// Use in previews
struct WalletView_Previews: PreviewProvider {
    static var previews: some View {
        WalletConnectView()
            .environmentObject(MockWalletConnectManager())
    }
}
```

## Troubleshooting

### Common Issues

1. **Connection Fails**
   - Verify the URI is valid and complete
   - Check relay connectivity
   - Ensure the wallet service is online

2. **Payments Fail**
   - Check wallet balance
   - Verify invoice validity
   - Ensure wallet has payment permissions

3. **No Notifications**
   - Check if wallet supports notifications
   - Verify relay subscriptions are active
   - Check connection state

### Debug Logging

Enable detailed logging for troubleshooting:

```swift
extension WalletConnectManager {
    func enableDebugLogging() {
        // Add logging to track issues
        NotificationCenter.default.addObserver(
            forName: nil,
            object: nil,
            queue: .main
        ) { notification in
            if notification.name.rawValue.contains("Relay") {
                print("Relay event: \(notification)")
            }
        }
    }
}
```

## Next Steps

- Implement QR code scanning for connection URIs
- Add transaction history persistence
- Create widgets for balance display
- Implement push notifications for payments
- Add multi-wallet management UI

## See Also

- [NIP-47 Specification](https://github.com/nostr-protocol/nips/blob/master/47.md)
- [Lightning Network Overview](https://lightning.network/)
- [NostrKit Documentation](https://github.com/SparrowTek/NostrKit)