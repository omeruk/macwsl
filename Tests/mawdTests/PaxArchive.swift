import Foundation

/// An entry of an uncompressed pax archive, as `maw --export` writes one, read in place from
/// the file: its header fields and the pax records that precede it, without its content, which
/// `contents(of:in:)` reads on request. Unlike `PaxEntry`, nothing re-encodes the archive, so
/// the records are the export's own.
struct PaxArchiveEntry {
    /// The path without a leading `./`, or `.` for the root.
    var path: String
    var type: UInt8
    /// The permission bits, with the set-user-ID, set-group-ID, and sticky bits.
    var mode: Int
    var uid: Int
    var gid: Int
    var size: Int
    /// The target of a hard or symbolic link.
    var linkPath: String
    /// Every pax record of the entry, by key.
    var records: [String: Data]
    /// Where the content starts in the file.
    var contentOffset: UInt64

    var isRegularFile: Bool { type == UInt8(ascii: "0") || type == 0 }
    var isHardLink: Bool { type == UInt8(ascii: "1") }
    var isSymbolicLink: Bool { type == UInt8(ascii: "2") }
    var isDirectory: Bool { type == UInt8(ascii: "5") }
    var isFIFO: Bool { type == UInt8(ascii: "6") }

    /// The extended attribute `name`, from its `SCHILY.xattr.` record, or from libarchive's
    /// base64 `LIBARCHIVE.xattr.` record.
    func extendedAttribute(_ name: String) -> Data? {
        if let raw = records["SCHILY.xattr.\(name)"] {
            return raw
        }
        guard let encoded = records["LIBARCHIVE.xattr.\(name)"] else { return nil }
        // libarchive writes base64 without padding.
        let text = String(decoding: encoded, as: UTF8.self)
        return Data(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4))
    }

    /// The keys of the records that carry a POSIX ACL: libarchive's `SCHILY.acl.access` and
    /// `SCHILY.acl.default`, and the kernel's attributes `system.posix_acl_access` and
    /// `system.posix_acl_default`, in either form.
    var aclRecordKeys: [String] {
        records.keys.filter {
            $0.hasPrefix("SCHILY.acl.") || $0.hasPrefix("SCHILY.xattr.system.posix_acl_")
                || $0.hasPrefix("LIBARCHIVE.xattr.system.posix_acl_")
        }.sorted()
    }

    /// The archive's entries, in order. Fails unless the archive ends with its two blocks of
    /// zeros, so that a truncated archive is noticed.
    static func read(_ archive: URL) throws -> [PaxArchiveEntry] {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var entries: [PaxArchiveEntry] = []
        var pending: [String: Data] = [:]
        var offset: UInt64 = 0
        while true {
            let header = try block(handle, at: offset)
            offset += 512
            guard header.contains(where: { $0 != 0 }) else {
                // The end: a second block of zeros must follow.
                guard try block(handle, at: offset).allSatisfy({ $0 == 0 }) else {
                    throw ArchiveError("a block of zeros is not followed by another")
                }
                return entries
            }
            let type = header[156]
            // A pax `size` record, for content over 8 GiB, replaces the header's field.
            let size =
                type == UInt8(ascii: "x") || type == UInt8(ascii: "g")
                ? octal(header[124..<136])
                : pending["size"].flatMap { Int(String(decoding: $0, as: UTF8.self)) }
                    ?? octal(header[124..<136])
            let padded = UInt64((size + 511) / 512 * 512)
            switch type {
            case UInt8(ascii: "x"):
                try handle.seek(toOffset: offset)
                pending = records(try handle.read(upToCount: size) ?? Data())
            case UInt8(ascii: "g"):
                break
            default:
                let name = string(header[0..<100])
                let prefix = string(header[345..<500])
                var path =
                    pending["path"].map { String(decoding: $0, as: UTF8.self) }
                    ?? (prefix.isEmpty ? name : "\(prefix)/\(name)")
                if path.hasPrefix("./") {
                    path.removeFirst(2)
                }
                if path.hasSuffix("/") {
                    path.removeLast()
                }
                if path.isEmpty {
                    path = "."
                }
                func number(_ key: String, _ field: Range<Int>) -> Int {
                    pending[key].flatMap { Int(String(decoding: $0, as: UTF8.self)) }
                        ?? octal(header[field])
                }
                entries.append(
                    PaxArchiveEntry(
                        path: path, type: type, mode: octal(header[100..<108]) & 0o7777,
                        uid: number("uid", 108..<116), gid: number("gid", 116..<124),
                        size: size,
                        linkPath: pending["linkpath"].map { String(decoding: $0, as: UTF8.self) }
                            ?? string(header[157..<257]),
                        records: pending, contentOffset: offset))
                pending = [:]
            }
            offset += padded
        }
    }

    /// The content of `entry`, a regular file, in `archive`.
    static func contents(of entry: PaxArchiveEntry, in archive: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.contentOffset)
        return try handle.read(upToCount: entry.size) ?? Data()
    }

    struct ArchiveError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func block(_ handle: FileHandle, at offset: UInt64) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: 512) ?? Data()
        guard data.count == 512 else {
            throw ArchiveError(
                "the archive ends inside a block, at byte \(offset + UInt64(data.count))")
        }
        return data
    }

    /// Pax records, `<length> <key>=<value>\n`, whose values may be binary.
    private static func records(_ data: Data) -> [String: Data] {
        var records: [String: Data] = [:]
        var index = data.startIndex
        while index < data.endIndex {
            guard let space = data[index...].firstIndex(of: UInt8(ascii: " ")),
                let length = Int(String(decoding: data[index..<space], as: UTF8.self)),
                length > 0, index + length <= data.endIndex
            else { break }
            let record = data[(space + 1)..<(index + length - 1)]
            if let equals = record.firstIndex(of: UInt8(ascii: "=")) {
                records[String(decoding: record[record.startIndex..<equals], as: UTF8.self)] =
                    Data(record[(equals + 1)...])
            }
            index += length
        }
        return records
    }

    private static func octal(_ bytes: Data) -> Int {
        Int(string(bytes).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
    }

    private static func string(_ bytes: Data) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}
