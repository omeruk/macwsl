/// What `GuestProcess.foregroundProgram(within:)` reports about the program in the foreground
/// of a session's terminal.
public enum ForegroundAnswer: Hashable, Sendable {
    /// No program other than the session's shell is in the foreground: the shell is, or the
    /// session is in pipe mode, or it has ended.
    case none
    /// A program other than the shell, in the guest's process group `processGroup`. `name` is
    /// its leader's command name, made safe to show (`displayableName(_:)`), or `nil` when the
    /// leader has exited.
    case program(processGroup: Int32, name: String?)
    /// The agent did not answer in time.
    case noAnswer

    /// The most bytes of a name that the host keeps.
    public static let nameLimit = 64

    /// The answer for the agent's reply.
    init(_ program: ForegroundProcess?) {
        guard let program else {
            self = .none
            return
        }
        self = .program(
            processGroup: program.processGroup, name: program.name.map(Self.displayableName))
    }

    /// `name`, which comes from the guest, made safe to show: control, format, and separator
    /// characters, which could move the cursor, change colors, or reorder text, become U+FFFD,
    /// and at most `nameLimit` bytes of whole Unicode scalars are kept.
    public static func displayableName(_ name: String) -> String {
        var result = String.UnicodeScalarView()
        var size = 0
        for scalar in name.unicodeScalars {
            let shown: Unicode.Scalar
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                shown = "\u{FFFD}"
            default:
                shown = scalar
            }
            size += shown.utf8.count
            guard size <= nameLimit else { break }
            result.append(shown)
        }
        return String(result)
    }
}
