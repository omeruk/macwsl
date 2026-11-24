import CMawSystem
import Darwin
import MawCore
import MawProtocol
import Testing
import os

@testable import MawDaemonKit

/// How the daemon binds a forwarded port on the Mac's 127.0.0.1 and ::1
/// (docs/decisions/0023-localhost-forwarding.md): without SO_REUSEADDR first, and with it only
/// after a connection to the same address was refused. SO_REUSEPORT is never set.
@Suite(.serialized) struct LoopbackListenersTests {
    /// What a fake `listen` and `probe` were asked, in order.
    final class Calls: Sendable {
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])

        var all: [String] { log.withLock { $0 } }

        func record(_ call: String) {
            log.withLock { $0.append(call) }
        }
    }

    /// A `listen` that fails with `inUse` on the families it names, without SO_REUSEADDR or
    /// with it, and otherwise returns an unbound socket.
    static func listen(
        _ calls: Calls, busy: Set<Bool> = [], busyWithReuse: Set<Bool> = [],
        error: Int32 = EADDRINUSE
    ) -> LoopbackListeners.Listen {
        { ipv6, port, reuse in
            calls.record("listen \(ipv6 ? "::1" : "127.0.0.1") reuse=\(reuse)")
            if (reuse ? busyWithReuse : busy).contains(ipv6) {
                return .failure(SystemError("bind", code: error))
            }
            return .success(OwnedDescriptor(socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)))
        }
    }

    static func probe(_ calls: Calls, answer: Int32) -> LoopbackListeners.Probe {
        { ipv6, _ in
            calls.record("probe \(ipv6 ? "::1" : "127.0.0.1")")
            return answer
        }
    }

    @Test func bindsAFreePortWithoutProbing() throws {
        let calls = Calls()
        let listeners = try LoopbackListeners.bind(
            port: 8000, listen: Self.listen(calls), probe: Self.probe(calls, answer: 0)
        ).get()
        listeners.close()
        #expect(calls.all == ["listen 127.0.0.1 reuse=false", "listen ::1 reuse=false"])
    }

    /// Nothing listens on the address: the port is held by connections in TIME_WAIT only, and
    /// the second bind sets SO_REUSEADDR.
    @Test(arguments: [false, true])
    func bindsAgainWithAddressReuseAfterARefusedProbe(onIPv6: Bool) throws {
        let calls = Calls()
        let listeners = try LoopbackListeners.bind(
            port: 8000, listen: Self.listen(calls, busy: [onIPv6]),
            probe: Self.probe(calls, answer: ECONNREFUSED)
        ).get()
        listeners.close()
        let family = onIPv6 ? "::1" : "127.0.0.1"
        let half = [
            "listen \(family) reuse=false", "probe \(family)", "listen \(family) reuse=true",
        ]
        #expect(
            calls.all
                == (onIPv6
                    ? ["listen 127.0.0.1 reuse=false"] + half
                    : half + ["listen ::1 reuse=false"]))
    }

    /// An accepted probe, a timeout, or another error leaves the port to the Mac, on both
    /// addresses, and SO_REUSEADDR is never tried.
    @Test(arguments: [0, ETIMEDOUT, ECONNRESET, ENETDOWN])
    func leavesThePortToTheMacUnlessTheProbeWasRefused(answer: Int32) {
        for onIPv6 in [false, true] {
            let calls = Calls()
            let result = LoopbackListeners.bind(
                port: 8000, listen: Self.listen(calls, busy: [onIPv6]),
                probe: Self.probe(calls, answer: answer))
            #expect(result.failure == .inUse)
            #expect(!calls.all.contains { $0.hasSuffix("reuse=true") })
            #expect(calls.all.filter { $0.hasPrefix("probe") }.count == 1)
        }
    }

    /// The bind with SO_REUSEADDR can still fail: a program bound in between.
    @Test func reportsInUseWhenTheSecondBindFails() {
        let calls = Calls()
        let result = LoopbackListeners.bind(
            port: 8000, listen: Self.listen(calls, busy: [false], busyWithReuse: [false]),
            probe: Self.probe(calls, answer: ECONNREFUSED))
        #expect(result.failure == .inUse)
        #expect(calls.all.last == "listen 127.0.0.1 reuse=true")
    }

    /// Only EADDRINUSE leads to a probe.
    @Test func neverProbesAfterAnotherError() {
        let calls = Calls()
        let result = LoopbackListeners.bind(
            port: 8000, listen: Self.listen(calls, busy: [true], error: EADDRNOTAVAIL),
            probe: Self.probe(calls, answer: ECONNREFUSED))
        #expect(result.failure == .other(family: "::1", code: EADDRNOTAVAIL))
        #expect(!calls.all.contains { $0.hasPrefix("probe") })
    }

    @Test func neverBindsAPortBelow1024() {
        let calls = Calls()
        let result = LoopbackListeners.bind(
            port: 1023, listen: Self.listen(calls), probe: Self.probe(calls, answer: 0))
        #expect(result.failure == .privileged)
        #expect(calls.all.isEmpty)
    }

    // MARK: Real sockets

    /// A port that nothing holds: neither socket sets SO_REUSEADDR or SO_REUSEPORT.
    @Test func setsNoReuseOnAFreePort() throws {
        let port = try PortForwarderTests.freePort()
        let listeners = try LoopbackListeners.bind(port: port).get()
        defer { listeners.close() }
        #expect(Self.option(listeners.ipv4, SO_REUSEADDR) == 0)
        #expect(Self.option(listeners.ipv6, SO_REUSEADDR) == 0)
        #expect(Self.option(listeners.ipv4, SO_REUSEPORT) == 0)
        #expect(Self.option(listeners.ipv6, SO_REUSEPORT) == 0)
        var only: Int32 = 0
        #expect(maw_socket_option(listeners.ipv6.rawValue, IPPROTO_IPV6, IPV6_V6ONLY, &only) == 0)
        #expect(only == 1)
    }

    /// A connection on 127.0.0.1 that the listening side closed first stays in TIME_WAIT and
    /// holds the port for a bind without SO_REUSEADDR. The probe is refused, and only the
    /// 127.0.0.1 socket sets SO_REUSEADDR.
    @Test func setsAddressReuseOnlyAfterARefusedProbe() throws {
        let port = try PortForwarderTests.freePort()
        try Self.leaveTimeWait(on: port)
        let held = LoopbackListeners.listen(ipv6: false, port: port)
        try #require(held.failure?.code == EADDRINUSE, "no TIME_WAIT on port \(port)")
        #expect(LoopbackListeners.probe(ipv6: false, port: port) == ECONNREFUSED)

        let listeners = try LoopbackListeners.bind(port: port).get()
        defer { listeners.close() }
        // Darwin's getsockopt answers a set flag with the option's bit, not 1.
        #expect(Self.option(listeners.ipv4, SO_REUSEADDR) != 0)
        #expect(Self.option(listeners.ipv6, SO_REUSEADDR) == 0)
        #expect(Self.option(listeners.ipv4, SO_REUSEPORT) == 0)
        #expect(Self.option(listeners.ipv6, SO_REUSEPORT) == 0)
        #expect(PortForwarderTests.isListening(port))
    }

    /// A Mac program on 127.0.0.1 keeps the port; it sees one connection that ends without a
    /// byte, and ::1 is not left bound.
    @Test func leavesAPortThatAMacProgramHoldsWithOneEmptyConnection() throws {
        let port = try PortForwarderTests.freePort()
        let program = try LoopbackListeners.listen(ipv6: false, port: port).get()
        defer { program.close() }
        #expect(LoopbackListeners.bind(port: port).failure == .inUse)
        let probe = try #require(Self.accept(program))
        #expect(PortForwarderTests.readToEnd(probe) == ("", 0))
        #expect(Self.accept(program, within: .milliseconds(100)) == nil)
        let other = LoopbackListeners.listen(ipv6: true, port: port)
        #expect(other.failure == nil)
        if case .success(let other) = other { other.close() }
    }

    static func option(_ descriptor: OwnedDescriptor, _ name: Int32) -> Int32 {
        var value: Int32 = -1
        #expect(maw_socket_option(descriptor.rawValue, SOL_SOCKET, name, &value) == 0)
        return value
    }

    /// Accepts a connection on a non-blocking listener, waiting at most `within`.
    static func accept(_ listener: OwnedDescriptor, within: Duration = .seconds(2))
        -> OwnedDescriptor?
    {
        let deadline = ContinuousClock.now + within
        repeat {
            var descriptor: Int32 = -1
            let code = maw_tcp_accept(listener.rawValue, &descriptor)
            if code == 0 { return OwnedDescriptor(descriptor) }
            guard code == EAGAIN || code == EWOULDBLOCK else { return nil }
            usleep(2_000)
        } while ContinuousClock.now < deadline
        return nil
    }

    /// Leaves a connection in TIME_WAIT on 127.0.0.1:`port`, on the listening side, as a
    /// forwarded connection whose guest server closed first leaves one.
    static func leaveTimeWait(on port: UInt16) throws {
        let listener = try LoopbackListeners.listen(ipv6: false, port: port).get()
        defer { listener.close() }
        let client = try PortForwarderTests.connect(false, port).get()
        let server = try #require(accept(listener))
        server.close()
        #expect(PortForwarderTests.readToEnd(client).error == 0)
        client.close()
        usleep(50_000)
    }
}

extension Result {
    fileprivate var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
