/// NostrKit - iOS-specific NOSTR protocol implementation.
///
/// NostrKit provides iOS-specific functionality for the NOSTR protocol,
/// including WebSocket connections, relay management, and networking features
/// that are specific to Apple platforms.
///
/// ## Overview
/// NostrKit builds on top of CoreNostr to provide:
/// - WebSocket relay connections using URLSession
/// - iOS-specific networking and caching
/// - Platform-optimized performance features
///
/// ## Usage
/// ```swift
/// import NostrKit
/// import CoreNostr
///
/// // Use CoreNostr for protocol operations
/// let keyPair = try CoreNostr.createKeyPair()
/// let event = try CoreNostr.createTextNote(
///     keyPair: keyPair,
///     content: "Hello from iOS!"
/// )
///
/// // Use NostrKit for relay operations
/// let relayService = RelayService()
/// try relayService.connectToSocket(URL(string: "wss://relay.nostr.com"))
/// ```
///
/// - Note: Import both NostrKit and CoreNostr in your iOS app to access
///         the full range of NOSTR functionality.

@_exported import CoreNostr