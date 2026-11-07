import Foundation
import MawCore
import MawXPC

/// The text of `maw --status` and `maw --version`. Pure functions, so that the tests can
/// check the output without a daemon.
enum Reports {
    /// `maw --status` with a running daemon, in the style of `maw --list --verbose`:
    ///
    /// ```
    /// mawd 0.1.0, process 4242, running for 2m 05s
    ///
    ///   NAME        STATE      UPTIME    CPUS  MEMORY  SESSIONS
    ///   initramfs   Running    2m 01s    4     2G      2
    /// ```
    static func status(_ status: DaemonStatus) -> String {
        var lines = [
            "mawd \(status.daemon.version), process \(status.daemon.processID), running for "
                + duration(milliseconds: status.uptimeMilliseconds)
        ]
        if !status.canRunVirtualMachines {
            lines.append(
                "warning: mawd is not signed with the virtualization entitlement, so it cannot "
                    + "start virtual machines. Run scripts/sign-dev.sh, then mawd install.")
        }
        lines.append("")
        if status.machines.isEmpty {
            lines.append("No virtual machine is running.")
        } else {
            let rows =
                [["NAME", "STATE", "UPTIME", "CPUS", "MEMORY", "SESSIONS"]]
                + status.machines.map { machine in
                    [
                        machine.machine.name,
                        machine.state.rawValue.capitalized,
                        machine.uptimeMilliseconds.map(duration(milliseconds:)) ?? "-",
                        String(machine.cpuCount),
                        ByteSize(bytes: machine.memoryBytes).description,
                        String(machine.sessionCount),
                    ]
                }
            lines += table(rows).map { "  " + $0 }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `maw --list --online`:
    ///
    /// ```
    /// The distributions that maw --install can install. * marks the one it installs when no
    /// name is given.
    ///
    ///     NAME          ALSO      DESCRIPTION        DOWNLOAD
    ///   * Ubuntu-24.04  Ubuntu    Ubuntu 24.04 LTS   388.3 MB
    /// ```
    static func online(_ catalog: DistroCatalog) -> String {
        let rows =
            [["  NAME", "ALSO", "DESCRIPTION", "DOWNLOAD"]]
            + catalog.entries.map { entry in
                [
                    (entry.name == catalog.recommended ? "* " : "  ") + entry.name.rawValue,
                    entry.aliases.isEmpty
                        ? "-" : entry.aliases.map(\.rawValue).joined(separator: ", "),
                    entry.displayName,
                    ByteSize(bytes: entry.image.size).approximateDescription,
                ]
            }
        let lines =
            [
                "The distributions that maw --install can install. * marks the one it installs "
                    + "when no name is given.",
                "",
            ] + table(rows).map { "  " + $0 }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `maw --status` when the daemon does not run.
    static let daemonNotRunning =
        "The maw daemon is not running. It starts when a command needs a virtual machine.\n"

    /// What `--version` reports about the daemon.
    enum DaemonVersion: Equatable {
        case running(DaemonInfo)
        case notRunning
        case notInstalled
        case unreachable(MawError)
    }

    /// What `--version` reports about the guest files.
    enum GuestVersion: Equatable {
        case installed(GuestFiles.Manifest)
        case unreadable
        case missing
    }

    /// `maw --version`:
    ///
    /// ```
    /// maw 0.1.0
    /// mawd 0.1.0 (process 4242, interface version 1)
    /// guest 2026.10.21, kernel 6.18.57-maw, commit c1abd31a2b3c
    /// ```
    static func version(daemon: DaemonVersion, guest: GuestVersion) -> String {
        var lines = ["maw \(MawVersion.current)"]
        switch daemon {
        case .running(let info):
            lines.append(
                "mawd \(info.version) (process \(info.processID), interface version "
                    + "\(info.interfaceVersion))")
        case .notRunning:
            lines.append("mawd: not running")
        case .notInstalled:
            lines.append("mawd: not installed (run mawd install)")
        case .unreachable(let error):
            lines.append("mawd: \(error.description)")
        }
        switch guest {
        case .installed(let manifest):
            lines.append(
                "guest \(manifest.guestVersion), kernel \(manifest.kernel.release), "
                    + "commit \(manifest.gitCommit.prefix(12))")
        case .unreadable:
            lines.append("guest: manifest.json could not be read")
        case .missing:
            lines.append("guest: not installed (run scripts/fetch-guest.sh)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `45s`, `2m 05s`, or `1h 02m`.
    static func duration(milliseconds: UInt64) -> String {
        let seconds = milliseconds / 1000
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds < 3600 {
            return "\(seconds / 60)m " + twoDigits(seconds % 60) + "s"
        }
        return "\(seconds / 3600)h " + twoDigits(seconds / 60 % 60) + "m"
    }

    private static func twoDigits(_ value: UInt64) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// Left-aligned columns separated by at least two spaces.
    static func table(_ rows: [[String]]) -> [String] {
        let widths = rows.reduce(into: [Int]()) { widths, row in
            for (index, cell) in row.enumerated() {
                if index < widths.count {
                    widths[index] = max(widths[index], cell.count)
                } else {
                    widths.append(cell.count)
                }
            }
        }
        return rows.map { row in
            row.enumerated().map { index, cell in
                index == row.count - 1
                    ? cell : cell.padding(toLength: widths[index] + 2, withPad: " ", startingAt: 0)
            }.joined()
        }
    }
}
