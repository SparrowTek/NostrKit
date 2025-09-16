// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NostrKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .macCatalyst(.v17)
    ],
    products: [
        .library(
            name: "NostrKit",
            targets: ["NostrKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SparrowTek/CoreNostr.git", branch: "main"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.8.3")
    ],
    targets: [
        .target(
            name: "NostrKit",
            dependencies: [
                "CoreNostr",
                "CryptoSwift"
            ]),
        .testTarget(
            name: "NostrKitTests",
            dependencies: ["NostrKit"]
        ),
    ]
)
