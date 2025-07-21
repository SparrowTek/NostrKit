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
//        .package(url: "git@github.com:SparrowTek/CoreNostr.git", branch: "main"),
        
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", from: "0.21.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.4.0"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.9.0"),
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.6.0"),
        .package(url: "https://github.com/bitcoindevkit/bdk-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/valpackett/SwiftCBOR.git", from: "0.5.0"),
        .package(url: "https://github.com/SparrowTek/Vault.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "NostrKit",
            dependencies: [
                "CoreNostr"
            ]),
        .target(
            name: "CoreNostr",
            dependencies: [
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CryptoSwift", package: "CryptoSwift"),
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "BitcoinDevKit", package: "bdk-swift"),
                .product(name: "SwiftCBOR", package: "SwiftCBOR"),
                .product(name: "Vault", package: "Vault"),
            ]
        ),
        .testTarget(
            name: "NostrKitTests",
            dependencies: ["NostrKit"]
        ),
    ]
)
