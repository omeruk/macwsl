import Foundation
import MawCore
import Testing
import XPC

@testable import MawXPC

/// Real XPC connections within the test process, through an anonymous listener.
@Suite struct XPCConnectionTests {
    /// A listener that answers every request with `reply`, and records peer events.
    final class EchoServer: Sendable {
        let listener: XPCServiceListener
        let peerEvents: AsyncStream<String>
        private let task: Task<Void, Never>

        init(
            codeSigningRequirement: String? = nil,
            reply: @escaping @Sendable (XPCObject) -> XPCObject?
        ) {
            listener = XPCServiceListener.anonymous(codeSigningRequirement: codeSigningRequirement)
            let (events, continuation) = AsyncStream.makeStream(of: String.self)
            peerEvents = events
            task = Task { [listener] in
                await withTaskGroup(of: Void.self) { group in
                    for await peer in listener.peers {
                        group.addTask {
                            for await event in peer.events {
                                switch event {
                                case .message(let message):
                                    if let answer = reply(message) {
                                        peer.send(answer)
                                    }
                                case .interrupted:
                                    continuation.yield("interrupted")
                                case .invalidated:
                                    continuation.yield("invalidated")
                                }
                            }
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

        func connect() -> XPCConnection {
            let connection = XPCConnection(endpoint: listener.endpoint)
            connection.activate()
            return connection
        }
    }

    @Test func exchangesARequestAndItsReply() async throws {
        let server = EchoServer { message in
            try? InterfaceCoding.encodeReply(to: message, DaemonReply.status(Self.status))
        }
        let client = server.connect()
        defer { client.cancel() }

        let reply = try await client.request(InterfaceCoding.encode(DaemonRequest.status)).get()
        #expect(
            try InterfaceCoding.decode(DaemonReply.self, from: reply, as: .client)
                == .status(Self.status))
    }

    @Test func passesADescriptorToTheClient() async throws {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        let serverSide = fds[1]
        let server = EchoServer { message in
            try? InterfaceCoding.encodeReply(
                to: message,
                DaemonReply.sessionOpened(SessionInfo(sessionID: 1, machine: .initramfs)),
                descriptor: serverSide)
        }
        let client = server.connect()
        defer { client.cancel() }

        let reply = try await client.request(
            InterfaceCoding.encode(DaemonRequest.openSession(.initramfs))
        ).get()
        let descriptor = try #require(InterfaceCoding.descriptor(in: reply))
        // No program that the receiver starts inherits it.
        #expect(fcntl(descriptor.rawValue, F_GETFD) & FD_CLOEXEC != 0)
        let text = Array("ping".utf8)
        #expect(write(descriptor.rawValue, text, text.count) == text.count)
        var buffer = [UInt8](repeating: 0, count: 4)
        #expect(read(fds[0], &buffer, buffer.count) == 4)
        #expect(buffer == text)
    }

    @Test func pushesAMessageWithoutARequest() async throws {
        let event = DaemonEvent.sessionEnded(
            SessionEnded(sessionID: 3, machine: .initramfs, reason: "test"))
        let server = EchoServer { _ in try? InterfaceCoding.encode(event) }
        let client = server.connect()
        defer { client.cancel() }

        client.send(try InterfaceCoding.encode(DaemonRequest.status))
        for await received in client.events {
            guard case .message(let message) = received else {
                Issue.record("expected a message, got \(received)")
                return
            }
            #expect(
                try InterfaceCoding.decode(DaemonEvent.self, from: message, as: .client) == event)
            return
        }
    }

    @Test func tellsTheServerWhenTheClientCloses() async throws {
        let server = EchoServer { message in
            try? InterfaceCoding.encodeReply(to: message, DaemonReply.status(Self.status))
        }
        let client = server.connect()
        _ = try await client.request(InterfaceCoding.encode(DaemonRequest.status)).get()
        client.cancel()

        for await event in server.peerEvents {
            #expect(event == "invalidated")
            return
        }
    }

    @Test func refusesAPeerThatFailsTheRequirement() async throws {
        let server = EchoServer(codeSigningRequirement: #"identifier "dev.maw.nobody""#) {
            message in
            try? InterfaceCoding.encodeReply(to: message, DaemonReply.status(Self.status))
        }
        let client = server.connect()
        defer { client.cancel() }

        let result = await client.request(try InterfaceCoding.encode(DaemonRequest.status))
        #expect(throws: XPCConnection.Failure.self) { try result.get() }
    }

    @Test func acceptsAPeerThatSatisfiesTheRequirement() async throws {
        let identifier = try #require(PeerRequirement.currentIdentifier())
        let server = EchoServer(codeSigningRequirement: "identifier \"\(identifier)\"") {
            message in
            try? InterfaceCoding.encodeReply(to: message, DaemonReply.status(Self.status))
        }
        let client = server.connect()
        defer { client.cancel() }

        let reply = try await client.request(InterfaceCoding.encode(DaemonRequest.status)).get()
        #expect(
            try InterfaceCoding.decode(DaemonReply.self, from: reply, as: .client)
                == .status(Self.status))
    }

    @Test func reportsAMissingServiceAsInvalid() async throws {
        let client = XPCConnection(machService: "dev.maw.tests.no-such-service")
        client.activate()
        defer { client.cancel() }
        let result = await client.request(try InterfaceCoding.encode(DaemonRequest.status))
        #expect(throws: XPCConnection.Failure.invalidated) { try result.get() }
    }

    static let status = DaemonStatus(
        daemon: DaemonInfo(version: "0.1.0", processID: 1, interfaceVersion: 1),
        uptimeMilliseconds: 1, canRunVirtualMachines: true, machines: [])
}
