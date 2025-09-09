# Getting Started with NostrKit

Build your first NOSTR application for iOS and macOS using NostrKit.

## Overview

This tutorial will guide you through creating a fully functional NOSTR client application from scratch. You'll learn how to:

- Set up NostrKit in your project
- Connect to NOSTR relays
- Create and manage user identities
- Publish and subscribe to events
- Build a real-time feed interface
- Implement social features

By the end of this tutorial, you'll have a working NOSTR app that can interact with the global NOSTR network.

## Prerequisites

Before starting, ensure you have:

- Xcode 16.0 or later
- iOS 17.0+ or macOS 14.0+ deployment target
- Basic knowledge of Swift and SwiftUI
- Understanding of async/await in Swift

## Chapter 1: Setting Up Your Project

### Step 1: Create a New Xcode Project

1. Open Xcode and create a new project
2. Choose **iOS App** or **macOS App**
3. Product Name: **MyNostrApp**
4. Interface: **SwiftUI**
5. Language: **Swift**
6. Use Core Data: **No**
7. Include Tests: **Yes**

### Step 2: Add NostrKit Package

1. Select your project in the navigator
2. Select your app target
3. Go to **General** → **Frameworks, Libraries, and Embedded Content**
4. Click **+** → **Add Package Dependency**
5. Enter: `https://github.com/SparrowTek/NostrKit.git`
6. Add both **NostrKit** and **CoreNostr** to your app

### Step 3: Configure App Capabilities

For iOS apps, enable these capabilities:

1. **Keychain Sharing** (for secure key storage)
2. **Background Modes** → **Background fetch** (for notifications)
3. **Face ID Usage Description** in Info.plist

Add to Info.plist:
```xml
<key>NSFaceIDUsageDescription</key>
<string>Authenticate to access your NOSTR keys</string>
```

## Chapter 2: Creating Your First Connection

### Step 1: Create a NOSTR Manager

Create a new file `NostrManager.swift`:

```swift
import Foundation
import NostrKit
import CoreNostr
import SwiftUI

@MainActor
class NostrManager: ObservableObject {
    @Published var isConnected = false
    @Published var connectionStatus: [String: RelayConnectionStatus] = [:]
    @Published var events: [NostrEvent] = []
    @Published var profiles: [PublicKey: Profile] = [:]
    
    private let relayPool = RelayPool()
    private let keyStore = SecureKeyStore()
    private let eventCache = EventCache()
    private let profileManager: ProfileManager
    
    private var subscriptions: [String: Subscription] = [:]
    
    init() {
        self.profileManager = ProfileManager(
            relayPool: relayPool,
            cache: eventCache
        )
    }
    
    func connect() async throws {
        // Add default relays
        let defaultRelays = [
            "wss://relay.damus.io",
            "wss://nos.lol",
            "wss://relay.nostr.band",
            "wss://nostr.wine",
            "wss://relay.snort.social"
        ]
        
        for relayURL in defaultRelays {
            do {
                try await relayPool.addRelay(url: relayURL)
            } catch {
                print("Failed to add relay \(relayURL): \(error)")
            }
        }
        
        // Connect to all relays
        try await relayPool.connectAll()
        
        // Monitor connection status
        await relayPool.setDelegate(self)
        
        isConnected = true
    }
    
    func disconnect() async {
        await relayPool.disconnectAll()
        isConnected = false
    }
}

// MARK: - Relay Pool Delegate
extension NostrManager: RelayPoolDelegate {
    func relayPool(_ pool: RelayPool, didChangeStatus status: RelayConnectionStatus, for url: String) {
        Task { @MainActor in
            connectionStatus[url] = status
        }
    }
    
    func relayPool(_ pool: RelayPool, didReceiveEvent event: NostrEvent, from url: String) {
        Task { @MainActor in
            // Deduplicate events
            if !events.contains(where: { $0.id == event.id }) {
                events.append(event)
                events.sort { $0.createdAt > $1.createdAt }
                
                // Limit to 500 most recent events
                if events.count > 500 {
                    events = Array(events.prefix(500))
                }
            }
        }
    }
}
```

### Step 2: Create the Main App View

Update your `ContentView.swift`:

```swift
import SwiftUI
import NostrKit
import CoreNostr

struct ContentView: View {
    @StateObject private var nostrManager = NostrManager()
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            FeedView()
                .tabItem {
                    Label("Feed", systemImage: "house")
                }
                .tag(0)
            
            PublishView()
                .tabItem {
                    Label("Publish", systemImage: "square.and.pencil")
                }
                .tag(1)
            
            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.circle")
                }
                .tag(2)
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(3)
        }
        .environmentObject(nostrManager)
        .task {
            do {
                try await nostrManager.connect()
            } catch {
                print("Connection failed: \(error)")
            }
        }
    }
}
```

## Chapter 3: Managing User Identity

### Step 1: Create Identity Manager

Create `IdentityManager.swift`:

```swift
import Foundation
import NostrKit
import CoreNostr
import LocalAuthentication

@MainActor
class IdentityManager: ObservableObject {
    @Published var currentIdentity: String?
    @Published var hasIdentity: Bool = false
    @Published var currentKeyPair: KeyPair?
    
    private let keyStore = SecureKeyStore()
    
    init() {
        Task {
            await checkForExistingIdentity()
        }
    }
    
    func checkForExistingIdentity() async {
        do {
            let identities = try await keyStore.listIdentities()
            if let first = identities.first {
                currentIdentity = first.identifier
                hasIdentity = true
                // Don't load keys until needed
            }
        } catch {
            hasIdentity = false
        }
    }
    
    func createNewIdentity(name: String) async throws -> KeyPair {
        // Generate new key pair
        let keyPair = try CoreNostr.createKeyPair()
        
        // Store securely with biometric protection
        try await keyStore.store(
            keyPair,
            for: "main",
            name: name,
            permissions: .biometricRequired
        )
        
        currentIdentity = "main"
        currentKeyPair = keyPair
        hasIdentity = true
        
        return keyPair
    }
    
    func loadIdentity() async throws -> KeyPair {
        guard let identity = currentIdentity else {
            throw NostrKitError.noIdentity
        }
        
        // Authenticate with biometrics
        let context = LAContext()
        let reason = "Authenticate to access your NOSTR keys"
        
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            throw NostrKitError.biometricUnavailable
        }
        
        let success = try await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        )
        
        guard success else {
            throw NostrKitError.authenticationFailed
        }
        
        // Retrieve keys
        let keyPair = try await keyStore.retrieve(
            identity: identity,
            authenticationRequired: true
        )
        
        currentKeyPair = keyPair
        return keyPair
    }
    
    func importIdentity(nsec: String, name: String) async throws -> KeyPair {
        // Decode nsec (Bech32 private key)
        guard case .nsec(let privateKey) = try? Bech32Entity.decode(nsec) else {
            throw NostrKitError.invalidNsec
        }
        
        // Create key pair
        let keyPair = try KeyPair(privateKey: privateKey)
        
        // Store securely
        try await keyStore.store(
            keyPair,
            for: "imported",
            name: name,
            permissions: .biometricRequired
        )
        
        currentIdentity = "imported"
        currentKeyPair = keyPair
        hasIdentity = true
        
        return keyPair
    }
}
```

### Step 2: Create Onboarding Flow

Create `OnboardingView.swift`:

```swift
import SwiftUI
import CoreNostr

struct OnboardingView: View {
    @StateObject private var identityManager = IdentityManager()
    @State private var showingImportSheet = false
    @State private var userName = ""
    @State private var isCreating = false
    @Binding var isOnboarded: Bool
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                // Logo
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 100))
                    .foregroundStyle(.tint)
                
                // Welcome text
                VStack(spacing: 12) {
                    Text("Welcome to NOSTR")
                        .font(.largeTitle.bold())
                    
                    Text("The decentralized social protocol")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                
                // Name input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose your display name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    TextField("Enter your name", text: $userName)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal)
                
                // Action buttons
                VStack(spacing: 16) {
                    Button(action: createNewIdentity) {
                        Label("Create New Identity", systemImage: "person.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(userName.isEmpty || isCreating)
                    
                    Button(action: { showingImportSheet = true }) {
                        Label("Import Existing Key", systemImage: "key")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.horizontal)
            }
            .padding()
            .navigationTitle("Get Started")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingImportSheet) {
                ImportKeyView(
                    identityManager: identityManager,
                    isOnboarded: $isOnboarded
                )
            }
        }
    }
    
    func createNewIdentity() {
        isCreating = true
        
        Task {
            do {
                let keyPair = try await identityManager.createNewIdentity(name: userName)
                
                // Create initial profile
                await createProfile(keyPair: keyPair)
                
                // Mark as onboarded
                UserDefaults.standard.set(true, forKey: "isOnboarded")
                isOnboarded = true
            } catch {
                print("Failed to create identity: \(error)")
            }
            
            isCreating = false
        }
    }
    
    func createProfile(keyPair: KeyPair) async {
        // This would use ProfileManager to set initial profile
        // Implementation depends on your NostrManager setup
    }
}
```

## Chapter 4: Publishing Events

### Step 1: Create Event Publisher

Add to `NostrManager.swift`:

```swift
extension NostrManager {
    func publishTextNote(content: String) async throws {
        // Get current identity
        guard let keyPair = try? await getCurrentKeyPair() else {
            throw NostrKitError.noIdentity
        }
        
        // Create text note event
        let event = try CoreNostr.createTextNote(
            keyPair: keyPair,
            content: content
        )
        
        // Publish to all connected relays
        let results = await relayPool.publish(event)
        
        // Check results
        if results.successes.isEmpty {
            throw NostrKitError.publishFailed
        }
        
        // Add to local cache immediately
        await MainActor.run {
            events.insert(event, at: 0)
        }
    }
    
    func publishReply(to parentEvent: NostrEvent, content: String) async throws {
        guard let keyPair = try? await getCurrentKeyPair() else {
            throw NostrKitError.noIdentity
        }
        
        // Create reply with proper NIP-10 tags
        let replyEvent = try EventBuilder(keyPair: keyPair)
            .kind(.textNote)
            .content(content)
            .tag("e", values: [parentEvent.id, "", "reply"])
            .tag("p", values: [parentEvent.pubkey])
            .build()
        
        let results = await relayPool.publish(replyEvent)
        
        if results.successes.isEmpty {
            throw NostrKitError.publishFailed
        }
    }
    
    func react(to event: NostrEvent, reaction: String = "+") async throws {
        guard let keyPair = try? await getCurrentKeyPair() else {
            throw NostrKitError.noIdentity
        }
        
        // Create reaction event (NIP-25)
        let reactionEvent = try EventBuilder(keyPair: keyPair)
            .kind(.reaction)
            .content(reaction)
            .tag("e", values: [event.id])
            .tag("p", values: [event.pubkey])
            .build()
        
        await relayPool.publish(reactionEvent)
    }
    
    private func getCurrentKeyPair() async throws -> KeyPair {
        // This would integrate with IdentityManager
        // For now, return a dummy implementation
        throw NostrKitError.noIdentity
    }
}
```

### Step 2: Create Publish View

Create `PublishView.swift`:

```swift
import SwiftUI
import PhotosUI

struct PublishView: View {
    @EnvironmentObject private var nostrManager: NostrManager
    @State private var noteContent = ""
    @State private var isPublishing = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var attachedImage: Image?
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Compose area
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Text editor
                        TextEditor(text: $noteContent)
                            .focused($isTextFieldFocused)
                            .frame(minHeight: 150)
                            .padding(8)
                            .background(Color(.systemGray6))
                            .cornerRadius(12)
                            .overlay(
                                Group {
                                    if noteContent.isEmpty {
                                        Text("What's on your mind?")
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 16)
                                            .allowsHitTesting(false)
                                    }
                                },
                                alignment: .topLeading
                            )
                        
                        // Attached image preview
                        if let attachedImage {
                            attachedImage
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 300)
                                .cornerRadius(12)
                                .overlay(
                                    Button(action: { self.attachedImage = nil }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .padding(8),
                                    alignment: .topTrailing
                                )
                        }
                        
                        // Character count
                        HStack {
                            Spacer()
                            Text("\(noteContent.count) characters")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                }
                
                // Bottom toolbar
                VStack(spacing: 0) {
                    Divider()
                    
                    HStack(spacing: 20) {
                        // Photo picker
                        PhotosPicker(selection: $selectedPhoto) {
                            Image(systemName: "photo")
                                .font(.title3)
                        }
                        
                        // Emoji picker
                        Button(action: insertEmoji) {
                            Image(systemName: "face.smiling")
                                .font(.title3)
                        }
                        
                        // Mention
                        Button(action: insertMention) {
                            Image(systemName: "@")
                                .font(.title3)
                        }
                        
                        // Hashtag
                        Button(action: insertHashtag) {
                            Image(systemName: "number")
                                .font(.title3)
                        }
                        
                        Spacer()
                        
                        // Publish button
                        Button(action: publishNote) {
                            if isPublishing {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Text("Publish")
                                    .fontWeight(.semibold)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(noteContent.isEmpty || isPublishing)
                    }
                    .padding()
                }
                .background(Color(.systemBackground))
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("Done") {
                            isTextFieldFocused = false
                        }
                    }
                }
            }
        }
        .onChange(of: selectedPhoto) { _, newValue in
            Task {
                if let data = try? await newValue?.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    attachedImage = Image(uiImage: uiImage)
                }
            }
        }
    }
    
    func publishNote() {
        isPublishing = true
        
        Task {
            do {
                try await nostrManager.publishTextNote(content: noteContent)
                
                // Clear form on success
                await MainActor.run {
                    noteContent = ""
                    attachedImage = nil
                    isTextFieldFocused = false
                }
            } catch {
                print("Failed to publish: \(error)")
            }
            
            isPublishing = false
        }
    }
    
    func insertEmoji() {
        // Show emoji picker
    }
    
    func insertMention() {
        // Show mention picker
    }
    
    func insertHashtag() {
        // Show hashtag suggestions
    }
}
```

## Chapter 5: Building the Feed

### Step 1: Create Feed View

Create `FeedView.swift`:

```swift
import SwiftUI
import CoreNostr

struct FeedView: View {
    @EnvironmentObject private var nostrManager: NostrManager
    @State private var filter = FeedFilter.global
    @State private var isRefreshing = false
    
    enum FeedFilter: String, CaseIterable {
        case global = "Global"
        case following = "Following"
        case mentions = "Mentions"
        
        var icon: String {
            switch self {
            case .global: return "globe"
            case .following: return "person.2"
            case .mentions: return "@"
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filter picker
                Picker("Filter", selection: $filter) {
                    ForEach(FeedFilter.allCases, id: \.self) { filter in
                        Label(filter.rawValue, systemImage: filter.icon)
                            .tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                
                // Feed list
                List {
                    ForEach(filteredEvents) { event in
                        EventRow(event: event)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await refreshFeed()
                }
            }
            .navigationTitle("Feed")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionStatusView()
                }
            }
        }
        .task {
            await subscribeTo Feed()
        }
        .onChange(of: filter) { _, _ in
            Task {
                await subscribeToFeed()
            }
        }
    }
    
    var filteredEvents: [NostrEvent] {
        switch filter {
        case .global:
            return nostrManager.events
        case .following:
            // Filter by following list
            return nostrManager.events.filter { event in
                // Check if author is in following list
                false // Implement following check
            }
        case .mentions:
            // Filter by mentions
            return nostrManager.events.filter { event in
                // Check if current user is mentioned
                false // Implement mention check
            }
        }
    }
    
    func subscribeToFeed() async {
        do {
            let filters: [Filter]
            
            switch filter {
            case .global:
                filters = [
                    Filter(kinds: [.textNote], limit: 100)
                ]
            case .following:
                // Get following list and create filter
                filters = [] // Implement
            case .mentions:
                // Create mentions filter
                filters = [] // Implement
            }
            
            let subscription = try await nostrManager.relayPool.subscribe(
                filters: filters
            )
            
            // Process events
            Task {
                for await event in subscription.events {
                    await MainActor.run {
                        if !nostrManager.events.contains(where: { $0.id == event.id }) {
                            nostrManager.events.append(event)
                            nostrManager.events.sort { $0.createdAt > $1.createdAt }
                        }
                    }
                }
            }
        } catch {
            print("Subscription failed: \(error)")
        }
    }
    
    func refreshFeed() async {
        isRefreshing = true
        await subscribeToFeed()
        isRefreshing = false
    }
}

// Event row component
struct EventRow: View {
    let event: NostrEvent
    @EnvironmentObject private var nostrManager: NostrManager
    @State private var profile: Profile?
    @State private var isLiked = false
    @State private var replyCount = 0
    @State private var likeCount = 0
    @State private var repostCount = 0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Author info
            HStack(spacing: 12) {
                // Avatar
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Text(profileInitial)
                            .font(.headline)
                            .foregroundColor(.accentColor)
                    )
                
                // Name and time
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile?.name ?? shortPubkey)
                        .font(.headline)
                    
                    Text(relativeTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // More button
                Menu {
                    Button(action: copyNote) {
                        Label("Copy Note ID", systemImage: "doc.on.doc")
                    }
                    Button(action: shareNote) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button(action: reportNote) {
                        Label("Report", systemImage: "flag")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                }
            }
            
            // Content
            Text(event.content)
                .font(.body)
                .lineLimit(10)
                .textSelection(.enabled)
            
            // Interaction buttons
            HStack(spacing: 0) {
                // Reply
                Button(action: reply) {
                    Label("\(replyCount)", systemImage: "bubble.left")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                
                // Repost
                Button(action: repost) {
                    Label("\(repostCount)", systemImage: "arrow.2.squarepath")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                
                // Like
                Button(action: toggleLike) {
                    Label("\(likeCount)", systemImage: isLiked ? "heart.fill" : "heart")
                        .font(.callout)
                        .foregroundColor(isLiked ? .red : .primary)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                
                // Zap
                Button(action: sendZap) {
                    Label("", systemImage: "bolt")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 8)
        }
        .padding()
        .background(Color(.systemBackground))
        .task {
            await loadProfile()
            await loadInteractionCounts()
        }
    }
    
    var profileInitial: String {
        if let name = profile?.name, !name.isEmpty {
            return String(name.prefix(1)).uppercased()
        }
        return "N"
    }
    
    var shortPubkey: String {
        let npub = try? Bech32Entity.npub(event.pubkey).encoded
        return String(npub?.prefix(8) ?? "Unknown") + "..."
    }
    
    var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: event.createdAt, relativeTo: Date())
    }
    
    func loadProfile() async {
        // Load profile from cache or fetch
    }
    
    func loadInteractionCounts() async {
        // Query for replies, likes, reposts
    }
    
    func reply() {
        // Show reply composer
    }
    
    func repost() {
        // Repost event
    }
    
    func toggleLike() {
        Task {
            do {
                try await nostrManager.react(to: event, reaction: isLiked ? "-" : "+")
                isLiked.toggle()
                likeCount += isLiked ? 1 : -1
            } catch {
                print("Failed to react: \(error)")
            }
        }
    }
    
    func sendZap() {
        // Show zap sheet
    }
    
    func copyNote() {
        UIPasteboard.general.string = event.id
    }
    
    func shareNote() {
        // Share event
    }
    
    func reportNote() {
        // Report event
    }
}

// Connection status indicator
struct ConnectionStatusView: View {
    @EnvironmentObject private var nostrManager: NostrManager
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(nostrManager.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            
            Text(nostrManager.isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.systemGray5))
        .cornerRadius(12)
    }
}
```

## Chapter 6: Advanced Features

### Implementing Direct Messages

```swift
extension NostrManager {
    func sendDirectMessage(to recipient: PublicKey, content: String) async throws {
        guard let keyPair = try? await getCurrentKeyPair() else {
            throw NostrKitError.noIdentity
        }
        
        // Encrypt message using NIP-44
        let encryptionManager = EncryptionManager()
        let encrypted = try await encryptionManager.encrypt(
            plaintext: content,
            to: recipient,
            keyPair: keyPair
        )
        
        // Create DM event
        let dmEvent = try EventBuilder(keyPair: keyPair)
            .kind(.encryptedDirectMessage)
            .content(encrypted)
            .tag("p", values: [recipient])
            .build()
        
        await relayPool.publish(dmEvent)
    }
    
    func decryptDirectMessage(_ event: NostrEvent) async throws -> String {
        guard let keyPair = try? await getCurrentKeyPair() else {
            throw NostrKitError.noIdentity
        }
        
        let encryptionManager = EncryptionManager()
        return try await encryptionManager.decrypt(
            ciphertext: event.content,
            from: event.pubkey,
            keyPair: keyPair
        )
    }
}
```

### Implementing Lightning Zaps

```swift
struct ZapSheet: View {
    let event: NostrEvent
    @State private var zapAmount = 1000 // sats
    @State private var comment = ""
    @State private var isZapping = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Amount") {
                    Picker("Sats", selection: $zapAmount) {
                        Text("⚡ 100").tag(100)
                        Text("⚡ 500").tag(500)
                        Text("⚡ 1,000").tag(1000)
                        Text("⚡ 5,000").tag(5000)
                        Text("⚡ 10,000").tag(10000)
                    }
                    .pickerStyle(.segmented)
                    
                    TextField("Custom amount", value: $zapAmount, format: .number)
                        .keyboardType(.numberPad)
                }
                
                Section("Comment (optional)") {
                    TextField("Add a comment...", text: $comment, axis: .vertical)
                        .lineLimit(3...6)
                }
                
                Section {
                    Button(action: sendZap) {
                        if isZapping {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Send ⚡ \(zapAmount) sats")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isZapping)
                }
            }
            .navigationTitle("Send Zap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    func sendZap() {
        isZapping = true
        
        Task {
            do {
                // Create zap request
                let socialManager = SocialManager(/* ... */)
                let zapRequest = try await socialManager.createZapRequest(
                    to: event.pubkey,
                    amount: Int64(zapAmount) * 1000, // Convert to millisats
                    comment: comment.isEmpty ? nil : comment,
                    keyPair: /* current key pair */
                )
                
                // Open Lightning wallet with invoice
                if let url = URL(string: "lightning:\(zapRequest.lnurl)") {
                    await UIApplication.shared.open(url)
                }
                
                dismiss()
            } catch {
                print("Zap failed: \(error)")
            }
            
            isZapping = false
        }
    }
}
```

## Best Practices

### 1. Connection Management

Always handle connection failures gracefully:

```swift
func connectWithRetry() async {
    var retryCount = 0
    let maxRetries = 3
    
    while retryCount < maxRetries {
        do {
            try await relayPool.connectAll()
            break
        } catch {
            retryCount += 1
            let delay = pow(2.0, Double(retryCount)) // Exponential backoff
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
```

### 2. Event Validation

Always validate events before processing:

```swift
func processEvent(_ event: NostrEvent) async {
    // Verify signature
    guard try CoreNostr.verifyEvent(event) else {
        print("Invalid event signature")
        return
    }
    
    // Check timestamp (not too far in future)
    let maxFuture = Date().addingTimeInterval(60) // 1 minute tolerance
    guard event.createdAt <= maxFuture else {
        print("Event timestamp too far in future")
        return
    }
    
    // Process valid event
    await handleValidEvent(event)
}
```

### 3. Memory Management

Limit cached data to prevent memory issues:

```swift
class EventCache {
    private var events: [EventID: NostrEvent] = [:]
    private let maxSize = 1000
    
    func add(_ event: NostrEvent) {
        events[event.id] = event
        
        // Evict oldest if over limit
        if events.count > maxSize {
            let sorted = events.values.sorted { $0.createdAt < $1.createdAt }
            for event in sorted.prefix(events.count - maxSize) {
                events.removeValue(forKey: event.id)
            }
        }
    }
}
```

### 4. Error Handling

Provide meaningful error messages:

```swift
enum NostrKitError: LocalizedError {
    case noIdentity
    case connectionFailed(String)
    case publishFailed
    case invalidNsec
    case biometricUnavailable
    case authenticationFailed
    
    var errorDescription: String? {
        switch self {
        case .noIdentity:
            return "No identity configured. Please create or import one."
        case .connectionFailed(let relay):
            return "Failed to connect to relay: \(relay)"
        case .publishFailed:
            return "Failed to publish event. Please check your connection."
        case .invalidNsec:
            return "Invalid private key format."
        case .biometricUnavailable:
            return "Biometric authentication is not available."
        case .authenticationFailed:
            return "Authentication failed. Please try again."
        }
    }
}
```

## Conclusion

Congratulations! You've built a fully functional NOSTR client using NostrKit. You've learned:

- How to set up NostrKit in your project
- Managing relay connections
- Creating and storing user identities securely
- Publishing and subscribing to events
- Building reactive UI with SwiftUI
- Implementing social features like reactions and zaps

### Next Steps

1. **Explore More NIPs**: Implement additional protocol features
2. **Optimize Performance**: Add caching and background processing
3. **Enhance UI/UX**: Polish the interface and add animations
4. **Add Tests**: Write unit and integration tests
5. **Deploy**: Submit to the App Store

### Resources

- [NostrKit Documentation](https://github.com/SparrowTek/NostrKit)
- [NOSTR Protocol Specification](https://github.com/nostr-protocol/nostr)
- [NIP Repository](https://github.com/nostr-protocol/nips)
- [Sample Apps](https://github.com/SparrowTek/NostrKit/examples)

Happy building with NostrKit! 🚀