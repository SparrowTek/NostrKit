import Testing
import Foundation
@testable import CoreNostr

@Suite("Crypto Tests")
struct CryptoTests {
    
    @Suite("KeyPair Tests")
    struct KeyPairTests {
        
        @Test("Generate new keypair")
        func testGenerateKeyPair() throws {
            let keyPair = try KeyPair.generate()
            
            #expect(keyPair.publicKey.count == 64)
            #expect(keyPair.privateKey.count == 64)
            #expect(keyPair.publicKey.bech32.starts(with: "npub1"))
            #expect(keyPair.privateKey.bech32.starts(with: "nsec1"))
        }
        
        @Test("Create keypair from private key hex")
        func testKeyPairFromPrivateKeyHex() throws {
            let privateKeyHex = "d09c106fb29bb1f17571cc9e97b39ae5f0ad90b1a7be9c026c8e3cf6fd5771f0"
            let expectedPublicKeyHex = "5b4be29b819e8c5b4c4d2e24dceb13e440a45a0f954a93c7387a5fa98b8cfb72"
            
            let keyPair = try KeyPair(privateKey: privateKeyHex)
            
            #expect(keyPair.privateKey == privateKeyHex)
            #expect(keyPair.publicKey == expectedPublicKeyHex)
        }
        
        @Test("Create keypair from nsec")
        func testKeyPairFromNsec() throws {
            let nsec = "nsec16zw3qmajnwclzatjexhf0wudet7c6jyc67lyqykysawldrwacuxqahjrda"
            let entity = try Bech32Entity(from: nsec)
            
            guard case .nsec(let privateKey) = entity else {
                Issue.record("Expected nsec entity")
                return
            }
            
            let keyPair = try KeyPair(privateKey: privateKey)
            
            #expect(try Bech32.encode(hrp: .nsec, data: Data(hex: keyPair.privateKey)) == nsec)
            #expect(keyPair.publicKey.count == 64)
        }
        
        @Test("Invalid private key throws error")
        func testInvalidPrivateKey() {
            #expect(throws: NostrError.self) {
                _ = try KeyPair(privateKey: "invalid")
            }
            
            #expect(throws: NostrError.self) {
                _ = try KeyPair(privateKey: String(repeating: "0", count: 64))
            }
        }
        
        @Test("Sign and verify message")
        func testSignAndVerify() throws {
            let keyPair = try KeyPair.generate()
            let message = "Hello, Nostr!"
            
            let signature = try keyPair.sign(message: message)
            
            #expect(signature.count == 128)
            
            let isValid = try keyPair.verify(signature: signature, for: message)
            #expect(isValid == true)
            
            let invalidMessage = "Different message"
            let isInvalid = try keyPair.verify(signature: signature, for: invalidMessage)
            #expect(isInvalid == false)
        }
        
        @Test("Schnorr signature format")
        func testSchnorrSignature() throws {
            let keyPair = try KeyPair.generate()
            let message = Data("Test message".utf8)
            
            let signature = try keyPair.schnorrSign(message: message)
            
            #expect(signature.count == 64)
            
            let isValid = try keyPair.schnorrVerify(signature: signature, message: message)
            #expect(isValid == true)
        }
        
        @Test("ECDH shared secret")
        func testECDHSharedSecret() throws {
            let alice = try KeyPair()
            let bob = try KeyPair()
            
            let aliceSharedSecret = try alice.getSharedSecret(with: bob.publicKey)
            let bobSharedSecret = try bob.getSharedSecret(with: alice.publicKey)
            
            #expect(aliceSharedSecret == bobSharedSecret)
            #expect(aliceSharedSecret.count == 32)
        }
    }
    
    @Suite("NIP-04 Encryption Tests")
    struct NIP04Tests {
        
        @Test("Encrypt and decrypt message")
        func testEncryptDecrypt() throws {
            let alice = try KeyPair()
            let bob = try KeyPair()
            let message = "Secret message for NIP-04"
            
            let encrypted = try alice.encrypt(message: message, to: bob.publicKey)
            
            #expect(encrypted.contains("?iv="))
            
            let decrypted = try bob.decrypt(message: encrypted, from: alice.publicKey)
            
            #expect(decrypted == message)
        }
        
        @Test("Decrypt with wrong key fails")
        func testDecryptWithWrongKey() throws {
            let alice = try KeyPair()
            let bob = try KeyPair()
            let charlie = try KeyPair()
            let message = "Secret message"
            
            let encrypted = try alice.encrypt(message: message, to: bob.publicKey)
            
            #expect(throws: NostrError.self) {
                _ = try charlie.decrypt(message: encrypted, from: alice.publicKey)
            }
        }
        
        @Test("Parse encrypted content format")
        func testEncryptedContentFormat() throws {
            let alice = try KeyPair()
            let bob = try KeyPair()
            let message = "Test message"
            
            let encrypted = try alice.encrypt(message: message, to: bob.publicKey)
            
            let parts = encrypted.split(separator: "?iv=")
            #expect(parts.count == 2)
            
            let ciphertext = String(parts[0])
            let iv = String(parts[1])
            
            #expect(!ciphertext.isEmpty)
            #expect(iv.count == 32) // 16 bytes hex encoded
        }
    }
    
    @Suite("BIP39 Mnemonic Tests")
    struct BIP39Tests {
        
        @Test("Generate mnemonic with different word counts")
        func testGenerateMnemonic() throws {
            let wordCounts: [BIP39.WordCount] = [.twelve, .fifteen, .eighteen, .twentyOne, .twentyFour]
            
            for wordCount in wordCounts {
                let mnemonic = try BIP39.generateMnemonic(wordCount: wordCount)
                let words = mnemonic.split(separator: " ")
                
                #expect(words.count == wordCount.rawValue)
                
                // Verify all words are in the wordlist
                for word in words {
                    #expect(BIP39.isValidWord(String(word)) == true)
                }
            }
        }
        
        @Test("Mnemonic to seed")
        func testMnemonicToSeed() throws {
            let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
            let passphrase = "TREZOR"
            
            let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic, passphrase: passphrase)
            
            #expect(seed == "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04")
        }
        
        @Test("Validate mnemonic")
        func testValidateMnemonic() {
            let validMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
            #expect(BIP39.isValidMnemonic(validMnemonic) == true)
            
            let invalidMnemonic = "invalid words that are not in wordlist"
            #expect(BIP39.isValidMnemonic(invalidMnemonic) == false)
            
            let wrongChecksum = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"
            #expect(BIP39.isValidMnemonic(wrongChecksum) == false)
        }
        
        @Test("Entropy to mnemonic")
        func testEntropyToMnemonic() throws {
            let entropy = Data(hex: "00000000000000000000000000000000")
            let mnemonic = try BIP39.entropyToMnemonic(entropy: entropy)
            
            #expect(mnemonic == "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        }
    }
    
    @Suite("BIP32 Key Derivation Tests")
    struct BIP32Tests {
        
        @Test("Derive master key from seed")
        func testDeriveMasterKey() throws {
            let seed = Data(hex: "000102030405060708090a0b0c0d0e0f")
            let masterKey = try BIP32.deriveMasterKey(from: seed)
            
            #expect(masterKey.privateKey.count == 32)
            #expect(masterKey.chainCode.count == 32)
        }
        
        @Test("Derive child keys")
        func testDeriveChildKeys() throws {
            let seed = Data(hex: "000102030405060708090a0b0c0d0e0f")
            let masterKey = try BIP32.deriveMasterKey(from: seed)
            
            // Derive m/0
            let child0 = try BIP32.deriveChildKey(from: masterKey, index: 0)
            #expect(child0.privateKey != masterKey.privateKey)
            
            // Derive m/0/1
            let child0_1 = try BIP32.deriveChildKey(from: child0, index: 1)
            #expect(child0_1.privateKey != child0.privateKey)
            
            // Hardened derivation m/0'
            let child0H = try BIP32.deriveChildKey(from: masterKey, index: 0x80000000)
            #expect(child0H.privateKey != child0.privateKey)
        }
        
        @Test("Derive from path")
        func testDeriveFromPath() throws {
            let seed = Data(hex: "000102030405060708090a0b0c0d0e0f")
            let path = "m/44'/1237'/0'/0/0" // Nostr derivation path
            
            let derivedKey = try BIP32.deriveKey(from: seed, path: path)
            
            #expect(derivedKey.privateKey.count == 32)
            
            // Verify step-by-step derivation matches
            let masterKey = try BIP32.deriveMasterKey(from: seed)
            let step1 = try BIP32.deriveChildKey(from: masterKey, index: 44 + 0x80000000)
            let step2 = try BIP32.deriveChildKey(from: step1, index: 1237 + 0x80000000)
            let step3 = try BIP32.deriveChildKey(from: step2, index: 0 + 0x80000000)
            let step4 = try BIP32.deriveChildKey(from: step3, index: 0)
            let step5 = try BIP32.deriveChildKey(from: step4, index: 0)
            
            #expect(derivedKey.privateKey == step5.privateKey)
        }
        
        @Test("Invalid derivation path")
        func testInvalidDerivationPath() throws {
            let seed = Data(hex: "000102030405060708090a0b0c0d0e0f")
            
            #expect(throws: NostrError.self) {
                _ = try BIP32.deriveKey(from: seed, path: "invalid/path")
            }
            
            #expect(throws: NostrError.self) {
                _ = try BIP32.deriveKey(from: seed, path: "m/abc/def")
            }
        }
    }
    
    @Suite("NIP-06 Tests")
    struct NIP06Tests {
        
        @Test("Derive Nostr private key from mnemonic")
        func testDeriveNostrKey() throws {
            let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
            let passphrase = ""
            
            let privateKey = try NIP06.deriveNostrPrivateKey(from: mnemonic, passphrase: passphrase)
            
            #expect(privateKey.count == 64)
            #expect(privateKey.bech32.starts(with: "nsec1"))
        }
        
        @Test("Derive with account index")
        func testDeriveWithAccountIndex() throws {
            let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
            
            let account0 = try NIP06.deriveNostrPrivateKey(from: mnemonic, accountIndex: 0)
            let account1 = try NIP06.deriveNostrPrivateKey(from: mnemonic, accountIndex: 1)
            
            #expect(account0 != account1)
        }
        
        @Test("Standard derivation path")
        func testStandardDerivationPath() {
            #expect(NIP06.standardDerivationPath(accountIndex: 0) == "m/44'/1237'/0'/0/0")
            #expect(NIP06.standardDerivationPath(accountIndex: 1) == "m/44'/1237'/1'/0/0")
            #expect(NIP06.standardDerivationPath(accountIndex: 999) == "m/44'/1237'/999'/0/0")
        }
    }
    
    @Suite("NostrCrypto Utilities Tests")
    struct NostrCryptoTests {
        
        @Test("Random bytes generation")
        func testRandomBytes() throws {
            let bytes1 = try NostrCrypto.randomBytes(count: 32)
            let bytes2 = try NostrCrypto.randomBytes(count: 32)
            
            #expect(bytes1.count == 32)
            #expect(bytes2.count == 32)
            #expect(bytes1 != bytes2) // Should be random
            
            // Test different sizes
            let small = try NostrCrypto.randomBytes(count: 16)
            #expect(small.count == 16)
            
            let large = try NostrCrypto.randomBytes(count: 64)
            #expect(large.count == 64)
        }
        
        @Test("SHA256 hashing")
        func testSHA256() {
            let message = "Hello, Nostr!"
            let data = Data(message.utf8)
            
            let hash = NostrCrypto.sha256(data)
            
            #expect(hash.count == 32)
            #expect(hash == "7e3d87e53ba7e82fe36dd18cd515e2cee2f265a784de2549a8c91932ce65b5a7")
        }
        
        @Test("HMAC-SHA256")
        func testHMACSHA256() throws {
            let key = Data("key".utf8)
            let message = Data("message".utf8)
            
            let hmac = try NostrCrypto.hmacSHA256(key: key, message: message)
            
            #expect(hmac.count == 32)
            #expect(hmac == "6e9ef29b75fffc5b7abae527d58fdadb2fe42e7219011976917343065f58ed4a")
        }
        
        @Test("AES encryption and decryption")
        func testAESEncryption() throws {
            let key = try NostrCrypto.randomBytes(count: 32)
            let iv = try NostrCrypto.randomBytes(count: 16)
            let plaintext = "Secret message for AES encryption"
            
            let encrypted = try NostrCrypto.aesEncrypt(
                plaintext: Data(plaintext.utf8),
                key: key,
                iv: iv
            )
            
            let decrypted = try NostrCrypto.aesDecrypt(
                ciphertext: encrypted,
                key: key,
                iv: iv
            )
            
            #expect(String(data: decrypted, encoding: .utf8) == plaintext)
        }
    }
}

// Helper extension for hex encoding
extension Data {
    init?(hex: String) {
        let length = hex.count / 2
        var data = Data(capacity: length)
        for i in 0..<length {
            let startIndex = hex.index(hex.startIndex, offsetBy: i * 2)
            let endIndex = hex.index(startIndex, offsetBy: 2)
            let subString = hex[startIndex..<endIndex]
            guard let byte = UInt8(subString, radix: 16) else { return nil }
            data.append(byte)
        }
        self = data
    }
    
    var hex: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}