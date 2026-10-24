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
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return nil }
    var entries = [proc_fdinfo](
        repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size)
    let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &entries, size)
    for entry in entries.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.size)
    where entry.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
        if let info = socketInfo(pid: pid, descriptor: entry.proc_fd),
            info.psi.soi_kind == Int32(SOCKINFO_UN),
            info.psi.soi_proto.pri_un.unsi_conn_pcb == own.psi.soi_pcb
        {
            return (pid, info)
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

final class Machine: @unchecked Sendable {
    let queue = DispatchQueue(label: "measure-vsock-buffer")
    var machine: VZVirtualMachine!
    var device: VZVirtioSocketDevice!

    init(kernelDirectory: URL, console: URL) {
        let bootLoader = VZLinuxBootLoader(kernelURL: kernelDirectory.appending(path: "Image"))
        bootLoader.initialRamdiskURL = kernelDirectory.appending(path: "initramfs.cpio.gz")
        bootLoader.commandLine = "console=hvc0"
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        do {
            serial.attachment = try VZFileSerialPortAttachment(url: console, append: false)
        } catch {
            fail("console: \(error)")
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
