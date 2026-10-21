// swift-tools-version: 6.0

import PackageDescription

// The terminal app's logic and views. A separate package rather than a target of the root
// package, so that the root build and the guest agent's Linux build never resolve SwiftTerm or
// need the Metal Toolchain that SwiftTerm's shader requires (docs/decisions/0008-app-package.md).
let package = Package(
    name: "MawTerminalKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MawTerminalKit", targets: ["MawTerminalKit"])
    ],
    dependencies: [
        // Approved in CLAUDE.md. 1.99.x is a preview of 2.0 with API changes.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")
    ],
    targets: [
        .target(
            name: "MawTerminalKit",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .testTarget(
            name: "MawTerminalKitTests",
            dependencies: ["MawTerminalKit", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
    ]
)
