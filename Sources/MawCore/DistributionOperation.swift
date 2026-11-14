/// An operation that holds a distribution's name while it runs, so that the daemon refuses the
/// requests that would conflict with it, with an error that names the operation
/// (docs/daemon.md, "Operations on a distribution").
public enum DistributionOperation: String, Codable, Equatable, Sendable, CaseIterable {
    /// `maw --install`, from the check of the name until the distribution is registered.
    case install
    /// `maw --export`, while the provisioning machine reads the distribution's disk.
    case export
    /// `maw --unregister`, from the stop of the machine until the files are deleted.
    case removal

    /// The command that runs the operation, as messages name it.
    public var command: String {
        switch self {
        case .install: "maw --install"
        case .export: "maw --export"
        case .removal: "maw --unregister"
        }
    }

    /// What the operation does to the distribution, as in "Ubuntu-24.04 is being exported".
    public var participle: String {
        switch self {
        case .install: "installed"
        case .export: "exported"
        case .removal: "removed"
        }
    }
}
