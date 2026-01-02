// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NostrKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
        .macCatalyst(.v26)
    ],
    products: [
        .library(
            name: "NostrKit",
            targets: ["NostrKit"]),
    ],
    dependencies: [
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
