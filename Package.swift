// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NostrKit",
    platforms: [
        // Floor is iOS 18 / macOS 15 / tvOS 18 / watchOS 11 — what's needed
        // for Swift 6.2 language features used here (isolated deinit from
        // SE-0371, Sendable URLSession tasks, @Observable MainActor classes).
        // Widens reach vs. requiring the current OS major.
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .macCatalyst(.v18)
    ],
    products: [
        .library(
            name: "NostrKit",
            targets: ["NostrKit"]),
    ],
    dependencies: [
//        .package(url: "https://github.com/SparrowTek/CoreNostr.git", from: "2.0.0"),
        .package(path: "../CoreNostr"),
    ],
    targets: [
        .target(
            name: "NostrKit",
            dependencies: [
                "CoreNostr",
            ]),
        .testTarget(
            name: "NostrKitTests",
            dependencies: ["NostrKit"]
        ),
    ]
)
