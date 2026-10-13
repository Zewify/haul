// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HaulCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HaulCore", targets: ["HaulCore"]),
        .executable(name: "licensetool", targets: ["licensetool"]),
    ],
    targets: [
        // Every rule in the product: the download engine, the model and library, the queue policy,
        // the free/Pro gate, the local server, pairing, licences and HLS. Foundation, Network and CryptoKit only; no AppKit.
        .target(name: "HaulCore"),
        // Creates the licence signing key pair and issues Pro licences for the direct edition.
        .executableTarget(name: "licensetool", dependencies: ["HaulCore"]),
        .testTarget(name: "HaulCoreTests", dependencies: ["HaulCore"]),
    ]
)
