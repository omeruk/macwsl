import Darwin
import Foundation
import MawXPC
import Testing

/// What the forwarding tests and measurements share: a server in the guest, an HTTP client on
/// the Mac, and the Mac's ports.
extension MawIntegration {
    /// A TCP server in the guest, Python's standard library only, run by a `maw` session that
    /// holds the machine: `http` answers `GET /bytes/<n>` with n bytes and `GET /file/<path>`
    /// with the file through `sendfile`, one thread per connection; `hold` accepts connections
    /// and keeps them open. It prints `listening` once it listens.
    static let serverScript = """
        import os, socket, sys, threading
        mode, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
        family = socket.AF_INET6 if ":" in host else socket.AF_INET
        listener = socket.socket(family, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if family == socket.AF_INET6:
            listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        listener.bind((host, port))
        listener.listen(1024)
        print("listening", flush=True)
        held = []
        def serve(connection):
            try:
                request = b""
                while b"\\r\\n\\r\\n" not in request:
                    data = connection.recv(4096)
                    if not data:
                        return
                    request += data
                path = request.split(b" ")[1].decode()
                if path.startswith("/file/"):
                    with open(path[len("/file"):], "rb") as file:
                        size = os.fstat(file.fileno()).st_size
                        connection.sendall(b"HTTP/1.1 200 OK\\r\\nContent-Length: %d\\r\\nConnection: close\\r\\n\\r\\n" % size)
                        connection.sendfile(file)
                else:
                    count = int(path.rsplit("/", 1)[1]) if path.startswith("/bytes/") else 2
                    connection.sendall(b"HTTP/1.1 200 OK\\r\\nContent-Length: %d\\r\\nConnection: close\\r\\n\\r\\n" % count + b"x" * count)
                connection.shutdown(socket.SHUT_WR)
                while connection.recv(4096):
                    pass
            except OSError:
                pass
            finally:
                connection.close()
        while True:
            connection, _ = listener.accept()
            if mode == "hold":
                held.append(connection)
            else:
                threading.Thread(target=serve, args=(connection,), daemon=True).start()
        """

    /// Starts a server in `distribution` (by default the test distribution) and waits until it
    /// listens.
    func startServer(
        _ mode: String = "http", host: String, port: UInt16, in distribution: String? = nil,
        as user: String? = nil
    ) async throws -> DebugBootProcess {
        let server = try start(
            ["-d", distribution ?? self.distribution] + (user.map { ["-u", $0] } ?? []) + [
                "-e", "python3", "-c", Self.serverScript, mode, host, String(port),
            ])
        let listening = await server.waitForLine(
            where: { $0 == "listening" }, every: .milliseconds(5), timeout: .seconds(60))
        try #require(listening, "the server did not start: \(server.output)\(server.standardError)")
        return server
    }

    /// Stops a server that `startServer` started: ending its `maw` hangs the server up.
    func stopServer(_ server: DebugBootProcess) async {
        server.signal(SIGTERM)
        _ = await server.waitForExit(timeout: .seconds(30))
    }

    /// Runs `/usr/bin/curl` with `arguments`; returns its exit status and standard output.
    static func curl(_ arguments: [String], timeout: Duration = .seconds(120)) async throws
        -> (status: Int32, output: String)
    {
        let process = try DebugBootProcess(
            executable: URL(filePath: "/usr/bin/curl"), arguments: ["-s", "-g"] + arguments,
            separateStandardError: true)
        let result = await process.waitForExit(timeout: timeout)
        return (result.status, result.output)
    }

    /// The HTTP status of `GET <url>`, or `nil` when curl could not complete the request.
    static func httpStatus(_ url: String) async throws -> Int? {
        let result = try await curl(
            ["-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", url])
        return result.status == 0 ? Int(result.output) : nil
    }

    /// Waits until `GET <url>` answers 200, or stops answering, as `answers` says.
    static func waitUntil(_ url: String, answers: Bool, within timeout: Duration = .seconds(10))
        async throws -> Bool
    {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await (httpStatus(url) == 200) == answers { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// Whether a connection to `port` on the Mac's 127.0.0.1, and on ::1, is refused: nothing
    /// listens there. A port in TIME_WAIT only is refused too.
    static func refuses(_ port: UInt16) -> Bool {
        MacListener.connect(ipv6: false, port: port) == ECONNREFUSED
            && MacListener.connect(ipv6: true, port: port) == ECONNREFUSED
    }

    /// Waits until `refuses(port)`.
    static func waitUntilRefused(_ port: UInt16, within timeout: Duration = .seconds(2))
        async throws -> Bool
    {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if refuses(port) { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return refuses(port)
    }

    /// A port that is free on the Mac's 127.0.0.1 and ::1 now, from 20000 to 60000.
    static func freePort() throws -> UInt16 {
        for _ in 0..<500 {
            let port = UInt16.random(in: 20_000...60_000)
            if let first = MacListener(ipv6: false, port: port) {
                defer { first.close() }
                if let second = MacListener(ipv6: true, port: port) {
                    second.close()
                    return port
                }
            }
        }
        throw WatchFailure(description: "no free port on the Mac's loopback addresses")
    }
}

/// A Mac program's listening socket on one loopback address, as the tests hold one.
final class MacListener: Sendable {
    let descriptor: Int32

    init?(ipv6: Bool, port: UInt16) {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var result: Int32
        if ipv6 {
            var only: Int32 = 1
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_loopback
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard result == 0, listen(fd, 16) == 0 else {
            Darwin.close(fd)
            return nil
        }
        descriptor = fd
    }

    func close() {
        Darwin.close(descriptor)
    }

    /// Accepts one waiting connection within `timeout`; returns its descriptor, or nil.
    func accept(within timeout: Duration) -> Int32? {
        var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let milliseconds =
            Int32(timeout.components.seconds * 1000)
            + Int32(timeout.components.attoseconds / 1_000_000_000_000_000)
        guard poll(&request, 1, milliseconds) == 1 else { return nil }
        let accepted = Darwin.accept(descriptor, nil, nil)
        return accepted >= 0 ? accepted : nil
    }

    /// Connects to `port` on 127.0.0.1 or ::1 and closes at once: 0, or the errno value.
    static func connect(ipv6: Bool, port: UInt16) -> Int32 {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno }
        defer { Darwin.close(fd) }
        var result: Int32
        if ipv6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_loopback
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return result == 0 ? 0 : errno
    }
}

extension Watcher {
    /// The first snapshot in which `distribution`'s forwarding satisfies `condition`.
    func forwarding(
        _ what: String, of distribution: String? = nil, within timeout: Duration = .seconds(10),
        _ condition: @escaping (PortForwarding?) -> Bool
    ) async throws -> PortForwarding? {
        let name = distribution ?? self.distribution
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let found = probe.results.reversed().lazy.compactMap { line -> PortForwarding?? in
                let parts = line.split(separator: " ", maxSplits: 2)
                guard parts.count == 3, parts[0] == "snapshot",
                    let snapshot = try? JSONDecoder().decode(
                        DistributionSnapshot.self, from: Data(parts[2].utf8)),
                    let figures = snapshot.distributions.first(where: { $0.name.rawValue == name })
                else { return nil }
                return .some(figures.forwarding)
            }.first
            if let found, condition(found) { return found }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WatchFailure(
            description:
                "no snapshot of \(name) with \(what) within \(timeout)\n\(probe.transcript)")
    }
}
