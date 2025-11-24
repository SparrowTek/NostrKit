import Foundation
import CoreNostr
import CryptoKit
import Security
import CommonCrypto

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
        guard count > 0 else { return Data() }
        
        var bytes = Data(count: count)
        let result = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
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
        guard key.count == kCCKeySizeAES256 else { throw NostrError.encryptionError(operation: .encrypt, reason: "Key must be 32 bytes") }
        guard iv.count == kCCBlockSizeAES128 else { throw NostrError.encryptionError(operation: .encrypt, reason: "IV must be 16 bytes") }
        
        return try aesCBCOperation(
            operation: CCOperation(kCCEncrypt),
            input: plaintext,
            key: key,
            iv: iv,
            errorOperation: .encrypt
        )
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
        guard key.count == kCCKeySizeAES256 else { throw NostrError.encryptionError(operation: .decrypt, reason: "Key must be 32 bytes") }
        guard iv.count == kCCBlockSizeAES128 else { throw NostrError.encryptionError(operation: .decrypt, reason: "IV must be 16 bytes") }
        
        return try aesCBCOperation(
            operation: CCOperation(kCCDecrypt),
            input: ciphertext,
            key: key,
            iv: iv,
            errorOperation: .decrypt
        )
    }
}

// MARK: - Private Helpers

private extension NostrCrypto {
    static func aesCBCOperation(
        operation: CCOperation,
        input: Data,
        key: Data,
        iv: Data,
        errorOperation: NostrError.EncryptionOperation
    ) throws -> Data {
        var outputLength: size_t = 0
        let outputCapacity = input.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outputBytes in
            guard let outputBase = outputBytes.baseAddress else {
                return CCCryptorStatus(kCCMemoryFailure)
            }
            
            return input.withUnsafeBytes { inputBytes in
                guard let inputBase = inputBytes.baseAddress else {
                    return CCCryptorStatus(kCCParamError)
                }
                
                return iv.withUnsafeBytes { ivBytes in
                    guard let ivBase = ivBytes.baseAddress else {
                        return CCCryptorStatus(kCCParamError)
                    }
                    
                    return key.withUnsafeBytes { keyBytes in
                        guard let keyBase = keyBytes.baseAddress else {
                            return CCCryptorStatus(kCCParamError)
                        }
                        
                        return CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBase,
                            key.count,
                            ivBase,
                            inputBase,
                            input.count,
                            outputBase,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        
        guard status == kCCSuccess else {
            let reason = ccStatusDescription(status)
            throw NostrError.encryptionError(operation: errorOperation, reason: reason)
        }
        
        output.removeSubrange(outputLength..<output.count)
        return output
    }
    
    static func ccStatusDescription(_ status: CCCryptorStatus) -> String {
        switch status {
        case CCCryptorStatus(kCCSuccess):
            return "Operation completed successfully"
        case CCCryptorStatus(kCCParamError):
            return "Parameter error"
        case CCCryptorStatus(kCCBufferTooSmall):
            return "Output buffer too small"
        case CCCryptorStatus(kCCMemoryFailure):
            return "Memory failure"
        case CCCryptorStatus(kCCAlignmentError):
            return "Input alignment error"
        case CCCryptorStatus(kCCDecodeError):
            return "Input decode error"
        case CCCryptorStatus(kCCUnimplemented):
            return "Operation not implemented"
        default:
            return "Unknown error (status \(status))"
        }
    }
}
