import MawProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Answers `sample` (docs/protocol.md): the guest's memory figures from `/proc/meminfo`, and
/// the IPv4 address of the default route's interface from `/proc/net/route` and
/// `getifaddrs`. It reads two small files and starts no process.
///
/// The files are read from `processDirectory`, `/proc` in the guest, so that tests can supply
/// a fixture.
struct GuestFigures: Sendable {
    var processDirectory: String

    /// Why a sample has no memory figures.
    struct Unavailable: Error, Equatable {
        var reason: String
    }

    /// The sample, or why `/proc/meminfo` gave no memory figures.
    func sample() -> Result<GuestSample, Unavailable> {
        guard let bytes = readBytes("\(processDirectory)/meminfo", limit: 64 << 10) else {
            return .failure(Unavailable(reason: "\(processDirectory)/meminfo cannot be read"))
        }
        let memory = Self.parseMemory(String(decoding: bytes, as: UTF8.self))
        guard let total = memory.total, let available = memory.available else {
            let missing = memory.total == nil ? "MemTotal" : "MemAvailable"
            return .failure(
                Unavailable(reason: "\(processDirectory)/meminfo has no \(missing)"))
        }
        guard available <= total else {
            return .failure(
                Unavailable(reason: "\(processDirectory)/meminfo has MemAvailable above MemTotal"))
        }
        return .success(
            GuestSample(
                memoryTotalBytes: total, memoryAvailableBytes: available,
                ipv4Address: defaultRouteInterface().flatMap(Self.ipv4Address(of:))))
    }

    /// `MemTotal` and `MemAvailable` in bytes, from lines such as `MemTotal:  2044624 kB`.
    static func parseMemory(_ text: String) -> (total: UInt64?, available: UInt64?) {
        var total: UInt64?
        var available: UInt64?
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 3, fields[2] == "kB", let kibibytes = UInt64(fields[1]) else {
                continue
            }
            let (bytes, overflow) = kibibytes.multipliedReportingOverflow(by: 1024)
            guard !overflow else { continue }
            switch fields[0] {
            case "MemTotal:": total = bytes
            case "MemAvailable:": available = bytes
            default: continue
            }
        }
        return (total, available)
    }

    /// The interface of the default route with the lowest metric, or `nil`.
    func defaultRouteInterface() -> String? {
        guard let bytes = readBytes("\(processDirectory)/net/route", limit: 64 << 10) else {
            return nil
        }
        return Self.parseDefaultRouteInterface(String(decoding: bytes, as: UTF8.self))
    }

    /// Reads `/proc/net/route`: a header line, then one route per line, with tab-separated
    /// fields `Iface Destination Gateway Flags RefCnt Use Metric Mask ...`, in hexadecimal
    /// except for `RefCnt`, `Use`, and `Metric`. A default route has destination and mask 0
    /// and the flag `RTF_UP` (1).
    static func parseDefaultRouteInterface(_ text: String) -> String? {
        var best: (interface: String, metric: UInt32)?
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard fields.count >= 8, let destination = UInt32(fields[1], radix: 16),
                let flags = UInt32(fields[3], radix: 16), let metric = UInt32(fields[6]),
                let mask = UInt32(fields[7], radix: 16),
                destination == 0, mask == 0, flags & 1 != 0
            else {
                continue
            }
            if best.map({ metric < $0.metric }) ?? true {
                best = (String(fields[0]), metric)
            }
        }
        return best?.interface
    }

    /// The first IPv4 address of the interface `name`, in dotted decimal, or `nil`.
    static func ipv4Address(of name: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr,
                Int32(address.pointee.sa_family) == AF_INET,
                String(cString: entry.pointee.ifa_name) == name
            else {
                continue
            }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let converted = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                var raw = $0.pointee.sin_addr
                return inet_ntop(AF_INET, &raw, &text, socklen_t(text.count)) != nil
            }
            if converted {
                return text.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            }
        }
        return nil
    }
}
