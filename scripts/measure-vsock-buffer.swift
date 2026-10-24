// Measures how much of a guest's output the host side of a Virtualization.framework vsock
// connection holds while nothing on the host reads it, and whether SO_RCVBUF on the host's
// descriptor changes that. scripts/measure-vsock-buffer.sh builds, signs, and runs it; it is a
// development tool and not part of maw.
//
// It boots the guest kernel and initramfs, as `mawd debug-boot` does, and for each variant opens
// a connection to the guest agent, optionally sets SO_RCVBUF, and starts a guest command that
// writes 8 KiB at a time to its standard output and counts each write on the console. Without
// reading, it waits until both the host socket and the count stop changing, then records:
//
// - the bytes in the host socket (SO_NREAD);
// - the buffers of the host's socket and of its peer in the virtual machine's process, found by
//   LOCAL_PEERPID and the peer's protocol control block (proc_pidfdinfo);
// - the bytes the guest command wrote before it blocked (8 KiB per count);
// - whether a second connection to the agent completes its version exchange within 2 seconds,
//   which it does not while the vsock device is blocked.
//
// It then reads the session to its end and checks that every byte arrived.
//
// In the "handed over" variants the descriptor goes to a second process over SCM_RIGHTS, as the
// daemon hands a session's descriptor to maw over XPC, and that process sets SO_RCVBUF and runs
// the session; this process closes its own copy.
//
// With --inspect <pid>..., it boots nothing and prints the buffers of every connected Unix
// stream socket of those processes, for checking a running maw, mawd, and virtual machine
// process: for example a `maw -e head -c 16777216 /dev/zero` whose standard output is a FIFO
// that nothing reads, and the virtual machine's com.apple.Virtualization.VirtualMachine.
//
// With --guest-initiated, the connections that carry output are opened by the guest instead:
// the host listens with VZVirtioSocketListener, and scripts/measure-vsock-guest.c, copied into
// the guest's /run through the agent, connects and writes. For each run it records the same
// figures, and also whether a guest-initiated connection (a guest program that connects every
// 100 ms) and the console (a shell on hvc0 that echoes a line) still answer within 2 seconds.
// It also checks which source ports the guest may bind, what VZVirtioSocketConnection reports
// for a guest-initiated connection, and how long a dial-back takes.

import Darwin
import Foundation
import Virtualization

let agentPort: UInt32 = 19799
let protocolVersion: UInt32 = 2
let chunkSize = 8192
let chunkCount = 2048

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("measure-vsock-buffer: \(message)\n".utf8))
    exit(1)
}

func describe(_ code: Int32) -> String { String(cString: strerror(code)) }

// MARK: Frames

func frame(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
    let size = UInt32(payload.count)
    return [
        UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF),
        UInt8(size & 0xFF), type,
    ] + payload
}

func versionFrame() -> [UInt8] {
    frame(
        0x01,
        [
            UInt8(protocolVersion >> 24), UInt8((protocolVersion >> 16) & 0xFF),
            UInt8((protocolVersion >> 8) & 0xFF), UInt8(protocolVersion & 0xFF),
        ])
}

/// The guest command: writes `chunkCount` chunks of `chunkSize` bytes, and after each one
/// writes `vsock-count <tag> <count>` to the console, which the host reads from the console
/// log. The tag tells this session's lines from those of earlier sessions, which the console
/// may deliver late.
func execFrame(tag: String) -> [UInt8] {
    let script =
        "i=0; while [ $i -lt \(chunkCount) ]; do head -c \(chunkSize) /dev/zero || exit 1; "
        + "i=$((i+1)); echo \"vsock-count \(tag) $i\" > /dev/hvc0; done"
    return execFrame(argv: ["/bin/sh", "-c", script])
}

func execFrame(argv: [String]) -> [UInt8] {
    let request: [String: Any] = ["exec": ["program": ["argv": argv]]]
    return frame(0x02, Array(try! JSONSerialization.data(withJSONObject: request)))
}

func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) {
    var offset = 0
    while offset < bytes.count {
        let count = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno == EINTR { continue }
            fail("write: \(describe(errno))")
        }
        offset += count
    }
}

/// Reads exactly `count` bytes, or returns nil at end-of-file or after `timeout` seconds.
func readExactly(_ descriptor: Int32, _ count: Int, timeout: Double) -> [UInt8]? {
    var bytes: [UInt8] = []
    let deadline = Date().addingTimeInterval(timeout)
    var buffer = [UInt8](repeating: 0, count: count)
    while bytes.count < count {
        var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        guard poll(&request, 1, remaining) > 0 else { return nil }
        let got = buffer.withUnsafeMutableBytes {
            read(descriptor, $0.baseAddress, count - bytes.count)
        }
        if got < 0 && errno == EINTR { continue }
        guard got > 0 else { return nil }
        bytes += buffer[..<got]
    }
    return bytes
}

// MARK: Socket buffers

func socketInfo(pid: pid_t, descriptor: Int32) -> socket_fdinfo? {
    var info = socket_fdinfo()
    let size = Int32(MemoryLayout<socket_fdinfo>.size)
    return proc_pidfdinfo(pid, descriptor, PROC_PIDFDSOCKETINFO, &info, size) == size ? info : nil
}

/// The socket at the other end of `descriptor`, in the process that holds it.
func peer(of descriptor: Int32) -> (pid: pid_t, info: socket_fdinfo)? {
    var pid: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
        let own = socketInfo(pid: getpid(), descriptor: descriptor)
    else { return nil }
    return socket(connectedTo: own.psi.soi_pcb, in: pid).map { (pid, $0) }
}

/// The socket in process `pid` whose peer is the socket with control block `pcb`.
func socket(connectedTo pcb: UInt64, in pid: pid_t) -> socket_fdinfo? {
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return nil }
    var entries = [proc_fdinfo](
        repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size)
    let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &entries, size)
    for entry in entries.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.size)
    where entry.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
        if let info = socketInfo(pid: pid, descriptor: entry.proc_fd),
            info.psi.soi_kind == Int32(SOCKINFO_UN),
            info.psi.soi_proto.pri_un.unsi_conn_pcb == pcb
        {
            return info
        }
    }
    return nil
}

func format(_ buffer: sockbuf_info) -> String {
    "cc \(buffer.sbi_cc) hiwat \(buffer.sbi_hiwat) lowat \(buffer.sbi_lowat) "
        + "mbcnt \(buffer.sbi_mbcnt) mbmax \(buffer.sbi_mbmax)"
}

func option(_ descriptor: Int32, _ name: Int32) -> Int32 {
    var value: Int32 = -1
    var length = socklen_t(MemoryLayout<Int32>.size)
    _ = getsockopt(descriptor, SOL_SOCKET, name, &value, &length)
    return value
}

// MARK: Console

func lastCount(in console: URL, tag: String) -> Int {
    guard let text = try? String(contentsOf: console, encoding: .utf8) else { return 0 }
    let prefix = "vsock-count \(tag) "
    var count = 0
    // Split on any line break: the console ends lines with CR LF, a single Character.
    for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix(prefix) {
        count = max(count, Int(line.dropFirst(prefix.count)) ?? 0)
    }
    return count
}

// MARK: One session

/// Starts the guest command on `descriptor`, waits without reading until the host socket and
/// the guest's count stop changing, and returns a report of what it found.
func measure(_ descriptor: Int32, receiveBuffer: Int32?, console: URL) -> String {
    var lines: [String] = []
    if let receiveBuffer {
        var value = receiveBuffer
        let result = setsockopt(
            descriptor, SOL_SOCKET, SO_RCVBUF, &value, socklen_t(MemoryLayout<Int32>.size))
        lines.append(
            "  setsockopt(SO_RCVBUF, \(receiveBuffer)): "
                + (result == 0 ? "accepted" : "refused, \(describe(errno))"))
    }
    lines.append(
        "  SO_RCVBUF \(option(descriptor, SO_RCVBUF)), SO_SNDBUF \(option(descriptor, SO_SNDBUF))")

    let tag = UUID().uuidString.prefix(8).lowercased()
    writeAll(descriptor, versionFrame() + execFrame(tag: tag))

    var stableSince = Date()
    var last = (bytes: Int32(-1), count: -1)
    let started = Date()
    while true {
        usleep(100_000)
        let now = (bytes: option(descriptor, SO_NREAD), count: lastCount(in: console, tag: tag))
        if now != last {
            last = now
            stableSince = Date()
        } else if Date().timeIntervalSince(stableSince) >= 1.5 {
            break
        }
        if Date().timeIntervalSince(started) > 30 { break }
    }
    lines.append("  host socket holds \(last.bytes) bytes (SO_NREAD)")
    lines.append(
        "  the guest command wrote \(last.count) of \(chunkCount) chunks, "
            + "\(last.count * chunkSize) bytes, before it blocked"
            + (last.count == chunkCount ? " (it did not block)" : ""))
    if let own = socketInfo(pid: getpid(), descriptor: descriptor) {
        lines.append("  host socket   receive: \(format(own.psi.soi_rcv))")
    }
    if let (pid, info) = peer(of: descriptor) {
        lines.append("  peer (pid \(pid)) send:  \(format(info.psi.soi_snd))")
    } else {
        lines.append("  peer socket: not found")
    }
    return lines.joined(separator: "\n")
}

/// Reads the session to its end. Returns a report of the output received and the exit.
func drain(_ descriptor: Int32) -> String {
    var output = 0
    var ending = "the connection closed without exited"
    while let header = readExactly(descriptor, 5, timeout: 60) {
        let size =
            Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        guard let payload = readExactly(descriptor, size, timeout: 60) else { break }
        if header[4] == 0x11 { output += size }
        if header[4] == 0x02, let text = String(bytes: payload, encoding: .utf8),
            text.contains("exited") || text.contains("error")
        {
            ending = text
            break
        }
    }
    let expected = chunkSize * chunkCount
    return "  after reading: \(output) of \(expected) bytes of output, then \(ending)"
        + (output == expected ? "" : " (INCOMPLETE)")
}

// MARK: Round trips

func readFrame(_ descriptor: Int32) -> (type: UInt8, payload: [UInt8])? {
    guard let header = readExactly(descriptor, 5, timeout: 10) else { return nil }
    let size = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
    guard let payload = readExactly(descriptor, size, timeout: 10) else { return nil }
    return (header[4], payload)
}

/// The time for one byte of input to come back as output from `cat` in the guest: the
/// round trip that one acknowledgement of a window would take, plus `cat` itself.
func roundTrips(on machine: Machine, count: Int) -> String {
    guard let descriptor = machine.connect(timeout: 5) else { fail("could not connect") }
    defer { close(descriptor) }
    writeAll(descriptor, versionFrame() + execFrame(argv: ["/bin/cat"]))
    _ = readFrame(descriptor)  // version
    _ = readFrame(descriptor)  // started
    var samples: [Double] = []
    for _ in 0..<count {
        let start = DispatchTime.now().uptimeNanoseconds
        writeAll(descriptor, frame(0x10, [0x61]))
        while let received = readFrame(descriptor), received.type != 0x11 {}
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
    }
    writeAll(descriptor, frame(0x02, Array(#"{"stdinEOF":{}}"#.utf8)))
    while let received = readFrame(descriptor),
        received.type != 0x02
            || !String(
                decoding: received.payload, as: UTF8.self
            ).contains("exited")
    {}
    samples.sort()
    return String(
        format: "  %d round trips: median %.0f µs, 95th percentile %.0f µs, slowest %.0f µs",
        count, samples[count / 2], samples[count * 95 / 100], samples[count - 1])
}

// MARK: Handing over

func sendDescriptor(_ descriptor: Int32, over socket: Int32) {
    var byte: UInt8 = 0
    var control = [UInt8](repeating: 0, count: 16)
    let sent = withUnsafeMutableBytes(of: &byte) { data -> Int in
        var vector = iovec(iov_base: data.baseAddress, iov_len: 1)
        return withUnsafeMutablePointer(to: &vector) { vector in
            control.withUnsafeMutableBytes { buffer -> Int in
                buffer.baseAddress!.assumingMemoryBound(to: cmsghdr.self).pointee = cmsghdr(
                    cmsg_len: 16, cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS)
                (buffer.baseAddress! + 12).storeBytes(of: descriptor, as: Int32.self)
                var message = msghdr(
                    msg_name: nil, msg_namelen: 0, msg_iov: vector, msg_iovlen: 1,
                    msg_control: buffer.baseAddress, msg_controllen: 16, msg_flags: 0)
                return sendmsg(socket, &message, 0)
            }
        }
    }
    if sent != 1 { fail("sendmsg: \(describe(errno))") }
}

func receiveDescriptor(over socket: Int32) -> Int32 {
    var byte: UInt8 = 0
    var control = [UInt8](repeating: 0, count: 16)
    return withUnsafeMutableBytes(of: &byte) { data -> Int32 in
        var vector = iovec(iov_base: data.baseAddress, iov_len: 1)
        return withUnsafeMutablePointer(to: &vector) { vector in
            control.withUnsafeMutableBytes { buffer -> Int32 in
                var message = msghdr(
                    msg_name: nil, msg_namelen: 0, msg_iov: vector, msg_iovlen: 1,
                    msg_control: buffer.baseAddress, msg_controllen: 16, msg_flags: 0)
                guard recvmsg(socket, &message, 0) == 1 else {
                    fail("recvmsg: \(describe(errno))")
                }
                return (buffer.baseAddress! + 12).load(as: Int32.self)
            }
        }
    }
}

func readLine(_ descriptor: Int32) -> String {
    var bytes: [UInt8] = []
    var byte: UInt8 = 0
    while read(descriptor, &byte, 1) == 1 {
        bytes.append(byte)
        if byte == 0 { break }
    }
    return String(decoding: bytes.dropLast(), as: UTF8.self)
}

func writeLine(_ descriptor: Int32, _ text: String) {
    writeAll(descriptor, Array(text.utf8) + [0])
}

/// The receiving process: takes the descriptor over descriptor 3, measures, waits for the
/// parent's probe, drains, and reports each step back over descriptor 3.
func runReceiver(receiveBuffer: Int32?, console: URL) -> Never {
    let control: Int32 = 3
    let descriptor = receiveDescriptor(over: control)
    writeLine(control, measure(descriptor, receiveBuffer: receiveBuffer, console: console))
    _ = readLine(control)
    writeLine(control, drain(descriptor))
    exit(0)
}

func spawnReceiver(receiveBuffer: Int32?, console: URL) -> (pid: pid_t, control: Int32) {
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { fail("socketpair") }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_adddup2(&actions, pair[1], 3)
    let arguments =
        [CommandLine.arguments[0], "--receiver", "--console", console.path]
        + (receiveBuffer.map { ["--rcvbuf", String($0)] } ?? [])
    let argv = arguments.map { strdup($0) } + [nil]
    var pid: pid_t = 0
    let result = posix_spawn(&pid, CommandLine.arguments[0], &actions, nil, argv, environ)
    guard result == 0 else { fail("posix_spawn: \(describe(result))") }
    close(pair[1])
    return (pid, pair[0])
}

// MARK: The virtual machine

/// A connection that the guest opened to a host listener.
struct AcceptedConnection {
    let descriptor: Int32
    let sourcePort: UInt32
    let destinationPort: UInt32
    /// When the listener's delegate received it (DispatchTime nanoseconds).
    let time: UInt64
}

final class ListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let queue: DispatchQueue
    let accept: (AcceptedConnection) -> Void

    init(queue: DispatchQueue, accept: @escaping (AcceptedConnection) -> Void) {
        self.queue = queue
        self.accept = accept
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let time = DispatchTime.now().uptimeNanoseconds
        // As the daemon does with a connection it opens: keep a duplicate of the descriptor
        // and close the connection object, here once the delegate has returned.
        let descriptor = dup(connection.fileDescriptor)
        queue.async { connection.close() }
        accept(
            AcceptedConnection(
                descriptor: descriptor, sourcePort: connection.sourcePort,
                destinationPort: connection.destinationPort, time: time))
        return true
    }
}

/// Accepted connections, in order, for one thread to wait for.
final class AcceptQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AcceptedConnection] = []
    private let available = DispatchSemaphore(value: 0)

    func add(_ connection: AcceptedConnection) {
        lock.lock()
        items.append(connection)
        lock.unlock()
        available.signal()
    }

    func next(timeout: Double) -> AcceptedConnection? {
        guard available.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return items.removeFirst()
    }
}

final class Machine: @unchecked Sendable {
    let queue = DispatchQueue(label: "measure-vsock-buffer")
    var machine: VZVirtualMachine!
    var device: VZVirtioSocketDevice!
    /// The write end of the console's input, with `debugShell`.
    var consoleInput: Int32 = -1
    private var delegates: [ListenerDelegate] = []

    /// With `debugShell`, the initramfs also runs a shell on the console, which reads what
    /// is written to `consoleInput`.
    init(kernelDirectory: URL, console: URL, debugShell: Bool = false) {
        let bootLoader = VZLinuxBootLoader(kernelURL: kernelDirectory.appending(path: "Image"))
        bootLoader.initialRamdiskURL = kernelDirectory.appending(path: "initramfs.cpio.gz")
        bootLoader.commandLine = "console=hvc0" + (debugShell ? " maw.debug=shell" : "")
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        if debugShell {
            var pipeEnds: [Int32] = [-1, -1]
            guard pipe(&pipeEnds) == 0,
                FileManager.default.createFile(atPath: console.path, contents: nil),
                let output = try? FileHandle(forWritingTo: console)
            else { fail("console: cannot create its pipe or its log") }
            consoleInput = pipeEnds[1]
            serial.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: FileHandle(fileDescriptor: pipeEnds[0]),
                fileHandleForWriting: output)
        } else {
            do {
                serial.attachment = try VZFileSerialPortAttachment(url: console, append: false)
            } catch {
                fail("console: \(error)")
            }
        }
        let configuration = VZVirtualMachineConfiguration()
        configuration.bootLoader = bootLoader
        configuration.cpuCount = 2
        configuration.memorySize = 1 << 30
        configuration.serialPorts = [serial]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        do {
            try configuration.validate()
        } catch {
            fail("configuration: \(error)")
        }
        let started = DispatchSemaphore(value: 0)
        queue.sync {
            machine = VZVirtualMachine(configuration: configuration, queue: queue)
            device = machine.socketDevices.first as? VZVirtioSocketDevice
            machine.start { result in
                if case .failure(let error) = result { fail("start: \(error)") }
                started.signal()
            }
        }
        started.wait()
    }

    /// A connection to the agent, or nil if none opens within `timeout` seconds.
    func connect(timeout: Double) -> Int32? {
        final class Box: @unchecked Sendable {
            var descriptor: Int32?
            var abandoned = false
            let lock = NSLock()
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        queue.async { [device] in
            device!.connect(toPort: agentPort) { result in
                if case .success(let connection) = result {
                    let descriptor = dup(connection.fileDescriptor)
                    connection.close()
                    box.lock.lock()
                    if box.abandoned { close(descriptor) } else { box.descriptor = descriptor }
                    box.lock.unlock()
                }
                done.signal()
            }
        }
        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        box.lock.lock()
        defer { box.lock.unlock() }
        if timedOut { box.abandoned = true }
        return box.descriptor
    }

    /// Accepts the guest's connections to `port` and passes each to `accept`, on the machine's
    /// queue.
    func listen(on port: UInt32, _ accept: @escaping (AcceptedConnection) -> Void) {
        queue.sync {
            let delegate = ListenerDelegate(queue: queue, accept: accept)
            delegates.append(delegate)
            let listener = VZVirtioSocketListener()
            listener.delegate = delegate
            device.setSocketListener(listener, forPort: port)
        }
    }

    /// Like `connect(timeout:)` for any port, also returning how long the connection took to
    /// open, in microseconds.
    func timedConnect(to port: UInt32, timeout: Double) -> (descriptor: Int32, micros: Double)? {
        final class Box: @unchecked Sendable {
            var result: (Int32, UInt64)?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let start = DispatchTime.now().uptimeNanoseconds
        queue.async { [device] in
            device!.connect(toPort: port) { result in
                if case .success(let connection) = result {
                    box.result = (dup(connection.fileDescriptor), DispatchTime.now().uptimeNanoseconds)
                    connection.close()
                }
                done.signal()
            }
        }
        guard done.wait(timeout: .now() + timeout) == .success, let (descriptor, end) = box.result
        else { return nil }
        return (descriptor, Double(end - start) / 1000)
    }

    /// Whether a new connection completes its version exchange within `timeout` seconds.
    func answers(within timeout: Double) -> Bool {
        let started = Date()
        guard let descriptor = connect(timeout: timeout) else { return false }
        defer { close(descriptor) }
        writeAll(descriptor, versionFrame())
        let remaining = max(0.1, timeout - Date().timeIntervalSince(started))
        return readExactly(descriptor, 9, timeout: remaining) != nil
    }

    func stop() {
        let stopped = DispatchSemaphore(value: 0)
        queue.async { [machine] in
            machine!.stop { _ in stopped.signal() }
        }
        _ = stopped.wait(timeout: .now() + 10)
    }
}

// MARK: Guest-initiated connections

let streamPort: UInt32 = 20000
let pingPort: UInt32 = 20001
let dialPort: UInt32 = 20002
let servePort: UInt32 = 20100
let acceptPort: UInt32 = 20101
let helperPath = "/run/measure-vsock-guest"

/// The virtual machine's process, which holds the other end of the host's vsock descriptors.
var machinePID: pid_t = 0

let endOfInputFrame = frame(0x02, Array(#"{"stdinEOF":{}}"#.utf8))

/// Reads a session's frames to its end. Returns its standard output and error, and the
/// control message that ended it.
func finish(_ descriptor: Int32) -> (output: String, ending: String) {
    var output: [UInt8] = []
    while let received = readFrame(descriptor) {
        if received.type == 0x11 || received.type == 0x12 { output += received.payload }
        let text = String(decoding: received.payload, as: UTF8.self)
        if received.type == 0x02, text.contains("exited") || text.contains("error") {
            return (String(decoding: output, as: UTF8.self), text)
        }
    }
    return (String(decoding: output, as: UTF8.self), "the connection closed without exited")
}

/// Runs `argv` in the guest through the agent, with `input` as its standard input.
func run(_ argv: [String], input: [UInt8] = [], on machine: Machine) -> (
    output: String, ending: String
) {
    guard let descriptor = machine.connect(timeout: 5) else { fail("could not connect") }
    defer { close(descriptor) }
    var bytes = versionFrame() + execFrame(argv: argv)
    for start in stride(from: 0, to: input.count, by: 32768) {
        bytes += frame(0x10, Array(input[start..<min(start + 32768, input.count)]))
    }
    writeAll(descriptor, bytes + endOfInputFrame)
    return finish(descriptor)
}

/// Arrival times of the guest's periodic connections.
final class Pings: @unchecked Sendable {
    private let lock = NSLock()
    private var arrivals: [Date] = []

    func record() {
        lock.lock()
        arrivals.append(Date())
        lock.unlock()
    }

    /// Waits up to `timeout` seconds for a connection that arrives after now.
    func arrive(within timeout: Double) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            lock.lock()
            let last = arrivals.last
            lock.unlock()
            if let last, last > start { return true }
            usleep(10_000)
        }
        return false
    }
}

/// Whether the shell on the console echoes a line within `timeout` seconds.
func consoleAnswers(_ machine: Machine, console: URL, within timeout: Double) -> Bool {
    let word = "console-pong-" + UUID().uuidString.prefix(8).lowercased()
    writeAll(machine.consoleInput, Array("echo \(word)\n".utf8))
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if let text = try? String(contentsOf: console, encoding: .utf8),
            text.split(whereSeparator: \.isNewline).contains(where: {
                $0.hasSuffix(word) && !$0.contains("echo")
            })
        {
            return true
        }
        usleep(20_000)
    }
    return false
}

/// Whether a host-initiated connection, a guest-initiated connection, and the console each
/// answer within 2 seconds, checked one after the other.
func checks(_ machine: Machine, pings: Pings, console: URL) -> String {
    let host = machine.answers(within: 2)
    let guest = pings.arrive(within: 2)
    let shell = consoleAnswers(machine, console: console, within: 2)
    return "  answers within 2 s: host-initiated connection \(host), "
        + "guest-initiated connection \(guest), console \(shell)"
}

/// Waits, without reading, until the bytes held by descriptor `descriptor` of process `pid`
/// and the guest's count stop changing, or 30 seconds pass. Returns a report.
func observe(pid: pid_t, descriptor: Int32, console: URL, tag: String, total: Int) -> String {
    var stableSince = Date()
    var last = (bytes: UInt32.max, count: -1)
    let started = Date()
    while Date().timeIntervalSince(started) < 30 {
        usleep(100_000)
        let held = socketInfo(pid: pid, descriptor: descriptor)?.psi.soi_rcv.sbi_cc ?? 0
        let now = (bytes: held, count: lastCount(in: console, tag: tag))
        if now != last {
            last = now
            stableSince = Date()
        } else if Date().timeIntervalSince(stableSince) >= 1.5 {
            break
        }
    }
    return snapshot(pid: pid, descriptor: descriptor, console: console, tag: tag, total: total)
}

func snapshot(pid: pid_t, descriptor: Int32, console: URL, tag: String, total: Int) -> String {
    guard let own = socketInfo(pid: pid, descriptor: descriptor) else {
        return "  host socket: cannot be inspected"
    }
    let count = lastCount(in: console, tag: tag)
    var lines = [
        "  host socket holds \(own.psi.soi_rcv.sbi_cc) bytes",
        "  the guest program wrote \(count) of \(total) bytes"
            + (count == total ? " (it did not block)" : " before it blocked"),
        "  host socket   receive: \(format(own.psi.soi_rcv)); kind \(own.psi.soi_kind), "
            + "family \(own.psi.soi_family), type \(own.psi.soi_type)",
    ]
    if let info = socket(connectedTo: own.psi.soi_pcb, in: machinePID) {
        lines.append("  peer (pid \(machinePID)) send:  \(format(info.psi.soi_snd))")
    } else {
        lines.append("  peer socket: not found in the virtual machine's process")
    }
    return lines.joined(separator: "\n")
}

/// Reads `descriptor` to end-of-file. Returns the byte count.
func drainRaw(_ descriptor: Int32) -> Int {
    var total = 0
    var buffer = [UInt8](repeating: 0, count: 64 << 10)
    while true {
        var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&request, 1, 60_000) > 0 else { return total }
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { return total }
        total += count
    }
}

/// The holding process for a handed-over guest-initiated connection: takes the descriptor over
/// descriptor 3 and reports its number. With `stream`, it then reads to end-of-file at once;
/// otherwise it waits for the parent's word first. Reports the byte count over descriptor 3.
func runHolder(stream: Bool) -> Never {
    let control: Int32 = 3
    let descriptor = receiveDescriptor(over: control)
    writeLine(control, String(descriptor))
    if !stream { _ = readLine(control) }
    writeLine(control, String(drainRaw(descriptor)))
    exit(0)
}

func spawnHolder(stream: Bool) -> (pid: pid_t, control: Int32) {
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { fail("socketpair") }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_adddup2(&actions, pair[1], 3)
    let arguments = [CommandLine.arguments[0], "--holder"] + (stream ? ["--stream"] : [])
    let argv = arguments.map { strdup($0) } + [nil]
    var pid: pid_t = 0
    let result = posix_spawn(&pid, CommandLine.arguments[0], &actions, nil, argv, environ)
    guard result == 0 else { fail("posix_spawn: \(describe(result))") }
    close(pair[1])
    return (pid, pair[0])
}

/// The control for `guestInitiatedRun`: the same guest program writes the same bytes on a
/// connection that the host opens, which this process holds and does not read.
func hostInitiatedRawRun(_ machine: Machine, pings: Pings, console: URL, total: Int) {
    let tag = UUID().uuidString.prefix(8).lowercased()
    guard let session = machine.connect(timeout: 5) else { fail("could not connect") }
    defer { close(session) }
    writeAll(
        session,
        versionFrame()
            + execFrame(argv: [helperPath, "accept-write", String(acceptPort), String(total), tag])
            + endOfInputFrame)
    var descriptor: Int32?
    for _ in 0..<50 where descriptor == nil {
        descriptor = machine.timedConnect(to: acceptPort, timeout: 2)?.descriptor
        if descriptor == nil { usleep(100_000) }
    }
    guard let descriptor else { fail("could not connect to the guest program") }
    print(observe(pid: getpid(), descriptor: descriptor, console: console, tag: tag, total: total))
    print(checks(machine, pings: pings, console: console))
    let received = drainRaw(descriptor)
    close(descriptor)
    print("  after reading: \(received) of \(total) bytes" + (received == total ? "" : " (INCOMPLETE)"))
    print("  the guest program's session ended with \(finish(session).ending)")
}

enum Holder {
    /// This process holds the connection and does not read it.
    case this
    /// A second process holds it and does not read it.
    case handedOver
    /// A second process reads it, and is stopped with SIGSTOP 300 ms after it starts.
    case handedOverStopped
}

/// One guest-initiated run: the guest program connects to `streamPort` and writes `total`
/// bytes, which `holder` leaves unread until the checks are done; then every byte is read.
func guestInitiatedRun(
    _ machine: Machine, streams: AcceptQueue, pings: Pings, console: URL, holder: Holder,
    total: Int, extraStall: UInt32 = 0
) {
    let tag = UUID().uuidString.prefix(8).lowercased()
    guard let session = machine.connect(timeout: 5) else { fail("could not connect") }
    defer { close(session) }
    writeAll(
        session,
        versionFrame()
            + execFrame(argv: [helperPath, "write", String(streamPort), String(total), tag])
            + endOfInputFrame)
    guard let accepted = streams.next(timeout: 10) else { fail("the guest did not connect") }
    print(
        "  accepted: sourcePort \(accepted.sourcePort), destinationPort "
            + "\(accepted.destinationPort)")

    func stall(pid: pid_t, descriptor: Int32) {
        print(observe(pid: pid, descriptor: descriptor, console: console, tag: tag, total: total))
        print(checks(machine, pings: pings, console: console))
        if extraStall > 0 {
            sleep(extraStall)
            print("  after \(extraStall) s more without reading:")
            print(snapshot(pid: pid, descriptor: descriptor, console: console, tag: tag, total: total))
            print(checks(machine, pings: pings, console: console))
        }
    }

    let received: Int
    switch holder {
    case .this:
        stall(pid: getpid(), descriptor: accepted.descriptor)
        received = drainRaw(accepted.descriptor)
        close(accepted.descriptor)
    case .handedOver, .handedOverStopped:
        let stopped = holder == .handedOverStopped
        let child = spawnHolder(stream: stopped)
        sendDescriptor(accepted.descriptor, over: child.control)
        close(accepted.descriptor)
        guard let descriptor = Int32(readLine(child.control)) else { fail("holder") }
        if stopped {
            usleep(300_000)
            kill(child.pid, SIGSTOP)
            print("  the holding process was stopped with SIGSTOP after 300 ms")
        }
        stall(pid: child.pid, descriptor: descriptor)
        if stopped {
            kill(child.pid, SIGCONT)
        } else {
            writeLine(child.control, "drain")
        }
        received = Int(readLine(child.control)) ?? -1
        var status: Int32 = 0
        waitpid(child.pid, &status, 0)
        close(child.control)
    }
    print("  after reading: \(received) of \(total) bytes" + (received == total ? "" : " (INCOMPLETE)"))
    print("  the guest program's session ended with \(finish(session).ending)")
}

func percentiles(_ samples: [Double]) -> String {
    let sorted = samples.sorted()
    return String(
        format: "median %.0f µs, 95th percentile %.0f µs, slowest %.0f µs (%d runs)",
        sorted[sorted.count / 2], sorted[sorted.count * 95 / 100], sorted[sorted.count - 1],
        sorted.count)
}

/// The time from writing a request on an open host-initiated connection to holding the
/// connection the guest dials back, and to having read the request's 16 bytes from it.
func dialBacks(_ machine: Machine, dials: AcceptQueue, count: Int) {
    let started = run([helperPath, "serve", String(servePort), String(dialPort)], on: machine)
    print("  the dial-back stand-in started: \(started.ending)")
    var control: Int32?
    for _ in 0..<50 where control == nil {
        control = machine.timedConnect(to: servePort, timeout: 2)?.descriptor
        if control == nil { usleep(100_000) }
    }
    guard let control else { fail("could not connect to the dial-back stand-in") }
    defer { close(control) }
    var accepted: [Double] = []
    var read: [Double] = []
    var ports: [UInt32] = []
    for _ in 0..<count {
        let nonce = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let start = DispatchTime.now().uptimeNanoseconds
        writeAll(control, nonce)
        guard let connection = dials.next(timeout: 5) else { fail("no dial-back") }
        guard readExactly(connection.descriptor, 16, timeout: 5) == nonce else {
            fail("the dial-back carried other bytes")
        }
        let end = DispatchTime.now().uptimeNanoseconds
        close(connection.descriptor)
        accepted.append(Double(connection.time - start) / 1000)
        read.append(Double(end - start) / 1000)
        ports.append(connection.sourcePort)
    }
    print("  request to accepted descriptor: \(percentiles(accepted))")
    print("  request to 16 bytes read from it: \(percentiles(read))")
    print(
        "  source ports reported: \(ports.min()!) to \(ports.max()!), destinationPort "
            + "\(dialPort)")

    var opened: [Double] = []
    var versions: [Double] = []
    for _ in 0..<count {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let connection = machine.timedConnect(to: agentPort, timeout: 5) else {
            fail("could not connect")
        }
        writeAll(connection.descriptor, versionFrame())
        guard readExactly(connection.descriptor, 9, timeout: 5) != nil else { fail("no version") }
        let end = DispatchTime.now().uptimeNanoseconds
        close(connection.descriptor)
        opened.append(connection.micros)
        versions.append(Double(end - start) / 1000)
    }
    print("  for comparison, connect(toPort:) to the agent: \(percentiles(opened))")
    print("  connect(toPort:) and the version exchange: \(percentiles(versions))")
}

func guestInitiatedMeasurements(kernelDirectory: URL, console: URL, helper: URL, runs: Int) {
    let machine = Machine(kernelDirectory: kernelDirectory, console: console, debugShell: true)
    let bootStarted = Date()
    while !machine.answers(within: 1) {
        if Date().timeIntervalSince(bootStarted) > 30 { fail("the agent did not answer in 30 s") }
    }
    print(String(format: "agent ready after %.1f s", Date().timeIntervalSince(bootStarted)))
    guard let probe = machine.connect(timeout: 5) else { fail("could not connect") }
    var length = socklen_t(MemoryLayout<pid_t>.size)
    getsockopt(probe, SOL_LOCAL, LOCAL_PEERPID, &machinePID, &length)
    close(probe)

    guard let program = FileManager.default.contents(atPath: helper.path) else {
        fail("cannot read \(helper.path)")
    }
    let installed = run(
        ["/bin/sh", "-c", "cat > \(helperPath) && chmod 755 \(helperPath)"],
        input: Array(program), on: machine)
    print("copied the guest program (\(program.count) bytes): \(installed.ending)")

    let streams = AcceptQueue()
    let dials = AcceptQueue()
    let pings = Pings()
    machine.listen(on: streamPort) { streams.add($0) }
    machine.listen(on: dialPort) { dials.add($0) }
    machine.listen(on: pingPort) { connection in
        DispatchQueue.global().async {
            if readExactly(connection.descriptor, 8, timeout: 2) != nil { pings.record() }
            close(connection.descriptor)
        }
    }

    print("source ports in the guest (\(helperPath) ports):")
    let ports = run([helperPath, "ports", String(pingPort)], on: machine)
    for line in ports.output.split(separator: "\n") { print("  \(line)") }
    print("  \(ports.ending)")

    print("guest connection every 100 ms: \(run([helperPath, "ping", String(pingPort), "100"], on: machine).ending)")
    print("with nothing stalled:")
    print(checks(machine, pings: pings, console: console))

    let chunks = chunkSize * chunkCount
    for index in 1...runs {
        print("host-initiated, in this process, run \(index):")
        guard let descriptor = machine.connect(timeout: 5) else { fail("could not connect") }
        print(measure(descriptor, receiveBuffer: nil, console: console))
        print(checks(machine, pings: pings, console: console))
        print(drain(descriptor))
        close(descriptor)
    }
    for index in 1...runs {
        print("host-initiated to the guest program, in this process, run \(index):")
        hostInitiatedRawRun(machine, pings: pings, console: console, total: chunks)
    }
    for index in 1...runs {
        print("guest-initiated, in this process, run \(index):")
        guestInitiatedRun(
            machine, streams: streams, pings: pings, console: console, holder: .this,
            total: chunks)
    }
    for index in 1...runs {
        print("guest-initiated, handed over, run \(index):")
        guestInitiatedRun(
            machine, streams: streams, pings: pings, console: console, holder: .handedOver,
            total: chunks)
    }
    for index in 1...runs {
        print("guest-initiated, handed over, holder reading and then stopped, run \(index):")
        guestInitiatedRun(
            machine, streams: streams, pings: pings, console: console,
            holder: .handedOverStopped, total: 1 << 30)
    }
    print("guest-initiated, in this process, 60 s stall:")
    guestInitiatedRun(
        machine, streams: streams, pings: pings, console: console, holder: .this, total: chunks,
        extraStall: 60)
    print("guest-initiated, handed over, 60 s stall:")
    guestInitiatedRun(
        machine, streams: streams, pings: pings, console: console, holder: .handedOver,
        total: chunks, extraStall: 60)

    print("dial-back:")
    dialBacks(machine, dials: dials, count: 200)
    machine.stop()
}

// MARK: Main

let arguments = CommandLine.arguments
func value(after flag: String) -> String? {
    arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
}

if let index = arguments.firstIndex(of: "--inspect") {
    for pid in arguments[(index + 1)...].compactMap({ pid_t($0) }) {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { fail("cannot list the descriptors of \(pid): \(describe(errno))") }
        var entries = [proc_fdinfo](
            repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &entries, size)
        for entry in entries.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.size)
        where entry.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            guard let info = socketInfo(pid: pid, descriptor: entry.proc_fd),
                info.psi.soi_kind == Int32(SOCKINFO_UN), info.psi.soi_type == SOCK_STREAM,
                info.psi.soi_proto.pri_un.unsi_conn_pcb != 0
            else { continue }
            print(
                "pid \(pid) fd \(entry.proc_fd) pcb "
                    + String(info.psi.soi_pcb, radix: 16) + " peer "
                    + String(info.psi.soi_proto.pri_un.unsi_conn_pcb, radix: 16))
            print("  receive: \(format(info.psi.soi_rcv))")
            print("  send:    \(format(info.psi.soi_snd))")
        }
    }
    exit(0)
}

if arguments.contains("--holder") {
    runHolder(stream: arguments.contains("--stream"))
}

if arguments.contains("--receiver") {
    guard let console = value(after: "--console") else { fail("--console is required") }
    runReceiver(
        receiveBuffer: value(after: "--rcvbuf").flatMap { Int32($0) },
        console: URL(filePath: console))
}

guard let kernelDirectory = value(after: "--kernel-dir"),
    let consolePath = value(after: "--console")
else { fail("usage: measure-vsock-buffer --kernel-dir <dir> --console <file> [--runs <n>]") }
let runs = value(after: "--runs").flatMap { Int($0) } ?? 3
let console = URL(filePath: consolePath)

signal(SIGPIPE, SIG_IGN)
if let helper = value(after: "--guest-initiated") {
    guestInitiatedMeasurements(
        kernelDirectory: URL(filePath: kernelDirectory), console: console,
        helper: URL(filePath: helper), runs: runs)
    exit(0)
}
print("sysctl net.local.stream.sendspace and recvspace, kern.ipc.maxsockbuf:")
for name in ["net.local.stream.sendspace", "net.local.stream.recvspace", "kern.ipc.maxsockbuf"] {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    sysctlbyname(name, &value, &size, nil, 0)
    print("  \(name) = \(value)")
}

let machine = Machine(kernelDirectory: URL(filePath: kernelDirectory), console: console)
let bootStarted = Date()
while !machine.answers(within: 1) {
    if Date().timeIntervalSince(bootStarted) > 30 { fail("the agent did not answer within 30 s") }
}
print(String(format: "agent ready after %.1f s", Date().timeIntervalSince(bootStarted)))

print("one byte through cat in the guest and back:")
print(roundTrips(on: machine, count: 2000))

let variants: [(name: String, receiveBuffer: Int32?, handedOver: Bool)] = [
    ("in this process, SO_RCVBUF unchanged", nil, false),
    ("in this process, SO_RCVBUF 64 KiB", 64 << 10, false),
    ("in this process, SO_RCVBUF 1 MiB", 1 << 20, false),
    ("in this process, SO_RCVBUF 8 MiB", 8 << 20, false),
    ("handed over, SO_RCVBUF unchanged", nil, true),
    ("handed over, SO_RCVBUF 1 MiB", 1 << 20, true),
]
for variant in variants {
    for run in 1...runs {
        print("\(variant.name), run \(run):")
        guard let descriptor = machine.connect(timeout: 5) else { fail("could not connect") }
        if variant.handedOver {
            let receiver = spawnReceiver(receiveBuffer: variant.receiveBuffer, console: console)
            sendDescriptor(descriptor, over: receiver.control)
            close(descriptor)
            print(readLine(receiver.control))
            print("  a second connection answers within 2 s: \(machine.answers(within: 2))")
            writeLine(receiver.control, "drain")
            print(readLine(receiver.control))
            var status: Int32 = 0
            waitpid(receiver.pid, &status, 0)
            close(receiver.control)
        } else {
            print(measure(descriptor, receiveBuffer: variant.receiveBuffer, console: console))
            print("  a second connection answers within 2 s: \(machine.answers(within: 2))")
            print(drain(descriptor))
            close(descriptor)
        }
    }
}
machine.stop()
