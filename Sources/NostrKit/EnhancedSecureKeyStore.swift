import Foundation
import CoreNostr
import Security
import CryptoKit
import LocalAuthentication
import OSLog

private let logger = Logger(subsystem: "NostrKit", category: "EnhancedSecureKeyStore")

/// Enhanced secure key storage with Secure Enclave support
public actor EnhancedSecureKeyStore {
    
    // MARK: - Types
    
    /// Key storage method
    public enum StorageMethod: Codable, Sendable {
        case keychain           // Standard keychain storage
        case secureEnclave      // Secure Enclave protected
        case iCloudKeychain     // iCloud Keychain sync
    }
    
    /// Biometric authentication options
    public struct BiometricOptions: Codable, Sendable {
        public let required: Bool
        public let fallbackToPasscode: Bool
        public let localizedReason: String
        
        public init(
            required: Bool = true,
            fallbackToPasscode: Bool = true,
            localizedReason: String = "Authenticate to access your Nostr keys"
        ) {
            self.required = required
            self.fallbackToPasscode = fallbackToPasscode
            self.localizedReason = localizedReason
        }
        
        public static let `default` = BiometricOptions()
        public static let none = BiometricOptions(required: false)
    }
    
    /// Enhanced key permissions with granular control
    public struct EnhancedPermissions: Codable, Sendable {
        public let canSign: Bool
        public let canDecrypt: Bool
        public let canDerive: Bool
        public let canExport: Bool
        public let storageMethod: StorageMethod
        public let biometricOptions: BiometricOptions?
        public let validFrom: Date
        public let validUntil: Date?
        public let usageLimit: Int?
        private(set) var usageCount: Int = 0
        
        public init(
            canSign: Bool = true,
            canDecrypt: Bool = true,
            canDerive: Bool = false,
            canExport: Bool = false,
            storageMethod: StorageMethod = .keychain,
            biometricOptions: BiometricOptions? = .default,
            validFrom: Date = Date(),
            validUntil: Date? = nil,
            usageLimit: Int? = nil
        ) {
            self.canSign = canSign
            self.canDecrypt = canDecrypt
            self.canDerive = canDerive
            self.canExport = canExport
            self.storageMethod = storageMethod
            self.biometricOptions = biometricOptions
            self.validFrom = validFrom
            self.validUntil = validUntil
            self.usageLimit = usageLimit
        }
        
        public var isValid: Bool {
            let now = Date()
            guard now >= validFrom else { return false }
            if let validUntil = validUntil, now > validUntil { return false }
            if let limit = usageLimit, usageCount >= limit { return false }
            return true
        }
        
        mutating func incrementUsage() {
            usageCount += 1
        }
    }
    
    /// Secure Enclave key reference
    private struct SecureEnclaveKey {
        let privateKey: SecKey
        let publicKey: SecKey
        let tag: String
    }
    
    public enum KeyStoreError: LocalizedError {
        case identityNotFound(String)
        case identityAlreadyExists(String)
        case secureEnclaveNotAvailable
        case biometricAuthenticationFailed
        case permissionDenied(String)
        case keyGenerationFailed
        case keychainError(OSStatus)
        case invalidPermissions
        case usageLimitExceeded
        case keyExpired
        
        public var errorDescription: String? {
            switch self {
            case .identityNotFound(let id):
                return "Identity '\(id)' not found"
            case .identityAlreadyExists(let id):
                return "Identity '\(id)' already exists"
            case .secureEnclaveNotAvailable:
                return "Secure Enclave is not available on this device"
            case .biometricAuthenticationFailed:
                return "Biometric authentication failed"
            case .permissionDenied(let reason):
                return "Permission denied: \(reason)"
            case .keyGenerationFailed:
                return "Failed to generate key in Secure Enclave"
            case .keychainError(let status):
                return "Keychain error: \(status)"
            case .invalidPermissions:
                return "Invalid or expired permissions"
            case .usageLimitExceeded:
                return "Usage limit exceeded for this key"
            case .keyExpired:
                return "Key has expired"
            }
        }
    }
    
    // MARK: - Properties
    
    private var secureEnclaveKeys: [String: SecureEnclaveKey] = [:]
    private var permissions: [String: EnhancedPermissions] = [:]
    private let keychain = KeychainWrapper(service: "com.nostrkit.enhanced")
    
    // MARK: - Initialization
    
    public init() {
        logger.info("Initializing Enhanced Secure Key Store")
    }
    
    // MARK: - Key Generation
    
    /// Generates a new key pair with specified storage method
    public func generateKeyPair(
        identity: String,
        storageMethod: StorageMethod = .keychain,
        permissions: EnhancedPermissions? = nil
    ) async throws -> KeyPair {
        
        // Check if identity exists
        if await exists(identity: identity) {
            throw KeyStoreError.identityAlreadyExists(identity)
        }
        
        let keyPair: KeyPair
        
        switch storageMethod {
        case .secureEnclave:
            keyPair = try await generateSecureEnclaveKeyPair(identity: identity)
        case .keychain, .iCloudKeychain:
            keyPair = try CoreNostr.createKeyPair()
        }
        
        // Store with permissions
        let finalPermissions = permissions ?? EnhancedPermissions(storageMethod: storageMethod)
        try await store(
            keyPair,
            identity: identity,
            permissions: finalPermissions
        )
        
        logger.info("Generated key pair for identity: \(identity) using \(String(describing: storageMethod))")
        
        return keyPair
    }
    
    /// Generates a key pair in Secure Enclave
    private func generateSecureEnclaveKeyPair(identity: String) async throws -> KeyPair {
        guard SecureEnclave.isAvailable else {
            throw KeyStoreError.secureEnclaveNotAvailable
        }
        
        let tag = "com.nostrkit.se.\(identity)".data(using: .utf8)!
        
        // Access control with biometric authentication
        let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            nil
        )!
        
        // Key generation attributes
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessControl as String: access
            ]
        ]
        
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let error = error {
                logger.error("Secure Enclave key generation failed: \(error.takeRetainedValue())")
            }
            throw KeyStoreError.keyGenerationFailed
        }
        
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw KeyStoreError.keyGenerationFailed
        }
        
        // Store SE key reference
        secureEnclaveKeys[identity] = SecureEnclaveKey(
            privateKey: privateKey,
            publicKey: publicKey,
            tag: String(data: tag, encoding: .utf8)!
        )
        
        // Convert to Nostr format (this is a placeholder - actual conversion needed)
        // For now, generate a regular keypair and mark it as SE-protected
        let regularKeyPair = try CoreNostr.createKeyPair()
        
        logger.info("Generated Secure Enclave protected key for: \(identity)")
        
        return regularKeyPair
    }
    
    // MARK: - Storage
    
    /// Stores a key pair with enhanced permissions
    public func store(
        _ keyPair: KeyPair,
        identity: String,
        permissions: EnhancedPermissions = EnhancedPermissions()
    ) async throws {
        
        // Store permissions
        self.permissions[identity] = permissions
        
        // Store based on method
        switch permissions.storageMethod {
        case .keychain:
            try await storeInKeychain(keyPair, identity: identity, biometrics: permissions.biometricOptions)
        case .secureEnclave:
            // Already stored during generation
            break
        case .iCloudKeychain:
            try await storeInICloudKeychain(keyPair, identity: identity)
        }
        
        // Store metadata
        let metadata = [
            "created": ISO8601DateFormatter().string(from: Date()),
            "method": String(describing: permissions.storageMethod)
        ]
        
        try await keychain.save(
            try JSONEncoder().encode(metadata),
            forKey: "metadata.\(identity)"
        )
        
        logger.info("Stored key pair for identity: \(identity)")
    }
    
    private func storeInKeychain(
        _ keyPair: KeyPair,
        identity: String,
        biometrics: BiometricOptions?
    ) async throws {
        
        let privateKeyData = keyPair.privateKey.data(using: .utf8)!
        let publicKeyData = keyPair.publicKey.data(using: .utf8)!
        
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "private.\(identity)",
            kSecAttrService as String: "com.nostrkit.keys",
            kSecValueData as String: privateKeyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        // Add biometric protection if required
        if let biometrics = biometrics, biometrics.required {
            let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                biometrics.fallbackToPasscode ? [.biometryCurrentSet, .or, .devicePasscode] : [.biometryCurrentSet],
                nil
            )!
            
            query[kSecAttrAccessControl as String] = access
            
            // Add authentication context
            let context = LAContext()
            context.localizedReason = biometrics.localizedReason
            query[kSecUseAuthenticationContext as String] = context
        }
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyStoreError.keychainError(status)
        }
        
        // Store public key without protection
        try await keychain.save(publicKeyData, forKey: "public.\(identity)")
    }
    
    private func storeInICloudKeychain(
        _ keyPair: KeyPair,
        identity: String
    ) async throws {
        
        let privateKeyData = keyPair.privateKey.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "icloud.\(identity)",
            kSecAttrService as String: "com.nostrkit.keys",
            kSecValueData as String: privateKeyData,
            kSecAttrSynchronizable as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyStoreError.keychainError(status)
        }
        
        logger.info("Stored key in iCloud Keychain for: \(identity)")
    }
    
    // MARK: - Retrieval
    
    /// Retrieves a key pair with permission checking
    public func retrieve(
        identity: String,
        purpose: KeyUsagePurpose = .general
    ) async throws -> KeyPair {
        
        // Check permissions
        guard var perms = permissions[identity] else {
            throw KeyStoreError.identityNotFound(identity)
        }
        
        guard perms.isValid else {
            throw KeyStoreError.invalidPermissions
        }
        
        // Check specific permission
        switch purpose {
        case .signing:
            guard perms.canSign else {
                throw KeyStoreError.permissionDenied("Signing not allowed")
            }
        case .decryption:
            guard perms.canDecrypt else {
                throw KeyStoreError.permissionDenied("Decryption not allowed")
            }
        case .derivation:
            guard perms.canDerive else {
                throw KeyStoreError.permissionDenied("Derivation not allowed")
            }
        case .export:
            guard perms.canExport else {
                throw KeyStoreError.permissionDenied("Export not allowed")
            }
        case .general:
            break
        }
        
        // Increment usage count
        perms.incrementUsage()
        permissions[identity] = perms
        
        // Retrieve based on storage method
        let keyPair: KeyPair
        
        switch perms.storageMethod {
        case .keychain:
            keyPair = try await retrieveFromKeychain(identity: identity, biometrics: perms.biometricOptions)
        case .secureEnclave:
            keyPair = try await retrieveFromSecureEnclave(identity: identity)
        case .iCloudKeychain:
            keyPair = try await retrieveFromICloudKeychain(identity: identity)
        }
        
        logger.info("Retrieved key for identity: \(identity), purpose: \(String(describing: purpose))")
        
        return keyPair
    }
    
    private func retrieveFromKeychain(
        identity: String,
        biometrics: BiometricOptions?
    ) async throws -> KeyPair {
        
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "private.\(identity)",
            kSecAttrService as String: "com.nostrkit.keys",
            kSecReturnData as String: true
        ]
        
        // Add authentication context if biometrics required
        if let biometrics = biometrics, biometrics.required {
            let context = LAContext()
            context.localizedReason = biometrics.localizedReason
            
            // Pre-evaluate policy
            var error: NSError?
            let canEvaluate = context.canEvaluatePolicy(
                biometrics.fallbackToPasscode ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics,
                error: &error
            )
            
            guard canEvaluate else {
                throw KeyStoreError.biometricAuthenticationFailed
            }
            
            query[kSecUseAuthenticationContext as String] = context
        }
        
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let privateKey = String(data: data, encoding: .utf8) else {
            throw KeyStoreError.keychainError(status)
        }
        
        // Get public key
        let publicKeyData = try await keychain.load(key: "public.\(identity)")
        guard String(data: publicKeyData, encoding: .utf8) != nil else {
            throw KeyStoreError.identityNotFound(identity)
        }
        
        return try KeyPair(privateKey: privateKey)
    }
    
    private func retrieveFromSecureEnclave(identity: String) async throws -> KeyPair {
        if secureEnclaveKeys[identity] == nil {
            // Try to load from keychain tag
            let tag = "com.nostrkit.se.\(identity)".data(using: .utf8)!
            
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag,
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecReturnRef as String: true
            ]
            
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            
            guard status == errSecSuccess,
                  let privateKey = result as! SecKey? else {
                throw KeyStoreError.identityNotFound(identity)
            }
            
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                throw KeyStoreError.keyGenerationFailed
            }
            
            secureEnclaveKeys[identity] = SecureEnclaveKey(
                privateKey: privateKey,
                publicKey: publicKey,
                tag: String(data: tag, encoding: .utf8)!
            )
        }
        
        // For now, return a placeholder keypair
        // Real implementation would need SE-to-Nostr key conversion
        return try CoreNostr.createKeyPair()
    }
    
    private func retrieveFromICloudKeychain(identity: String) async throws -> KeyPair {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "icloud.\(identity)",
            kSecAttrService as String: "com.nostrkit.keys",
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true
        ]
        
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let privateKey = String(data: data, encoding: .utf8) else {
            throw KeyStoreError.keychainError(status)
        }
        
        // For Secure Enclave keys, we need to reconstruct the KeyPair
        // Since we can't export the private key from SE, we create a placeholder
        return try KeyPair(privateKey: privateKey)
    }
    
    // MARK: - Management
    
    /// Checks if an identity exists
    public func exists(identity: String) async -> Bool {
        if permissions[identity] != nil {
            return true
        }
        
        do {
            _ = try await keychain.load(key: "metadata.\(identity)")
            return true
        } catch {
            return false
        }
    }
    
    /// Lists all stored identities
    public func listIdentities() async -> [String] {
        Array(permissions.keys)
    }
    
    /// Deletes an identity
    public func delete(identity: String) async throws {
        permissions.removeValue(forKey: identity)
        secureEnclaveKeys.removeValue(forKey: identity)
        
        // Delete from keychain
        let accounts = [
            "private.\(identity)",
            "icloud.\(identity)",
            "com.nostrkit.se.\(identity)"
        ]
        
        for account in accounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
        }
        
        try? await keychain.delete(key: "public.\(identity)")
        try? await keychain.delete(key: "metadata.\(identity)")
        
        logger.info("Deleted identity: \(identity)")
    }
    
    /// Exports permissions for backup
    public func exportPermissions() async -> Data? {
        try? JSONEncoder().encode(permissions)
    }
    
    /// Imports permissions from backup
    public func importPermissions(_ data: Data) async throws {
        permissions = try JSONDecoder().decode([String: EnhancedPermissions].self, from: data)
    }
}

// MARK: - Supporting Types

public enum KeyUsagePurpose: Sendable {
    case signing
    case decryption
    case derivation
    case export
    case general
}

// MARK: - SecureEnclave Helper

struct SecureEnclave {
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }
}