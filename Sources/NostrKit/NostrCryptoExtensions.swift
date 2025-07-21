import Foundation
import CoreNostr
import CryptoKit
import CryptoSwift

// MARK: - Data Extensions for NostrKit

public extension Data {
    /// Converts Data to a hexadecimal string representation.
    /// 
    /// - Returns: Lowercase hexadecimal string
    var hex: String {
        return self.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Creates Data from a hexadecimal string
    /// - Parameter hex: Hex string (with or without 0x prefix)
    init(hex: String) {
        let hex = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        let len = hex.count / 2
        var data = Data(capacity: len)
        for i in 0..<len {
            let j = hex.index(hex.startIndex, offsetBy: i*2)
            let k = hex.index(j, offsetBy: 2)
            let bytes = hex[j..<k]
            if var num = UInt8(bytes, radix: 16) {
                data.append(&num, count: 1)
            }
        }
        self = data
    }
}

// MARK: - NostrEvent Extensions for NostrKit

public extension NostrEvent {
    /// Converts the event to a JSON string
    /// - Returns: JSON string representation of the event
    /// - Throws: Serialization error if encoding fails
    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw NostrError.serializationError(type: "NostrEvent", reason: "Failed to convert to UTF-8 string")
        }
        return string
    }
}

// MARK: - NostrCrypto Extensions for NostrKit

public extension NostrCrypto {
    /// Generates cryptographically secure random bytes.
    /// 
    /// - Parameter count: The number of random bytes to generate
    /// - Returns: Random bytes as Data
    /// - Throws: ``NostrError/cryptographyError(_:)`` if random generation fails
    static func randomBytes(count: Int) throws -> Data {
        var bytes = Data(count: count)
        let result = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        
        guard result == errSecSuccess else {
            throw NostrError.cryptographyError(operation: .keyGeneration, reason: "Failed to generate random bytes")
        }
        
        return bytes
    }
    
    /// Computes SHA-256 hash of the given data.
    /// 
    /// - Parameter data: The data to hash
    /// - Returns: 32-byte hash result
    static func sha256(_ data: Data) -> Data {
        let digest = CryptoKit.SHA256.hash(data: data)
        return Data(digest)
    }
    
    /// Computes HMAC-SHA256 of the given message with key.
    /// 
    /// - Parameters:
    ///   - key: The secret key
    ///   - message: The message to authenticate
    /// - Returns: 32-byte HMAC result
    /// - Throws: ``NostrError/cryptographyError(_:)`` if HMAC computation fails
    static func hmacSHA256(key: Data, message: Data) throws -> Data {
        let mac = HMAC<CryptoKit.SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(mac)
    }
    
    /// Encrypts data using AES-256-CBC.
    /// 
    /// - Parameters:
    ///   - plaintext: The data to encrypt
    ///   - key: 32-byte encryption key
    ///   - iv: 16-byte initialization vector
    /// - Returns: Encrypted data
    /// - Throws: ``NostrError/encryptionError(_:)`` if encryption fails
    static func aesEncrypt(plaintext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 32 else {
            throw NostrError.encryptionError(operation: .encrypt, reason: "Key must be 32 bytes")
        }
        guard iv.count == 16 else {
            throw NostrError.encryptionError(operation: .encrypt, reason: "IV must be 16 bytes")
        }
        
        do {
            let aes = try AES(key: Array(key), blockMode: CBC(iv: Array(iv)), padding: .pkcs7)
            let encrypted = try aes.encrypt(Array(plaintext))
            return Data(encrypted)
        } catch {
            throw NostrError.encryptionError(operation: .encrypt, reason: error.localizedDescription)
        }
    }
    
    /// Decrypts data using AES-256-CBC.
    /// 
    /// - Parameters:
    ///   - ciphertext: The data to decrypt
    ///   - key: 32-byte decryption key
    ///   - iv: 16-byte initialization vector
    /// - Returns: Decrypted data
    /// - Throws: ``NostrError/encryptionError(_:)`` if decryption fails
    static func aesDecrypt(ciphertext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 32 else {
            throw NostrError.encryptionError(operation: .decrypt, reason: "Key must be 32 bytes")
        }
        guard iv.count == 16 else {
            throw NostrError.encryptionError(operation: .decrypt, reason: "IV must be 16 bytes")
        }
        
        do {
            let aes = try AES(key: Array(key), blockMode: CBC(iv: Array(iv)), padding: .pkcs7)
            let decrypted = try aes.decrypt(Array(ciphertext))
            return Data(decrypted)
        } catch {
            throw NostrError.encryptionError(operation: .decrypt, reason: error.localizedDescription)
        }
    }
}