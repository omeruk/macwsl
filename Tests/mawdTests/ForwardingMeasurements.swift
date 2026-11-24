import Darwin
import Foundation
import MawXPC
import Testing

/// The measurements of `prompts/08-networking.md`, "Speed targets", for pull request A, which
/// scripts/measure-forwarding.sh runs through scripts/integration-test.sh with `MAW_MEASURE=1`.
/// They never run with the other integration tests.
///
/// Each measurement runs 5 times and prints its median and its slowest run on a line that starts
/// with "measurement:". Times are taken in this process with `ContinuousClock`, or by curl for
/// one request. The comparisons without forwarding register the test daemon again with
/// `mawd serve --without-forwarding`.
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled && MawIntegration.environment["MAW_MEASURE"] == "1",
        "The measurements run only through scripts/measure-forwarding.sh."),
    .serialized,
    .timeLimit(.minutes(60))
)
struct ForwardingMeasurements {
    static let runs = 5
    static let gibibyte = 1_073_741_824.0

    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    /// `measurement: <what>, 5 runs: …; median …, slowest …`, with three decimals.
    @discardableResult
    static func report(
        _ what: String, _ values: [Double], unit: String = "ms", higherIsFaster: Bool = false
    ) -> Double {
        guard !values.isEmpty else {
            print("measurement: \(what), no successful runs")
            return .infinity
        }
        let sorted = values.sorted()
        let median =
            sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        let slowest = (higherIsFaster ? sorted.first : sorted.last) ?? 0
        func format(_ value: Double) -> String { String(format: "%.3f", value) }
        print(
            "measurement: \(what), \(values.count) runs: "
                + values.map(format).joined(separator: ", ")
                + " \(unit); median \(format(median)) \(unit), slowest \(format(slowest)) \(unit)")
        return median
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .infinity }
        return sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    /// The guest's IPv4 address on the NAT network.
    func natAddress() async throws -> String {
        let result = try await maw.run([
            "-d", maw.distribution, "-e", "sh", "-c",
            "ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1",
        ])
        let address = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(!address.isEmpty, "no NAT address: \(result.output)\(result.standardError)")
        return address
    }

    /// From the guest server's `listening` line on the Mac to the first connection that the
    /// Mac's 127.0.0.1 accepts. The line crosses the session's connection, so the figure
    /// includes that transit; the server listens before it prints.
    @Test func measuresTheTimeFromListenToLocalhost() async throws {
        let keeper = try maw.start(["-d", maw.distribution, "-e", "sleep", "600"])
        defer { keeper.signal(SIGTERM) }
        var times: [Double] = []
        for _ in 1...Self.runs {
            let port = try MawIntegration.freePort()
            let server = try maw.start([
                "-d", maw.distribution, "-e", "python3", "-c", MawIntegration.serverScript,
                "hold", "0.0.0.0", String(port),
            ])
            let listening = await server.waitForLine(
                where: { $0 == "listening" }, every: .milliseconds(1), timeout: .seconds(60))
            try #require(listening)
            let started = ContinuousClock.now
            var accepted = false
            while ContinuousClock.now - started < .seconds(5) {
                if Self.connects(port) {
                    accepted = true
                    break
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            if accepted {
                times.append((ContinuousClock.now - started).fractionalMilliseconds)
            }
            await maw.stopServer(server)
        }
        let median = Self.report(
            "from the guest's listen() to localhost accepting on the Mac", times)
        #expect(times.count == Self.runs)
        #expect(median < 1_000)
    }

    static func connects(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    /// The time to the first byte of 100 short requests, forwarded and to the NAT address, in
    /// alternating runs, after a warm-up of each.
    @Test func measuresTheTimeToTheFirstByte() async throws {
        let port = try MawIntegration.freePort()
        let server = try await maw.startServer(host: "0.0.0.0", port: port)
        let nat = try await natAddress()
        let directory = maw.logDirectory.appending(
            path: "forwarding-\(port)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var medians: [String: [Double]] = [:]
        let targets = [("forwarded", "127.0.0.1"), ("NAT address", nat)]
        for run in 0...Self.runs {
            for (name, host) in targets {
                let config = directory.appending(path: "\(name.first!).cfg")
                let lines = (0..<100).map { _ in
                    "url = \"http://\(host):\(port)/bytes/100\"\noutput = \"/dev/null\""
                }
                try lines.joined(separator: "\n").write(
                    to: config, atomically: true, encoding: .utf8)
                let result = try await MawIntegration.curl([
                    "-w", "%{time_starttransfer}\\n", "-K", config.path(percentEncoded: false),
                ])
                let times = result.output.split(separator: "\n").compactMap { Double($0) }
                    .map { $0 * 1e3 }
                try #require(times.count == 100, "\(name): \(result.output)")
                // Run 0 warms both paths up.
                if run > 0 { medians[name, default: []].append(Self.median(times)) }
            }
        }
        let forwarded = Self.report(
            "time to the first byte of a forwarded request, median of 100 per run",
            medians["forwarded"] ?? [])
        let direct = Self.report(
            "time to the first byte of a request to the NAT address, median of 100 per run",
            medians["NAT address"] ?? [])
        print(
            "measurement: forwarding adds \(String(format: "%.3f", forwarded - direct)) ms to the"
                + " time to the first byte (target: under 5 ms)")
        #expect(forwarded - direct < 5)
        await maw.stopServer(server)
    }

    /// A 1 GiB response, forwarded and from the NAT address, in alternating runs.
    @Test func measuresTheThroughput() async throws {
        let port = try MawIntegration.freePort()
        // Not in /tmp: Ubuntu's systemd-tmpfiles-setup empties /tmp early in each boot, after
        // the agent already accepts sessions, so a file made in a cold start's first half
        // second would be gone (docs/known-limitations.md).
        let file = "/var/tmp/maw-forwarding-\(port)"
        let made = try await maw.run(
            ["-d", maw.distribution, "-e", "sh", "-c", "head -c 1073741824 /dev/zero > \(file)"],
            timeout: .seconds(300))
        try #require(made.status == 0)
        let server = try await maw.startServer(host: "0.0.0.0", port: port)
        let nat = try await natAddress()
        try #require(
            try await MawIntegration.waitUntil("http://127.0.0.1:\(port)/", answers: true),
            "the port was not forwarded")
        var rates: [String: [Double]] = [:]
        for _ in 1...Self.runs {
            for (name, host) in [("forwarded", "127.0.0.1"), ("NAT address", nat)] {
                // Only a complete response counts; a failed one is an issue, not a rate of 0.
                let result = try await MawIntegration.curl([
                    "-o", "/dev/null", "-w", "%{http_code} %{size_download} %{speed_download}",
                    "http://\(host):\(port)/file\(file)",
                ])
                let fields = result.output.split(separator: " ")
                guard result.status == 0, fields.count == 3, fields[0] == "200",
                    fields[1] == "1073741824", let rate = Double(fields[2])
                else {
                    Issue.record(
                        "\(name): curl exited with \(result.status) and wrote \(result.output)")
                    continue
                }
                rates[name, default: []].append(rate / 1e6)
            }
        }
        Self.report(
            "throughput of a forwarded 1 GiB response", rates["forwarded"] ?? [], unit: "MB/s",
            higherIsFaster: true)
        Self.report(
            "throughput of a 1 GiB response from the NAT address", rates["NAT address"] ?? [],
            unit: "MB/s", higherIsFaster: true)
        await maw.stopServer(server)
        _ = try await maw.run(["-d", maw.distribution, "-e", "rm", "-f", file])
    }

    /// The guest agent's CPU time over 60 seconds on an idle machine, with forwarding and with
    /// `mawd serve --without-forwarding`, alternating; each run boots the machine again.
    @Test func measuresTheAgentsIdleCost() async throws {
        defer { try? maw.reinstallDaemon() }
        var costs: [Bool: [Double]] = [true: [], false: []]
        let read = "cut -d' ' -f14,15 /proc/$(pidof maw-agent | cut -d' ' -f1)/stat"
        for _ in 1...Self.runs {
            for forwarding in [true, false] {
                if forwarding {
                    try maw.reinstallDaemon()
                } else {
                    try await maw.registerDaemon(["--without-forwarding"])
                }
                _ = try await maw.run(["--terminate", maw.distribution])
                let keeper = try maw.start(["-d", maw.distribution, "-e", "sleep", "600"])
                defer { keeper.signal(SIGTERM) }
                try await Task.sleep(for: .seconds(10))
                func ticks() async throws -> Double {
                    let result = try await maw.run(
                        ["-d", maw.distribution, "-u", "root", "-e", "sh", "-c", read])
                    let parts = result.output.split(whereSeparator: \.isWhitespace)
                        .compactMap { Double($0) }
                    try #require(parts.count == 2, "\(result.output)\(result.standardError)")
                    return parts[0] + parts[1]
                }
                let before = try await ticks()
                try await Task.sleep(for: .seconds(60))
                let after = try await ticks()
                // USER_HZ is 100: a tick is 10 ms.
                costs[forwarding]?.append((after - before) * 10)
                keeper.signal(SIGTERM)
                _ = await keeper.waitForExit(timeout: .seconds(30))
            }
        }
        let with = Self.report(
            "the guest agent's CPU time per minute on an idle machine, with forwarding",
            costs[true] ?? [])
        let without = Self.report(
            "the same without forwarding (mawd serve --without-forwarding), as on main",
            costs[false] ?? [])
        print(
            "measurement: forwarding adds \(String(format: "%.0f", with - without)) ms of the"
                + " agent's CPU time per minute")
    }

    /// Cold start to a prompt, with forwarding and without, alternating.
    @Test func measuresColdStartToAPrompt() async throws {
        defer { try? maw.reinstallDaemon() }
        var times: [Bool: [Double]] = [true: [], false: []]
        for _ in 1...Self.runs {
            for forwarding in [true, false] {
                if forwarding {
                    try maw.reinstallDaemon()
                } else {
                    try await maw.registerDaemon(["--without-forwarding"])
                }
                _ = try await maw.run(["--status"])
                _ = try await maw.run(["--terminate", maw.distribution])
                try await Task.sleep(for: .seconds(2))
                let started = ContinuousClock.now
                let session = try maw.interactive(["-d", maw.distribution])
                #expect(
                    await session.waitForPrompt(
                        user: maw.user, host: maw.hostname(of: maw.distribution)))
                times[forwarding]?.append((ContinuousClock.now - started).fractionalMilliseconds)
                session.type("exit\r")
                _ = await session.waitForExit(timeout: .seconds(30))
            }
        }
        let with = Self.report("cold start to a prompt, with forwarding", times[true] ?? [])
        let without = Self.report(
            "cold start to a prompt, without forwarding (mawd serve --without-forwarding)",
            times[false] ?? [])
        print(
            "measurement: forwarding adds \(String(format: "%.0f", with - without)) ms to the"
                + " median cold start to a prompt (target: under 20 ms)")
        #expect(with - without < 20)
    }

    /// With 256 forwarded connections held open: the threads of the daemon and the agent, and
    /// the median of `maw -- true` and the time of `maw --list`, against the same without them.
    /// The owner's rule: if the median grows by more than 50 ms or `maw --list` takes more than
    /// 1 s, the daemon uses a kqueue loop instead of two threads per connection.
    @Test func measuresSessionsBeside256Connections() async throws {
        let port = try MawIntegration.freePort()
        let server = try await maw.startServer("hold", host: "0.0.0.0", port: port)
        #expect(try await MawIntegration.waitUntilConnects(port))
        func threads() async throws -> (daemon: Int, agent: Int) {
            let pid = try await maw.daemonProcessID()
            let ps = try DebugBootProcess(
                executable: URL(filePath: "/bin/ps"), arguments: ["-M", "-p", String(pid)],
                separateStandardError: true)
            let daemon = max(
                0,
                (await ps.waitForExit(timeout: .seconds(10))).lines
                    .filter { !$0.isEmpty }.count - 1)
            let result = try await maw.run([
                "-d", maw.distribution, "-u", "root", "-e", "sh", "-c",
                "grep Threads /proc/$(pidof maw-agent | cut -d' ' -f1)/status",
            ])
            let agent = Int(result.output.split(whereSeparator: \.isWhitespace).last ?? "") ?? -1
            return (daemon, agent)
        }
        // Each time runs from just before the process starts to its own termination, as its
        // termination handler records it. The wait for the exit, which polls every 50 ms and
        // then sleeps 100 ms for the output, is not part of it: timed that way, a difference of
        // about 12 ms appeared as one polling tick (decision record 0023).
        func timed(_ arguments: [String]) async throws -> Double? {
            let started = ContinuousClock.now
            let process = try maw.start(arguments)
            let result = await process.waitForExit(timeout: .seconds(60))
            #expect(result.status == 0, "\(arguments): \(result.output)\(result.standardError)")
            guard let exited = process.exitedAt else {
                Issue.record("\(arguments): no termination time")
                return nil
            }
            return (exited - started).fractionalMilliseconds
        }
        func sessions(_ label: String) async throws -> (median: Double, list: Double) {
            var trues: [Double] = []
            for _ in 0..<20 {
                if let time = try await timed(["-d", maw.distribution, "--", "true"]) {
                    trues.append(time)
                }
            }
            var lists: [Double] = []
            for _ in 1...Self.runs {
                if let time = try await timed(["--list"]) { lists.append(time) }
            }
            let median = Self.report("maw -- true, \(label)", trues)
            let list = Self.report("maw --list, \(label)", lists)
            return (median, list)
        }
        let idle = try await threads()
        print(
            "measurement: threads without held connections: mawd \(idle.daemon), agent \(idle.agent)"
        )
        let before = try await sessions("without held connections")

        // The daemon's limit of 256 forwarded connections, in batches of 32, 250 ms apart, so
        // that each batch is relayed before the next. The connection of `waitUntilConnects`
        // is the first: the Mac closed it, but the server never closes its side, so its relay
        // stays open, half-closed.
        var held: [Int32] = []
        defer { for fd in held { close(fd) } }
        while held.count < 255 {
            for _ in 0..<min(32, 255 - held.count) {
                if let fd = Self.connectToLoopback(port) { held.append(fd) }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        try await Task.sleep(for: .seconds(2))
        let open = Self.alive(held) + 1
        let busy = try await threads()
        print(
            "measurement: threads with \(open) forwarded connections open: mawd"
                + " \(busy.daemon), agent \(busy.agent)")
        #expect(open == 256)
        let after = try await sessions("with \(open) forwarded connections held open")
        print(
            "measurement: holding the connections adds "
                + "\(String(format: "%.1f", after.median - before.median)) ms to the median of"
                + " maw -- true (rule: at most 50 ms); maw --list takes"
                + " \(String(format: "%.1f", after.list)) ms (rule: at most 1 s)")
        #expect(after.median - before.median <= 50)
        #expect(after.list <= 1_000)
        for fd in held { close(fd) }
        held = []
        // The server in `hold` mode never closes its side, so the relays end with it.
        await maw.stopServer(server)

        // 256 connections at once, to a new server: the daemon resets those that find the
        // gate's 64 places for waiting connections taken.
        let burstPort = try MawIntegration.freePort()
        let burstServer = try await maw.startServer("hold", host: "0.0.0.0", port: burstPort)
        #expect(try await MawIntegration.waitUntilConnects(burstPort))
        var burst: [Int32] = []
        for _ in 0..<256 {
            if let fd = Self.connectToLoopback(burstPort) { burst.append(fd) }
        }
        try await Task.sleep(for: .seconds(2))
        print(
            "measurement: of 256 connections opened at once, \(burst.count) connected and"
                + " \(Self.alive(burst)) are still open after 2 s")
        for fd in burst { close(fd) }
        await maw.stopServer(burstServer)
    }
}

extension ForwardingMeasurements {
    /// A blocking connection to 127.0.0.1:<port>, or nil.
    static func connectToLoopback(_ port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 { return fd }
        close(fd)
        return nil
    }

    /// How many of `descriptors` are open: neither ended nor reset. The server in `hold` mode
    /// never sends, so a readable connection has ended.
    static func alive(_ descriptors: [Int32]) -> Int {
        descriptors.filter { fd in
            var request = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            return poll(&request, 1, 0) == 0
        }.count
    }
}

extension MawIntegration {
    /// Waits until 127.0.0.1:<port> accepts a connection.
    static func waitUntilConnects(_ port: UInt16, within timeout: Duration = .seconds(10))
        async
        throws -> Bool
    {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if ForwardingMeasurements.connects(port) { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
