import Foundation
import MawTerminalKit

/// The app's entry point. Everything else is in the MawTerminalKit package
/// (docs/decisions/0008-app-package.md).
///
/// maw runs on the AppKit application life cycle rather than SwiftUI's `App` protocol, because
/// its menu bar is built from the command registry and its windows need AppKit's title bar
/// configuration. SwiftUI draws all window content.
@main
struct MawApp {
    @MainActor
    static func main() {
        AppController.run(
            fontsDirectory: Bundle.main.url(forResource: "Fonts", withExtension: nil))
    }
}
