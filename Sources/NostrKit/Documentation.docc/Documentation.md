# ``NostrKit``

A comprehensive iOS SDK for building Nostr applications with Swift.

## Overview

NostrKit provides a complete set of tools for integrating Nostr protocol functionality into iOS applications. It builds on top of CoreNostr to provide iOS-specific features including relay management, secure key storage, and wallet integration.

### Features

- **Relay Management**: Connect to multiple relays with automatic failover and health monitoring
- **Secure Storage**: Keychain-based storage with biometric protection
- **Event Handling**: Subscribe to and publish Nostr events with ease
- **Profile Management**: Handle user profiles and metadata
- **Social Features**: Follow lists, direct messages, and social interactions
- **Wallet Integration**: NIP-47 Nostr Wallet Connect support for Lightning payments
- **Caching**: Intelligent event caching for offline support

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:BasicConcepts>
- ``RelayPool``
- ``RelayService``

### Key Management

- ``KeychainWrapper``
- ``SecureKeyStore``
- ``EnhancedSecureKeyStore``

### Event Management

- ``EventCache``
- ``ContentManager``
- ``SubscriptionManager``

### Social Features

- ``ProfileManager``
- ``SocialManager``
- ``EncryptionManager``

### Wallet Integration

- <doc:NIP47WalletConnect>
- ``WalletConnectManager``

### Remote Signing

- <doc:GettingStartedWithRemoteSigning>
- ``RemoteSignerManager``

### Advanced Features

- ``RelayDiscovery``
- ``NetworkResilience``
- ``QueryBuilder``

### Utilities

- ``NostrKitError``
- ``Logging``
- ``NostrCryptoExtensions``