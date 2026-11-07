/// The check of a distribution's root file system that the initramfs runs with `e2fsck -p`
/// before it mounts the file system (`Guest/initramfs/maw-check-root`).
///
/// The script prints e2fsck's exit status on the console in a line of its own, the marker
/// `maw-initramfs: root-check e2fsck-status=<status>`, and the daemon reads it to tell a
/// failed check from other power-offs before the guest agent answers. Only the exit status is
/// read; e2fsck's own messages are free-form and are never interpreted.
public struct RootFileSystemCheck: Equatable, Sendable {
    /// What e2fsck's exit status says, by the values that e2fsck(8) documents. The status is
    /// a sum of those values; the largest one present decides.
    public enum Outcome: Equatable, Sendable {
        /// 0: no errors.
        case clean
        /// 1, 2, or 3: errors were corrected. 2 asks for a reboot, which a file system that is
        /// not mounted yet does not need. The distribution boots.
        case repaired
        /// 4 to 7: errors were left uncorrected.
        case errorsLeftUncorrected
        /// 8 or more: e2fsck could not complete the check, for example because it could not
        /// open the disk or read the superblock (8), was used wrongly (16), was cancelled
        /// (32), or could not load a library (128). A shell also reports 126 and 127 for a
        /// program it cannot run, and 128 plus the signal for one that a signal ended.
        case checkNotCompleted
    }

    /// The marker line, without the status.
    public static let markerPrefix = "maw-initramfs: root-check e2fsck-status="
    /// The beginning of the line that `/init` prints just before it starts the distribution's
    /// systemd. Markers after it come from the distribution, not from the initramfs.
    public static let systemdStartPrefix = "maw-initramfs: starting systemd"

    /// e2fsck's exit status, 0 to 255.
    public let e2fsckStatus: Int

    public init(e2fsckStatus: Int) {
        self.e2fsckStatus = e2fsckStatus
    }

    /// The check that `line` reports, if it is a marker line exactly: the prefix followed by
    /// one to three decimal digits whose value is at most 255, and nothing else.
    public init?(consoleLine line: String) {
        guard line.hasPrefix(Self.markerPrefix) else { return nil }
        let digits = line.dropFirst(Self.markerPrefix.count)
        guard (1...3).contains(digits.count), digits.allSatisfy({ ("0"..."9").contains($0) }),
            let status = Int(digits), status <= 255
        else { return nil }
        e2fsckStatus = status
    }

    public var outcome: Outcome {
        switch e2fsckStatus {
        case 0: .clean
        case 1...3: .repaired
        case 4...7: .errorsLeftUncorrected
        default: .checkNotCompleted
        }
    }

    /// Whether the initramfs mounts the file system and boots the distribution: with no
    /// errors, or with only corrected ones.
    public var allowsBoot: Bool {
        switch outcome {
        case .clean, .repaired: true
        case .errorsLeftUncorrected, .checkNotCompleted: false
        }
    }
}

/// Follows a distribution machine's console from its start, and keeps the root file system
/// check that the initramfs reports.
///
/// The last marker before the line that starts systemd counts: e2fsck's output comes before
/// the initramfs's own marker, so a marker-like line in it, such as a file name, cannot take
/// the marker's place. Lines after systemd starts are not read.
public struct RootFileSystemCheckScanner: Sendable {
    /// The check the console has reported so far, if any.
    public private(set) var check: RootFileSystemCheck?
    /// Whether systemd has started, after which no line is read.
    public private(set) var isFinished = false

    public init() {}

    /// Reads one console line, without its line terminator.
    public mutating func read(_ line: String) {
        guard !isFinished else { return }
        if let check = RootFileSystemCheck(consoleLine: line) {
            self.check = check
        } else if line.hasPrefix(RootFileSystemCheck.systemdStartPrefix) {
            isFinished = true
        }
    }
}
