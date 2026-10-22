import Foundation
import MawCore
import Testing
import XPC

@testable import MawXPC

@Suite struct InterfaceCodingTests {
    static let info = DaemonInfo(version: "0.1.0", processID: 4242, interfaceVersion: 1)

    static let requests: [DaemonRequest] = [
        .hello(clientVersion: "0.1.0"),
        .openSession(.initramfs),
        .openSession(.distribution(try! DistroName("Ubuntu-24.04"))),
        .openSession(nil),
        .status,
        .shutdown,
        .install(
            InstallRequest(
                distribution: "Ubuntu", name: try! DistroName("Work"), user: "ayse",
                password: Secret("correct horse"), locale: "tr_TR.UTF-8")),
        .install(
            InstallRequest(distribution: nil, user: "ayse", password: Secret("x"), locale: nil)),
        .cancelInstall,
    ]

    static let replies: [DaemonReply] = [
        .welcome(info),
        .sessionOpened(SessionInfo(sessionID: 7, machine: .initramfs)),
        .status(
            DaemonStatus(
                daemon: info, uptimeMilliseconds: 12_000, canRunVirtualMachines: true,
                machines: [
                    MachineStatus(
                        machine: .initramfs, state: .running, uptimeMilliseconds: 9_000,
                        cpuCount: 4, memoryBytes: 2 << 30, sessionCount: 2),
                    MachineStatus(
                        machine: .distribution(try! DistroName("Debian")), state: .starting,
                        uptimeMilliseconds: nil, cpuCount: 2, memoryBytes: 1 << 30,
                        sessionCount: 0),
                ])),
        .installed(
            InstallSummary(
                name: try! DistroName("Ubuntu-24.04"), displayName: "Ubuntu 24.04 LTS",
                defaultUser: "ayse", isDefault: true, milliseconds: 15_000)),
        .installCancelled(wasRunning: true),
        .shutdownComplete(ShutdownSummary(stoppedMachines: [.initramfs], endedSessions: 2)),
        .failure(.virtualizationEntitlementMissing),
        .failure(.distributionNotInstalled(try! DistroName("Ubuntu"))),
    ]

    static let events: [DaemonEvent] = [
        .sessionEnded(
            SessionEnded(sessionID: 7, machine: .initramfs, reason: "maw --shutdown was run")),
        .installProgress(.started(.extract)),
        .installProgress(.finished(.extract, milliseconds: 5_512)),
        .installProgress(
            .download(
                DownloadProgress(
                    receivedBytes: 1_000, totalBytes: 388_300_496, bytesPerSecond: 5_000_000,
                    resumedFromBytes: 0))),
    ]

    @Test func neverDescribesAPassword() throws {
        let request = DaemonRequest.install(
            InstallRequest(
                distribution: nil, user: "ayse", password: Secret("hunter2-secret"), locale: nil))
        for text in [
            String(describing: request), String(reflecting: request), "\(request)",
            String(describing: Mirror(reflecting: request).children.map(\.value)),
        ] {
            #expect(!text.contains("hunter2-secret"), "\(text)")
        }
        // The encoded message carries it, for the daemon only.
        let message = try InterfaceCoding.encode(request)
        #expect(
            try InterfaceCoding.decode(DaemonRequest.self, from: message, as: .daemon) == request)
    }

    @Test(arguments: requests)
    func roundTripsARequest(_ request: DaemonRequest) throws {
        let message = try InterfaceCoding.encode(request)
        #expect(
            try InterfaceCoding.decode(DaemonRequest.self, from: message, as: .daemon) == request)
    }

    @Test(arguments: replies)
    func roundTripsAReply(_ reply: DaemonReply) throws {
        let message = try InterfaceCoding.encode(reply)
        #expect(try InterfaceCoding.decode(DaemonReply.self, from: message, as: .client) == reply)
    }

    @Test(arguments: events)
    func roundTripsAnEvent(_ event: DaemonEvent) throws {
        let message = try InterfaceCoding.encode(event)
        #expect(try InterfaceCoding.decode(DaemonEvent.self, from: message, as: .client) == event)
    }

    @Test func carriesTheVersionOutsideTheBody() throws {
        let message = try InterfaceCoding.encode(DaemonRequest.status)
        #expect(InterfaceCoding.version(of: message) == DaemonInterface.version)
        #expect(
            xpc_dictionary_get_uint64(message.raw, "interfaceVersion")
                == UInt64(DaemonInterface.version))
    }

    @Test func reportsANewerDaemonToTheClient() throws {
        let current = DaemonInterface.version
        let message = try InterfaceCoding.encode(
            DaemonReply.welcome(Self.info), version: current + 1)
        #expect(throws: MawError.daemonVersionMismatch(client: current, daemon: current + 1)) {
            try InterfaceCoding.decode(DaemonReply.self, from: message, as: .client)
        }
    }

    @Test func reportsANewerClientToTheDaemon() throws {
        let current = DaemonInterface.version
        let message = try InterfaceCoding.encode(
            DaemonRequest.hello(clientVersion: "9.9.9"), version: current + 1)
        #expect(throws: MawError.daemonVersionMismatch(client: current + 1, daemon: current)) {
            try InterfaceCoding.decode(DaemonRequest.self, from: message, as: .daemon)
        }
    }

    @Test func checksTheVersionBeforeTheBody() throws {
        // A body from another version may not decode at all; the version must win.
        let current = DaemonInterface.version
        let message = try InterfaceCoding.encode(
            ["unknownRequest": [String: String]()], version: current + 2)
        #expect(throws: MawError.daemonVersionMismatch(client: current, daemon: current + 2)) {
            try InterfaceCoding.decode(DaemonReply.self, from: message, as: .client)
        }
    }

    @Test func rejectsAMessageWithoutAVersion() {
        let message = XPCObject(xpc_dictionary_create_empty())
        #expect(throws: MawError.daemonProtocolError(reason: "a message has no interface version"))
        {
            try InterfaceCoding.decode(DaemonRequest.self, from: message, as: .daemon)
        }
    }

    @Test func rejectsABodyItCannotDecode() throws {
        let message = try InterfaceCoding.encode(["unknownRequest": [String: String]()])
        #expect {
            try InterfaceCoding.decode(DaemonRequest.self, from: message, as: .daemon)
        } throws: { error in
            guard case .daemonProtocolError = error as? MawError else { return false }
            return true
        }
    }

    @Test func carriesADescriptor() throws {
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        let message = try InterfaceCoding.encode(
            DaemonReply.sessionOpened(SessionInfo(sessionID: 1, machine: .initramfs)),
            descriptor: fds[1])
        let received = try #require(InterfaceCoding.descriptor(in: message))
        #expect(received.rawValue != fds[1], "The message must hold a duplicate.")

        var byte: UInt8 = 42
        #expect(write(received.rawValue, &byte, 1) == 1)
        byte = 0
        #expect(read(fds[0], &byte, 1) == 1)
        #expect(byte == 42)
    }

    @Test func hasNoDescriptorUnlessOneWasAdded() throws {
        let message = try InterfaceCoding.encode(DaemonRequest.status)
        #expect(InterfaceCoding.descriptor(in: message) == nil)
    }

    @Test func readsTheLabelFromTheEnvironment() {
        #expect(DaemonInterface.label(environment: [:]) == "dev.maw.mawd")
        #expect(DaemonInterface.label(environment: ["MAW_DAEMON_LABEL": ""]) == "dev.maw.mawd")
        #expect(
            DaemonInterface.label(environment: ["MAW_DAEMON_LABEL": "dev.maw.mawd.test"])
                == "dev.maw.mawd.test")
    }
}

@Suite struct PeerRequirementTests {
    @Test func namesMawsExecutables() {
        #expect(
            PeerRequirement.codeSigningRequirement
                == #"identifier "dev.maw.maw" or identifier "dev.maw.mawd""#)
    }

    @Test func rejectsATestRunnerThatIsNotSignedAsMaw() {
        let identifier = PeerRequirement.currentIdentifier()
        #expect(identifier != nil)
        #expect(throws: MawError.clientSignatureRejected(identifier: identifier ?? "")) {
            try PeerRequirement.checkCurrentProcess()
        }
    }
}
