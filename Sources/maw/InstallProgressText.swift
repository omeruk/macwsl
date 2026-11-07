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

    /// While downloading: `134.2 MB of 388.3 MB, 5.4 MB/s, 47 s left`, and
    /// ` (resumed at 42.8 MB)` when it continues an interrupted download.
    static func downloading(_ progress: DownloadProgress) -> String {
        DownloadParts(progress).body(amount: true, rate: true, resumed: true)
    }

    /// After the download: `388.3 MB in 1 min 9 s (5.6 MB/s)`, and `, resumed at 42.8 MB` when it
    /// continued an interrupted download.
    static func downloaded(_ progress: DownloadProgress?, milliseconds: UInt64) -> String {
        guard let progress else { return duration(milliseconds: milliseconds) }
        return downloaded(progress, milliseconds: milliseconds, rate: true, resumed: true)
    }

    /// The download's line on a terminal, label included, at most `columns` wide (`nil`: no
    /// limit). It drops, in this order, until the line fits: the resumption note, the rate, the
    /// padding after the label, the distribution's name in the label, the sizes (for a
    /// percentage), and the time left; then it truncates.
    func downloadingLine(_ progress: DownloadProgress?, columns: Int?) -> String {
        let short = "Downloading"
        guard let progress else {
            return Self.fit([padded(.download), label(for: .download), short], columns: columns)
        }
        let parts = DownloadParts(progress)
        let full = parts.body(amount: true, rate: true, resumed: false)
        let withoutRate = parts.body(amount: true, rate: false, resumed: false)
        return Self.fit(
            [
                padded(.download) + parts.body(amount: true, rate: true, resumed: true),
                padded(.download) + full,
                padded(.download) + withoutRate,
                label(for: .download) + " " + withoutRate,
                short + " " + withoutRate,
                short + " " + parts.body(amount: false, rate: false, resumed: false),
                short + " " + parts.percentage,
            ], columns: columns)
    }

    /// The download's last line on a terminal, at most `columns` wide. It drops, in this order:
    /// the rate, the padding, the distribution's name, and the resumption note, which only this
    /// line shows; then it truncates.
    func downloadedLine(_ progress: DownloadProgress?, milliseconds: UInt64, columns: Int?)
        -> String
    {
        guard let progress else {
            return Self.fit(
                [padded(.download) + Self.duration(milliseconds: milliseconds)], columns: columns)
        }
        let withoutRate = Self.downloaded(
            progress, milliseconds: milliseconds, rate: false, resumed: true)
        return Self.fit(
            [
                padded(.download)
                    + Self.downloaded(
                        progress, milliseconds: milliseconds, rate: true, resumed: true),
                padded(.download) + withoutRate,
                label(for: .download) + " " + withoutRate,
                "Downloading " + withoutRate,
                "Downloading "
                    + Self.downloaded(
                        progress, milliseconds: milliseconds, rate: false, resumed: false),
            ], columns: columns)
    }

    /// The first candidate that fits, or the last one truncated.
    static func fit(_ candidates: [String], columns: Int?) -> String {
        guard let columns else { return candidates[0] }
        return candidates.first { $0.count <= columns } ?? String(candidates.last!.prefix(columns))
    }

    private static func downloaded(
        _ progress: DownloadProgress, milliseconds: UInt64, rate: Bool, resumed: Bool
    ) -> String {
        let fetched =
            progress.receivedBytes - min(progress.receivedBytes, progress.resumedFromBytes)
        var text = "\(size(progress.totalBytes)) in \(duration(milliseconds: milliseconds))"
        if rate, milliseconds > 0 {
            text += " (\(size(fetched * 1000 / milliseconds))/s)"
        }
        if resumed, progress.resumedFromBytes > 0 {
            text += ", resumed at \(size(progress.resumedFromBytes))"
        }
        return text
    }

    /// The pieces of a download's progress text.
    private struct DownloadParts {
        let progress: DownloadProgress

        init(_ progress: DownloadProgress) {
            self.progress = progress
        }

        var percentage: String {
            guard progress.totalBytes > 0 else { return "0%" }
            return
                "\(min(progress.receivedBytes, progress.totalBytes) * 100 / progress.totalBytes)%"
        }

        /// The sizes or the percentage, the rate if asked for, and the time left; the rate and
        /// the time left only once the rate is known.
        func body(amount: Bool, rate: Bool, resumed: Bool) -> String {
            var parts = [
                amount
                    ? "\(InstallProgressText.size(progress.receivedBytes)) of \(InstallProgressText.size(progress.totalBytes))"
                    : percentage
            ]
            if progress.bytesPerSecond > 0 {
                if rate {
                    parts.append("\(InstallProgressText.size(progress.bytesPerSecond))/s")
                }
                let remaining =
                    progress.totalBytes - min(progress.totalBytes, progress.receivedBytes)
                parts.append(
                    "\(InstallProgressText.duration(seconds: remaining / progress.bytesPerSecond)) left"
                )
            }
            var text = parts.joined(separator: ", ")
            if resumed, progress.resumedFromBytes > 0 {
                text += " (resumed at \(InstallProgressText.size(progress.resumedFromBytes)))"
            }
            return text
        }
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

    fileprivate static func size(_ bytes: UInt64) -> String {
        ByteSize(bytes: bytes).approximateDescription
    }
}
