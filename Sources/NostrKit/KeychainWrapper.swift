import Foundation
import Security

/// A simple wrapper around iOS Keychain Services for secure storage.
actor KeychainWrapper {
    
    enum KeychainError: Error, LocalizedError {
        case unhandledError(status: OSStatus)
        case noData
        case unexpectedData
        case duplicateItem
        
        var errorDescription: String? {
            switch self {
            case .unhandledError(let status):
                return "Keychain error: \(status)"
            case .noData:
                return "No data found in keychain"
            case .unexpectedData:
                return "Unexpected data format in keychain"
            case .duplicateItem:
                return "Item already exists in keychain"
            }
        }
    }
    
    private let service: String
    
    init(service: String) {
        self.service = service
    }
    
    /// Saves data to the keychain
    func save(_ data: Data, forKey key: String, withAccess access: String = String(kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: access as CFString
        ]
        
        // First try to delete any existing item
        SecItemDelete(query as CFDictionary)
        
        // Add the new item
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
    }
    
    /// Saves a string to the keychain
    func save(_ string: String, forKey key: String, withAccess access: String = String(kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)) throws {
        guard let data = string.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }
        try save(data, forKey: key, withAccess: access)
    }
    
    /// Loads data from the keychain
    func load(key: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.noData
            }
            throw KeychainError.unhandledError(status: status)
        }
        
        guard let data = dataTypeRef as? Data else {
            throw KeychainError.unexpectedData
        }
        
        return data
    }
    
    /// Loads a string from the keychain
    func loadString(key: String) throws -> String {
        let data = try load(key: key)
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return string
    }
    
    /// Deletes an item from the keychain
    func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }
    
    /// Checks if an item exists in the keychain
    func exists(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Lists all keys for this service
    func allKeys() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        var items: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        
        guard status == errSecSuccess,
              let itemsArray = items as? [[String: Any]] else {
            return []
        }
        
        return itemsArray.compactMap { $0[kSecAttrAccount as String] as? String }
    }
    
    /// Checks if biometric authentication is available
    func canUseBiometrics() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }
}

// Import LocalAuthentication for biometric checks
import LocalAuthentication