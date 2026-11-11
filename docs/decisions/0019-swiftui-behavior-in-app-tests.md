# 0019: SwiftUI behavior in the app package's tests follows the test runner's SDK

- Status: Accepted
- Date: 2026-11-11

## Context

SwiftUI chooses some behavior by the SDK that a program was linked with. In the app built by
Xcode 27.2, the command palette's query field writes its unchanged text back through its
binding whenever the view updates. Until `WindowModel.setPaletteQuery(_:)` ignored that write
(`1f89fa4`, pull request #26), it undid each arrow key in the theme list. No test showed it:
the palette's tests called the window model directly. `otool -l` reported `sdk 14.0`, the
deployment target, in the `LC_BUILD_VERSION` of the package's test bundle, and `sdk 27.2` in
the app, so the gap was first attributed to the SDK that the test bundle was linked with.

Measured on macOS 27.0.1 with Xcode 27.2 and Swift 6.4.2:

- **Why the bundle records 14.0.** swift-build, the default build system of Swift 6.4 and the
  build system that `xcodebuild` uses for package targets, links through `swiftc`, which passes
  clang the SDK as `--sysroot` only. Clang takes the SDK version from `-isysroot` or `SDKROOT`,
  so it falls back to the deployment target: `-platform_version macos 14.0.0 14.0.0`. Under
  `xcrun`, which sets `SDKROOT`, the same link records 27.2. The native build system, which
  Swift 6.3 and therefore CI use, records the current SDK.
- **Which SDK SwiftUI follows.** It is the main program's. Under `swift test` that program is
  the runner of the selected Xcode, `swiftpm-testing-helper` for swift-testing or `xctest` for
  XCTest, and both record `sdk 27.2`. With the palette's guard reverted, a test that drives
  the palette in a window behaved as follows, with copies of the runner whose build version
  `vtool` rewrote:

  | Test bundle | Runner with SDK 14.0 | Runner with SDK 27.2 |
  |-------------|----------------------|----------------------|
  | SDK 14.0    | ↓ ↓ ↑ move           | each arrow undone    |
  | SDK 27.2    | ↓ ↓ ↑ move           | each arrow undone    |

  With runners rewritten to SDK 15.0, 26.0, and 26.5 the arrows moved; with 27.0 each was
  undone. The field's first write, when it receives the focus, happened with every runner and
  opened the theme list on its first row.

The options considered for testing behavior that depends on the SDK:

1. **Relink the test bundle with the current SDK**, by passing
   `-Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc <SDK path>`,
   by `-Xlinker -platform_version`, by `unsafeFlags` in the test target, or with
   `--build-system native`. Each makes the bundle record the current SDK, and none changes what
   SwiftUI does in the tests, because the runner decides that.
2. **Run the tests with `xcodebuild test`**, through a test target in `App/project.yml`. The
   target's bundle records the current SDK, but the runner is again the Xcode's `xctest`, so
   SwiftUI behaves the same, at the cost of a second Xcode build in CI. Running `xcodebuild
   test` on the package itself records 14.0, for the reason above.
3. **Leave the build unchanged, and test SDK-dependent behavior through the real views in a
   window.**

## Decision

Option 3. The app package's tests are built and run with `swift test`, as before. A behavior
that SwiftUI chooses by the SDK is tested by hosting the real view in an `NSWindow`, delivering
input as AppKit delivers it, and laying the view out before checking the model, as
`CommandPaletteWindowTests` does for the palette's keys. Such a test does not order the window
on screen, and it waits for SwiftUI by turns of the main actor, not by time.

## Consequences

- The tests follow the SDK of the Xcode that runs them, which is also the SDK that Xcode links
  the app with on that Mac or runner. A behavior that appears only with a newer SDK is caught
  once the Mac or runner that runs the tests has that SDK and that macOS.
- `otool -l` on a test bundle built by swift-build still reports the deployment target as its
  SDK. That value does not describe what the tests exercise.
- The terminal app job prints the SDK version, so that a log shows which SDK's behavior the run
  exercised.
