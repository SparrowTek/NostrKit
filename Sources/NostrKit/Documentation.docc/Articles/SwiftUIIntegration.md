# SwiftUI Integration

Build reactive NOSTR interfaces with SwiftUI and NostrKit.

## Overview

NostrKit is designed to work seamlessly with SwiftUI, providing observable objects, async sequences, and reactive patterns that integrate naturally with SwiftUI's declarative syntax. This guide shows you how to build modern, reactive NOSTR interfaces.

## Observable Architecture

### Creating Observable Models

```swift
import SwiftUI
import NostrKit
import CoreNostr
import Combine

@MainActor
class NostrViewModel: ObservableObject {
    @Published var events: [NostrEvent] = []
    @Published var profiles: [PublicKey: Profile] = [:]
    @Published var isConnected = false
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var error: Error?
    
    private let relayPool = RelayPool()
    private let profileManager: ProfileManager
    private let eventCache = EventCache()
    private var cancellables = Set<AnyCancellable>()
    
    enum ConnectionStatus {
        case disconnected
        case connecting
        case connected(relayCount: Int)
        case reconnecting
        
        var description: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting..."
            case .connected(let count): return "Connected to \\(count) relays"
            case .reconnecting: return "Reconnecting..."
            }
        }
        
        var color: Color {
            switch self {
            case .connected: return .green
            case .connecting, .reconnecting: return .orange
            case .disconnected: return .red
            }
        }
    }
    
    init() {
        self.profileManager = ProfileManager(
            relayPool: relayPool,
            cache: eventCache
        )
        setupBindings()
    }
    
    private func setupBindings() {
        // Monitor connection changes
        relayPool.connectionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.updateConnectionStatus(status)
            }
            .store(in: &cancellables)
        
        // Monitor new events
        relayPool.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleNewEvent(event)
            }
            .store(in: &cancellables)
    }
}
```

### AsyncSequence Integration

```swift
extension NostrViewModel {
    func startEventStream() {
        Task {
            do {
                let subscription = try await relayPool.subscribe(
                    filters: [Filter(kinds: [.textNote], limit: 100)]
                )
                
                for await event in subscription.events {
                    await MainActor.run {
                        insertEvent(event)
                    }
                }
            } catch {
                await MainActor.run {
                    self.error = error
                }
            }
        }
    }
    
    private func insertEvent(_ event: NostrEvent) {
        // Deduplicate and insert sorted
        guard !events.contains(where: { $0.id == event.id }) else { return }
        
        events.append(event)
        events.sort { $0.createdAt > $1.createdAt }
        
        // Limit array size
        if events.count > 500 {
            events = Array(events.prefix(500))
        }
        
        // Fetch profile if needed
        Task {
            await fetchProfileIfNeeded(for: event.pubkey)
        }
    }
}
```

## Building Reactive Views

### Feed View with Pull-to-Refresh

```swift
struct FeedView: View {
    @StateObject private var viewModel = NostrViewModel()
    @State private var searchText = ""
    
    var filteredEvents: [NostrEvent] {
        if searchText.isEmpty {
            return viewModel.events
        }
        return viewModel.events.filter { event in
            event.content.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredEvents) { event in
                    EventRow(event: event, viewModel: viewModel)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Search notes")
            .refreshable {
                await viewModel.refresh()
            }
            .navigationTitle("Feed")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionIndicator(status: viewModel.connectionStatus)
                }
            }
            .overlay {
                if viewModel.events.isEmpty {
                    ContentUnavailableView(
                        "No Events",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Pull to refresh or check your connection")
                    )
                }
            }
        }
        .task {
            await viewModel.connect()
            viewModel.startEventStream()
        }
        .alert("Error", isPresented: .constant(viewModel.error != nil)) {
            Button("OK") {
                viewModel.error = nil
            }
        } message: {
            Text(viewModel.error?.localizedDescription ?? "Unknown error")
        }
    }
}

struct ConnectionIndicator: View {
    let status: NostrViewModel.ConnectionStatus
    @State private var isAnimating = false
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
                .scaleEffect(isAnimating ? 1.2 : 1.0)
                .animation(
                    status.color == .orange ?
                    .easeInOut(duration: 1).repeatForever() : .default,
                    value: isAnimating
                )
            
            Text(status.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .onAppear {
            isAnimating = true
        }
    }
}
```

### Event Row with Interactions

```swift
struct EventRow: View {
    let event: NostrEvent
    @ObservedObject var viewModel: NostrViewModel
    @State private var isLiked = false
    @State private var showingReplySheet = false
    @State private var showingProfileSheet = false
    
    var profile: Profile? {
        viewModel.profiles[event.pubkey]
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Author header
            HStack {
                ProfilePicture(profile: profile, size: 48)
                    .onTapGesture {
                        showingProfileSheet = true
                    }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile?.displayName ?? shortenedPubkey)
                        .font(.headline)
                    
                    Text(relativeTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Menu {
                    Button {
                        copyNoteId()
                    } label: {
                        Label("Copy Note ID", systemImage: "doc.on.doc")
                    }
                    
                    Button {
                        shareNote()
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    
                    Divider()
                    
                    Button(role: .destructive) {
                        reportNote()
                    } label: {
                        Label("Report", systemImage: "flag")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
            }
            
            // Content
            ExpandableText(event.content)
            
            // Media attachments
            MediaAttachments(event: event)
            
            // Interactions
            HStack {
                InteractionButton(
                    icon: "bubble.left",
                    count: 0,
                    action: { showingReplySheet = true }
                )
                
                InteractionButton(
                    icon: "arrow.2.squarepath",
                    count: 0,
                    action: repost
                )
                
                InteractionButton(
                    icon: isLiked ? "heart.fill" : "heart",
                    count: 0,
                    color: isLiked ? .red : nil,
                    action: toggleLike
                )
                
                InteractionButton(
                    icon: "bolt",
                    count: nil,
                    color: .orange,
                    action: sendZap
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .sheet(isPresented: $showingReplySheet) {
            ReplyView(parentEvent: event, viewModel: viewModel)
        }
        .sheet(isPresented: $showingProfileSheet) {
            ProfileView(pubkey: event.pubkey, viewModel: viewModel)
        }
    }
    
    var shortenedPubkey: String {
        let npub = try? Bech32Entity.npub(event.pubkey).encoded
        return String(npub?.prefix(12) ?? "Unknown") + "..."
    }
    
    var relativeTime: String {
        event.createdAt.formatted(.relative(presentation: .abbreviated))
    }
    
    func toggleLike() {
        Task {
            do {
                try await viewModel.react(to: event, reaction: isLiked ? "-" : "+")
                isLiked.toggle()
            } catch {
                print("Failed to react: \\(error)")
            }
        }
    }
    
    func repost() {
        Task {
            try await viewModel.repost(event)
        }
    }
    
    func sendZap() {
        // Show zap sheet
    }
    
    func copyNoteId() {
        UIPasteboard.general.string = event.id
    }
    
    func shareNote() {
        // Show share sheet
    }
    
    func reportNote() {
        // Report event
    }
}

struct InteractionButton: View {
    let icon: String
    let count: Int?
    var color: Color?
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                
                if let count, count > 0 {
                    Text(formatCount(count))
                        .font(.caption)
                }
            }
            .foregroundColor(color ?? .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
    
    func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\\(count)"
    }
}
```

### Profile View

```swift
struct ProfileView: View {
    let pubkey: PublicKey
    @ObservedObject var viewModel: NostrViewModel
    @State private var profile: Profile?
    @State private var isFollowing = false
    @State private var followerCount = 0
    @State private var followingCount = 0
    @Environment(\\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    ProfileHeader(
                        profile: profile,
                        isFollowing: isFollowing,
                        followerCount: followerCount,
                        followingCount: followingCount,
                        onFollow: toggleFollow
                    )
                    
                    // Bio
                    if let about = profile?.about {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("About")
                                .font(.headline)
                            
                            Text(about)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    }
                    
                    // NIP-05 Verification
                    if let nip05 = profile?.nip05 {
                        NIP05Badge(identifier: nip05, pubkey: pubkey)
                    }
                    
                    // Recent notes
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recent Notes")
                            .font(.headline)
                            .padding(.horizontal)
                        
                        LazyVStack(spacing: 0) {
                            ForEach(recentNotes) { event in
                                EventRow(event: event, viewModel: viewModel)
                                Divider()
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(profile?.displayName ?? "Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            copyNpub()
                        } label: {
                            Label("Copy npub", systemImage: "doc.on.doc")
                        }
                        
                        Button {
                            shareProfile()
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        
                        if !isOwnProfile {
                            Divider()
                            
                            Button {
                                sendDirectMessage()
                            } label: {
                                Label("Message", systemImage: "envelope")
                            }
                            
                            Button(role: .destructive) {
                                blockUser()
                            } label: {
                                Label("Block", systemImage: "hand.raised")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task {
            await loadProfile()
            await loadSocialGraph()
            await loadRecentNotes()
        }
    }
    
    var isOwnProfile: Bool {
        // Check if viewing own profile
        false
    }
    
    var recentNotes: [NostrEvent] {
        viewModel.events.filter { $0.pubkey == pubkey }
    }
    
    func loadProfile() async {
        profile = try? await viewModel.profileManager.fetchProfile(pubkey: pubkey)
    }
    
    func loadSocialGraph() async {
        // Load follower/following counts
    }
    
    func loadRecentNotes() async {
        // Fetch recent notes from this user
    }
    
    func toggleFollow() {
        Task {
            if isFollowing {
                try await viewModel.unfollow(pubkey)
            } else {
                try await viewModel.follow(pubkey)
            }
            isFollowing.toggle()
        }
    }
    
    func copyNpub() {
        let npub = try? Bech32Entity.npub(pubkey).encoded
        UIPasteboard.general.string = npub
    }
    
    func shareProfile() {
        // Share profile
    }
    
    func sendDirectMessage() {
        // Open DM view
    }
    
    func blockUser() {
        // Block user
    }
}

struct ProfileHeader: View {
    let profile: Profile?
    let isFollowing: Bool
    let followerCount: Int
    let followingCount: Int
    let onFollow: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            // Banner
            if let banner = profile?.banner {
                AsyncImage(url: URL(string: banner)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.1))
                }
                .frame(height: 150)
                .clipped()
            }
            
            // Avatar and stats
            VStack(spacing: 12) {
                ProfilePicture(profile: profile, size: 80)
                    .overlay(
                        Circle()
                            .stroke(Color(.systemBackground), lineWidth: 4)
                    )
                    .offset(y: profile?.banner != nil ? -40 : 0)
                
                VStack(spacing: 4) {
                    Text(profile?.displayName ?? "Unknown")
                        .font(.title2.bold())
                    
                    if let name = profile?.name {
                        Text("@\\(name)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                
                // Stats
                HStack(spacing: 30) {
                    VStack {
                        Text("\\(followerCount)")
                            .font(.headline)
                        Text("Followers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    VStack {
                        Text("\\(followingCount)")
                            .font(.headline)
                        Text("Following")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                // Follow button
                Button(action: onFollow) {
                    Text(isFollowing ? "Following" : "Follow")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }
}
```

### Compose View

```swift
struct ComposeView: View {
    @ObservedObject var viewModel: NostrViewModel
    @State private var content = ""
    @State private var isPublishing = false
    @FocusState private var isFocused: Bool
    @Environment(\\.dismiss) private var dismiss
    
    var characterCount: Int {
        content.count
    }
    
    var canPublish: Bool {
        !content.isEmpty && !isPublishing
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Compose area
                ScrollView {
                    TextEditor(text: $content)
                        .focused($isFocused)
                        .font(.body)
                        .padding()
                        .frame(minHeight: 200)
                        .overlay(alignment: .topLeading) {
                            if content.isEmpty {
                                Text("What's on your mind?")
                                    .foregroundStyle(.tertiary)
                                    .padding()
                                    .allowsHitTesting(false)
                            }
                        }
                }
                
                Divider()
                
                // Bottom toolbar
                HStack {
                    // Character count
                    Text("\\(characterCount)")
                        .font(.caption)
                        .foregroundStyle(characterCount > 280 ? .red : .secondary)
                    
                    Spacer()
                    
                    // Media buttons
                    Button {
                        // Add photo
                    } label: {
                        Image(systemName: "photo")
                    }
                    
                    Button {
                        // Add link
                    } label: {
                        Image(systemName: "link")
                    }
                    
                    Button {
                        // Add hashtag
                    } label: {
                        Image(systemName: "number")
                    }
                }
                .padding()
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Publish") {
                        publishNote()
                    }
                    .disabled(!canPublish)
                }
            }
        }
        .interactiveDismissDisabled(!content.isEmpty)
        .onAppear {
            isFocused = true
        }
    }
    
    func publishNote() {
        isPublishing = true
        
        Task {
            do {
                try await viewModel.publishTextNote(content: content)
                dismiss()
            } catch {
                // Show error
                isPublishing = false
            }
        }
    }
}
```

## Custom Components

### ProfilePicture

```swift
struct ProfilePicture: View {
    let profile: Profile?
    let size: CGFloat
    
    var body: some View {
        Group {
            if let picture = profile?.picture,
               let url = URL(string: picture) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(width: size, height: size)
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size, height: size)
                            .clipShape(Circle())
                    case .failure:
                        placeholderImage
                    @unknown default:
                        placeholderImage
                    }
                }
            } else {
                placeholderImage
            }
        }
    }
    
    var placeholderImage: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.2))
            
            Text(initials)
                .font(.system(size: size / 2.5, weight: .semibold))
                .foregroundColor(.accentColor)
        }
        .frame(width: size, height: size)
    }
    
    var initials: String {
        guard let name = profile?.displayName ?? profile?.name else {
            return "?"
        }
        
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1)) + String(parts[1].prefix(1))
        }
        return String(name.prefix(2)).uppercased()
    }
}
```

### ExpandableText

```swift
struct ExpandableText: View {
    let text: String
    let lineLimit: Int
    
    @State private var isExpanded = false
    @State private var isTruncated = false
    
    init(_ text: String, lineLimit: Int = 5) {
        self.text = text
        self.lineLimit = lineLimit
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .lineLimit(isExpanded ? nil : lineLimit)
                .background(
                    GeometryReader { geometry in
                        Color.clear.onAppear {
                            determineTruncation(geometry: geometry)
                        }
                    }
                )
            
            if isTruncated {
                Button(isExpanded ? "Show less" : "Show more") {
                    withAnimation {
                        isExpanded.toggle()
                    }
                }
                .font(.caption)
                .foregroundStyle(.blue)
            }
        }
    }
    
    func determineTruncation(geometry: GeometryProxy) {
        let total = text.boundingRect(
            with: CGSize(
                width: geometry.size.width,
                height: .greatestFiniteMagnitude
            ),
            options: .usesLineFragmentOrigin,
            attributes: [.font: UIFont.preferredFont(forTextStyle: .body)],
            context: nil
        )
        
        if total.size.height > geometry.size.height {
            isTruncated = true
        }
    }
}
```

### NIP-05 Badge

```swift
struct NIP05Badge: View {
    let identifier: String
    let pubkey: PublicKey
    @State private var isVerified = false
    @State private var isVerifying = true
    
    var body: some View {
        HStack(spacing: 4) {
            if isVerifying {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Image(systemName: isVerified ? "checkmark.seal.fill" : "xmark.seal")
                    .foregroundColor(isVerified ? .green : .red)
            }
            
            Text(identifier)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(20)
        .task {
            await verify()
        }
    }
    
    func verify() async {
        do {
            isVerified = try await NostrNIP05Identifier.verify(
                identifier: identifier,
                pubkey: pubkey
            )
        } catch {
            isVerified = false
        }
        isVerifying = false
    }
}
```

## State Management

### Using @AppStorage

```swift
extension View {
    func withNostrPreferences() -> some View {
        self
            .environmentObject(NostrPreferences.shared)
    }
}

class NostrPreferences: ObservableObject {
    static let shared = NostrPreferences()
    
    @AppStorage("defaultRelays") var defaultRelays: [String] = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.nostr.band"
    ]
    
    @AppStorage("autoLoadImages") var autoLoadImages = true
    @AppStorage("showAvatars") var showAvatars = true
    @AppStorage("theme") var theme = Theme.system
    @AppStorage("defaultZapAmount") var defaultZapAmount = 1000
    
    enum Theme: String, CaseIterable {
        case system, light, dark
        
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }
}

struct SettingsView: View {
    @StateObject private var preferences = NostrPreferences.shared
    
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $preferences.theme) {
                    ForEach(NostrPreferences.Theme.allCases, id: \\.self) { theme in
                        Text(theme.rawValue.capitalized)
                    }
                }
                
                Toggle("Show Avatars", isOn: $preferences.showAvatars)
                Toggle("Auto-load Images", isOn: $preferences.autoLoadImages)
            }
            
            Section("Defaults") {
                Stepper(
                    "Default Zap: \\(preferences.defaultZapAmount) sats",
                    value: $preferences.defaultZapAmount,
                    in: 100...100000,
                    step: 100
                )
            }
        }
    }
}
```

## Performance Optimization

### Lazy Loading

```swift
struct OptimizedFeedView: View {
    @StateObject private var viewModel = NostrViewModel()
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.events) { event in
                    EventRow(event: event, viewModel: viewModel)
                        .id(event.id)
                        .onAppear {
                            // Load more when approaching end
                            if viewModel.events.last?.id == event.id {
                                Task {
                                    await viewModel.loadMore()
                                }
                            }
                        }
                    
                    Divider()
                }
            }
        }
    }
}
```

### Image Caching

```swift
class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()
    
    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }
    
    func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url.absoluteString as NSString)
    }
}

struct CachedAsyncImage: View {
    let url: URL?
    @State private var image: UIImage?
    
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
            } else {
                ProgressView()
                    .task {
                        await loadImage()
                    }
            }
        }
    }
    
    func loadImage() async {
        guard let url else { return }
        
        // Check cache first
        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }
        
        // Download
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let downloaded = UIImage(data: data) {
                ImageCache.shared.store(downloaded, for: url)
                image = downloaded
            }
        } catch {
            // Handle error
        }
    }
}
```

## Summary

NostrKit provides excellent SwiftUI integration with:

- Observable models that work with SwiftUI's property wrappers
- AsyncSequence support for real-time updates
- Reusable components for common NOSTR UI elements
- Performance optimizations for smooth scrolling
- State management patterns for complex apps

By following these patterns, you can build responsive, efficient NOSTR applications that feel native to iOS and macOS.