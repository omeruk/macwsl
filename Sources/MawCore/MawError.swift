#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Errors shared by every maw component.
///
/// Each case carries a user-facing message (`errorDescription`) and, where one exists, a concrete
/// next step (`recoverySuggestion`). Front ends print both; they never print a raw Swift error.
///
/// `Codable`, so that the daemon can return an error to its clients unchanged.
public enum MawError: Error, Equatable, Sendable, Codable {
    /// A distribution name failed validation. `reason` explains which rule it broke.
    case invalidDistroName(String, reason: String)
    /// The requested feature exists in the command surface but has no implementation yet.
    /// `phase` names the roadmap phase that adds it, for example `"05"`.
    case notImplemented(feature: String, phase: String)
    /// A size such as `--memory 4G` could not be parsed.
    case invalidSize(String, reason: String)

    // MARK: Distributions and sessions

    /// `-d` names a distribution that is not installed.
    case distributionNotInstalled(DistroName)
    /// `--cd` names a directory that maw cannot use yet: a relative or macOS path.
    case unsupportedDirectory(String)

    // MARK: Daemon

    /// The LaunchAgent that runs `mawd` is not registered with launchd. `label` names it.
    case daemonNotInstalled(label: String)
    /// The daemon could not be reached, or it closed the connection.
    case daemonUnreachable(reason: String)
    /// The daemon exited, or the connection to it broke, while a request or session was active.
    case daemonConnectionLost(during: String)
    /// The client and the daemon speak different versions of the XPC interface.
    case daemonVersionMismatch(client: UInt32, daemon: UInt32)
    /// The daemon sent a message that the client cannot read, or the reverse.
    case daemonProtocolError(reason: String)
    /// This executable's code signature does not satisfy the daemon's peer requirement, so the
    /// daemon would refuse its connection. `identifier` is the signature's identifier.
    case clientSignatureRejected(identifier: String)
    /// The virtual machine that ran the session stopped. `reason` says why.
    case machineStopped(machine: String, reason: String)
    /// The LaunchAgent could not be installed or removed.
    case launchAgentFailed(reason: String)

    // MARK: Guest files

    /// A guest file (kernel, initramfs, or manifest) is missing. `path` is the missing file.
    case kernelNotFound(path: String)

    // MARK: Virtualization

    /// The process is not signed with the `com.apple.security.virtualization` entitlement.
    case virtualizationEntitlementMissing
    /// Virtualization.framework cannot run virtual machines here, for example inside a VM.
    case virtualizationUnavailable(reason: String)
    /// Virtualization.framework rejected the virtual machine configuration.
    case invalidVMConfiguration(reason: String)
    /// The virtual machine failed to start.
    case vmStartFailed(reason: String)
    /// The virtual machine stopped because of an error, or an operation on it failed.
    case vmFailed(reason: String)
    /// The guest did not stop within the allowed time.
    case guestStopTimedOut(seconds: Int)

    // MARK: Disk images

    /// A disk image to be created already exists.
    case diskImageExists(path: String)
    /// A disk image to be attached does not exist.
    case diskImageNotFound(path: String)
    /// The volume cannot store sparse files, so a disk image would occupy its full size.
    case sparseFilesUnsupported(path: String)
    /// Creating a disk image failed.
    case diskImageCreationFailed(path: String, reason: String)

    // MARK: Console and terminal

    /// The console log could not be opened or written.
    case consoleLogFailed(path: String, reason: String)
    /// An interactive session, selected by `option`, needs a terminal, but `stream` is not one.
    case notATerminal(option: String, stream: String)
    /// `--detach-key` could not be parsed or names a key that the session needs.
    case invalidDetachKey(String, reason: String)

    // MARK: Guest agent

    /// The guest agent did not answer before the deadline, or could not be reached.
    case guestAgentUnavailable(reason: String)
    /// The host and the guest agent speak different protocol versions.
    case guestAgentVersionMismatch(host: UInt32, guest: UInt32)
    /// A conversation with the guest agent failed partway through.
    case guestAgentFailed(reason: String)
    /// The command to run in the guest does not exist there. Shells report this as 127.
    case guestCommandNotFound(command: String, reason: String)
    /// The command exists in the guest but could not be started. Shells report this as 126.
    case guestCommandNotStarted(command: String, reason: String)
}

extension MawError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDistroName(let name, let reason):
            "'\(name)' is not a valid distribution name: \(reason)."
        case .notImplemented(let feature, let phase):
            "\(feature) is not implemented yet; phase \(phase) adds it."
        case .invalidSize(let text, let reason):
            "'\(text)' is not a valid size: \(reason)."
        case .distributionNotInstalled(let name):
            "No distribution named '\(name)' is installed."
        case .unsupportedDirectory(let path):
            "--cd needs an absolute Linux path, such as /root, but '\(path)' is not one."
        case .daemonNotInstalled(let label):
            "The maw daemon is not installed: launchd has no LaunchAgent named \(label)."
        case .daemonUnreachable(let reason):
            "The maw daemon cannot be reached: \(reason)."
        case .daemonConnectionLost(let request):
            "The maw daemon exited or closed the connection during \(request)."
        case .daemonVersionMismatch(let client, let daemon):
            "The maw daemon speaks interface version \(daemon), but this maw speaks version "
                + "\(client)."
        case .daemonProtocolError(let reason):
            "A message between maw and its daemon could not be read: \(reason)."
        case .clientSignatureRejected(let identifier):
            "This executable is signed as '\(identifier)', which the maw daemon does not accept."
        case .machineStopped(let machine, let reason):
            "The session ended because the virtual machine \(machine) stopped: \(reason)."
        case .launchAgentFailed(let reason):
            "The maw LaunchAgent could not be changed: \(reason)."
        case .kernelNotFound(let path):
            "The guest kernel files are missing: \(path) does not exist."
        case .virtualizationEntitlementMissing:
            "mawd is not signed with the virtualization entitlement "
                + "(com.apple.security.virtualization), so it cannot create virtual machines."
        case .virtualizationUnavailable(let reason):
            "Virtualization is not available on this Mac: \(reason)"
        case .invalidVMConfiguration(let reason):
            "The virtual machine configuration is invalid: \(reason)"
        case .vmStartFailed(let reason):
            "The virtual machine failed to start: \(reason)"
        case .vmFailed(let reason):
            "The virtual machine failed: \(reason)"
        case .guestStopTimedOut(let seconds):
            "The guest did not stop within \(seconds) seconds."
        case .diskImageExists(let path):
            "The disk image \(path) already exists."
        case .diskImageNotFound(let path):
            "The disk image \(path) does not exist."
        case .sparseFilesUnsupported(let path):
            "The volume that contains \(path) does not support sparse files."
        case .diskImageCreationFailed(let path, let reason):
            "Could not create the disk image \(path): \(reason)."
        case .consoleLogFailed(let path, let reason):
            "Could not write the console log \(path): \(reason)."
        case .notATerminal(let option, let stream):
            "\(option) needs a terminal, but \(stream) is not a terminal."
        case .invalidDetachKey(let text, let reason):
            "'\(text)' cannot be the detach key: \(reason)."
        case .guestAgentUnavailable(let reason):
            "The guest agent is not responding: \(reason)."
        case .guestAgentVersionMismatch(let host, let guest):
            "The guest agent speaks protocol version \(guest), but this build of maw speaks "
                + "version \(host)."
        case .guestAgentFailed(let reason):
            "The connection to the guest agent failed: \(reason)."
        case .guestCommandNotFound(let command, let reason):
            "\(command): command not found in the guest (\(reason))."
        case .guestCommandNotStarted(let command, let reason):
            "\(command) could not be started in the guest: \(reason)."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidDistroName:
            "Use 1 to \(DistroName.maximumLength) letters, digits, '.', '-' or '_', "
                + "starting with a letter or digit (for example 'Ubuntu-24.04')."
        case .notImplemented:
            nil
        case .invalidSize:
            "Write a whole number followed by K, M, G, or T, for example 512M or 4G."
        case .distributionNotInstalled(let name):
            "Install it with maw --install \(name)."
        case .unsupportedDirectory:
            "Translating relative and macOS paths arrives in phase 07. Until then, give an "
                + "absolute path inside Linux."
        case .daemonNotInstalled:
            "Register the daemon with mawd install."
        case .daemonUnreachable, .daemonConnectionLost, .daemonProtocolError:
            "The daemon's log, ~/Library/Logs/maw/mawd.log, may say why."
        case .daemonVersionMismatch:
            "Run mawd install again, so that launchd runs the daemon from this build."
        case .clientSignatureRejected:
            "Build and sign with scripts/sign-dev.sh; a plain swift build replaces the signature."
        case .machineStopped:
            "Run the command again to start a new virtual machine."
        case .launchAgentFailed:
            nil
        case .kernelNotFound:
            "Install the guest kernel and initramfs with scripts/fetch-guest.sh."
        case .virtualizationEntitlementMissing:
            "Build and sign with scripts/sign-dev.sh, then run it again. For the daemon, run "
                + "mawd install after signing, so that launchd starts the signed build."
        case .virtualizationUnavailable:
            "Run maw on an Apple silicon Mac directly; nested virtualization is not supported."
        case .invalidVMConfiguration, .vmStartFailed, .vmFailed:
            "The console log may contain details."
        case .guestStopTimedOut:
            "Increase --timeout, or check the console log for what the guest was doing."
        case .diskImageExists:
            "Choose another path, or remove the existing file first."
        case .diskImageNotFound:
            "Pass --create-disk <size> to create it as a sparse image."
        case .sparseFilesUnsupported:
            "Create the disk image on an APFS volume."
        case .diskImageCreationFailed:
            nil
        case .consoleLogFailed:
            "Check that ~/Library/Logs/maw is writable."
        case .notATerminal(let option, _):
            "Run the command from a terminal, or omit \(option)."
        case .invalidDetachKey:
            "Use a control key such as ^Q or ^], or none. The ~. escape always works."
        case .guestAgentUnavailable:
            "Check the console log. Guest files from before the agent existed have no agent; "
                + "update them with scripts/fetch-guest.sh."
        case .guestAgentVersionMismatch:
            "Update the guest files with scripts/fetch-guest.sh."
        case .guestAgentFailed:
            "The console log may contain details."
        case .guestCommandNotFound:
            "Check the command's name, or give its full path."
        case .guestCommandNotStarted:
            nil
        }
    }
}

extension MawError: CustomStringConvertible {
    public var description: String {
        errorDescription ?? String(describing: self)
    }
}
