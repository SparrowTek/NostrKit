# Key Management

Securely manage NOSTR keys and identities in your iOS/macOS applications.

## Overview

Key management is the foundation of security in NOSTR applications. This guide covers best practices for generating, storing, and using cryptographic keys with NostrKit's secure key management system.

## Understanding NOSTR Keys

### Key Pairs

NOSTR uses secp256k1 elliptic curve cryptography:

- **Private Key**: 32-byte secret used for signing events
- **Public Key**: 32-byte identifier derived from private key
- **Schnorr Signatures**: 64-byte signatures for event authentication

### Key Formats

```swift
// Hex format (64 characters)
let privateKeyHex = "3f4c5b2a1e9d8c7b6a5f4e3d2c1b0a9876543210fedcba9876543210fedcba98"
let publicKeyHex = "a1b2c3d4e5f67890abcdef1234567890abcdef1234567890abcdef1234567890"

// Bech32 format (human-readable)
let nsec = "nsec1qyq8wumn8ghj7un0d3shxtnf9e3k7mns0aujcm" // Private key
let npub = "npub1qyq8wumn8ghj7un0d3shxtnf9e3k7mns0aujcm" // Public key

// Convert between formats
let keyPair = try KeyPair(privateKey: privateKeyHex)
let nsecEncoded = try Bech32Entity.nsec(keyPair.privateKey).encoded
let npubEncoded = try Bech32Entity.npub(keyPair.publicKey).encoded
```

## SecureKeyStore

NostrKit provides `SecureKeyStore` for secure key management using iOS Keychain:

### Basic Usage

```swift
import NostrKit
import CoreNostr

let keyStore = SecureKeyStore()

// Generate and store a new key pair
let keyPair = try CoreNostr.createKeyPair()
try await keyStore.store(
    keyPair,
    for: "main-identity",
    name: "My NOSTR Identity",
    permissions: .biometricRequired
)

// Retrieve with authentication
let retrieved = try await keyStore.retrieve(
    identity: "main-identity",
    authenticationRequired: true
)

// List all stored identities
let identities = try await keyStore.listIdentities()
for identity in identities {
    print("Identity: \\(identity.identifier) - \\(identity.name)")
}

// Delete an identity
try await keyStore.delete(identity: "old-identity")
```

### Storage Permissions

```swift
enum KeyPermissions {
    case none                    // No special protection
    case devicePasscode         // Require device passcode
    case biometricAny          // Any biometric (Face ID or Touch ID)
    case biometricRequired     // Biometric required, no fallback
    case biometricOrPasscode   // Biometric with passcode fallback
}

// Store with different permission levels
try await keyStore.store(
    keyPair,
    for: "high-security",
    permissions: .biometricRequired
)

try await keyStore.store(
    viewOnlyKeyPair,
    for: "read-only",
    permissions: .devicePasscode
)
```

### Biometric Authentication

```swift
import LocalAuthentication

class BiometricKeyManager {
    let keyStore = SecureKeyStore()
    
    func authenticateAndRetrieve(identity: String) async throws -> KeyPair {
        let context = LAContext()
        var error: NSError?
        
        // Check biometric availability
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        ) else {
            throw KeyError.biometricUnavailable(error)
        }
        
        // Set authentication properties
        context.localizedReason = "Authenticate to access your NOSTR keys"
        context.localizedFallbackTitle = "Use Passcode"
        context.localizedCancelTitle = "Cancel"
        
        // Authenticate
        let success = try await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Access your NOSTR identity"
        )
        
        guard success else {
            throw KeyError.authenticationFailed
        }
        
        // Retrieve keys after successful authentication
        return try await keyStore.retrieve(
            identity: identity,
            authenticationRequired: false // Already authenticated
        )
    }
    
    func checkBiometricType() -> BiometricType {
        let context = LAContext()
        var error: NSError?
        
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        ) else {
            return .none
        }
        
        switch context.biometryType {
        case .faceID:
            return .faceID
        case .touchID:
            return .touchID
        case .opticID:
            return .opticID
        case .none:
            return .none
        @unknown default:
            return .none
        }
    }
    
    enum BiometricType {
        case none, faceID, touchID, opticID
    }
}
```

## Key Generation

### Creating New Keys

```swift
// Generate a random key pair
let keyPair = try CoreNostr.createKeyPair()

// Generate from seed phrase (NIP-06)
let mnemonic = try Mnemonic.generate(strength: .normal)
let seed = try mnemonic.seed(passphrase: "optional-passphrase")
let hdKey = try HDKey(seed: seed)
let nostrKey = try hdKey.derive(path: "m/44'/1237'/0'/0/0")
let keyPairFromSeed = try KeyPair(privateKey: nostrKey.privateKey)

// Generate vanity address
func generateVanityKeyPair(prefix: String) async throws -> KeyPair {
    let lowercasePrefix = prefix.lowercased()
    
    return try await withCheckedThrowingContinuation { continuation in
        Task.detached(priority: .userInitiated) {
            var attempts = 0
            let maxAttempts = 1_000_000
            
            while attempts < maxAttempts {
                do {
                    let keyPair = try CoreNostr.createKeyPair()
                    let npub = try Bech32Entity.npub(keyPair.publicKey).encoded
                    
                    if npub.dropFirst(4).lowercased().hasPrefix(lowercasePrefix) {
                        continuation.resume(returning: keyPair)
                        return
                    }
                    
                    attempts += 1
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
            }
            
            continuation.resume(throwing: KeyError.vanityTimeout)
        }
    }
}

// Usage
let vanityKeyPair = try await generateVanityKeyPair(prefix: "alice")
```

### Hierarchical Deterministic Keys (NIP-06)

```swift
class HDKeyManager {
    private let keyStore = SecureKeyStore()
    
    struct HDPath {
        static let nostrRoot = "m/44'/1237'"
        static let account = "m/44'/1237'/0'"
        static let identity = "m/44'/1237'/0'/0"
        
        static func identity(index: Int) -> String {
            return "m/44'/1237'/0'/0/\\(index)"
        }
    }
    
    func generateMasterSeed() throws -> Mnemonic {
        return try Mnemonic.generate(strength: .high) // 24 words
    }
    
    func deriveIdentities(
        from mnemonic: Mnemonic,
        count: Int,
        passphrase: String = ""
    ) throws -> [KeyPair] {
        let seed = try mnemonic.seed(passphrase: passphrase)
        let hdKey = try HDKey(seed: seed)
        
        var identities: [KeyPair] = []
        
        for i in 0..<count {
            let path = HDPath.identity(index: i)
            let derivedKey = try hdKey.derive(path: path)
            let keyPair = try KeyPair(privateKey: derivedKey.privateKey)
            identities.append(keyPair)
        }
        
        return identities
    }
    
    func storeMasterSeed(_ mnemonic: Mnemonic) async throws {
        // Store encrypted seed in keychain
        let encryptedSeed = try encrypt(mnemonic.phrase)
        
        try await keyStore.storeRaw(
            data: encryptedSeed,
            for: "master-seed",
            permissions: .biometricRequired
        )
    }
    
    func recoverFromSeed(_ phrase: String) throws -> Mnemonic {
        return try Mnemonic(phrase: phrase)
    }
}
```

## Key Import/Export

### Importing Keys

```swift
class KeyImporter {
    let keyStore = SecureKeyStore()
    
    func importFromNsec(_ nsec: String, name: String) async throws -> KeyPair {
        // Validate and decode nsec
        guard nsec.hasPrefix("nsec1") else {
            throw KeyError.invalidFormat
        }
        
        guard case .nsec(let privateKey) = try Bech32Entity.decode(nsec) else {
            throw KeyError.invalidNsec
        }
        
        // Create key pair
        let keyPair = try KeyPair(privateKey: privateKey)
        
        // Store securely
        try await keyStore.store(
            keyPair,
            for: UUID().uuidString,
            name: name,
            permissions: .biometricRequired
        )
        
        return keyPair
    }
    
    func importFromHex(_ hex: String, name: String) async throws -> KeyPair {
        // Validate hex format
        guard hex.count == 64,
              hex.allSatisfy({ $0.isHexDigit }) else {
            throw KeyError.invalidHexFormat
        }
        
        let keyPair = try KeyPair(privateKey: hex)
        
        try await keyStore.store(
            keyPair,
            for: UUID().uuidString,
            name: name,
            permissions: .biometricRequired
        )
        
        return keyPair
    }
    
    func importFromFile(url: URL) async throws -> KeyPair {
        // Read encrypted key file
        let encryptedData = try Data(contentsOf: url)
        
        // Prompt for decryption password
        let password = try await promptForPassword()
        
        // Decrypt
        let decryptedKey = try decrypt(encryptedData, password: password)
        
        // Import
        return try await importFromHex(decryptedKey, name: url.lastPathComponent)
    }
}
```

### Exporting Keys

```swift
class KeyExporter {
    let keyStore = SecureKeyStore()
    
    func exportAsNsec(identity: String) async throws -> String {
        // Require authentication
        let keyPair = try await keyStore.retrieve(
            identity: identity,
            authenticationRequired: true
        )
        
        // Convert to nsec
        return try Bech32Entity.nsec(keyPair.privateKey).encoded
    }
    
    func exportAsEncryptedFile(
        identity: String,
        password: String
    ) async throws -> Data {
        let keyPair = try await keyStore.retrieve(
            identity: identity,
            authenticationRequired: true
        )
        
        // Encrypt with password
        let encrypted = try encrypt(
            keyPair.privateKey,
            password: password
        )
        
        // Create export format
        let export = KeyExport(
            version: 1,
            algorithm: "AES-256-GCM",
            encrypted: encrypted,
            hint: "Enter your password",
            createdAt: Date()
        )
        
        return try JSONEncoder().encode(export)
    }
    
    func exportAsQRCode(identity: String) async throws -> UIImage {
        let nsec = try await exportAsNsec(identity: identity)
        
        // Generate QR code
        let data = nsec.data(using: .utf8)!
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let output = filter.outputImage!.transformed(by: transform)
        
        let context = CIContext()
        let cgImage = context.createCGImage(output, from: output.extent)!
        
        return UIImage(cgImage: cgImage)
    }
}

struct KeyExport: Codable {
    let version: Int
    let algorithm: String
    let encrypted: Data
    let hint: String?
    let createdAt: Date
}
```

## Multi-Identity Management

```swift
class IdentityManager: ObservableObject {
    @Published var identities: [Identity] = []
    @Published var currentIdentity: Identity?
    
    private let keyStore = SecureKeyStore()
    
    struct Identity: Identifiable {
        let id: String
        let name: String
        let publicKey: PublicKey
        let createdAt: Date
        var isActive: Bool
        var metadata: IdentityMetadata?
    }
    
    struct IdentityMetadata: Codable {
        var color: String?
        var emoji: String?
        var relays: [String]?
        var follows: [PublicKey]?
    }
    
    func createIdentity(name: String) async throws -> Identity {
        let keyPair = try CoreNostr.createKeyPair()
        let id = UUID().uuidString
        
        try await keyStore.store(
            keyPair,
            for: id,
            name: name,
            permissions: .biometricRequired
        )
        
        let identity = Identity(
            id: id,
            name: name,
            publicKey: keyPair.publicKey,
            createdAt: Date(),
            isActive: false
        )
        
        identities.append(identity)
        
        if currentIdentity == nil {
            await switchTo(identity)
        }
        
        return identity
    }
    
    func switchTo(_ identity: Identity) async {
        // Deactivate current
        if let current = currentIdentity,
           let index = identities.firstIndex(where: { $0.id == current.id }) {
            identities[index].isActive = false
        }
        
        // Activate new
        if let index = identities.firstIndex(where: { $0.id == identity.id }) {
            identities[index].isActive = true
            currentIdentity = identities[index]
        }
    }
    
    func getKeyPair(for identity: Identity) async throws -> KeyPair {
        return try await keyStore.retrieve(
            identity: identity.id,
            authenticationRequired: true
        )
    }
    
    func deleteIdentity(_ identity: Identity) async throws {
        try await keyStore.delete(identity: identity.id)
        identities.removeAll { $0.id == identity.id }
        
        if currentIdentity?.id == identity.id {
            currentIdentity = identities.first
        }
    }
}
```

## Security Best Practices

### 1. Never Expose Private Keys

```swift
// BAD: Logging private keys
print("Private key: \\(keyPair.privateKey)") // NEVER DO THIS

// GOOD: Log public keys only
print("Public key: \\(keyPair.publicKey)")
print("npub: \\(try Bech32Entity.npub(keyPair.publicKey).encoded)")
```

### 2. Secure Key Generation

```swift
// Use system random number generator
func secureRandom(bytes: Int) -> Data {
    var data = Data(count: bytes)
    let result = data.withUnsafeMutableBytes { buffer in
        SecRandomCopyBytes(kSecRandomDefault, bytes, buffer.baseAddress!)
    }
    
    guard result == errSecSuccess else {
        fatalError("Failed to generate secure random bytes")
    }
    
    return data
}

// Validate key strength
func validateKeyStrength(_ privateKey: String) -> Bool {
    // Check entropy
    let entropy = calculateEntropy(privateKey)
    return entropy > 128 // Minimum 128 bits of entropy
}
```

### 3. Secure Key Storage

```swift
// Configure keychain attributes
let keychainAttributes: [String: Any] = [
    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    kSecAttrSynchronizable as String: false, // Don't sync to iCloud
    kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave // Use Secure Enclave if available
]
```

### 4. Key Rotation

```swift
class KeyRotationManager {
    let identityManager: IdentityManager
    
    func rotateKeys(for identity: Identity) async throws {
        // Generate new key pair
        let newKeyPair = try CoreNostr.createKeyPair()
        
        // Create rotation event
        let rotationEvent = try await createKeyRotationEvent(
            from: identity,
            to: newKeyPair.publicKey
        )
        
        // Publish rotation event
        await publishRotationEvent(rotationEvent)
        
        // Update local storage
        try await updateStoredKeys(identity: identity, newKeyPair: newKeyPair)
        
        // Notify followers
        await notifyFollowers(of: identity, about: newKeyPair.publicKey)
    }
}
```

### 5. Emergency Recovery

```swift
class KeyRecovery {
    func createRecoveryKit(for identity: Identity) async throws -> RecoveryKit {
        let keyPair = try await getKeyPair(for: identity)
        
        // Generate recovery code
        let recoveryCode = generateRecoveryCode()
        
        // Create encrypted backup
        let encryptedBackup = try encrypt(
            keyPair.privateKey,
            with: recoveryCode
        )
        
        // Split into shares (Shamir's Secret Sharing)
        let shares = try splitIntoShares(
            encryptedBackup,
            threshold: 3,
            total: 5
        )
        
        return RecoveryKit(
            identityId: identity.id,
            recoveryCode: recoveryCode,
            shares: shares,
            createdAt: Date()
        )
    }
    
    func recoverFromShares(
        _ shares: [RecoveryShare],
        recoveryCode: String
    ) async throws -> KeyPair {
        // Reconstruct secret
        let encryptedBackup = try reconstructFromShares(shares)
        
        // Decrypt
        let privateKey = try decrypt(encryptedBackup, with: recoveryCode)
        
        return try KeyPair(privateKey: privateKey)
    }
}

struct RecoveryKit {
    let identityId: String
    let recoveryCode: String
    let shares: [RecoveryShare]
    let createdAt: Date
}

struct RecoveryShare {
    let index: Int
    let data: Data
}
```

## Troubleshooting

### Common Issues and Solutions

**Keychain Access Errors**
```swift
func handleKeychainError(_ error: Error) {
    if let status = error as? OSStatus {
        switch status {
        case errSecItemNotFound:
            print("Key not found in keychain")
        case errSecAuthFailed:
            print("Authentication failed")
        case errSecUserCanceled:
            print("User canceled authentication")
        case errSecInteractionNotAllowed:
            print("Interaction not allowed (device locked?)")
        default:
            print("Keychain error: \\(status)")
        }
    }
}
```

**Biometric Changes**
```swift
// Detect and handle biometric changes
func detectBiometricChanges() {
    let context = LAContext()
    
    if let domainState = context.evaluatedPolicyDomainState {
        // Store domain state
        UserDefaults.standard.set(domainState, forKey: "BiometricDomainState")
        
        // Check for changes on next launch
        if let previousState = UserDefaults.standard.data(forKey: "BiometricDomainState"),
           domainState != previousState {
            // Biometric data has changed
            handleBiometricChange()
        }
    }
}

func handleBiometricChange() {
    // Re-authenticate user
    // Consider requiring additional verification
}
```

## Summary

Proper key management is essential for NOSTR application security. NostrKit provides:

- Secure key generation and storage
- Biometric authentication integration
- Multi-identity management
- Import/export capabilities
- Recovery mechanisms

Always prioritize security when handling cryptographic keys, and follow the best practices outlined in this guide.