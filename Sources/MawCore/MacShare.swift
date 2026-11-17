/// The share of the owner's home directory with every distribution's machine
/// (docs/decisions/0021-mac-share.md): the names that the host and the guest agree on.
public enum MacShare {
    /// The virtiofs tag of the share, the same in every machine.
    public static let tag = "maw-mac"

    /// Where the guest mounts the share.
    public static let linuxPath = "/mnt/mac"

    /// The kernel command line argument, `maw.share=<tag>`, with which the daemon asks the
    /// initramfs to mount the share. A machine without the share device never gets it.
    public static let kernelArgument = "maw.share"

    /// `maw.share=maw-mac`.
    public static var commandLineArgument: String { "\(kernelArgument)=\(tag)" }
}
