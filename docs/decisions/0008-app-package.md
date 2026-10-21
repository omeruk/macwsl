# 0008: The terminal app's code is a separate Swift package under App/

- Status: Accepted
- Date: 2026-10-21

## Context

The terminal app's logic and views, `MawTerminalKit`, depend on SwiftTerm (approved in
`CLAUDE.md`). Two facts about SwiftTerm 1.20.0 shape where that code can live:

- **It compiles a Metal shader.** Building it requires Xcode's Metal Toolchain, which Xcode 27.1
  installs as a separate download. Without it, the build stops with
  `cannot execute tool 'metal' due to missing Metal Toolchain`.
- **Its manifest is evaluated wherever the package is resolved.** A dependency of the root
  package is fetched and its manifest evaluated even on platforms where no target uses it.

The root `Package.swift` is also built on Linux, by the Guest workflow, with the Swift Static
Linux SDK, to produce `macwsl-agent`. `Package.swift` and `Package.resolved` are among that
workflow's path filters.

The options considered:

1. **A target of the root package.** Every root build, on every developer machine and in the
   main CI job, would need the Metal Toolchain, including builds that never touch the app.
   The Guest workflow would fetch SwiftTerm and evaluate its manifest on every agent build,
   and every SwiftTerm update would change `Package.resolved` and rerun the full guest
   pipeline. A target dependency condition such as `.when(platforms: [.macOS])` does not
   prevent the package from being resolved.
2. **A separate package at `App/MawTerminalKit/`.** The root package, its resolved file, and
   the guest build are unaffected. The app's tests run with
   `swift test --package-path App/MawTerminalKit`, which the CI app job does.

## Decision

Option 2. `App/MawTerminalKit/Package.swift` defines the `MawTerminalKit` library and the
`MawTerminalKitTests` test target. It pins SwiftTerm to exactly `1.20.0`. The 1.99.x line is
a preview of SwiftTerm 2.0, with API changes.

- **Dependencies point from the app to the root package, never back.** When a `LinuxSession`
  needs MacWSL's modules, `MawTerminalKit` will depend on the root package through
  `.package(path: "../..")`. The root package never depends on anything under `App/`.
- **The package follows the root package's conventions:** Swift 6 language mode, macOS 14,
  swift-testing, `swift format` with the repository's `.swift-format`, and `os.Logger`.
- **It is macOS only.** Unlike the root package's macOS modules, its sources are not wrapped
  in `#if os(macOS)`, because no Linux build ever includes it.

## Consequences

- Building or testing the app requires the Metal Toolchain
  (`xcodebuild -downloadComponent MetalToolchain`). The root package does not.
- The CI app job installs the Metal Toolchain, and the main job does not.
- `swift test` at the repository root does not run the app's tests. The README and the CI
  configuration name both commands.
