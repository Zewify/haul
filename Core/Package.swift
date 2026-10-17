// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DownhaulCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DownhaulCore", targets: ["DownhaulCore"]),
    ],
    targets: [
        // Every rule in the product: the download engine, the model and library, the queue policy,
        // the local server, pairing, HLS and DASH joining. Foundation, Network and AVFoundation only; no AppKit.
        .target(name: "DownhaulCore"),
        .testTarget(name: "DownhaulCoreTests", dependencies: ["DownhaulCore"]),
    ]
)
