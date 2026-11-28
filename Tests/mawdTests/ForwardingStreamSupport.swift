import CryptoKit
import Darwin
import Foundation
import Testing

/// What the tests of a forwarded connection's ends share (docs/decisions/0023-localhost-forwarding.md,
/// "Correction of 2026-11-28"): a guest server that sends or receives 64 MiB, and a Mac client
/// in the test's own code, which checks every byte and tells a clean end from a reset.
extension MawIntegration {
    /// The bytes each transfer carries.
    static let transferSize = 64 << 20

    /// A TCP server in the guest on 127.0.0.1, Python's standard library only, for one
    /// connection. It prints `listening` once it listens.
    /// - `send`: sends 64 MiB of random bytes and closes; then prints `sent <SHA-256>`.
    /// - `request`: reads the request to its end, prints `request <bytes>`, then as `send`.
    /// - `stall`: reads 4 MiB, prints `stalled`, and then reads nothing more.
    static let streamServerScript = """
        import hashlib, os, socket, sys, time
        mode, port, size = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", port))
        listener.listen(4)
        print("listening", flush=True)
        connection, _ = listener.accept()
        if mode == "request":
            request = b""
            while True:
                data = connection.recv(65536)
                if not data:
                    break
                request += data
            print("request %d" % len(request), flush=True)
        if mode in ("send", "request"):
            digest = hashlib.sha256()
            left = size
            while left:
                chunk = os.urandom(min(left, 1 << 20))
                connection.sendall(chunk)
                digest.update(chunk)
                left -= len(chunk)
            connection.close()
            print("sent " + digest.hexdigest(), flush=True)
        elif mode == "stall":
            received = 0
            while received < 4 << 20:
                data = connection.recv(65536)
                if not data:
                    break
                received += len(data)
            print("stalled", flush=True)
            time.sleep(600)
        """

    /// Starts the stream server in the test distribution and waits until the daemon forwards
    /// its port. The server accepts one connection, so nothing probes it.
    func startStreamServer(_ mode: String, port: UInt16, watcher: Watcher) async throws
        -> DebugBootProcess
    {
        let server = try start([
            "-d", distribution, "-e", "python3", "-c", Self.streamServerScript, mode,
            String(port), String(Self.transferSize),
        ])
        let listening = await server.waitForLine(
            where: { $0 == "listening" }, every: .milliseconds(5), timeout: .seconds(60))
        try #require(listening, "the server did not start: \(server.output)\(server.standardError)")
        _ = try await watcher.forwarding("port \(port) forwarded") {
            $0?.forwarded.contains(port) == true
        }
        return server
    }

    /// The Mac's sockets on `port`, as `lsof` lists them; empty when none is open.
    static func macSockets(on port: UInt16) async throws -> [String] {
        let process = try DebugBootProcess(
            executable: URL(filePath: "/usr/sbin/lsof"), arguments: ["-nP", "-iTCP:\(port)"],
            separateStandardError: true)
        let result = await process.waitForExit(timeout: .seconds(30))
        return result.lines.filter { !$0.isEmpty && !$0.hasPrefix("COMMAND") }
    }
}

/// A Mac client of a forwarded port, in the test's own code.
final class MacStreamClient: @unchecked Sendable {
    /// How a direction of the connection ended.
    enum Ending: Equatable, CustomStringConvertible {
        /// `read(2)` returned 0, this long after the last byte arrived.
        case end(afterLastByte: Duration)
        /// A read or write failed with this errno value.
        case error(Int32)
        /// Nothing arrived for this long.
        case silence(Duration)

        var description: String {
            switch self {
            case .end(let after): "a clean end \(after) after the last byte"
            case .error(let code): "error \(code) (\(String(cString: strerror(code))))"
            case .silence(let duration): "no end and no byte for \(duration)"
            }
        }

        var isClean: Bool {
            if case .end = self { return true }
            return false
        }
    }

    let descriptor: Int32
    private(set) var received = 0
    private var digest = SHA256()

    /// Connects to `port` on 127.0.0.1.
    init(port: UInt16) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(connected == 0, "connect: errno \(errno)")
    }

    deinit { close(descriptor) }

    /// The SHA-256 of what arrived, in lowercase hexadecimal.
    var receivedDigest: String {
        digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func send(_ text: String) throws {
        let written = text.withCString { write(descriptor, $0, strlen($0)) }
        try #require(written == text.utf8.count, "write: errno \(errno)")
    }

    func halfClose() throws {
        try #require(shutdown(descriptor, SHUT_WR) == 0, "shutdown: errno \(errno)")
    }

    /// Reads until at least `count` bytes in all have arrived; returns how reading ended if it
    /// ended first.
    func read(atLeast count: Int, silence: Duration = .seconds(30)) -> Ending? {
        readUntil(silence: silence) { self.received >= count }
    }

    /// Reads to the connection's end, a failure, or `silence` without a byte.
    func readToEnd(silence: Duration = .seconds(5)) -> Ending {
        readUntil(silence: silence) { false } ?? .silence(silence)
    }

    private func readUntil(silence: Duration, _ done: () -> Bool) -> Ending? {
        var buffer = [UInt8](repeating: 0, count: 1 << 17)
        var lastByte = ContinuousClock.now
        while !done() {
            var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(
                silence.components.seconds * 1_000
                    + silence.components.attoseconds / 1_000_000_000_000_000)
            guard poll(&request, 1, milliseconds) > 0 else { return .silence(silence) }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return .end(afterLastByte: ContinuousClock.now - lastByte) }
            if count < 0 { return .error(errno) }
            buffer.withUnsafeBytes {
                digest.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count]))
            }
            received += count
            lastByte = ContinuousClock.now
        }
        return nil
    }

    /// Writes until a write fails or the connection ends, or `limit` passes without either:
    /// it writes whenever the socket takes more, and reads whatever arrives. Returns how the
    /// connection ended, and the bytes written.
    func writeUntilItEnds(within limit: Duration) -> (ending: Ending, written: Int) {
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let chunk = [UInt8](repeating: 0x5A, count: 1 << 16)
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var written = 0
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            var request = pollfd(
                fd: descriptor, events: Int16(POLLIN) | Int16(POLLOUT), revents: 0)
            guard poll(&request, 1, 100) > 0 else { continue }
            if request.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count == 0 { return (.end(afterLastByte: .zero), written) }
                if count < 0 && errno != EAGAIN { return (.error(errno), written) }
            }
            if request.revents & Int16(POLLOUT) != 0 {
                let count = chunk.withUnsafeBytes { write(descriptor, $0.baseAddress!, $0.count) }
                if count > 0 {
                    written += count
                } else if count < 0 && errno != EAGAIN {
                    return (.error(errno), written)
                }
            }
        }
        return (.silence(limit), written)
    }
}
