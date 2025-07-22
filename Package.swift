// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NostrKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
        .macCatalyst(.v13)
    ],
    products: [
        .library(
            name: "NostrKit",
            targets: ["NostrKit"]),
    ],
    dependencies: [
        .package(url: "git@github.com:SparrowTek/CoreNostr.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "NostrKit",
            dependencies: [
                "CoreNostr"
            ]),
        .testTarget(
            name: "NostrKitTests",
            dependencies: ["NostrKit"]
        ),
    ]
)
