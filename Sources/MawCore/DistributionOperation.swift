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
    /// `maw --import`, from the check of the name until the first start has ended.
    case `import`

    /// The command that runs the operation, as messages name it.
    public var command: String {
        switch self {
        case .install: "maw --install"
        case .export: "maw --export"
        case .removal: "maw --unregister"
        case .import: "maw --import"
        }
    }

    /// What the operation does to the distribution, as in "Ubuntu-24.04 is being exported".
    public var participle: String {
        switch self {
        case .install: "installed"
        case .export: "exported"
        case .removal: "removed"
        case .import: "imported"
        }
    }

    /// The operation as a noun, as in "Wait for the other installation to finish".
    public var noun: String {
        switch self {
        case .install: "installation"
        case .export: "export"
        case .removal: "removal"
        case .import: "import"
        }
    }

    /// Whether the operation creates the distribution: an installation or an import. It holds
    /// a name that is not installed yet, starts the new distribution's machine itself, and
    /// excludes another operation of the same kind on that name.
    public var createsTheDistribution: Bool {
        switch self {
        case .install, .import: true
        case .export, .removal: false
        }
    }
}
