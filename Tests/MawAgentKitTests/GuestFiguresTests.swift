import MawCore
import MawProtocol
import Testing

@testable import MawAgentKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The agent's answer to `sample`, against fixture files laid out as `/proc`.
@Suite struct GuestFiguresTests {
    /// `/proc/meminfo` of a 2 GiB Ubuntu 24.04 machine, shortened.
    static let meminfo = """
        MemTotal:        2044624 kB
        MemFree:         1757020 kB
        MemAvailable:    1937500 kB
        Buffers:           12040 kB
        Cached:           178100 kB
        SwapTotal:             0 kB
        HugePages_Total:       0
        Hugepagesize:       2048 kB

        """

    /// `/proc/net/route` with a default route on `eth0` and its subnet.
    static let route = """
        Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT
        eth0\t00000000\t0140A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0
        eth0\t0040A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0

        """

    /// The loopback interface, which has an IPv4 address on every Mac and Linux system.
    #if canImport(Darwin)
        static let loopback = "lo0"
    #else
        static let loopback = "lo"
    #endif

    @Test func readsMemoryInBytes() {
        let memory = GuestFigures.parseMemory(Self.meminfo)
        #expect(memory.total == 2_044_624 * 1024)
        #expect(memory.available == 1_937_500 * 1024)
    }

    @Test func reportsMissingMemoryLines() {
        let withoutAvailable = GuestFigures.parseMemory("MemTotal: 2044624 kB\nMemFree: 1 kB\n")
        #expect(withoutAvailable.total == 2_044_624 * 1024 && withoutAvailable.available == nil)
        let empty = GuestFigures.parseMemory("")
        #expect(empty.total == nil && empty.available == nil)
        // A value that is not in kB, does not parse, or overflows is ignored.
        let malformed = GuestFigures.parseMemory(
            "MemTotal: 12 MB\nMemAvailable: x kB\nMemAvailable: 18446744073709551615 kB\n")
        #expect(malformed.total == nil && malformed.available == nil)
    }

    @Test func findsTheDefaultRoutesInterface() {
        #expect(GuestFigures.parseDefaultRouteInterface(Self.route) == "eth0")
    }

    @Test func prefersTheDefaultRouteWithTheLowestMetric() {
        let text = """
            Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT
            wlan0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0
            eth1\t00000000\t0140A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0
            eth0\t00000000\t0140A8C0\t0003\t0\t0\t200\t00000000\t0\t0\t0

            """
        #expect(GuestFigures.parseDefaultRouteInterface(text) == "eth1")
    }

    @Test func findsNoInterfaceWithoutAnActiveDefaultRoute() {
        let header = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\n"
        #expect(GuestFigures.parseDefaultRouteInterface("") == nil)
        #expect(GuestFigures.parseDefaultRouteInterface(header) == nil)
        // Only the subnet route; a default route that is not up; a malformed line.
        #expect(
            GuestFigures.parseDefaultRouteInterface(
                header + "eth0\t0040A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\n") == nil)
        #expect(
            GuestFigures.parseDefaultRouteInterface(
                header + "eth0\t00000000\t0140A8C0\t0002\t0\t0\t100\t00000000\n") == nil)
        #expect(
            GuestFigures.parseDefaultRouteInterface(header + "eth0\t00000000\tzz\n") == nil)
    }

    @Test func readsTheIPv4AddressOfAnInterface() {
        #expect(GuestFigures.ipv4Address(of: Self.loopback) == "127.0.0.1")
        #expect(GuestFigures.ipv4Address(of: "maw-no-such-interface") == nil)
    }

    @Test func samplesFromTheProcessDirectory() throws {
        let proc = try FiguresFixture(meminfo: Self.meminfo, route: Self.route)
        let sample = try GuestFigures(processDirectory: proc.directory).sample().get()
        #expect(sample.memoryTotalBytes == 2_044_624 * 1024)
        #expect(sample.memoryAvailableBytes == 1_937_500 * 1024)
        // The fixture's eth0 does not exist on the test machine.
        #expect(sample.ipv4Address == nil)
    }

    @Test func refusesMemoryFiguresItCannotRead() throws {
        let withoutAvailable = try FiguresFixture(meminfo: "MemTotal: 2044624 kB\n", route: "")
        #expect(
            GuestFigures(processDirectory: withoutAvailable.directory).sample()
                == .failure(
                    .init(reason: "\(withoutAvailable.directory)/meminfo has no MemAvailable")))
        let aboveTotal = try FiguresFixture(
            meminfo: "MemTotal: 1 kB\nMemAvailable: 2 kB\n", route: "")
        #expect(
            GuestFigures(processDirectory: aboveTotal.directory).sample()
                == .failure(
                    .init(
                        reason: "\(aboveTotal.directory)/meminfo has MemAvailable above MemTotal")))
        #expect(
            GuestFigures(processDirectory: "/nonexistent/proc").sample()
                == .failure(.init(reason: "/nonexistent/proc/meminfo cannot be read")))
    }

    /// The whole request through the agent's server: the reply carries the default route's
    /// address, here the loopback interface's.
    @Test func answersSampleThroughTheAgent() async throws {
        let route = """
            Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT
            \(Self.loopback)\t00000000\t00000000\t0001\t0\t0\t0\t00000000\t0\t0\t0

            """
        let proc = try FiguresFixture(meminfo: Self.meminfo, route: route)
        let sample = try await TestAgent(processDirectory: proc.directory).client.sample()
        #expect(
            sample
                == GuestSample(
                    memoryTotalBytes: 2_044_624 * 1024, memoryAvailableBytes: 1_937_500 * 1024,
                    ipv4Address: "127.0.0.1"))
    }

    /// Without `MemAvailable` the agent sends an error, which the host reports without a
    /// figure.
    @Test func reportsAMissingMemAvailableThroughTheAgent() async throws {
        let proc = try FiguresFixture(meminfo: "MemTotal: 2044624 kB\n", route: Self.route)
        await #expect(
            throws: MawError.guestAgentFailed(
                reason: "sample: \(proc.directory)/meminfo has no MemAvailable")
        ) {
            _ = try await TestAgent(processDirectory: proc.directory).client.sample()
        }
    }
}

/// A directory with `meminfo` and `net/route`, removed when the fixture goes away.
final class FiguresFixture {
    let directory: String

    init(meminfo: String, route: String) throws {
        var template = Array("/tmp/maw-figures.XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else {
            throw FixtureError(message: "mkdtemp failed with errno \(errno)")
        }
        directory = String(cString: created)
        mkdir("\(directory)/net", 0o755)
        try store(meminfo, at: "\(directory)/meminfo")
        try store(route, at: "\(directory)/net/route")
    }

    deinit {
        unlink("\(directory)/meminfo")
        unlink("\(directory)/net/route")
        rmdir("\(directory)/net")
        rmdir(directory)
    }

    private func store(_ text: String, at path: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else {
            throw FixtureError(message: "open \(path) failed with errno \(errno)")
        }
        defer { close(descriptor) }
        let bytes = Array(text.utf8)
        guard write(descriptor, bytes, bytes.count) == bytes.count else {
            throw FixtureError(message: "write \(path) failed with errno \(errno)")
        }
    }
}
