import MawCore
import MawXPC

/// The text of `maw --install`'s progress: one line per step, its label padded so that the
/// durations line up, in the order the steps run.
///
/// ```
/// Downloading Ubuntu 24.04 LTS     388.3 MB in 1 min 9 s (5.6 MB/s)
/// Verifying the image              0.3 s
/// Extracting the root file system  5.5 s
/// ```
struct InstallProgressText {
    let name: DistroName
    let displayName: String

    func label(for step: InstallStep) -> String {
        switch step {
        case .download: "Downloading \(displayName)"
        case .verify: "Verifying the image"
        case .prepare: "Creating the virtual disk"
        case .format: "Formatting the disk"
        case .extract: "Extracting the root file system"
        case .configure: "Configuring \(name)"
        case .finish: "Writing the disk"
        case .start: "Starting \(name)"
        }
    }

    /// The width every label is padded to: the longest label and two spaces.
    var labelWidth: Int {
        InstallStep.allCases.map { label(for: $0).count }.max()! + 2
    }

    func padded(_ step: InstallStep) -> String {
        label(for: step).padding(toLength: labelWidth, withPad: " ", startingAt: 0)
    }

    /// While downloading: `134.2 MB of 388.3 MB, 5.4 MB/s, 47 s left`.
    static func downloading(_ progress: DownloadProgress) -> String {
        var parts = [
            "\(size(progress.receivedBytes)) of \(size(progress.totalBytes))"
        ]
        if progress.bytesPerSecond > 0 {
            parts.append("\(size(progress.bytesPerSecond))/s")
            let remaining = progress.totalBytes - min(progress.totalBytes, progress.receivedBytes)
            parts.append("\(duration(seconds: remaining / progress.bytesPerSecond)) left")
        }
        var text = parts.joined(separator: ", ")
        if progress.resumedFromBytes > 0 {
            text += " (resumed at \(size(progress.resumedFromBytes)))"
        }
        return text
    }

    /// After the download: `388.3 MB in 1 min 9 s (5.6 MB/s)`.
    static func downloaded(_ progress: DownloadProgress?, milliseconds: UInt64) -> String {
        guard let progress else { return duration(milliseconds: milliseconds) }
        let fetched =
            progress.receivedBytes - min(progress.receivedBytes, progress.resumedFromBytes)
        var text = "\(size(progress.totalBytes)) in \(duration(milliseconds: milliseconds))"
        if milliseconds > 0 {
            text += " (\(size(fetched * 1000 / milliseconds))/s)"
        }
        return text
    }

    /// `0.4 s`, `12.3 s`, `1 min 9 s`.
    static func duration(milliseconds: UInt64) -> String {
        if milliseconds < 60_000 {
            let tenths = (milliseconds + 50) / 100
            return "\(tenths / 10).\(tenths % 10) s"
        }
        return duration(seconds: (milliseconds + 500) / 1000)
    }

    /// `47 s`, `1 min 9 s`, `12 min`.
    static func duration(seconds: UInt64) -> String {
        if seconds < 60 {
            return "\(seconds) s"
        }
        let minutes = seconds / 60
        let rest = seconds % 60
        if minutes >= 10 || rest == 0 {
            return "\(minutes) min"
        }
        return "\(minutes) min \(rest) s"
    }

    private static func size(_ bytes: UInt64) -> String {
        ByteSize(bytes: bytes).approximateDescription
    }
}
