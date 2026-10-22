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
        .status,
        .shutdown,
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
        .shutdownComplete(ShutdownSummary(stoppedMachines: [.initramfs], endedSessions: 2)),
        .failure(.virtualizationEntitlementMissing),
        .failure(.distributionNotInstalled(try! DistroName("Ubuntu"))),
    ]

    static let events: [DaemonEvent] = [
        .sessionEnded(
            SessionEnded(sessionID: 7, machine: .initramfs, reason: "maw --shutdown was run"))
    ]

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
        #expect(xpc_dictionary_get_uint64(message.raw, "interfaceVersion") == 1)
    }

    @Test func reportsANewerDaemonToTheClient() throws {
        let message = try InterfaceCoding.encode(DaemonReply.welcome(Self.info), version: 2)
        #expect(throws: MawError.daemonVersionMismatch(client: 1, daemon: 2)) {
            try InterfaceCoding.decode(DaemonReply.self, from: message, as: .client)
        }
    }

    @Test func reportsANewerClientToTheDaemon() throws {
        let message = try InterfaceCoding.encode(
            DaemonRequest.hello(clientVersion: "9.9.9"), version: 2)
        #expect(throws: MawError.daemonVersionMismatch(client: 2, daemon: 1)) {
            try InterfaceCoding.decode(DaemonRequest.self, from: message, as: .daemon)
        }
    }

    @Test func checksTheVersionBeforeTheBody() throws {
        // A body from another version may not decode at all; the version must win.
        let message = try InterfaceCoding.encode(["unknownRequest": [String: String]()], version: 3)
        #expect(throws: MawError.daemonVersionMismatch(client: 1, daemon: 3)) {
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
