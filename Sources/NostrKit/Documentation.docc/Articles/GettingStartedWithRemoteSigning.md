# Getting Started with Remote Signing

Integrate secure key management into your iOS app using the NIP-46 Nostr Remote Signing protocol.

## Overview

NIP-46 Remote Signing (also known as "Nostr Connect" or "Bunker") allows your app to perform cryptographic operations without ever touching private keys. Users keep their keys in a secure signer application (like Amber, nsec.app, or a self-hosted bunker), and your app requests signatures through encrypted Nostr events.

### Why Use Remote Signing?

- **Security**: Private keys never leave the signer application
- **User Control**: Users manage their own keys across multiple apps
- **Trust Minimization**: Your app doesn't need to be trusted with key material
- **Portability**: Users can use the same identity across many apps

### What You'll Learn

- How NIP-46 works under the hood
- Setting up `RemoteSignerManager`
- Connecting via bunker:// and nostrconnect:// flows
- Signing events and encrypting content
- Best practices for production apps

## Understanding NIP-46

NIP-46 uses encrypted Nostr events (kind 24133) to communicate between your app (the client) and a remote signer (the bunker). All messages are encrypted with NIP-44.

### Connection Flows

There are two ways to establish a connection:

#### 1. Bunker-Initiated (bunker://)

The user provides a `bunker://` URI from their signer app:

```
bunker://<signer-pubkey>?relay=<relay-url>&secret=<shared-secret>
```

This flow is best when:
- The user has an existing signer app
- The signer app generates the connection credentials
- You want the simplest integration

#### 2. Client-Initiated (nostrconnect://)

Your app creates a `nostrconnect://` URI for the user to scan:

```
nostrconnect://<client-pubkey>?relay=<relay-url>&secret=<secret>&name=<app-name>
```

This flow is best when:
- You want to display a QR code for easy scanning
- You want to specify permissions upfront
- The user might not have credentials ready

### Supported Operations

| Method | Description |
|--------|-------------|
| `connect` | Establish connection with the signer |
| `sign_event` | Sign a Nostr event |
| `get_public_key` | Get the user's public key |
| `ping` | Check if signer is responsive |
| `nip04_encrypt` | Encrypt using NIP-04 (legacy) |
| `nip04_decrypt` | Decrypt using NIP-04 (legacy) |
| `nip44_encrypt` | Encrypt using NIP-44 (recommended) |
| `nip44_decrypt` | Decrypt using NIP-44 (recommended) |

## Setting Up RemoteSignerManager

### Basic Setup

Add `RemoteSignerManager` to your SwiftUI app:

```swift
import SwiftUI
import NostrKit

@main
struct MyApp: App {
    @StateObject private var signerManager = RemoteSignerManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(signerManager)
        }
    }
}
```

### Configuration Options

Customize the manager with rate limiting:

```swift
// Default: 30 requests per minute
let signerManager = RemoteSignerManager()

// Higher limit for power users
let signerManager = RemoteSignerManager(maxRequestsPerMinute: 60)
```

## Connecting via Bunker URI

### Parse and Connect

When a user provides a `bunker://` URI:

```swift
struct ConnectSignerView: View {
    @EnvironmentObject var signerManager: RemoteSignerManager
    @State private var bunkerURI = ""
    @State private var isConnecting = false
    @State private var error: Error?
    
    var body: some View {
        VStack(spacing: 20) {
            TextField("Paste bunker:// URI", text: $bunkerURI)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .autocorrectionDisabled()
            
            Button("Connect Signer") {
                Task { await connect() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(bunkerURI.isEmpty || isConnecting)
            
            if isConnecting {
                ProgressView("Connecting to signer...")
            }
            
            if let error = error {
                Text(error.localizedDescription)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
        .padding()
    }
    
    func connect() async {
        isConnecting = true
        error = nil
        
        do {
            try await signerManager.connect(
                bunkerURI: bunkerURI,
                alias: "My Signer"
            )
            // Success! Signer is now connected
        } catch let nip46Error as NIP46.NIP46Error {
            handleNIP46Error(nip46Error)
        } catch {
            self.error = error
        }
        
        isConnecting = false
    }
    
    func handleNIP46Error(_ error: NIP46.NIP46Error) {
        switch error {
        case .authRequired(let url):
            // Open URL in browser for authentication
            UIApplication.shared.open(url)
        case .timeout:
            self.error = NSError(
                domain: "NIP46",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Connection timed out. Is your signer online?"]
            )
        default:
            self.error = error
        }
    }
}
```

## Connecting via NostrConnect URI

### Generate QR Code

For the client-initiated flow, generate a URI and display it:

```swift
import CoreImage.CIFilterBuiltins

struct QRConnectView: View {
    @EnvironmentObject var signerManager: RemoteSignerManager
    @State private var connectURI: NIP46.NostrConnectURI?
    @State private var isWaiting = false
    @State private var error: Error?
    
    var body: some View {
        VStack(spacing: 20) {
            if let uri = connectURI {
                // Display QR code
                QRCodeView(string: uri.toString())
                    .frame(width: 250, height: 250)
                
                Text("Scan with your signer app")
                    .font(.headline)
                
                // Also show copyable text
                Text(uri.toString())
                    .font(.caption)
                    .lineLimit(3)
                    .truncationMode(.middle)
                
                Button("Copy URI") {
                    UIPasteboard.general.string = uri.toString()
                }
                .buttonStyle(.bordered)
                
                if isWaiting {
                    ProgressView("Waiting for signer...")
                }
            } else {
                Button("Generate Connection") {
                    generateAndWait()
                }
                .buttonStyle(.borderedProminent)
            }
            
            if let error = error {
                Text(error.localizedDescription)
                    .foregroundColor(.red)
            }
        }
        .padding()
    }
    
    func generateAndWait() {
        do {
            // Generate the URI
            connectURI = try signerManager.createNostrConnectURI(
                relays: ["wss://relay.damus.io", "wss://relay.nostr.band"],
                permissions: [
                    NIP46.Permission(method: .signEvent),
                    NIP46.Permission(method: .getPublicKey),
                    NIP46.Permission(method: .nip44Encrypt),
                    NIP46.Permission(method: .nip44Decrypt)
                ],
                name: "My Nostr App",
                url: "https://myapp.example.com"
            )
            
            // Wait for the signer to connect
            Task {
                isWaiting = true
                do {
                    try await signerManager.waitForConnection(
                        uri: connectURI!,
                        timeout: 300, // 5 minutes
                        alias: "My Signer"
                    )
                    // Success!
                } catch {
                    self.error = error
                }
                isWaiting = false
            }
        } catch {
            self.error = error
        }
    }
}

struct QRCodeView: View {
    let string: String
    
    var body: some View {
        if let image = generateQRCode(from: string) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }
    
    func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        
        guard let outputImage = filter.outputImage else { return nil }
        
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: transform)
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        
        return UIImage(cgImage: cgImage)
    }
}
```

## Monitoring Connection State

Track the connection status in your UI:

```swift
struct ConnectionStatusView: View {
    @EnvironmentObject var signerManager: RemoteSignerManager
    
    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
            
            Text(statusText)
                .font(.subheadline)
            
            Spacer()
            
            if let pubkey = signerManager.userPublicKey {
                Text(String(pubkey.prefix(8)) + "...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
    }
    
    var statusColor: Color {
        switch signerManager.connectionState {
        case .connected:
            return .green
        case .connecting, .waitingForSigner:
            return .orange
        case .disconnected:
            return .gray
        case .authRequired:
            return .yellow
        case .failed:
            return .red
        }
    }
    
    var statusText: String {
        switch signerManager.connectionState {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .waitingForSigner:
            return "Waiting for signer..."
        case .disconnected:
            return "Disconnected"
        case .authRequired(let url):
            return "Auth required"
        case .failed(let message):
            return "Error: \(message)"
        }
    }
}
```

## Signing Events

### Sign a Text Note

```swift
func postNote(_ content: String) async throws -> NostrEvent {
    // Create an unsigned event
    let unsignedEvent = NIP46.UnsignedEvent(
        kind: 1,  // Text note
        content: content,
        tags: []
    )
    
    // Request signature from remote signer
    let signedEvent = try await signerManager.signEvent(unsignedEvent)
    
    // signedEvent now has id, pubkey, and sig populated
    return signedEvent
}
```

### Sign with Tags

```swift
func replyToNote(content: String, replyTo: NostrEvent) async throws -> NostrEvent {
    let unsignedEvent = NIP46.UnsignedEvent(
        kind: 1,
        content: content,
        tags: [
            ["e", replyTo.id, "", "reply"],
            ["p", replyTo.pubkey]
        ]
    )
    
    return try await signerManager.signEvent(unsignedEvent)
}
```

### Sign Different Event Kinds

```swift
// Reaction
func reactToNote(_ noteId: String, notePubkey: String) async throws -> NostrEvent {
    let event = NIP46.UnsignedEvent(
        kind: 7,
        content: "+",
        tags: [
            ["e", noteId],
            ["p", notePubkey]
        ]
    )
    return try await signerManager.signEvent(event)
}

// Profile metadata
func updateProfile(name: String, about: String) async throws -> NostrEvent {
    let content = """
    {"name":"\(name)","about":"\(about)"}
    """
    let event = NIP46.UnsignedEvent(
        kind: 0,
        content: content,
        tags: []
    )
    return try await signerManager.signEvent(event)
}
```

## Encryption Operations

### Encrypt a Direct Message (NIP-44)

```swift
func encryptMessage(_ plaintext: String, to recipientPubkey: String) async throws -> String {
    // Use NIP-44 encryption via the remote signer
    let ciphertext = try await signerManager.nip44Encrypt(
        plaintext: plaintext,
        recipientPubkey: recipientPubkey
    )
    return ciphertext
}
```

### Decrypt a Direct Message

```swift
func decryptMessage(_ ciphertext: String, from senderPubkey: String) async throws -> String {
    let plaintext = try await signerManager.nip44Decrypt(
        ciphertext: ciphertext,
        senderPubkey: senderPubkey
    )
    return plaintext
}
```

### Full DM Flow

```swift
func sendEncryptedDM(content: String, to recipientPubkey: String) async throws -> NostrEvent {
    // Encrypt the content
    let encrypted = try await signerManager.nip44Encrypt(
        plaintext: content,
        recipientPubkey: recipientPubkey
    )
    
    // Create and sign the event
    let event = NIP46.UnsignedEvent(
        kind: 4,  // Encrypted DM
        content: encrypted,
        tags: [["p", recipientPubkey]]
    )
    
    return try await signerManager.signEvent(event)
}
```

## Getting User Information

### Get Public Key

```swift
func getUserPubkey() async throws -> String {
    // This is also available as signerManager.userPublicKey
    // after connection, but can be refreshed:
    let pubkey = try await signerManager.getPublicKey()
    return pubkey
}
```

### Check Connectivity

```swift
func checkSignerOnline() async throws -> Bool {
    return try await signerManager.ping()
}
```

## Handling Auth Challenges

Some signers (especially web-based ones) require authentication:

```swift
struct SignerAuthView: View {
    @EnvironmentObject var signerManager: RemoteSignerManager
    
    var body: some View {
        VStack {
            if case .authRequired(let url) = signerManager.connectionState {
                Text("Authentication Required")
                    .font(.headline)
                
                Text("Your signer requires you to authenticate in a browser.")
                    .multilineTextAlignment(.center)
                    .padding()
                
                Button("Open Authentication") {
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
                
                Button("I've Authenticated") {
                    Task {
                        // Retry the connection
                        try? await signerManager.reconnect()
                    }
                }
                .buttonStyle(.bordered)
                .padding(.top)
            }
        }
        .padding()
    }
}
```

## Automatic Reconnection

RemoteSignerManager includes automatic reconnection with exponential backoff:

```swift
// Enable/disable auto-reconnection (enabled by default)
signerManager.setAutoReconnect(enabled: true)

// Manually trigger reconnection
try await signerManager.reconnect()

// Cancel pending reconnection attempts
signerManager.cancelReconnection()

// Notify of connection loss (triggers auto-reconnect)
signerManager.handleConnectionLost()
```

The reconnection strategy:
- Base delay: 1 second
- Maximum delay: 5 minutes
- Maximum attempts: 10
- Includes jitter to prevent thundering herd

## Error Handling

### NIP-46 Errors

```swift
func handleSigningError(_ error: Error) {
    guard let nip46Error = error as? NIP46.NIP46Error else {
        // Generic error handling
        return
    }
    
    switch nip46Error {
    case .invalidURI:
        showAlert("Invalid bunker URI format")
        
    case .connectionFailed(let reason):
        showAlert("Connection failed: \(reason)")
        
    case .signingFailed(let reason):
        showAlert("Signing failed: \(reason)")
        
    case .encryptionFailed(let reason):
        showAlert("Encryption failed: \(reason)")
        
    case .decryptionFailed(let reason):
        showAlert("Decryption failed: \(reason)")
        
    case .timeout:
        showAlert("Request timed out. Is your signer online?")
        
    case .unauthorized:
        showAlert("Not authorized for this operation")
        
    case .methodNotSupported(let method):
        showAlert("Your signer doesn't support: \(method)")
        
    case .invalidResponse:
        showAlert("Invalid response from signer")
        
    case .authRequired(let url):
        // Open auth URL
        UIApplication.shared.open(url)
        
    case .secretMismatch:
        showAlert("Connection secret mismatch")
        
    case .signerDisconnected:
        showAlert("Signer is disconnected")
        
    case .serializationFailed:
        showAlert("Failed to serialize request")
    }
}
```

## Best Practices

### 1. Always Check Connection State

```swift
guard case .connected = signerManager.connectionState else {
    throw MyError.signerNotConnected
}
```

### 2. Cache the User's Public Key

```swift
// After successful connection, the public key is cached:
if let pubkey = signerManager.userPublicKey {
    // Use cached value for display
}

// Only call getPublicKey() when you need to refresh
```

### 3. Handle Timeouts Gracefully

```swift
func signWithTimeout(_ event: NIP46.UnsignedEvent) async throws -> NostrEvent {
    do {
        return try await signerManager.signEvent(event)
    } catch NIP46.NIP46Error.timeout {
        // Signer might be offline or slow
        showAlert("Your signer isn't responding. Please check it's running.")
        throw MyError.signerOffline
    }
}
```

### 4. Request Minimal Permissions

When using client-initiated flow, only request permissions you need:

```swift
// Good - only request what you need
let uri = try signerManager.createNostrConnectURI(
    relays: ["wss://relay.example.com"],
    permissions: [
        NIP46.Permission(method: .signEvent, kind: 1), // Only kind 1
        NIP46.Permission(method: .getPublicKey)
    ],
    name: "Simple Note App"
)

// Avoid requesting all permissions if you don't need them
```

### 5. Provide Clear User Feedback

```swift
struct SigningButton: View {
    @EnvironmentObject var signerManager: RemoteSignerManager
    let onSign: () async throws -> Void
    
    @State private var isSigning = false
    
    var body: some View {
        Button(action: { Task { await sign() } }) {
            if isSigning {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Waiting for signer...")
                }
            } else {
                Text("Sign & Post")
            }
        }
        .disabled(isSigning)
    }
    
    func sign() async {
        isSigning = true
        defer { isSigning = false }
        
        do {
            try await onSign()
        } catch {
            // Handle error
        }
    }
}
```

## Compatible Signers

Users can use these signer applications with NIP-46:

| Signer | Platform | URL |
|--------|----------|-----|
| Amber | Android | [github.com/greenart7c3/Amber](https://github.com/greenart7c3/Amber) |
| nsec.app | Web | [nsec.app](https://nsec.app) |
| Nostr Connect | Self-hosted | Various implementations |
| Keystache | macOS | [keystache.com](https://keystache.com) |

## Next Steps

- Explore ``RemoteSignerManager`` API reference
- Learn about <doc:GettingStartedWithNWC> for Lightning payments
- See the NIP-46 specification for protocol details

## See Also

- ``RemoteSignerManager``
- ``NIP46``
- ``NIP46/BunkerURI``
- ``NIP46/NostrConnectURI``
- ``NIP46/UnsignedEvent``
- ``NIP46/NIP46Error``
