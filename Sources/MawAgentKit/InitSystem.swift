/// The program running as PID 1 in the guest, which the agent asks to power off.
///
/// The initramfs machine runs busybox `init` (docs/decisions/0005-init-supervises-the-agent.md);
/// a distribution's machine runs systemd (docs/decisions/0013-systemd-and-the-agent.md).
public enum InitSystem: Equatable, Sendable {
    case busybox
    case systemd

    /// systemd creates `/run/systemd/system` early in its boot, which is how `sd_booted(3)`
    /// recognizes it.
    public static let systemdMarker = "/run/systemd/system"

    public static func detect(directoryExists: (String) -> Bool) -> InitSystem {
        directoryExists(systemdMarker) ? .systemd : .busybox
    }

    /// The Linux signal that makes PID 1 power off cleanly.
    ///
    /// - busybox `init`: SIGUSR2, which runs the inittab shutdown actions.
    /// - systemd: SIGRTMIN+4, which starts `poweroff.target`. systemd is built against glibc,
    ///   whose SIGRTMIN is 34. The agent is linked against musl, whose SIGRTMIN is 35, so the
    ///   number is spelled out rather than computed.
    public var powerOffSignal: Int32 {
        switch self {
        case .busybox: 12
        case .systemd: 38
        }
    }
}
