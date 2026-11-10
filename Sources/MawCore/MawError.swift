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

    /// `-d`, `--set-default`, or `--terminate` names a distribution that is not installed.
    case distributionNotInstalled(DistroName)
    /// `--cd` names a directory that maw cannot use yet: a relative or macOS path.
    case unsupportedDirectory(String)
    /// A session needs a distribution, and none is installed.
    case noDistributionInstalled
    /// `-u` names a user that does not exist in the distribution.
    case userNotFound(String, distribution: String)
    /// The initramfs did not boot `distribution`, because `e2fsck -p` could not check or repair
    /// its root file system: it exited with `e2fsckStatus`, 4 or more
    /// (`RootFileSystemCheck`). `diskImage` and `consoleLog` are the paths of the
    /// distribution's disk image and console log.
    case rootFileSystemCheckFailed(
        distribution: DistroName, e2fsckStatus: Int, diskImage: String, consoleLog: String)

    // MARK: Installation

    /// `--install` names a distribution that the catalog does not have.
    case unknownDistribution(String)
    /// `--install` names a distribution that is already installed.
    case distributionAlreadyInstalled(DistroName)
    /// Another `maw --install` is installing the same distribution.
    case installationInProgress(DistroName)
    /// The distribution's directory, `path`, exists but holds no `distro.json`, as a partial
    /// manual removal leaves it. maw never changes it: it may hold the distribution's disk.
    case distributionDirectoryExists(path: String)
    /// A user name failed Ubuntu's rules. `reason` explains which.
    case invalidUserName(String, reason: String)
    /// The password is empty, or the two entries differ, or standard input had none.
    case invalidPassword(reason: String)
    /// `--install` without `--user` must ask for the user, but standard input is not a
    /// terminal.
    case installNeedsTerminal
    /// The Mac has no network connection, or the server cannot be reached.
    case networkUnavailable(host: String, reason: String)
    /// The download failed for another reason, such as an HTTP error.
    case downloadFailed(url: String, reason: String)
    /// A downloaded image is shorter or longer than the catalog says.
    case imageSizeMismatch(path: String, expected: UInt64, actual: UInt64)
    /// A downloaded image does not have the SHA-256 that the catalog pins.
    case imageChecksumMismatch(path: String, expected: String, actual: String)
    /// A downloaded image that should be in the cache is not there.
    case imageMissing(path: String)
    /// The Mac's volume has less free space than the installation needs.
    case insufficientDiskSpace(required: UInt64, available: UInt64, volume: String)
    /// A provisioning step failed. `step` names it.
    case provisioningFailed(step: String, reason: String)
    /// The installation was cancelled, because its client went away or the daemon stopped.
    case installationCancelled(DistroName)
    /// After Ctrl-C, the daemon answered that the installation had already ended, but its
    /// result did not reach maw, so whether the distribution was installed is not known.
    case installationOutcomeUnknown(DistroName)
    /// After Ctrl-C, the daemon did not answer the cancellation within the time that maw waits
    /// for it, although the connection stayed open, so the installation may still be ending.
    case installationCancellationUnconfirmed(DistroName)

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
    /// A `launchctl` command did not finish within `seconds` and was killed. `command` is the
    /// command line.
    case launchctlTimedOut(command: String, seconds: Int)
    /// launchd still had the job `service` (`gui/<uid>/<label>`) `seconds` seconds after
    /// `launchctl bootout`, so it could not be loaded again.
    case launchAgentNotRemoved(service: String, seconds: Int)

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
    /// Another virtual machine holds the disk image.
    case diskImageInUse(path: String)
    /// One of maw's own files cannot be read or written, such as a distribution's
    /// `distro.json`.
    case fileNotAccessible(path: String, reason: String)

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
    /// A session's connection to `distribution` ended before the command's exit status
    /// arrived, and the daemon reported no stop of the machine. The command's output may be
    /// incomplete, and the command may still be running in the guest.
    case sessionConnectionEnded(distribution: String)
    /// The guest agent could not open a session's connection to the host (protocol version 3's
    /// `dialBack`), and reported why.
    case sessionDialBackFailed(reason: String)
    /// The guest agent reported that it opened a session's connection to the host, but no
    /// connection with the session's nonce arrived within `milliseconds`.
    case sessionDialBackMissing(milliseconds: Int)
    /// `limit` sessions are already waiting for their connections from one machine's agent.
    case sessionDialBackBusy(limit: Int)
    /// The command to run in the guest does not exist there. Shells report this as 127.
    case guestCommandNotFound(command: String, reason: String)
    /// The command exists in the guest but could not be started. Shells report this as 126.
    case guestCommandNotStarted(command: String, reason: String)
}

extension MawError: LocalizedError {
    public var errorDescription: String? {
        // A reason from Foundation, such as a URLError's description, ends with a period of
        // its own.
        guard let message, message.hasSuffix("..") else { return message }
        return String(message.dropLast())
    }

    private var message: String? {
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
        case .noDistributionInstalled:
            "No Linux distribution is installed."
        case .userNotFound(let user, let distribution):
            "There is no user named '\(user)' in \(distribution)."
        case .rootFileSystemCheckFailed(let name, let status, _, let consoleLog):
            "The file system of \(name) "
                + Self.rootFileSystemCheckFinding(e2fsckStatus: status)
                + ". \(name) was not started; its console log, \(consoleLog), has the details."
        case .unknownDistribution(let name):
            "There is no distribution named '\(name)' that maw can install."
        case .distributionAlreadyInstalled(let name):
            "\(name) is already installed."
        case .installationInProgress(let name):
            "\(name) is being installed by another maw --install."
        case .distributionDirectoryExists(let path):
            "\(path) already exists, but it holds no installed distribution: its distro.json is "
                + "missing."
        case .invalidUserName(let name, let reason):
            "'\(name)' cannot be the user name: \(reason)."
        case .invalidPassword(let reason):
            "The password cannot be used: \(reason)."
        case .installNeedsTerminal:
            "maw --install asks for a user name and a password, but standard input is not a "
                + "terminal."
        case .networkUnavailable(let host, let reason):
            "Cannot reach \(host): \(reason)."
        case .downloadFailed(let url, let reason):
            "The download of \(url) failed: \(reason)."
        case .imageSizeMismatch(let path, let expected, let actual):
            "The downloaded image \(path) has \(actual) bytes, but it should have \(expected)."
        case .imageChecksumMismatch(let path, let expected, let actual):
            "The downloaded image \(path) is not the expected file: its SHA-256 is \(actual), "
                + "but it should be \(expected)."
        case .imageMissing(let path):
            "The downloaded image \(path) is missing."
        case .insufficientDiskSpace(let required, let available, let volume):
            "The installation needs \(ByteSize(bytes: required).approximateDescription) of free "
                + "space on \(volume), but only \(ByteSize(bytes: available).approximateDescription) "
                + "is available."
        case .provisioningFailed(let step, let reason):
            "The installation failed while \(step): \(reason)."
        case .installationCancelled(let name):
            "The installation of \(name) was cancelled."
        case .installationOutcomeUnknown(let name):
            "The installation of \(name) had already ended when maw asked the daemon to cancel "
                + "it, but its result did not reach maw, so it is not known whether \(name) was "
                + "installed."
        case .installationCancellationUnconfirmed(let name):
            "The daemon has not yet confirmed the cancellation of the installation of\n"
                + "\(name). The installation may still be ending."
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
        // The reason starts a line of its own, so that the daemon's own reasons (maw
        // --shutdown, maw --terminate, idle) fit in 80 columns with `maw: ` and a name as long
        // as Ubuntu-24.04. The reason for an unexpected stop comes from the framework.
        case .machineStopped(let machine, let reason):
            "The session ended because the virtual machine \(machine) stopped:\n\(reason)."
        case .launchAgentFailed(let reason):
            "The maw LaunchAgent could not be changed: \(reason)."
        case .launchctlTimedOut(let command, let seconds):
            "\(command) did not finish within \(seconds) seconds and was stopped."
        case .launchAgentNotRemoved(let service, let seconds):
            "launchd had not removed \(service) \(seconds) seconds after launchctl bootout, "
                + "so it could not be loaded again."
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
        case .diskImageInUse(let path):
            "The disk image \(path) is in use by another virtual machine."
        case .fileNotAccessible(let path, let reason):
            "The file \(path) cannot be used: \(reason)."
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
        // The line breaks keep each line within 80 columns, `maw: ` included, for a name as
        // long as Ubuntu-24.04: the terminal prints these lines as they are.
        case .sessionConnectionEnded(let name):
            "The connection to the session in \(name) ended unexpectedly.\n"
                + "The output may be incomplete, and the command may still be running there."
        case .sessionDialBackFailed(let reason):
            "The guest agent could not connect to maw for the session: \(reason)."
        case .sessionDialBackMissing(let milliseconds):
            "The guest agent reported that it connected to maw for the session, but no "
                + "connection with the session's nonce arrived within \(milliseconds) ms."
        case .sessionDialBackBusy(let limit):
            "\(limit) sessions are already waiting for a connection from this virtual "
                + "machine's agent."
        case .guestCommandNotFound(let command, let reason):
            "\(command): command not found in the guest (\(reason))."
        case .guestCommandNotStarted(let command, let reason):
            "\(command) could not be started in the guest: \(reason)."
        }
    }

    /// What e2fsck's exit status establishes about a file system that failed its check. Only
    /// statuses 4 to 7 say that the file system has errors; 8 and more say only that the check
    /// did not complete.
    private static func rootFileSystemCheckFinding(e2fsckStatus status: Int) -> String {
        switch (RootFileSystemCheck(e2fsckStatus: status).outcome, status) {
        case (.errorsLeftUncorrected, _):
            "could not be repaired automatically: e2fsck found errors that it left uncorrected "
                + "(exit status \(status))"
        case (_, 8...15):
            "could not be checked automatically: e2fsck stopped with an operational error "
                + "(exit status \(status)), as it does, for example, when it cannot open the disk "
                + "or read its superblock"
        default:
            "could not be checked automatically: e2fsck ended with exit status \(status) and "
                + "did not complete the check"
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
        // A catalog name or alias, such as `ubuntu`, may be what the user meant to install. The
        // entry may also be installed already under its catalog name, which maw --list shows.
        case .distributionNotInstalled(let name):
            if let entry = DistroCatalog.builtIn.entry(named: name.rawValue) {
                "Install it with maw --install \(entry.name), or see maw --list."
            } else {
                "maw --list shows the installed distributions."
            }
        case .unsupportedDirectory:
            "Translating relative and macOS paths arrives in phase 07. Until then, give an "
                + "absolute path inside Linux."
        case .noDistributionInstalled:
            "Install Ubuntu with maw --install."
        case .userNotFound:
            "Check the name, or create the user in the distribution with sudo adduser."
        case .rootFileSystemCheckFailed(_, _, let diskImage, _):
            "maw keeps the disk image \(diskImage) and has not written to it; only e2fsck -p "
                + "may have repaired parts of it before it stopped. Copy the image to a safe "
                + "place before you try any repair by hand. maw has no command to repair a "
                + "file system yet; a later phase adds one. If you do not need the "
                + "distribution's files, the README explains how to remove it, after which "
                + "maw --install can install it again."
        case .unknownDistribution:
            "maw --list --online shows the distributions that can be installed."
        case .distributionAlreadyInstalled(let name):
            "Use it with maw -d \(name). The README explains how to remove a distribution."
        case .installationInProgress:
            "Wait for the other installation to finish."
        case .distributionDirectoryExists:
            "maw leaves the directory as it is, because it may hold a distribution's disk.img. "
                + "Move it elsewhere, or delete it if you no longer need what it holds, then run "
                + "maw --install again. Or install under another name with --name."
        case .invalidUserName:
            "Choose another name: 1 to \(UserName.maximumLength) lowercase letters, digits, '-' or "
                + "'_', starting with a letter, and not one the distribution already uses, for "
                + "example 'ayse'."
        case .invalidPassword:
            "Type the same non-empty password twice. With --user, give it as the first\n"
                + "line of standard input."
        case .installNeedsTerminal:
            "Run it in a terminal, or give the user with --user <name> and the password as the "
                + "first line of standard input."
        case .networkUnavailable:
            "Check the Mac's internet connection and run maw --install again; the download "
                + "resumes where it stopped."
        case .downloadFailed:
            "Run maw --install again; the download resumes where it stopped."
        case .imageSizeMismatch, .imageChecksumMismatch:
            "The file was removed. Run maw --install again to download it again; if this "
                + "happens again, the download is being altered on its way to this Mac."
        case .imageMissing:
            "Run maw --install again to download it again."
        case .insufficientDiskSpace:
            "Free up space on the volume, then run maw --install again."
        case .provisioningFailed:
            "Nothing was installed. The installation's console log in ~/Library/Logs/maw has "
                + "details."
        case .installationCancelled:
            "Nothing was installed. Run maw --install to start again; an interrupted\n"
                + "download resumes where it stopped."
        case .installationOutcomeUnknown(let name):
            "maw --list shows whether \(name) was installed. If it was not, run\n"
                + "maw --install again."
        case .installationCancellationUnconfirmed(let name):
            "Wait a moment, then run maw --list. It lists \(name) if the installation\n"
                + "finished after all."
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
        case .launchctlTimedOut:
            "launchd did not answer in time. Run the command again; if it still does not "
                + "finish, log out and back in, which restarts your launchd session."
        case .launchAgentNotRemoved(let service, _):
            "Wait until launchctl print \(service) reports that it cannot find the service, "
                + "then run mawd install again. If the daemon does not exit, find it with "
                + "pgrep -fl 'mawd serve' and end it with kill."
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
        case .diskImageInUse:
            "A virtual machine of a daemon that stopped may still be exiting; run the command "
                + "again in a moment. Otherwise another process runs it."
        case .fileNotAccessible:
            "Check the file's permissions and the free space on its volume. A damaged "
                + "distro.json can be restored from a backup."
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
            "The guest files come from another build of maw. Install guest files built from "
                + "the same commit: fetch them with scripts/fetch-guest.sh, or rebuild them as "
                + "Guest/README.md describes. The script fetches main's files; for a build of "
                + "another branch, pass the branch's name: scripts/fetch-guest.sh <branch>."
        case .guestAgentFailed:
            "The console log may contain details."
        case .sessionConnectionEnded(let name):
            "If the command is still running, find its process ID with\n"
                + "maw -d \(name) -e ps -ef and end it with maw -d \(name) -e kill <ID>.\n"
                + "maw --terminate \(name) also ends it, and every other session there."
        case .sessionDialBackFailed:
            "Run the command again. If it fails again, restart the virtual machines with "
                + "maw --shutdown; the console log in ~/Library/Logs/maw has the agent's "
                + "warning."
        case .sessionDialBackMissing:
            "Run the command again. If it fails again, restart the virtual machines with "
                + "maw --shutdown; the virtual machine's console log in ~/Library/Logs/maw "
                + "lists the connections that were refused."
        case .sessionDialBackBusy:
            "Wait for other sessions to start, then run the command again."
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
