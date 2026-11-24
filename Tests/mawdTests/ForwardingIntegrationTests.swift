import Darwin
import Foundation
import MawXPC
import Testing

/// `localhost` forwarding on the test distribution (docs/decisions/0023-localhost-forwarding.md):
/// servers in the guest answer on the Mac's 127.0.0.1 and ::1, and the snapshot reports what
/// was not forwarded. No test binds a wildcard address on the Mac.
@Suite(.tags(.integration), .enabled(if: MawIntegration.isEnabled), .serialized)
struct ForwardingIntegrationTests {
    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    /// Servers on 0.0.0.0, 127.0.0.1, and :: in the guest answer on the Mac's 127.0.0.1 and ::1,
    /// and the snapshot lists their ports in order.
    @Test func forwardsServersOnEveryGuestAddress() async throws {
        let watcher = try Watcher(maw)
        defer { watcher.stop() }
        let ports = try (0..<3).map { _ in try MawIntegration.freePort() }
        let servers = [
            try await maw.startServer(host: "0.0.0.0", port: ports[0]),
            try await maw.startServer(host: "127.0.0.1", port: ports[1]),
            try await maw.startServer(host: "::", port: ports[2]),
        ]
        for port in ports {
            for host in ["127.0.0.1", "[::1]"] {
                #expect(
                    try await MawIntegration.waitUntil(
                        "http://\(host):\(port)/bytes/10", answers: true),
                    "\(host):\(port)")
            }
        }
        _ = try await watcher.forwarding("the three ports") {
            $0?.forwarded == ports.sorted() && $0?.notForwarded == []
        }
        for server in servers {
            await maw.stopServer(server)
        }
    }

    /// A port that a Mac program holds on 127.0.0.1 is forwarded on neither address, the Mac
    /// program keeps it, and the snapshot says why. The daemon's probe is the program's one
    /// connection, which ends without a byte.
    @Test func leavesAPortThatAMacProgramHolds() async throws {
        let watcher = try Watcher(maw)
        defer { watcher.stop() }
        let port = try MawIntegration.freePort()
        let program = try #require(MacListener(ipv6: false, port: port))
        defer { program.close() }
        let server = try await maw.startServer(host: "0.0.0.0", port: port)
        _ = try await watcher.forwarding("port \(port) in use on the Mac") {
            $0?.notForwarded == [.init(port: port, reason: .inUseOnMac)]
        }
        let probe = try #require(program.accept(within: .seconds(2)))
        var byte: UInt8 = 0
        #expect(read(probe, &byte, 1) == 0)
        close(probe)
        #expect(program.accept(within: .milliseconds(100)) == nil)
        #expect(reachesTheProgram(port, program))
        // ::1 was left free too.
        let other = MacListener(ipv6: true, port: port)
        #expect(other != nil)
        other?.close()
        await maw.stopServer(server)
    }

    /// A connection to 127.0.0.1:<port> reaches the Mac program: it waits in its backlog.
    private func reachesTheProgram(_ port: UInt16, _ program: MacListener) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
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
        guard connected == 0 else { return false }
        let accepted = accept(program.descriptor, nil, nil)
        defer { if accepted >= 0 { close(accepted) } }
        return accepted >= 0
    }

    /// A port below 1024 is never forwarded; the snapshot says why.
    @Test func reportsAPortBelow1024() async throws {
        let watcher = try Watcher(maw)
        defer { watcher.stop() }
        let server = try await maw.startServer(host: "0.0.0.0", port: 1000, as: "root")
        _ = try await watcher.forwarding("port 1000 privileged on the Mac") {
            $0?.notForwarded.contains(.init(port: 1000, reason: .privilegedOnMac)) == true
        }
        await maw.stopServer(server)
    }

    /// The port is released within a second of the server's end, and at `maw --terminate`.
    @Test func releasesThePortWhenTheServerStopsAndAtTerminate() async throws {
        let watcher = try Watcher(maw)
        defer { watcher.stop() }
        let port = try MawIntegration.freePort()
        let url = "http://127.0.0.1:\(port)/bytes/10"
        var server = try await maw.startServer(host: "0.0.0.0", port: port)
        #expect(try await MawIntegration.waitUntil(url, answers: true))
        await maw.stopServer(server)
        #expect(try await MawIntegration.waitUntilRefused(port))
        _ = try await watcher.forwarding("no port") { $0?.forwarded == [] }

        // A session that keeps the machine running while the server is ended by the stop.
        let keeper = try maw.start(["-d", maw.distribution, "-e", "sleep", "600"])
        defer { keeper.signal(SIGTERM) }
        server = try await maw.startServer(host: "0.0.0.0", port: port)
        #expect(try await MawIntegration.waitUntil(url, answers: true))
        let terminated = try await maw.run(["--terminate", maw.distribution])
        #expect(terminated.status == 0)
        #expect(try await MawIntegration.httpStatus(url) == nil)
        #expect(MawIntegration.refuses(port))
        _ = await server.waitForExit(timeout: .seconds(30))
    }

    /// A server restarted within 30 seconds is forwarded again: the forwarded connections that
    /// its first run closed hold the Mac's port in TIME_WAIT, the daemon's probe is refused,
    /// and the second bind sets SO_REUSEADDR.
    @Test func forwardsAServerRestartedWithinThirtySeconds() async throws {
        let watcher = try Watcher(maw)
        defer { watcher.stop() }
        let port = try MawIntegration.freePort()
        let url = "http://127.0.0.1:\(port)/bytes/10"
        var server = try await maw.startServer(host: "0.0.0.0", port: port)
        #expect(try await MawIntegration.waitUntil(url, answers: true))
        for _ in 0..<5 {
            #expect(try await MawIntegration.httpStatus(url) == 200)
        }
        await maw.stopServer(server)
        #expect(try await MawIntegration.waitUntilRefused(port))
        _ = try await watcher.forwarding("no port") { $0?.forwarded == [] }
        // The port is in TIME_WAIT: a bind without SO_REUSEADDR still fails.
        #expect(MacListener(ipv6: false, port: port).map { $0.close() } == nil)

        let restarted = ContinuousClock.now
        server = try await maw.startServer(host: "0.0.0.0", port: port)
        _ = try await watcher.forwarding("port \(port) forwarded again") {
            $0?.forwarded == [port] && $0?.notForwarded == []
        }
        #expect(ContinuousClock.now - restarted < .seconds(30))
        #expect(try await MawIntegration.waitUntil(url, answers: true))
        #expect(try await MawIntegration.waitUntil("http://[::1]:\(port)/bytes/10", answers: true))
        await maw.stopServer(server)
    }

    /// Two distributions listening on the same port: the first keeps it, the second reports
    /// it, and the port reaches the first.
    @Test(.timeLimit(.minutes(15))) func forwardsAPortForOneDistributionAtATime() async throws {
        try await maw.withDistribution("forwarding") { second in
            let watcher = try Watcher(maw)
            defer { watcher.stop() }
            let port = try MawIntegration.freePort()
            let first = try await maw.startServer(host: "0.0.0.0", port: port)
            _ = try await watcher.forwarding("port \(port) forwarded") { $0?.forwarded == [port] }
            let other = try await maw.startServer(host: "0.0.0.0", port: port, in: second)
            _ = try await watcher.forwarding("port \(port) taken", of: second) {
                $0?.notForwarded == [.init(port: port, reason: .forwardedForAnotherDistribution)]
            }
            #expect(try await MawIntegration.httpStatus("http://127.0.0.1:\(port)/bytes/1") == 200)
            await maw.stopServer(other)
            await maw.stopServer(first)
            _ = try await maw.run(["--terminate", second])
        }
    }

    /// A 1 GiB response arrives intact through the forwarding.
    @Test func carriesAGibibyteIntact() async throws {
        let port = try MawIntegration.freePort()
        // Not in /tmp, which a boot empties (see ForwardingMeasurements.measuresTheThroughput).
        let file = "/var/tmp/maw-forwarding-\(port)"
        let made = try await maw.run(
            [
                "-d", maw.distribution, "-e", "sh", "-c",
                "head -c 1073741824 /dev/urandom > \(file) && sha256sum \(file)",
            ], timeout: .seconds(300))
        try #require(made.status == 0, "\(made.output)\(made.standardError)")
        let expected = try #require(made.output.split(separator: " ").first.map(String.init))
        let server = try await maw.startServer(host: "127.0.0.1", port: port)
        #expect(
            try await MawIntegration.waitUntil(
                "http://127.0.0.1:\(port)/bytes/1", answers: true))
        let pipeline = try DebugBootProcess(
            executable: URL(filePath: "/bin/sh"),
            arguments: [
                "-c",
                "/usr/bin/curl -s http://127.0.0.1:\(port)/file\(file) | /usr/bin/shasum -a 256",
            ], separateStandardError: true)
        let result = await pipeline.waitForExit(timeout: .seconds(300))
        #expect(result.output.split(separator: " ").first.map(String.init) == expected)
        await maw.stopServer(server)
        _ = try await maw.run(["-d", maw.distribution, "-e", "rm", "-f", file])
    }
}
