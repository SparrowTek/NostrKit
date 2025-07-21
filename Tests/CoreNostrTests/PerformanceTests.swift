import Testing
import Foundation
@testable import CoreNostr

@Suite("Performance Tests", .serialized)
struct PerformanceTests {
    
    // Number of iterations for performance tests
    let iterations = 100
    let largeIterations = 1000
    
    @Suite("Key Generation Performance")
    struct KeyGenerationPerformance {
        
        @Test("Measure keypair generation time")
        func testKeypairGenerationPerformance() throws {
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for _ in 0..<100 {
                _ = try KeyPair()
            }
            
            let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
            let avgTime = timeElapsed / 100.0
            
            print("Average keypair generation time: \(avgTime * 1000)ms")
            
            // Should be reasonably fast (less than 10ms per keypair on average)
            #expect(avgTime < 0.01)
        }
        
        @Test("Measure keypair derivation from private key")
        func testKeypairDerivationPerformance() throws {
            let privateKeys = (0..<100).map { _ in
                try! KeyPair().privateKey.hex
            }
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for privateKey in privateKeys {
                _ = try KeyPair(privateKey: privateKey)
            }
            
            let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
            let avgTime = timeElapsed / Double(privateKeys.count)
            
            print("Average keypair derivation time: \(avgTime * 1000)ms")
            
            // Derivation should be faster than generation
            #expect(avgTime < 0.005)
        }
    }
    
    @Suite("Signing Performance")
    struct SigningPerformance {
        
        @Test("Measure event signing performance")
        func testEventSigningPerformance() throws {
            let keyPair = try KeyPair()
            let messages = (0..<100).map { "Test message #\($0)" }
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for message in messages {
                _ = try CoreNostr.createTextNote(
                    content: message,
                    keyPair: keyPair
                )
            }
            
            let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
            let avgTime = timeElapsed / Double(messages.count)
            
            print("Average event signing time: \(avgTime * 1000)ms")
            
            // Should be fast (less than 5ms per event)
            #expect(avgTime < 0.005)
        }
        
        @Test("Measure raw signature performance")
        func testRawSignaturePerformance() throws {
            let keyPair = try KeyPair()
            let messages = (0..<1000).map { index in
                Data("Message \(index)".utf8)
            }
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for message in messages {
                _ = try keyPair.schnorrSign(message: message)
            }
            
            let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
            let avgTime = timeElapsed / Double(messages.count)
            
            print("Average Schnorr signature time: \(avgTime * 1000)ms")
            
            // Raw signatures should be very fast
            #expect(avgTime < 0.001)
        }
    }
    
    @Suite("Verification Performance")
    struct VerificationPerformance {
        
        @Test("Measure event verification performance")
        func testEventVerificationPerformance() throws {
            let keyPair = try KeyPair()
            
            // Pre-generate signed events
            let events = try (0..<100).map { index in
                try CoreNostr.createTextNote(
                    content: "Event #\(index)",
                    keyPair: keyPair
                )
            }
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for event in events {
                _ = try CoreNostr.verifyEvent(event)
            }
            
            let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
            let avgTime = timeElapsed / Double(events.count)
            
            print("Average event verification time: \(avgTime * 1000)ms")
            
            // Verification should be reasonably fast
            #expect(avgTime < 0.005)
        }
        
        @Test("Measure signature verification performance")
        func testSignatureVerificationPerformance() throws {
            let keyPair = try KeyPair()
            
            // Pre-generate signatures
            let signedMessages = try (0..<1000).map { index in
                let message = Data("Message \(index)".utf8)
                let signature = try keyPair.schnorrSign(message: message)
                return (message, signature)
            }
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for (message, signature) in signedMessages {
                _ = try keyPair.schnorrVerify(signature: signature, message: message)
            }
            
            let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
            let avgTime = timeElapsed / Double(signedMessages.count)
            
            print("Average Schnorr verification time: \(avgTime * 1000)ms")
            
            // Raw verification should be very fast
            #expect(avgTime < 0.001)
        }
    }
    
    @Suite("Encryption Performance")
    struct EncryptionPerformance {
        
        @Test("Measure NIP-04 encryption performance")
        func testNIP04EncryptionPerformance() throws {
            let alice = try KeyPair()
            let bob = try KeyPair()
            let messages = (0..<100).map { "Secret message #\($0)" }
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for message in messages {
                _ = try alice.encrypt(message: message, to: bob.publicKey)
            }
            
            let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
            let avgTime = timeElapsed / Double(messages.count)
            
            print("Average NIP-04 encryption time: \(avgTime * 1000)ms")
            
            // Encryption includes ECDH + AES
            #expect(avgTime < 0.01)
        }
        
        @Test("Measure NIP-04 decryption performance")
        func testNIP04DecryptionPerformance() throws {
            let alice = try KeyPair()
            let bob = try KeyPair()
            
            // Pre-encrypt messages
            let encryptedMessages = try (0..<100).map { index in
                try alice.encrypt(message: "Secret message #\(index)", to: bob.publicKey)
            }
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for encrypted in encryptedMessages {
                _ = try bob.decrypt(message: encrypted, from: alice.publicKey)
            }
            
            let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
            let avgTime = timeElapsed / Double(encryptedMessages.count)
            
            print("Average NIP-04 decryption time: \(avgTime * 1000)ms")
            
            // Decryption should be similar to encryption
            #expect(avgTime < 0.01)
        }
        
        @Test("Measure ECDH shared secret performance")
        func testECDHPerformance() throws {
            let alice = try KeyPair()
            let otherKeys = try (0..<1000).map { _ in
                try KeyPair().publicKey
            }
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for pubkey in otherKeys {
                _ = try alice.getSharedSecret(with: pubkey)
            }
            
            let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
            let avgTime = timeElapsed / Double(otherKeys.count)
            
            print("Average ECDH computation time: \(avgTime * 1000)ms")
            
            // ECDH should be fast
            #expect(avgTime < 0.001)
        }
    }
    
    @Suite("Hashing Performance")
    struct HashingPerformance {
        
        @Test("Measure SHA256 performance")
        func testSHA256Performance() {
            let data = (0..<10000).map { index in
                Data("Data chunk #\(index)".utf8)
            }
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for chunk in data {
                _ = NostrCrypto.sha256(chunk)
            }
            
            let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
            let avgTime = timeElapsed / Double(data.count)
            
            print("Average SHA256 time: \(avgTime * 1000)ms")
            
            // SHA256 should be extremely fast
            #expect(avgTime < 0.0001)
        }
        
        @Test("Measure event ID calculation performance")
        func testEventIDCalculationPerformance() throws {
            let keyPair = try KeyPair()
            let events = try (0..<1000).map { index in
                NostrEvent(
                    id: EventID(hex: String(repeating: "0", count: 64)), // Dummy ID
                    pubkey: keyPair.publicKey,
                    createdAt: Date(),
                    kind: .textNote,
                    tags: [],
                    content: "Event #\(index)",
                    signature: Signature(hex: String(repeating: "0", count: 128)) // Dummy sig
                )
            }
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for event in events {
                _ = try event.calculateId()
            }
            
            let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
            let avgTime = timeElapsed / Double(events.count)
            
            print("Average event ID calculation time: \(avgTime * 1000)ms")
            
            // ID calculation involves serialization + hashing
            #expect(avgTime < 0.001)
        }
    }
    
    @Suite("BIP39/BIP32 Performance")
    struct BIPPerformance {
        
        @Test("Measure mnemonic generation performance")
        func testMnemonicGenerationPerformance() throws {
            let wordCounts: [BIP39.WordCount] = [.twelve, .twentyFour]
            
            for wordCount in wordCounts {
                let startTime = CFAbsoluteTimeGetCurrent()
                
                for _ in 0..<100 {
                    _ = try BIP39.generateMnemonic(wordCount: wordCount)
                }
                
                let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
                let avgTime = timeElapsed / 100.0
                
                print("Average \(wordCount.rawValue)-word mnemonic generation time: \(avgTime * 1000)ms")
                
                // Mnemonic generation should be reasonably fast
                #expect(avgTime < 0.01)
            }
        }
        
        @Test("Measure seed derivation performance")
        func testSeedDerivationPerformance() throws {
            let mnemonics = try (0..<10).map { _ in
                try BIP39.generateMnemonic()
            }
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for mnemonic in mnemonics {
                _ = try BIP39.mnemonicToSeed(mnemonic: mnemonic)
            }
            
            let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
            let avgTime = timeElapsed / Double(mnemonics.count)
            
            print("Average seed derivation time: \(avgTime * 1000)ms")
            
            // Seed derivation uses PBKDF2 with 2048 iterations, so it's intentionally slow
            #expect(avgTime < 1.0) // Less than 1 second
        }
        
        @Test("Measure key derivation performance")
        func testKeyDerivationPerformance() throws {
            let seed = try BIP39.mnemonicToSeed(
                mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
            )
            
            let paths = [
                "m/44'/1237'/0'/0/0",
                "m/44'/1237'/1'/0/0",
                "m/44'/1237'/2'/0/0",
                "m/84'/0'/0'/0/0",
                "m/86'/0'/0'/0/0"
            ]
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for path in paths {
                _ = try BIP32.deriveKey(from: seed, path: path)
            }
            
            let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
            let avgTime = timeElapsed / Double(paths.count)
            
            print("Average HD key derivation time: \(avgTime * 1000)ms")
            
            // Key derivation should be reasonably fast
            #expect(avgTime < 0.05)
        }
    }
    
    @Suite("Serialization Performance")
    struct SerializationPerformance {
        
        @Test("Measure event JSON serialization performance")
        func testJSONSerializationPerformance() throws {
            let keyPair = try KeyPair()
            let events = try (0..<1000).map { index in
                try CoreNostr.createTextNote(
                    content: "Event #\(index) with some content",
                    keyPair: keyPair,
                    tags: [["t", "test"], ["p", keyPair.publicKey.hex]]
                )
            }
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for event in events {
                _ = try event.jsonString()
            }
            
            let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
            let avgTime = timeElapsed / Double(events.count)
            
            print("Average JSON serialization time: \(avgTime * 1000)ms")
            
            // JSON serialization should be fast
            #expect(avgTime < 0.001)
        }
        
        @Test("Measure event JSON deserialization performance")
        func testJSONDeserializationPerformance() throws {
            let keyPair = try KeyPair()
            
            // Pre-serialize events
            let jsonStrings = try (0..<1000).map { index in
                let event = try CoreNostr.createTextNote(
                    content: "Event #\(index)",
                    keyPair: keyPair
                )
                return try event.jsonString()
            }
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for json in jsonStrings {
                _ = try JSONDecoder().decode(NostrEvent.self, from: Data(json.utf8))
            }
            
            let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
            let avgTime = timeElapsed / Double(jsonStrings.count)
            
            print("Average JSON deserialization time: \(avgTime * 1000)ms")
            
            // JSON deserialization should be fast
            #expect(avgTime < 0.001)
        }
    }
}