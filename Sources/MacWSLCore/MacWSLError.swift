#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Errors shared by every MacWSL component.
///
/// Each case carries a user-facing message (`errorDescription`) and, where one exists, a concrete
/// next step (`recoverySuggestion`). Front ends print both; they never print a raw Swift error.
public enum MacWSLError: Error, Equatable, Sendable {
    /// A distribution name failed validation. `reason` explains which rule it broke.
    case invalidDistroName(String, reason: String)
    /// The requested feature exists in the command surface but has no implementation yet.
    case notImplemented(feature: String)
    /// A size such as `--memory 4G` could not be parsed.
    case invalidSize(String, reason: String)

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
    /// An interactive session needs a terminal, but `stream` is not one.
    case notATerminal(stream: String)
    /// `--detach-key` could not be parsed or names a key that the session needs.
    case invalidDetachKey(String, reason: String)
}

extension MacWSLError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDistroName(let name, let reason):
            "'\(name)' is not a valid distribution name: \(reason)."
        case .notImplemented(let feature):
            "\(feature) is not implemented yet"
        case .invalidSize(let text, let reason):
            "'\(text)' is not a valid size: \(reason)."
        case .kernelNotFound(let path):
            "The guest kernel files are missing: \(path) does not exist."
        case .virtualizationEntitlementMissing:
            "This executable is not signed with the virtualization entitlement "
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
        case .notATerminal(let stream):
            "--interactive needs a terminal, but \(stream) is not a terminal."
        case .invalidDetachKey(let text, let reason):
            "'\(text)' cannot be the detach key: \(reason)."
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
        case .kernelNotFound:
            "Install the guest kernel and initramfs with scripts/fetch-guest.sh."
        case .virtualizationEntitlementMissing:
            "Sign the development build with scripts/sign-dev.sh, then run it again."
        case .virtualizationUnavailable:
            "Run MacWSL on an Apple silicon Mac directly; nested virtualization is not supported."
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
            "Check that ~/Library/Logs/MacWSL is writable."
        case .notATerminal:
            "Run the command from a terminal, or omit --interactive."
        case .invalidDetachKey:
            "Use a control key such as ^Q or ^], or none. The ~. escape always works."
        }
    }
}

extension MacWSLError: CustomStringConvertible {
    public var description: String {
        errorDescription ?? String(describing: self)
    }
}
