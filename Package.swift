// swift-tools-version: 6.0

import PackageDescription

// Targets marked "macOS only" wrap their sources in `#if os(macOS)`. The manifest is evaluated
// on the host even when cross-compiling, so `#if os(...)` here cannot exclude them; instead the
// guest agent depends only on the portable modules, which keeps
// `swift build --swift-sdk aarch64-swift-linux-musl --product macwsl-agent` free of macOS code.
// The portable modules import FoundationEssentials where it exists, so that the agent does not
// link ICU (see docs/decisions/0005-init-supervises-the-agent.md).
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
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        // Guest only: the agent's logging (approved in CLAUDE.md).
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.1"),
    ],
    targets: [
        // Portable: macOS and Linux.
        .target(name: "MacWSLCore"),
        // System calls that Swift cannot make directly (docs/decisions/0006).
        .target(name: "CMacWSLSystem"),
        .target(name: "MacWSLProtocol", dependencies: ["MacWSLCore", "CMacWSLSystem"]),
        // The guest agent's logic. Portable, so that its tests run on macOS.
        .target(
            name: "MacWSLAgentKit",
            dependencies: [
                "MacWSLCore", "MacWSLProtocol", "CMacWSLSystem",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // macOS only.
        .target(name: "MacWSLVirtualization", dependencies: ["MacWSLCore", "MacWSLProtocol"]),
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
        .executableTarget(
            name: "macwsld",
            dependencies: [
                "MacWSLCore",
                "MacWSLCommandLine",
                "MacWSLDaemonKit",
                "MacWSLProtocol",
                "MacWSLVirtualization",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // Linux only (guest). Also compiles on macOS so that a plain `swift build` succeeds.
        .executableTarget(
            name: "macwsl-agent",
            dependencies: [
                "MacWSLAgentKit", "MacWSLCore", "MacWSLProtocol",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        .testTarget(name: "MacWSLCoreTests", dependencies: ["MacWSLCore"]),
        .testTarget(
            name: "MacWSLProtocolTests",
            dependencies: ["MacWSLProtocol", "MacWSLAgentKit", "MacWSLCore", "CMacWSLSystem"]
        ),
        .testTarget(
            name: "MacWSLAgentKitTests",
            dependencies: ["MacWSLAgentKit", "MacWSLProtocol", "MacWSLCore", "CMacWSLSystem"]
        ),
        .testTarget(
            name: "MacWSLCommandLineTests",
            dependencies: [
                "MacWSLCommandLine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "MacWSLVirtualizationTests", dependencies: ["MacWSLVirtualization"]),
        .testTarget(
            name: "macwslTests",
            dependencies: [
                "macwsl",
                "MacWSLCore",
                "MacWSLCommandLine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "macwsldTests",
            dependencies: [
                "macwsld",
                "MacWSLCore",
                "MacWSLProtocol",
                "MacWSLVirtualization",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
