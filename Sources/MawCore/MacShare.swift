/// The share of the owner's home directory with every distribution's machine
/// (docs/decisions/0021-mac-share.md): the names that the host and the guest agree on.
public enum MacShare {
    /// The virtiofs tag of the share, the same in every machine.
    public static let tag = "maw-mac"

    /// Where the guest mounts the share.
    public static let linuxPath = "/mnt/mac"

    /// Whether `path` is `/mnt/mac` or a path under it, as written.
    public static func contains(linuxPath path: String) -> Bool {
        path == linuxPath || path.hasPrefix(linuxPath + "/")
    }

    /// The kernel command line argument, `maw.share=<tag>`, with which the daemon asks the
    /// initramfs to mount the share. A machine without the share device never gets it.
    public static let kernelArgument = "maw.share"

    /// `maw.share=maw-mac`.
    public static var commandLineArgument: String { "\(kernelArgument)=\(tag)" }

    /// The kernel command line argument, `maw.home=<path>`, that carries the Mac home
    /// directory's path to the guest, for `mawpath`. The daemon adds it next to `maw.share`.
    public static let homeKernelArgument = "maw.home"

    /// The longest encoded home directory that the daemon puts on the kernel command line,
    /// which Linux on arm64 limits to 2,048 bytes in all.
    public static let encodedHomeLimit = 1_024

    /// `maw.home=<home>`, with every byte of `home` other than a letter, a digit, and
    /// `/ . _ ~ -` written as `%XX`, so that spaces and non-ASCII letters survive the kernel's
    /// splitting of its command line; `nil` if the encoded path is longer than
    /// `encodedHomeLimit`.
    public static func homeCommandLineArgument(_ home: String) -> String? {
        var encoded = ""
        for byte in home.utf8 {
            if isUnreserved(byte) {
                encoded.append(Character(Unicode.Scalar(byte)))
            } else {
                encoded += "%" + hexDigit(byte >> 4) + hexDigit(byte & 0xF)
            }
        }
        guard encoded.utf8.count <= encodedHomeLimit else { return nil }
        return "\(homeKernelArgument)=\(encoded)"
    }

    /// The Mac home directory from a kernel command line (`/proc/cmdline`), or `nil` if it
    /// carries no `maw.home`, or one whose encoding is invalid, that is not UTF-8, or that is
    /// not an absolute path.
    public static func home(fromCommandLine commandLine: String) -> String? {
        let prefix = "\(homeKernelArgument)="
        var value: Substring?
        for word in commandLine.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        where word.hasPrefix(prefix) {
            value = word.dropFirst(prefix.count)
        }
        guard let value, let home = decode(value), home.hasPrefix("/") else { return nil }
        return home
    }

    private static func decode(_ value: Substring) -> String? {
        var bytes: [UInt8] = []
        var iterator = value.utf8.makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "%") else {
                guard isUnreserved(byte) else { return nil }
                bytes.append(byte)
                continue
            }
            guard let high = iterator.next().flatMap(hexValue),
                let low = iterator.next().flatMap(hexValue)
            else { return nil }
            bytes.append(high << 4 | low)
        }
        // A repaired decoding differs from the bytes: they were not UTF-8.
        let text = String(decoding: bytes, as: UTF8.self)
        return Array(text.utf8) == bytes ? text : nil
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "/"), UInt8(ascii: "."),
            UInt8(ascii: "_"), UInt8(ascii: "~"), UInt8(ascii: "-"):
            true
        default:
            false
        }
    }

    private static func hexDigit(_ value: UInt8) -> String {
        String(Character(Unicode.Scalar(value < 10 ? 48 + value : 55 + value)))
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - 48
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - 55
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - 87
        default: nil
        }
    }
}
