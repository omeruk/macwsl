// swift-tools-version: 6.0

import PackageDescription

// Targets marked "macOS only" wrap their sources in `#if os(macOS)`. The manifest is evaluated
// on the host even when cross-compiling, so `#if os(...)` here cannot exclude them; instead the
// guest agent depends only on the portable modules, which keeps
// `swift build --swift-sdk aarch64-swift-linux-musl --product macwsl-agent` free of macOS code.
let package = Package(
    name: "MacWSL",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "macwsl", targets: ["macwsl"]),
        .executable(name: "macwsld", targets: ["macwsld"]),
        .executable(name: "macwsl-agent", targets: ["macwsl-agent"]),
        .library(name: "MacWSLCore", targets: ["MacWSLCore"]),
        .library(name: "MacWSLProtocol", targets: ["MacWSLProtocol"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2")
    ],
    targets: [
        // Portable: macOS and Linux.
        .target(name: "MacWSLCore"),
        .target(name: "MacWSLProtocol", dependencies: ["MacWSLCore"]),

        // macOS only.
        .target(name: "MacWSLVirtualization", dependencies: ["MacWSLCore"]),
        // Error reporting shared by the macwsl and macwsld command lines.
        .target(
            name: "MacWSLCommandLine",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .target(
            name: "MacWSLDaemonKit",
            dependencies: ["MacWSLCore", "MacWSLProtocol", "MacWSLVirtualization"]
        ),
        .executableTarget(
            name: "macwsl",
            dependencies: [
                "MacWSLCore",
                "MacWSLCommandLine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "macwsld", dependencies: ["MacWSLCore", "MacWSLDaemonKit"]),

        // Linux only (guest). Also compiles on macOS so that a plain `swift build` succeeds.
        .executableTarget(name: "macwsl-agent", dependencies: ["MacWSLCore", "MacWSLProtocol"]),

        .testTarget(name: "MacWSLCoreTests", dependencies: ["MacWSLCore"]),
        .testTarget(
            name: "MacWSLCommandLineTests",
            dependencies: [
                "MacWSLCommandLine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "macwslTests",
            dependencies: [
                "macwsl",
                "MacWSLCore",
                "MacWSLCommandLine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
