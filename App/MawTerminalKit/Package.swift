// swift-tools-version: 6.0

import PackageDescription

// The terminal app's logic and views. A separate package rather than a target of the root
// package, so that the root build and the guest agent's Linux build never resolve SwiftTerm or
// need the Metal Toolchain that SwiftTerm's shader requires (docs/decisions/0008-app-package.md).
// The dependency points one way: this package uses the root package's client products, named
// `maw` so that a clone into a directory of any name resolves them.
let package = Package(
    name: "MawTerminalKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MawTerminalKit", targets: ["MawTerminalKit"])
    ],
    dependencies: [
        // Approved in CLAUDE.md. 1.99.x is a preview of 2.0 with API changes.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(name: "maw", path: "../.."),
    ],
    targets: [
        // The fork that starts a local shell, whose child may only make async-signal-safe calls.
        .target(name: "CMawTerminal"),
        .target(
            name: "MawTerminalKit",
            dependencies: [
                "CMawTerminal",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "MawClient", package: "maw"),
                .product(name: "MawXPC", package: "maw"),
                .product(name: "MawCore", package: "maw"),
                .product(name: "MawProtocol", package: "maw"),
            ]
        ),
        // The app's measurements of phase 11c, which scripts/measure-figures.sh builds, signs
        // as the app, and runs against the test daemon. Not part of any product.
        .executableTarget(
            name: "maw-figures-harness",
            dependencies: ["MawTerminalKit", .product(name: "MawCore", package: "maw")],
            path: "Tests/FiguresHarness"
        ),
        .testTarget(
            name: "MawTerminalKitTests",
            dependencies: ["MawTerminalKit", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
    ]
)
