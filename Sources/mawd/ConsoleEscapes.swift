import MawCore

/// The control key that detaches an interactive session, or none.
///
/// Written as `^X` or `ctrl-X`, case-insensitive, for example `^]` or `ctrl-q`, or `none`.
struct DetachKey: Equatable, Sendable, CustomStringConvertible {
    /// Ctrl-], like telnet. It needs the Option key on many non-US keyboard layouts, so the
    /// `~.` escape sequence is always available as well.
    static let `default` = DetachKey(byte: 0x1D)
    static let none = DetachKey(byte: nil)

    /// The byte the terminal sends for the key, or `nil` for none.
    let byte: UInt8?

    init(byte: UInt8?) {
        self.byte = byte
    }

    init(parsing text: String) throws(MawError) {
        let lowered = text.lowercased()
        if lowered == "none" {
            self.byte = nil
            return
        }
        let key: Substring
        if lowered.hasPrefix("^") {
            key = text.dropFirst()
        } else if lowered.hasPrefix("ctrl-") {
            key = text.dropFirst(5)
        } else {
            throw .invalidDetachKey(text, reason: "write it as ^X or ctrl-X, or none")
        }
        // Control keys are the characters @, A to Z, [, \, ], ^, and _ with Ctrl held, which
        // the terminal sends as 0x00 to 0x1F.
        guard key.count == 1, let scalar = key.uppercased().unicodeScalars.first,
            (0x40...0x5F).contains(scalar.value)
        else {
            throw .invalidDetachKey(text, reason: "it is not a control key")
        }
        let byte = UInt8(scalar.value) ^ 0x40
        switch byte {
        case 0x1B:
            throw .invalidDetachKey(text, reason: "it is Escape, which starts arrow-key sequences")
        case 0x0A, 0x0D:
            throw .invalidDetachKey(text, reason: "it is Enter")
        default:
            self.byte = byte
        }
    }

    /// `Ctrl-]`, `Ctrl-Q`, or `none`.
    var description: String {
        guard let byte else { return "none" }
        return "Ctrl-\(Character(Unicode.Scalar(byte ^ 0x40)))"
    }
}

/// Recognizes an interactive session's escape sequences in the bytes the user types, as ssh
/// does:
///
/// - `~.` at the start of a line detaches;
/// - `~?` at the start of a line lists the escape sequences;
/// - `~~` at the start of a line sends a single `~`;
/// - the detach key, anywhere, detaches.
///
/// A line starts at the beginning of the session and after Enter (CR or LF). A `~` at the start
/// of a line is held back until the next byte shows whether it begins an escape sequence; any
/// other byte sends both. Escape sequences need no particular key, so they work on every
/// keyboard layout.
struct ConsoleEscapes {
    enum Action: Equatable {
        /// Bytes to send to the guest.
        case send([UInt8])
        /// The user asked for the list of escape sequences.
        case showHelp
        /// The user asked to detach. Bytes after it are not processed.
        case detach
    }

    let detachKey: DetachKey
    private var isAtLineStart = true
    private var isHoldingTilde = false

    init(detachKey: DetachKey) {
        self.detachKey = detachKey
    }

    mutating func process(_ bytes: some Sequence<UInt8>) -> [Action] {
        var actions: [Action] = []
        var pending: [UInt8] = []
        func sendPending() {
            if !pending.isEmpty {
                actions.append(.send(pending))
                pending.removeAll()
            }
        }

        for byte in bytes {
            if isHoldingTilde {
                isHoldingTilde = false
                switch byte {
                case UInt8(ascii: "."):
                    sendPending()
                    actions.append(.detach)
                    return actions
                case UInt8(ascii: "?"):
                    sendPending()
                    actions.append(.showHelp)
                    continue
                case UInt8(ascii: "~"):
                    pending.append(UInt8(ascii: "~"))
                    isAtLineStart = false
                    continue
                default:
                    // Not an escape sequence: send the held "~", then handle this byte.
                    pending.append(UInt8(ascii: "~"))
                    isAtLineStart = false
                }
            }
            if byte == detachKey.byte {
                sendPending()
                actions.append(.detach)
                return actions
            }
            if isAtLineStart && byte == UInt8(ascii: "~") {
                isHoldingTilde = true
                continue
            }
            pending.append(byte)
            isAtLineStart = byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n")
        }
        sendPending()
        return actions
    }

    /// The text `~?` prints, with the line ending the terminal needs.
    func help(lineEnding: String) -> String {
        var lines = [
            "Escape sequences, typed at the start of a line:",
            "  ~.  stop the virtual machine and detach",
            "  ~?  list these escape sequences",
            "  ~~  send a single ~",
        ]
        if detachKey.byte != nil {
            lines.append("\(detachKey) also stops the virtual machine and detaches.")
        }
        return lines.map { $0 + lineEnding }.joined()
    }

    /// The startup line that names the active detach keys.
    var instructions: String {
        if detachKey.byte != nil {
            return "To stop the virtual machine and detach, type ~. at the start of a line "
                + "or press \(detachKey). Type ~? for help."
        }
        return "To stop the virtual machine and detach, type ~. at the start of a line. "
            + "Type ~? for help."
    }
}
