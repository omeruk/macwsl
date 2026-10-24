import Darwin
import Foundation
import MawCore
import MawTestSupport
import Testing

/// What scripts/integration-test.sh sets up for the tests that run `maw`: a daemon of its own,
/// an image cache of its own, and a test distribution installed from the cached image.
///
/// | Variable | Content |
/// |----------|---------|
/// | `MAW_PATH` | the signed `maw` |
/// | `MAW_DAEMON_LABEL` | the test daemon's label, never `dev.maw.mawd` |
/// | `MAW_TEST_LOG_DIRECTORY` | the test daemon's logs |
/// | `MAW_TEST_MACHINE_IDLE_TIMEOUT` | its machine idle timeout, in seconds |
/// | `MAW_TEST_DISTRIBUTION` | the installed test distribution |
/// | `MAW_TEST_USER`, `MAW_TEST_PASSWORD` | its user and that user's password |
/// | `MAW_TEST_IMAGE_CACHE` | the test daemon's image cache |
/// | `MAW_TEST_PREFIX` | the prefix of every distribution this run may create; the script removes them all at the end |
struct MawIntegration: Sendable {
    static let environment = ProcessInfo.processInfo.environment
    static let isEnabled = environment["MAW_INTEGRATION"] == "1"

    let maw: URL
    let label: String
    let logDirectory: URL
    let machineIdleTimeout: Int
    let distribution: String
    let user: String
    let password: String
    let imageCache: URL
    let prefix: String
    let paths = MawPaths()

    init() throws {
        let environment = Self.environment
        maw = URL(
            filePath: try #require(
                environment["MAW_PATH"], "MAW_PATH must point to the signed maw."))
        label = try #require(environment["MAW_DAEMON_LABEL"])
        try #require(
            label != "dev.maw.mawd", "The integration tests must not use the installed daemon.")
        logDirectory = URL(
            filePath: try #require(environment["MAW_TEST_LOG_DIRECTORY"]),
            directoryHint: .isDirectory)
        machineIdleTimeout = Int(environment["MAW_TEST_MACHINE_IDLE_TIMEOUT"] ?? "") ?? 3
        distribution = try #require(environment["MAW_TEST_DISTRIBUTION"])
        user = try #require(environment["MAW_TEST_USER"])
        password = try #require(environment["MAW_TEST_PASSWORD"])
        imageCache = URL(
            filePath: try #require(environment["MAW_TEST_IMAGE_CACHE"]), directoryHint: .isDirectory
        )
        prefix = try #require(environment["MAW_TEST_PREFIX"])
    }

    /// The host name the distribution has, as the installer derives it from its name.
    func hostname(of distribution: String) -> String {
        distribution.lowercased().replacing(/[^a-z0-9]+/, with: "-")
    }

    // MARK: Running maw

    /// The test runner's environment without its `DYLD_*` variables. `swift test` points them
    /// at Xcode's frameworks, and dyld would search those for every maw process, which slows
    /// each launch by over a hundred milliseconds and is not what users run.
    var mawEnvironment: [String: String] {
        Self.environment.filter { !$0.key.hasPrefix("DYLD_") }
    }

    func start(_ arguments: [String], standardInput: Data? = nil) throws -> DebugBootProcess {
        try DebugBootProcess(
            executable: maw, arguments: arguments, standardInput: standardInput,
            separateStandardError: true, environment: mawEnvironment)
    }

    /// Runs maw with standard error collected separately and waits for it to exit.
    func run(
        _ arguments: [String], standardInput: Data? = nil, timeout: Duration = .seconds(60)
    ) async throws -> DebugBootProcess.Result {
        try await start(arguments, standardInput: standardInput).waitForExit(timeout: timeout)
    }

    /// `maw -d <distribution> <arguments>`, by default in the test distribution.
    func session(
        _ arguments: [String], in distribution: String? = nil, standardInput: Data? = nil
    ) async throws -> DebugBootProcess.Result {
        try await run(
            ["-d", distribution ?? self.distribution] + arguments, standardInput: standardInput)
    }

    /// A command line run as root through `sudo`, with the password on its standard input.
    func sudo(_ command: String, in distribution: String? = nil) async throws
        -> DebugBootProcess.Result
    {
        try await run(
            ["-d", distribution ?? self.distribution, "--", "sudo -S -p '' sh -c \"\(command)\""],
            standardInput: Data("\(password)\n".utf8), timeout: .seconds(300))
    }

    /// maw on a pseudo-terminal, as a user at a keyboard runs it.
    func interactive(_ arguments: [String], rows: UInt16 = 24, columns: UInt16 = 80) throws
        -> InteractiveSession
    {
        try InteractiveSession(
            executable: maw, arguments: arguments, environment: mawEnvironment, rows: rows,
            columns: columns)
    }

    /// Installs a distribution under `name` for the test user, without a terminal.
    func install(_ name: String) throws -> DebugBootProcess {
        try start(
            ["--install", "--name", name, "-u", user], standardInput: Data("\(password)\n".utf8))
    }

    /// Removes a distribution that a test created: stops the test daemon's machines and deletes
    /// its directory, as the README describes for users until phase 06.
    func remove(_ name: String) async throws {
        _ = try await run(["--shutdown"])
        let directory = paths.distroDirectory(for: try DistroName(name))
        if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// The names in the distributions directory that contain `name`, including staging
    /// directories.
    func traces(of name: String) -> [String] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                atPath: paths.distrosDirectory.path(percentEncoded: false))) ?? []
        return entries.filter { $0 == name || $0.hasPrefix("\(MawPaths.stagingPrefix)\(name)-") }
    }

    func eventually(within timeout: Duration, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return await condition()
    }

    /// Runs maw with its output discarded and returns its status and the wall-clock time
    /// from starting it to its exit, in milliseconds. Kills it after `timeout`.
    ///
    /// `posix_spawn` and a kqueue rather than `Process`: `Process.waitUntilExit()` waits on a
    /// run loop and adds tens of milliseconds, more than the latency being measured.
    func timed(_ arguments: [String], timeout: Duration = .seconds(60)) throws
        -> (status: Int32, milliseconds: Double)
    {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(
                &actions, descriptor, "/dev/null", descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY,
                0)
        }
        let argv = ([maw.path(percentEncoded: false)] + arguments).map { strdup($0) } + [nil]
        let envp = mawEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for string in argv + envp {
                free(string)
            }
        }
        var pid: pid_t = 0
        let start = ContinuousClock.now
        let error = posix_spawn(&pid, argv[0], &actions, nil, argv, envp)
        try #require(error == 0, "posix_spawn failed with error \(error)")
        let status = Self.reap(pid, within: timeout)
        let elapsed = ContinuousClock.now - start
        let exited = try #require(status, "maw \(arguments) did not exit within \(timeout).")
        // WEXITSTATUS, which Swift does not import.
        return ((exited >> 8) & 0xFF, elapsed.fractionalMilliseconds)
    }

    /// Waits for the child `pid` to exit, at most `timeout`, and returns its wait status. After
    /// `timeout`, kills it and returns `nil`.
    static func reap(_ pid: pid_t, within timeout: Duration) -> Int32? {
        let queue = kqueue()
        defer { close(queue) }
        var change = kevent(
            ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: NOTE_EXIT, data: 0, udata: nil)
        var event = kevent()
        var limit = timespec(
            tv_sec: Int(timeout.components.seconds),
            tv_nsec: Int(timeout.components.attoseconds / 1_000_000_000))
        // A child that has already exited makes the registration fail, which also returns.
        var ready: Int32
        repeat {
            ready = kevent(queue, &change, 1, &event, 1, &limit)
        } while ready < 0 && errno == EINTR
        if ready == 0 {
            kill(pid, SIGKILL)
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return ready == 0 ? nil : status
    }

    /// `measurement: <what>, 5 runs: 1, 2, 3, 4, 5 ms; median 3 ms, slowest 5 ms`, which the
    /// pull request quotes. Returns the median, or infinity if no run succeeded.
    @discardableResult
    static func report(_ what: String, _ times: [Double], unit: String = "ms") -> Double {
        guard !times.isEmpty else {
            print("measurement: \(what), no successful runs")
            return .infinity
        }
        let sorted = times.sorted()
        let median =
            sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        print(
            "measurement: \(what), \(times.count) runs: "
                + times.map { String(format: "%.0f", $0) }.joined(separator: ", ")
                + " \(unit); median "
                + String(format: "%.0f %@, slowest %.0f %@", median, unit, sorted.last ?? 0, unit))
        return median
    }
}

extension Duration {
    var fractionalMilliseconds: Double {
        Double(components.seconds) * 1e3 + Double(components.attoseconds) / 1e15
    }
}

extension InteractiveSession {
    /// The output without terminal escape sequences, such as the colors of Ubuntu's prompt and
    /// the window title it sets.
    var plainOutput: String {
        output.replacing(/\u{1B}\[[0-9;?]*[A-Za-z]/, with: "")
            .replacing(/\u{1B}\][^\u{07}]*\u{07}/, with: "")
    }

    /// Waits until the shell prompt of `user` on `host` has appeared `count` times.
    func waitForPrompt(
        user: String, host: String, count: Int = 1, timeout: Duration = .seconds(30)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if promptCount(user: user, host: host) >= count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// How often the shell prompt of `user` on `host` has appeared so far. Readline draws the
    /// prompt again when the window size changes, so a count taken before an action is a
    /// better reference for the next prompt than a fixed number.
    func promptCount(user: String, host: String) -> Int {
        plainOutput.components(separatedBy: "\(user)@\(host):").dropFirst()
            .filter { $0.firstMatch(of: #/^\S*\$ /#) != nil }.count
    }
}

/// The entries of a pax archive, as `/usr/bin/tar -cf - --format pax @<image>` writes it from
/// a distribution image: each entry's path, type, owner, group, and file capabilities.
struct PaxEntry: Equatable {
    var path: String
    var type: UInt8
    var uid: Int
    var gid: Int
    /// The raw `security.capability` attribute, if the entry has one.
    var capability: Data?

    var isRegularFile: Bool { type == UInt8(ascii: "0") || type == 0 }

    /// Reads every entry of `image` through `/usr/bin/tar`.
    static func read(image: URL) throws -> [PaxEntry] {
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = [
            "-c", "-f", "-", "--format", "pax", "@" + image.path(percentEncoded: false),
        ]
        let output = Pipe()
        tar.standardOutput = output
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        let watchdog = tar.terminate(after: .seconds(300))
        defer { watchdog.cancel() }
        let reader = BlockReader(output.fileHandleForReading)
        var entries: [PaxEntry] = []
        var pending: [String: Data] = [:]
        while let header = try reader.block(), header.contains(where: { $0 != 0 }) {
            let size = octal(header[124..<136])
            let type = header[156]
            let data = try reader.bytes(size)
            switch type {
            case UInt8(ascii: "x"):
                pending = records(data)
            case UInt8(ascii: "g"):
                continue
            default:
                let name = string(header[0..<100])
                let prefix = string(header[345..<500])
                let headerPath = prefix.isEmpty ? name : "\(prefix)/\(name)"
                var capability = pending["SCHILY.xattr.security.capability"]
                if capability == nil, let encoded = pending["LIBARCHIVE.xattr.security.capability"]
                {
                    // libarchive writes base64 without padding.
                    let text = String(decoding: encoded, as: UTF8.self)
                    capability = Data(
                        base64Encoded: text
                            + String(repeating: "=", count: (4 - text.count % 4) % 4))
                }
                entries.append(
                    PaxEntry(
                        path: pending["path"].map { String(decoding: $0, as: UTF8.self) }
                            ?? headerPath,
                        type: type,
                        uid: pending["uid"].flatMap { Int(String(decoding: $0, as: UTF8.self)) }
                            ?? octal(header[108..<116]),
                        gid: pending["gid"].flatMap { Int(String(decoding: $0, as: UTF8.self)) }
                            ?? octal(header[116..<124]),
                        capability: capability))
                pending = [:]
            }
        }
        tar.terminate()
        tar.waitForExitSynchronously(within: .seconds(10))
        return entries
    }

    /// Pax records, `<length> <key>=<value>\n`, whose values may be binary.
    private static func records(_ data: Data) -> [String: Data] {
        var records: [String: Data] = [:]
        var index = data.startIndex
        while index < data.endIndex {
            guard let space = data[index...].firstIndex(of: UInt8(ascii: " ")),
                let length = Int(String(decoding: data[index..<space], as: UTF8.self)),
                length > 0, index + length <= data.endIndex
            else { break }
            let record = data[(space + 1)..<(index + length - 1)]
            if let equals = record.firstIndex(of: UInt8(ascii: "=")) {
                records[String(decoding: record[record.startIndex..<equals], as: UTF8.self)] =
                    Data(record[(equals + 1)...])
            }
            index += length
        }
        return records
    }

    private static func octal(_ bytes: Data) -> Int {
        Int(string(bytes).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
    }

    private static func string(_ bytes: Data) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Reads 512-byte blocks from a pipe.
    private final class BlockReader {
        private let handle: FileHandle
        private var buffer = Data()

        init(_ handle: FileHandle) {
            self.handle = handle
        }

        func block() throws -> Data? {
            try fill(512) ? take(512) : nil
        }

        /// `count` bytes of content, and the padding to the next block.
        func bytes(_ count: Int) throws -> Data {
            let padded = (count + 511) / 512 * 512
            guard try fill(padded) else { return Data() }
            return take(padded).prefix(count)
        }

        private func fill(_ count: Int) throws -> Bool {
            while buffer.count < count {
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else {
                    return false
                }
                buffer.append(chunk)
            }
            return true
        }

        private func take(_ count: Int) -> Data {
            let taken = Data(buffer.prefix(count))
            buffer.removeFirst(count)
            return taken
        }
    }
}
