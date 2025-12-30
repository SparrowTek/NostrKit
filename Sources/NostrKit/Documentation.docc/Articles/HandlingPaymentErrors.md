# Handling Payment Errors

Implement robust error handling for Lightning payment operations in your NWC integration.

## Overview

Payment operations can fail for many reasons: insufficient balance, expired invoices, network issues, or wallet service problems. This guide shows you how to handle these errors gracefully and provide a good user experience.

## NWC Error Types

### NWCError Structure

All NWC errors conform to a standard structure:

```swift
public struct NWCError: Error, Codable {
    public let code: NWCErrorCode
    public let message: String
}

public enum NWCErrorCode: String, Codable {
    case rateLimited = "RATE_LIMITED"
    case notImplemented = "NOT_IMPLEMENTED"
    case insufficientBalance = "INSUFFICIENT_BALANCE"
    case quotaExceeded = "QUOTA_EXCEEDED"
    case restricted = "RESTRICTED"
    case unauthorized = "UNAUTHORIZED"
    case internal = "INTERNAL"
    case paymentFailed = "PAYMENT_FAILED"
    case notFound = "NOT_FOUND"
    case other = "OTHER"
}
```

### Common Error Scenarios

| Error Code | Cause | Recovery |
|------------|-------|----------|
| `insufficientBalance` | Wallet lacks funds | Prompt user to add funds |
| `rateLimited` | Too many requests | Wait and retry with backoff |
| `paymentFailed` | Route not found, invoice issue | Check invoice, retry later |
| `unauthorized` | Invalid secret or connection | Reconnect wallet |
| `notImplemented` | Wallet doesn't support method | Use alternative or inform user |
| `quotaExceeded` | Daily/monthly limit reached | Wait for reset or upgrade |

## Basic Error Handling

### Try-Catch Pattern

```swift
func makePayment(_ invoice: String) async {
    do {
        let result = try await walletManager.payInvoice(invoice)
        showSuccess(preimage: result.preimage)
    } catch let error as NWCError {
        handleNWCError(error)
    } catch {
        handleGenericError(error)
    }
}

func handleNWCError(_ error: NWCError) {
    switch error.code {
    case .insufficientBalance:
        showAlert(
            title: "Insufficient Balance",
            message: "Your wallet doesn't have enough funds for this payment.",
            action: "Add Funds"
        )
        
    case .rateLimited:
        showAlert(
            title: "Too Many Requests",
            message: "Please wait a moment before trying again.",
            action: "OK"
        )
        
    case .paymentFailed:
        showAlert(
            title: "Payment Failed",
            message: error.message,
            action: "Try Again"
        )
        
    case .unauthorized:
        showAlert(
            title: "Connection Lost",
            message: "Please reconnect your wallet.",
            action: "Reconnect"
        )
        
    case .notImplemented:
        showAlert(
            title: "Not Supported",
            message: "Your wallet doesn't support this feature.",
            action: "OK"
        )
        
    default:
        showAlert(
            title: "Error",
            message: error.message,
            action: "OK"
        )
    }
}
```

## Advanced Error Handling

### Error Recovery Coordinator

Create a reusable error handler with recovery actions:

```swift
@MainActor
class PaymentErrorHandler: ObservableObject {
    @Published var currentError: PaymentError?
    @Published var isRecovering = false
    
    private let walletManager: WalletConnectManager
    
    init(walletManager: WalletConnectManager) {
        self.walletManager = walletManager
    }
    
    func handle(_ error: Error) {
        if let nwcError = error as? NWCError {
            currentError = PaymentError(from: nwcError)
        } else if error is CancellationError {
            currentError = .cancelled
        } else {
            currentError = .network(error.localizedDescription)
        }
    }
    
    func attemptRecovery() async -> Bool {
        guard let error = currentError else { return false }
        
        isRecovering = true
        defer { isRecovering = false }
        
        switch error {
        case .connectionLost:
            return await recoverConnection()
        case .rateLimited:
            return await waitForRateLimit()
        default:
            return false
        }
    }
    
    private func recoverConnection() async -> Bool {
        do {
            try await walletManager.reconnect()
            currentError = nil
            return true
        } catch {
            return false
        }
    }
    
    private func waitForRateLimit() async -> Bool {
        try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
        currentError = nil
        return true
    }
}

enum PaymentError: Identifiable {
    case insufficientBalance(required: Int64?, available: Int64?)
    case rateLimited
    case paymentFailed(String)
    case connectionLost
    case invoiceExpired
    case network(String)
    case cancelled
    case unknown(String)
    
    var id: String {
        switch self {
        case .insufficientBalance: return "insufficient"
        case .rateLimited: return "rate_limited"
        case .paymentFailed: return "payment_failed"
        case .connectionLost: return "connection_lost"
        case .invoiceExpired: return "invoice_expired"
        case .network: return "network"
        case .cancelled: return "cancelled"
        case .unknown: return "unknown"
        }
    }
    
    init(from nwcError: NWCError) {
        switch nwcError.code {
        case .insufficientBalance:
            self = .insufficientBalance(required: nil, available: nil)
        case .rateLimited:
            self = .rateLimited
        case .paymentFailed:
            self = .paymentFailed(nwcError.message)
        case .unauthorized:
            self = .connectionLost
        default:
            self = .unknown(nwcError.message)
        }
    }
    
    var title: String {
        switch self {
        case .insufficientBalance: return "Insufficient Balance"
        case .rateLimited: return "Please Wait"
        case .paymentFailed: return "Payment Failed"
        case .connectionLost: return "Connection Lost"
        case .invoiceExpired: return "Invoice Expired"
        case .network: return "Network Error"
        case .cancelled: return "Cancelled"
        case .unknown: return "Error"
        }
    }
    
    var message: String {
        switch self {
        case .insufficientBalance(let required, let available):
            if let req = required, let avail = available {
                return "Need \(req / 1000) sats, have \(avail / 1000) sats"
            }
            return "Your wallet doesn't have enough funds"
        case .rateLimited:
            return "Too many requests. Please wait a moment."
        case .paymentFailed(let msg):
            return msg
        case .connectionLost:
            return "Lost connection to wallet. Please reconnect."
        case .invoiceExpired:
            return "This invoice has expired. Request a new one."
        case .network(let msg):
            return msg
        case .cancelled:
            return "Payment was cancelled"
        case .unknown(let msg):
            return msg
        }
    }
    
    var isRecoverable: Bool {
        switch self {
        case .rateLimited, .connectionLost, .network:
            return true
        case .invoiceExpired, .cancelled:
            return false
        default:
            return true
        }
    }
    
    var recoveryAction: String? {
        switch self {
        case .insufficientBalance:
            return "Add Funds"
        case .rateLimited:
            return "Wait"
        case .connectionLost:
            return "Reconnect"
        case .network:
            return "Retry"
        case .paymentFailed:
            return "Try Again"
        default:
            return nil
        }
    }
}
```

### Error Display View

```swift
struct PaymentErrorView: View {
    @ObservedObject var errorHandler: PaymentErrorHandler
    let onDismiss: () -> Void
    let onRetry: () -> Void
    
    var body: some View {
        if let error = errorHandler.currentError {
            VStack(spacing: 16) {
                // Error icon
                Image(systemName: iconName(for: error))
                    .font(.system(size: 48))
                    .foregroundColor(iconColor(for: error))
                
                // Title
                Text(error.title)
                    .font(.headline)
                
                // Message
                Text(error.message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                // Recovery progress
                if errorHandler.isRecovering {
                    ProgressView()
                        .padding()
                }
                
                // Actions
                HStack(spacing: 12) {
                    Button("Dismiss") {
                        errorHandler.currentError = nil
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    
                    if let action = error.recoveryAction, error.isRecoverable {
                        Button(action) {
                            Task {
                                if await errorHandler.attemptRecovery() {
                                    onRetry()
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(errorHandler.isRecovering)
                    }
                }
            }
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(16)
            .shadow(radius: 10)
        }
    }
    
    func iconName(for error: PaymentError) -> String {
        switch error {
        case .insufficientBalance: return "creditcard.trianglebadge.exclamationmark"
        case .rateLimited: return "clock.badge.exclamationmark"
        case .paymentFailed: return "xmark.circle"
        case .connectionLost: return "wifi.exclamationmark"
        case .invoiceExpired: return "clock.badge.xmark"
        case .network: return "network.slash"
        case .cancelled: return "xmark"
        case .unknown: return "exclamationmark.triangle"
        }
    }
    
    func iconColor(for error: PaymentError) -> Color {
        switch error {
        case .insufficientBalance, .invoiceExpired:
            return .orange
        case .rateLimited:
            return .yellow
        case .cancelled:
            return .gray
        default:
            return .red
        }
    }
}
```

## Retry Strategies

### Exponential Backoff

```swift
func payWithRetry(_ invoice: String, maxAttempts: Int = 3) async throws -> PaymentResult {
    var lastError: Error?
    
    for attempt in 0..<maxAttempts {
        do {
            return try await walletManager.payInvoice(invoice)
        } catch let error as NWCError {
            lastError = error
            
            // Don't retry certain errors
            switch error.code {
            case .insufficientBalance, .unauthorized, .notImplemented:
                throw error
            case .rateLimited:
                // Wait longer for rate limiting
                let delay = UInt64(60_000_000_000) // 60 seconds
                try await Task.sleep(nanoseconds: delay)
            default:
                // Exponential backoff
                let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }
    
    throw lastError ?? NWCError(code: .other, message: "Max retries exceeded")
}
```

### Circuit Breaker Pattern

```swift
actor PaymentCircuitBreaker {
    private var failures = 0
    private var lastFailure: Date?
    private let threshold = 5
    private let resetTimeout: TimeInterval = 60
    
    enum State {
        case closed    // Normal operation
        case open      // Failing, reject requests
        case halfOpen  // Testing if recovered
    }
    
    var state: State {
        guard failures >= threshold else { return .closed }
        
        if let lastFailure = lastFailure,
           Date().timeIntervalSince(lastFailure) > resetTimeout {
            return .halfOpen
        }
        
        return .open
    }
    
    func recordSuccess() {
        failures = 0
        lastFailure = nil
    }
    
    func recordFailure() {
        failures += 1
        lastFailure = Date()
    }
    
    func shouldAllowRequest() -> Bool {
        switch state {
        case .closed, .halfOpen:
            return true
        case .open:
            return false
        }
    }
}

// Usage
class ResilientPaymentService {
    private let walletManager: WalletConnectManager
    private let circuitBreaker = PaymentCircuitBreaker()
    
    func pay(_ invoice: String) async throws -> PaymentResult {
        guard await circuitBreaker.shouldAllowRequest() else {
            throw PaymentError.rateLimited
        }
        
        do {
            let result = try await walletManager.payInvoice(invoice)
            await circuitBreaker.recordSuccess()
            return result
        } catch {
            await circuitBreaker.recordFailure()
            throw error
        }
    }
}
```

## Validation Before Payment

### Pre-flight Checks

```swift
func validatePayment(invoice: String, amount: Int64) async throws {
    // Check connection
    guard case .connected = walletManager.connectionState else {
        throw PaymentError.connectionLost
    }
    
    // Check wallet supports payment
    guard walletManager.supportsMethod(.payInvoice) else {
        throw PaymentError.unknown("Wallet doesn't support payments")
    }
    
    // Check balance (if supported)
    if walletManager.supportsMethod(.getBalance) {
        let balance = try await walletManager.getBalance()
        if balance < amount {
            throw PaymentError.insufficientBalance(
                required: amount,
                available: balance
            )
        }
    }
    
    // Validate invoice format
    guard invoice.lowercased().hasPrefix("lnbc") ||
          invoice.lowercased().hasPrefix("lntb") ||
          invoice.lowercased().hasPrefix("lnbcrt") else {
        throw PaymentError.unknown("Invalid invoice format")
    }
}
```

## Logging and Diagnostics

### Payment Event Logging

```swift
struct PaymentLogger {
    static func logAttempt(invoice: String, amount: Int64) {
        print("[NWC] Payment attempt - amount: \(amount) msats")
    }
    
    static func logSuccess(result: PaymentResult, duration: TimeInterval) {
        print("[NWC] Payment success - preimage: \(result.preimage.prefix(16))... duration: \(duration)s")
    }
    
    static func logFailure(error: Error, invoice: String) {
        if let nwcError = error as? NWCError {
            print("[NWC] Payment failed - code: \(nwcError.code.rawValue) message: \(nwcError.message)")
        } else {
            print("[NWC] Payment failed - error: \(error.localizedDescription)")
        }
    }
}

// Usage
func payWithLogging(_ invoice: String) async throws -> PaymentResult {
    let amount: Int64 = 1000 // Parse from invoice
    PaymentLogger.logAttempt(invoice: invoice, amount: amount)
    
    let start = Date()
    
    do {
        let result = try await walletManager.payInvoice(invoice)
        PaymentLogger.logSuccess(result: result, duration: Date().timeIntervalSince(start))
        return result
    } catch {
        PaymentLogger.logFailure(error: error, invoice: invoice)
        throw error
    }
}
```

## User Experience Tips

### 1. Show Progress During Payment

```swift
struct PaymentProgressView: View {
    @State private var status = "Initiating payment..."
    
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text(status)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .onAppear {
            animateStatus()
        }
    }
    
    func animateStatus() {
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            status = "Finding payment route..."
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            status = "Processing payment..."
        }
    }
}
```

### 2. Provide Clear Error Messages

Always translate technical errors into user-friendly language:

```swift
extension NWCError {
    var userFriendlyMessage: String {
        switch code {
        case .insufficientBalance:
            return "You don't have enough funds. Please add more to your wallet."
        case .rateLimited:
            return "You're making too many requests. Please wait a minute and try again."
        case .paymentFailed:
            return "The payment couldn't be completed. The recipient may be offline."
        case .unauthorized:
            return "Your wallet connection has expired. Please reconnect."
        default:
            return "Something went wrong. Please try again."
        }
    }
}
```

### 3. Offer Contextual Help

```swift
struct ErrorHelpView: View {
    let error: PaymentError
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What happened?")
                .font(.headline)
            
            Text(error.message)
            
            Text("What can I do?")
                .font(.headline)
                .padding(.top)
            
            Text(helpText)
        }
    }
    
    var helpText: String {
        switch error {
        case .insufficientBalance:
            return "Open your wallet app and add funds via Lightning or on-chain deposit."
        case .paymentFailed:
            return "Try again in a few minutes. If it keeps failing, ask the recipient for a new invoice."
        case .connectionLost:
            return "Check your internet connection, then tap Reconnect."
        default:
            return "If this keeps happening, try disconnecting and reconnecting your wallet."
        }
    }
}
```

## See Also

- <doc:GettingStartedWithNWC>
- ``WalletConnectManager``
- ``NWCError``
- ``NWCErrorCode``
