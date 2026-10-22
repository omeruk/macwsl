/// Identifies one of the daemon's virtual machines.
///
/// Until distributions can be installed (phase 05), the only machine is the initramfs machine:
/// the guest kernel and initramfs, with no disk. Phase 05 adds one machine per distribution.
public enum MachineID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The kernel and initramfs, as `mawd debug-boot` boots them.
    case initramfs
    /// The machine that runs an installed distribution, backed by its disk image.
    case distribution(DistroName)

    /// The name shown to users, which also names the machine's console log.
    public var name: String {
        switch self {
        case .initramfs: "initramfs"
        case .distribution(let name): name.rawValue
        }
    }

    public var description: String { name }
}
