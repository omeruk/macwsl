import Foundation
import MawDaemonKit
import MawProtocol
import Testing

/// The measurements of `prompts/08-networking.md`, "Speed targets", for pull request B, which
/// scripts/measure-dns.sh runs through scripts/integration-test.sh with `MAW_MEASURE=1`. They
/// never run with the other integration tests.
///
/// Each measurement runs 5 times and prints its median and its slowest run on a line that starts
/// with "measurement:". Lookups go to public names. A name that the Mac's resolver has not seen
/// is made unique with a random label: under `example.com`, which has no wildcard, for a name
/// that does not exist, and under `nip.io`, a public service whose names under
/// `<address>.nip.io` all have that IPv4 address and no IPv6 address, for a name with an A
/// record only.
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled && MawIntegration.environment["MAW_MEASURE"] == "1",
        "The measurements run only through scripts/measure-dns.sh."),
    .serialized,
    .timeLimit(.minutes(60))
)
struct DNSMeasurements {
    static let runs = 5

    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    @discardableResult
    static func report(_ what: String, _ values: [Double], unit: String = "ms") -> Double {
        ForwardingMeasurements.report(what, values, unit: unit)
    }

    static func unique() -> String { "m\(UInt32.random(in: 0...UInt32.max))" }

    /// A time as resolvectl prints it, such as `1.2ms`, `3.6s`, or `845µs`, in milliseconds.
    static func milliseconds(_ text: Substring) -> Double? {
        if text.hasSuffix("ms") { return Double(text.dropLast(2)) }
        // Microseconds: `us`, or with the micro sign or the Greek letter mu in a UTF-8 locale.
        if ["us", "\u{00B5}s", "\u{03BC}s"].contains(where: { text.hasSuffix($0) }) {
            return Double(text.dropLast(2)).map { $0 / 1_000 }
        }
        if text.hasSuffix("s") { return Double(text.dropLast(1)).map { $0 * 1_000 } }
        return nil
    }

    /// A warm lookup in the guest: the time that `resolvectl query --cache=no` reports, which
    /// passes systemd-resolved, the agent, the daemon, and the Mac's cache, and `getent hosts`
    /// with systemd-resolved's cache, as a program sees it, process start included. Each run is
    /// the median of 20 lookups.
    @Test func measuresAWarmLookup() async throws {
        var resolvectl: [Double] = []
        var getent: [Double] = []
        for _ in 1...Self.runs {
            let result = try await maw.session([
                "-e", "sh", "-c",
                """
                getent hosts github.com > /dev/null; resolvectl query github.com > /dev/null
                for i in $(seq 20); do
                    out=$(resolvectl query --cache=no github.com 2>&1)
                    t=$(echo "$out" | sed -n 's/.* in \\([0-9.]*[^ ]*s\\)\\.$/\\1/p')
                    if [ -n "$t" ]; then echo "resolvectl $t"; else echo "unparsed: $out"; fi
                    a=$(date +%s%N); getent hosts github.com > /dev/null; b=$(date +%s%N)
                    echo "getent $(( (b - a) / 1000 ))"
                done
                """,
            ])
            let fields = result.lines.map { $0.split(separator: " ") }.filter { $0.count == 2 }
            let byResolvectl = fields.filter { $0[0] == "resolvectl" }.compactMap {
                Self.milliseconds($0[1])
            }
            let byGetent = fields.filter { $0[0] == "getent" }.compactMap {
                Double($0[1]).map { $0 / 1_000 }
            }
            try #require(byResolvectl.count == 20 && byGetent.count == 20, "\(result.output)")
            resolvectl.append(ForwardingMeasurements.median(byResolvectl))
            getent.append(ForwardingMeasurements.median(byGetent))
        }
        let warm = Self.report(
            "a warm lookup in the guest, resolvectl query --cache=no github.com, median of 20",
            resolvectl)
        Self.report(
            "a warm lookup in the guest, getent hosts github.com with systemd-resolved's cache,"
                + " process start included, median of 20", getent)
        #expect(warm < 10)
    }

    /// The first lookup after a cold start: `maw --terminate`, then one session that looks
    /// github.com up first. The lookup's own time is taken in the guest; the session's, from
    /// the Mac.
    @Test func measuresTheFirstLookupAfterAColdStart() async throws {
        var lookups: [Double] = []
        var sessions: [Double] = []
        for _ in 1...Self.runs {
            _ = try await maw.run(["--terminate", maw.distribution])
            try await Task.sleep(for: .seconds(2))
            let started = ContinuousClock.now
            let result = try await maw.session([
                "-e", "sh", "-c",
                "a=$(date +%s%N); getent hosts github.com > /dev/null; s=$?; b=$(date +%s%N);"
                    + " echo \"status=$s microseconds=$(( (b - a) / 1000 ))\"",
            ])
            sessions.append((ContinuousClock.now - started).fractionalMilliseconds)
            let line = try #require(
                result.lines.first { $0.hasPrefix("status=0 ") }, "\(result.output)")
            lookups.append(try #require(Double(line.split(separator: "=").last ?? "")) / 1_000)
        }
        let first = Self.report("the first lookup after a cold start, in the guest", lookups)
        Self.report("the session of that lookup from the Mac, the cold start included", sessions)
        #expect(first < 1_000)
    }

    /// Cold start to a prompt, with DNS through the Mac and with `mawd serve --without-dns`,
    /// alternating.
    @Test func measuresColdStartToAPrompt() async throws {
        defer { try? maw.reinstallDaemon() }
        var times: [Bool: [Double]] = [true: [], false: []]
        for _ in 1...Self.runs {
            for dns in [true, false] {
                if dns {
                    try maw.reinstallDaemon()
                } else {
                    try await maw.registerDaemon(["--without-dns"])
                }
                _ = try await maw.run(["--status"])
                _ = try await maw.run(["--terminate", maw.distribution])
                try await Task.sleep(for: .seconds(2))
                let started = ContinuousClock.now
                let session = try maw.interactive(["-d", maw.distribution])
                #expect(
                    await session.waitForPrompt(
                        user: maw.user, host: maw.hostname(of: maw.distribution)))
                times[dns]?.append((ContinuousClock.now - started).fractionalMilliseconds)
                session.type("exit\r")
                _ = await session.waitForExit(timeout: .seconds(30))
            }
        }
        let with = Self.report(
            "cold start to a prompt, with DNS through the Mac", times[true] ?? [])
        let without = Self.report(
            "cold start to a prompt, without it (mawd serve --without-dns)", times[false] ?? [])
        print(
            "measurement: DNS through the Mac adds \(String(format: "%.0f", with - without)) ms to"
                + " the median cold start to a prompt (target: under 20 ms)")
        #expect(with - without < 20)
    }

    /// Negative lookups through the agent's server, without systemd-resolved: AAAA for a name
    /// with an A record only, and a name that does not exist, each the first time the Mac's
    /// resolver sees the name (cold) and right after (warm). These are the lookups that the
    /// existence probe of decision record 0024 lengthens.
    @Test func measuresNegativeLookups() async throws {
        var times: [String: [Double]] = [:]
        for _ in 1...Self.runs {
            let aOnly = "\(Self.unique()).192.0.2.1.nip.io"
            let missing = "nx-\(Self.unique()).example.com"
            for (label, name, type, code) in [
                ("AAAA for a name with an A record only", aOnly, 28, 0),
                ("a name that does not exist", missing, 1, 3),
            ] {
                for warmth in ["cold", "warm"] {
                    let reply = try await maw.queryAgent(name, type: type)
                    #expect(reply.code == code && reply.answers == 0, "\(label): \(reply)")
                    times["\(label), \(warmth)", default: []].append(reply.seconds * 1_000)
                }
            }
            let known = try await maw.queryAgent("github.com", type: 28)
            times["AAAA for github.com, which has A records only, warm", default: []].append(
                known.seconds * 1_000)
        }
        for (label, values) in times.sorted(by: { $0.key < $1.key }) {
            Self.report("a negative lookup through the agent's server: \(label)", values)
        }
    }

    /// The Mac's resolver as the daemon uses it, `MacDNSResolver`, from this process: for each
    /// type the outcome, the records, and the time of a warm lookup; and cold lookups.
    @Test func measuresTheMacsResolver() async throws {
        let resolver = MacDNSResolver()
        func timed(_ name: String, _ type: UInt16) async -> (DNSLookup, Double) {
            let started = ContinuousClock.now
            let lookup = await resolver.lookup(DNSName(presentation: name)!, type: type)
            return (lookup, (ContinuousClock.now - started).fractionalMilliseconds)
        }
        let cases: [(String, UInt16)] = [
            ("github.com", DNSRecordType.a), ("google.com", DNSRecordType.aaaa),
            ("www.github.com", DNSRecordType.cname), ("gmail.com", DNSRecordType.mx),
            ("google.com", DNSRecordType.txt), ("_imaps._tcp.gmail.com", DNSRecordType.srv),
            ("1.1.1.1.in-addr.arpa", DNSRecordType.ptr), ("github.com", DNSRecordType.aaaa),
            ("nx-\(Self.unique()).example.com", DNSRecordType.a),
        ]
        for (name, type) in cases {
            _ = await timed(name, type)
            var times: [Double] = []
            var last = DNSLookup(.failed)
            for _ in 1...Self.runs {
                let (lookup, milliseconds) = await timed(name, type)
                times.append(milliseconds)
                last = lookup
            }
            let types = Set(last.records.map { DNSRecordType.name($0.type) }).sorted()
            Self.report(
                "the Mac's resolver, warm: \(DNSRecordType.name(type)) \(name.hasPrefix("nx-") ? "<a name that does not exist>" : name)"
                    + " -> \(last.outcome), \(last.records.count) records (\(types.joined(separator: ", ")))",
                times)
        }
        var cold: [String: [Double]] = [:]
        for _ in 1...Self.runs {
            for (label, name, type) in [
                ("A for a new name", "\(Self.unique()).192.0.2.1.nip.io", DNSRecordType.a),
                (
                    "A for a name that does not exist", "nx-\(Self.unique()).example.com",
                    DNSRecordType.a
                ),
            ] {
                let (lookup, milliseconds) = await timed(name, type)
                cold[label, default: []].append(milliseconds)
                print("measurement: the Mac's resolver, cold: \(label) -> \(lookup.outcome)")
            }
        }
        for (label, values) in cold.sorted(by: { $0.key < $1.key }) {
            Self.report("the Mac's resolver, cold: \(label)", values)
        }
    }
}
