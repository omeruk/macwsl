import Foundation
import Testing

/// What the DNS tests and measurements share (docs/decisions/0024-dns-through-the-mac.md): a
/// packet capture in the guest, raw queries to the agent's server, and commands run as root.
extension MawIntegration {
    /// The agent's DNS server in the guest.
    static let dnsServer = "169.254.77.53"

    /// Runs `script` with `sh` as root in `distribution`, by default the test distribution.
    func asRoot(_ script: String, in distribution: String? = nil, timeout: Duration = .seconds(120))
        async throws -> DebugBootProcess.Result
    {
        try await run(
            ["-d", distribution ?? self.distribution, "-u", "root", "--", "sh", "-c", script],
            timeout: timeout)
    }

    /// Shell lines that set `IF` to the interface of the default route, waiting for DHCP.
    static let defaultInterface = """
        for i in $(seq 100); do IF=$(ip route show default | awk '{print $5; exit}'); \
        [ -n "$IF" ] && break; sleep 0.1; done
        """

    /// Captures, on interface `argv[1]` for `argv[3]` seconds, every packet to port 53, and
    /// writes `udp|tcp <destination> <count>` lines, or nothing, to `argv[2]`. It creates
    /// `argv[2].ready` once it captures. Python's standard library only; needs root.
    static let captureScript = """
        import socket, struct, sys, time
        iface, out, seconds = sys.argv[1], sys.argv[2], float(sys.argv[3])
        s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
        s.bind((iface, 0)); s.settimeout(0.2)
        open(out, "w").close(); open(out + ".ready", "w").close()
        end = time.time() + seconds; hits = {}
        while time.time() < end:
            try: frame = s.recv(65535)
            except socket.timeout: continue
            kind = struct.unpack("!H", frame[12:14])[0]; p = frame[14:]
            if kind == 0x0800:
                proto = p[9]; dst = socket.inet_ntoa(p[16:20]); l4 = p[(p[0] & 15) * 4:]
            elif kind == 0x86DD:
                proto = p[6]; dst = socket.inet_ntop(socket.AF_INET6, p[24:40]); l4 = p[40:]
            else:
                continue
            if proto in (6, 17) and len(l4) >= 4 and struct.unpack("!H", l4[2:4])[0] == 53:
                key = "%s %s" % ("udp" if proto == 17 else "tcp", dst)
                hits[key] = hits.get(key, 0) + 1
                with open(out, "w") as f:
                    f.write("".join("%s %d\\n" % kv for kv in sorted(hits.items())))
        """

    /// Lookups of several kinds through the guest's resolver, as programs make them.
    static let lookups = """
        getent hosts github.com; getent hosts example.org; getent hosts nx-$$-maw.example.com
        getent hosts buildhost; getent hosts 1.1.1.1
        resolvectl query --cache=no -t MX gmail.com; resolvectl query --cache=no -t TXT google.com
        resolvectl query --cache=no -t AAAA github.com
        resolvectl query --cache=no -t SRV _imaps._tcp.gmail.com
        """

    /// Runs `lookups` while capturing on the default route's interface, and returns the
    /// capture's lines: empty when no packet to port 53 left the guest's network interface.
    func packetsToPort53(during lookups: String = lookups, in distribution: String? = nil)
        async throws -> [String]
    {
        let script = """
            set -u
            \(Self.defaultInterface)
            W=$(mktemp -d)
            cat > $W/capture.py << 'PY'
            \(Self.captureScript)
            PY
            python3 $W/capture.py "$IF" $W/out 15 & C=$!
            for i in $(seq 100); do [ -e $W/out.ready ] && break; sleep 0.1; done
            resolvectl flush-caches
            ( \(lookups) ) > /dev/null 2>&1
            sleep 1; kill $C; wait $C 2>/dev/null
            echo "capture begin"; cat $W/out; echo "capture end"
            rm -rf $W
            """
        let result = try await asRoot(script, in: distribution)
        let lines = result.lines
        let begin = try #require(
            lines.firstIndex(of: "capture begin"), "\(result.output)\(result.standardError)")
        let end = try #require(lines.firstIndex(of: "capture end"))
        return Array(lines[(begin + 1)..<end]).filter { !$0.isEmpty }
    }

    /// Sends one query to the agent's server and prints `rcode=<n> answers=<n> tc=<n>
    /// seconds=<s>`; with `twoquestions`, a malformed query of two questions instead.
    static let queryScript = """
        import random, socket, struct, sys, time
        name, qtype = sys.argv[1], int(sys.argv[2])
        two = len(sys.argv) > 3 and sys.argv[3] == "twoquestions"
        q = struct.pack("!HHHHHH", random.randrange(65536), 0x0100, 2 if two else 1, 0, 0, 0)
        question = b"".join(bytes([len(l)]) + l.encode() for l in name.split(".") if l)
        question += b"\\0" + struct.pack("!HH", qtype, 1)
        q += question * (2 if two else 1)
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(8)
        start = time.perf_counter(); s.sendto(q, ("169.254.77.53", 53)); r = s.recv(4096)
        took = time.perf_counter() - start
        flags, answers = struct.unpack("!H", r[2:4])[0], struct.unpack("!H", r[6:8])[0]
        print("rcode=%d answers=%d tc=%d seconds=%.6f" % (flags & 15, answers, (flags >> 9) & 1, took))
        """

    /// The reply of the agent's server to one query, as `queryScript` prints it.
    struct DNSReply: Equatable {
        var code: Int
        var answers: Int
        var truncated: Bool
        var seconds: Double
    }

    /// Queries the agent's server directly, without systemd-resolved.
    func queryAgent(
        _ name: String, type: Int, malformed: Bool = false, in distribution: String? = nil
    )
        async throws -> DNSReply
    {
        let result = try await run(
            [
                "-d", distribution ?? self.distribution, "-e", "python3", "-c", Self.queryScript,
                name,
                String(type),
            ] + (malformed ? ["twoquestions"] : []))
        let fields = Dictionary(
            uniqueKeysWithValues: result.output.split(whereSeparator: \.isWhitespace).compactMap {
                field -> (String, String)? in
                let parts = field.split(separator: "=", maxSplits: 1)
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            })
        guard let code = fields["rcode"].flatMap(Int.init),
            let answers = fields["answers"].flatMap(Int.init),
            let truncated = fields["tc"].flatMap(Int.init),
            let seconds = fields["seconds"].flatMap(Double.init)
        else {
            Issue.record(
                "no reply from the agent's server: \(result.output)\(result.standardError)")
            throw CancellationError()
        }
        return DNSReply(code: code, answers: answers, truncated: truncated == 1, seconds: seconds)
    }
}
