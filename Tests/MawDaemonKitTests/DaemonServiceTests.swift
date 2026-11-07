import Foundation
import MawClient
import MawCore
import MawDaemonKit
import MawProtocol
import MawXPC
import Testing

/// The daemon's service and `DaemonClient`, over real XPC connections through an anonymous
/// listener, with fake machines.
@Suite struct DaemonServiceTests {
    final class Daemon: Sendable {
        let clock = TestClock()
        let factory: FakeFactory
        let registry: MachineRegistry<TestClock>
        let service: DaemonService<TestClock>
        let listener = XPCServiceListener.anonymous()
        private let task: Task<Void, Never>

        init(factory: FakeFactory = FakeFactory()) {
            self.factory = factory
            registry = MachineRegistry(clock: clock, factory: factory.factory)
            service = DaemonService(
                clock: clock, registry: registry,
                lifetime: DaemonLifetime(clock: clock) {}, canRunVirtualMachines: true)
            task = Task { [service, listener] in await service.serve(listener) }
            listener.activate()
        }

        deinit {
            listener.cancel()
            task.cancel()
        }

        func connect() async throws -> DaemonClient {
            try await DaemonClient.connect(
                over: XPCConnection(endpoint: listener.endpoint), label: "test")
        }

        /// A connection that has not said hello.
        func rawConnection() -> XPCConnection {
            let connection = XPCConnection(endpoint: listener.endpoint)
            connection.activate()
            return connection
        }
    }

    @Test func greetsWithItsVersion() async throws {
        let daemon = Daemon()
        let client = try await daemon.connect()
        defer { client.close() }
        #expect(client.daemon.version == MawVersion.current)
        #expect(client.daemon.interfaceVersion == DaemonInterface.version)
        #expect(client.daemon.processID == getpid())
    }

    @Test func opensASessionWithAnAgentConnection() async throws {
        let daemon = Daemon()
        let client = try await daemon.connect()
        defer { client.close() }

        let session = try await client.openSession(on: .initramfs)
        #expect(session.info.machine == .initramfs)
        #expect(session.agentConnection.rawValue >= 0)
        let status = try await client.status()
        #expect(status.machines.count == 1)
        #expect(status.machines.first?.sessionCount == 1)
        #expect(status.canRunVirtualMachines)
    }

    @Test func twoClientsShareOneMachine() async throws {
        let daemon = Daemon()
        let first = try await daemon.connect()
        let second = try await daemon.connect()
        defer {
            first.close()
            second.close()
        }
        async let a = first.openSession(on: .initramfs)
        async let b = second.openSession(on: .initramfs)
        _ = try await (a, b)

        #expect(daemon.factory.machines.count == 1)
        let status = try await first.status()
        #expect(status.machines.map(\.sessionCount) == [2])
    }

    @Test func closingTheConnectionReleasesTheSession() async throws {
        let daemon = Daemon()
        let observer = try await daemon.connect()
        defer { observer.close() }
        let client = try await daemon.connect()
        _ = try await client.openSession(on: .initramfs)
        #expect(try await observer.status().machines.first?.sessionCount == 1)

        client.close()
        try await eventually("the lease is released") {
            (try? await observer.status().machines.first?.sessionCount) == 0
        }
        try await eventually("the idle timer starts") { daemon.clock.sleeperCount == 1 }
        daemon.clock.advance(by: .seconds(60))
        try await eventually("the machine stops") {
            (try? await observer.status().machines.isEmpty) == true
        }
    }

    @Test func shutdownEndsOtherClientsSessionsWithTheReason() async throws {
        let daemon = Daemon()
        let client = try await daemon.connect()
        defer { client.close() }
        let session = try await client.openSession(on: .initramfs)

        let admin = try await daemon.connect()
        defer { admin.close() }
        let summary = try await admin.shutdown()
        #expect(summary == ShutdownSummary(stoppedMachines: [.initramfs], endedSessions: 1))

        for await event in client.events {
            #expect(
                event
                    == .sessionEnded(
                        SessionEnded(
                            sessionID: session.info.sessionID, machine: .initramfs,
                            reason: "maw --shutdown was run")))
            break
        }
        #expect(try await admin.status().machines.isEmpty)
    }

    @Test func returnsTheMachinesErrorToTheClient() async throws {
        let daemon = Daemon(
            factory: FakeFactory { _ in (.virtualizationEntitlementMissing, false) })
        let client = try await daemon.connect()
        defer { client.close() }
        await #expect(throws: MawError.virtualizationEntitlementMissing) {
            try await client.openSession(on: .initramfs)
        }
    }

    @Test func requiresHelloFirst() async throws {
        let daemon = Daemon()
        let connection = daemon.rawConnection()
        defer { connection.cancel() }
        let reply = try await connection.request(InterfaceCoding.encode(DaemonRequest.status))
            .get()
        #expect(
            try InterfaceCoding.decode(DaemonReply.self, from: reply, as: .client)
                == .failure(
                    .daemonProtocolError(reason: "the first request on a connection must be hello"))
        )
    }

    @Test func refusesAClientOfAnotherInterfaceVersion() async throws {
        let daemon = Daemon()
        let connection = daemon.rawConnection()
        defer { connection.cancel() }
        let current = DaemonInterface.version
        let hello = try InterfaceCoding.encode(
            DaemonRequest.hello(clientVersion: "9.0.0"), version: current + 1)
        let reply = try await connection.request(hello).get()
        #expect(
            try InterfaceCoding.decode(DaemonReply.self, from: reply, as: .client)
                == .failure(.daemonVersionMismatch(client: current + 1, daemon: current)))
    }

    /// A listener that answers `hello` with `welcome` at interface `version`, then, with
    /// `dropsAfterHello`, closes the connection.
    final class ScriptedDaemon: Sendable {
        let listener = XPCServiceListener.anonymous()
        private let task: Task<Void, Never>

        init(version: UInt32 = DaemonInterface.version, dropsAfterHello: Bool = false) {
            task = Task { [listener] in
                for await peer in listener.peers {
                    for await case .message(let message) in peer.events {
                        let welcome = DaemonReply.welcome(
                            DaemonInfo(version: "9.0.0", processID: 1, interfaceVersion: version))
                        if let reply = try? InterfaceCoding.encodeReply(
                            to: message, welcome, version: version)
                        {
                            peer.send(reply)
                        }
                        if dropsAfterHello {
                            try? await Task.sleep(for: .milliseconds(50))
                            peer.cancel()
                        }
                    }
                }
            }
            listener.activate()
        }

        deinit {
            listener.cancel()
            task.cancel()
        }

        func connect() async throws(MawError) -> DaemonClient {
            try await DaemonClient.connect(
                over: XPCConnection(endpoint: listener.endpoint), label: "test")
        }
    }

    @Test func reportsADaemonOfAnotherInterfaceVersion() async throws {
        let current = DaemonInterface.version
        let daemon = ScriptedDaemon(version: current + 1)
        await #expect(throws: MawError.daemonVersionMismatch(client: current, daemon: current + 1))
        {
            try await daemon.connect()
        }
    }

    @Test func reportsADaemonThatClosesTheConnection() async throws {
        let daemon = ScriptedDaemon(dropsAfterHello: true)
        let client = try await daemon.connect()
        defer { client.close() }

        for await event in client.events {
            #expect(event == .connectionLost)
            break
        }
        await #expect(throws: MawError.daemonConnectionLost(during: "the status request")) {
            try await client.status()
        }
    }

    @Test func doesNotReportItsOwnClosingAsALoss() async throws {
        let daemon = Daemon()
        let client = try await daemon.connect()
        client.close()
        var events: [DaemonClient.Event] = []
        for await event in client.events {
            events.append(event)
        }
        #expect(events.isEmpty)
    }
}
