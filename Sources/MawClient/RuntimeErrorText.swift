import Foundation

/// The text that `maw` prints for a runtime error, for clients that show an error as `maw`
/// does, such as the terminal app's panes: `maw: <message>`, then the suggested fix on the next
/// line when there is one, ending in a line feed. The message and the suggestion may contain
/// line feeds of their own.
///
/// It renders a `MawError` byte for byte as `maw` prints it (a unit test in `mawTests` compares
/// the two), and any other `LocalizedError` in the same form.
public func runtimeErrorText(_ error: some LocalizedError) -> String {
    var lines = ["maw: \(error.errorDescription ?? String(describing: error))"]
    if let suggestion = error.recoverySuggestion {
        lines.append(suggestion)
    }
    return lines.joined(separator: "\n") + "\n"
}
