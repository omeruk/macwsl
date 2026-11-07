/// The names of the locales in glibc's `/usr/lib/locale/locale-archive`, where `locale-gen`
/// compiles them.
///
/// The format is glibc's `locarchive.h`: a header of 32-bit fields in the machine's byte
/// order, little-endian on arm64, the first being the magic number 0xde020109, followed by a hash table of
/// `(hash, name offset, record offset)` entries. Empty slots have a zero name offset. The
/// agent reads it directly so that choosing `LANG` costs no process start.
enum LocaleArchive {
    static let magic: UInt32 = 0xde02_0109

    /// The locale names, such as `tr_TR.utf8`; empty if `bytes` is not an archive.
    static func names(in bytes: [UInt8]) -> [String] {
        func word(at offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16
                | Int(bytes[offset + 3]) << 24
        }
        guard let magic = word(at: 0), UInt32(magic) == Self.magic,
            let tableOffset = word(at: 8), let tableSize = word(at: 16),
            tableSize <= bytes.count / 12
        else {
            return []
        }
        var names: [String] = []
        for index in 0..<tableSize {
            let entry = tableOffset + index * 12
            guard let nameOffset = word(at: entry + 4), let record = word(at: entry + 8),
                nameOffset != 0, record != 0, nameOffset < bytes.count
            else {
                continue
            }
            let end = bytes[nameOffset...].firstIndex(of: 0) ?? bytes.count
            names.append(String(decoding: bytes[nameOffset..<end], as: UTF8.self))
        }
        return names
    }
}
