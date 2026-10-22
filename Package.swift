// swift-tools-version: 6.0

import PackageDescription

// Targets marked "macOS only" wrap their sources in `#if os(macOS)`. The manifest is evaluated
// on the host even when cross-compiling, so `#if os(...)` here cannot exclude them; instead the
// guest agent depends only on the portable modules, which keeps
// `swift build --swift-sdk aarch64-swift-linux-musl --product maw-agent` free of macOS code.
// The portable modules import FoundationEssentials where it exists, so that the agent does not
// link ICU (see docs/decisions/0005-init-supervises-the-agent.md).
let package = Package(
    name: "maw",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "maw", targets: ["maw"]),
        .executable(name: "mawd", targets: ["mawd"]),
        .executable(name: "maw-agent", targets: ["maw-agent"]),
        .library(name: "MawCore", targets: ["MawCore"]),
        .library(name: "MawProtocol", targets: ["MawProtocol"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        // Guest only: the agent's logging (approved in CLAUDE.md).
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.1"),
    ],
    targets: [
        // Portable: macOS and Linux.
        .target(name: "MawCore"),
        // System calls that Swift cannot make directly (docs/decisions/0006).
        .target(name: "CMawSystem"),
        .target(name: "MawProtocol", dependencies: ["MawCore", "CMawSystem"]),
        // The guest agent's logic. Portable, so that its tests run on macOS.
        .target(
            name: "MawAgentKit",
            dependencies: [
                "MawCore", "MawProtocol", "CMawSystem",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // macOS only.
        .target(name: "MawVirtualization", dependencies: ["MawCore", "MawProtocol"]),
        // The XPC interface between mawd and its clients (docs/daemon.md).
        .target(name: "MawXPC", dependencies: ["MawCore", "MawProtocol"]),
        // Error reporting shared by the maw and mawd command lines.
        .target(
            name: "MawCommandLine",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .target(
            name: "MawDaemonKit",
            dependencies: ["MawCore", "MawProtocol", "MawVirtualization"]
        ),
        .executableTarget(
            name: "maw",
            dependencies: [
                "MawCore",
                "MawCommandLine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "mawd",
            dependencies: [
                "MawCore",
                "MawCommandLine",
                "MawDaemonKit",
                "MawProtocol",
                "MawVirtualization",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // Linux only (guest). Also compiles on macOS so that a plain `swift build` succeeds.
        .executableTarget(
            name: "maw-agent",
            dependencies: [
                "MawAgentKit", "MawCore", "MawProtocol",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        .testTarget(name: "MawCoreTests", dependencies: ["MawCore"]),
        .testTarget(
            name: "MawProtocolTests",
            dependencies: ["MawProtocol", "MawAgentKit", "MawCore", "CMawSystem"]
        ),
        .testTarget(
            name: "MawAgentKitTests",
            dependencies: ["MawAgentKit", "MawProtocol", "MawCore", "CMawSystem"]
        ),
        .testTarget(
            name: "MawCommandLineTests",
            dependencies: [
                "MawCommandLine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "MawVirtualizationTests", dependencies: ["MawVirtualization"]),
        .testTarget(
            name: "MawXPCTests", dependencies: ["MawXPC", "MawCore", "MawProtocol", "CMawSystem"]),
        .testTarget(
            name: "mawTests",
            dependencies: [
                "maw",
                "MawCore",
                "MawCommandLine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "mawdTests",
            dependencies: [
                "mawd",
                "MawCore",
                "MawProtocol",
                "MawVirtualization",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
