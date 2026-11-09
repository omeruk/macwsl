import MawProtocol
import Testing

@testable import MawAgentKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The foreground probe's decision against a fixture `/proc`, laid out as phase 11b measured a
/// login shell in Ubuntu: `runuser` (263) started by the agent, its child `bash` (304) leading
/// its own group, and a foreground job in a group of its own.
@Suite struct ForegroundProbeTests {
    static let runuser: pid_t = 263
    static let bash: pid_t = 304
    static let bashThroughRunuser = ShellIdentity.loginShell("/bin/bash", position: .childOfChild)
    static let bashDirectly = ShellIdentity.loginShell("/bin/bash", position: .child)

    @Test func reportsNoneWhileTheShellThatRunuserStartedIsInTheForeground() throws {
        let proc = try ProcessFixture()
        proc.add(Self.bash, parent: Self.runuser, name: "bash")
        #expect(proc.answer(group: Self.bash, child: Self.runuser, Self.bashThroughRunuser) == nil)
    }

    @Test func reportsNoneWhileRunuserItselfLeadsTheForegroundGroup() throws {
        let proc = try ProcessFixture()
        proc.add(Self.runuser, parent: 1, name: "runuser")
        #expect(
            proc.answer(group: Self.runuser, child: Self.runuser, Self.bashThroughRunuser) == nil)
    }

    @Test func reportsAForegroundJobByItsLeadersName() throws {
        let proc = try ProcessFixture()
        proc.add(Self.bash, parent: Self.runuser, name: "bash")
        proc.add(346, parent: Self.bash, name: "sleep")
        #expect(
            proc.answer(group: 346, child: Self.runuser, Self.bashThroughRunuser)
                == ForegroundProcess(processGroup: 346, name: "sleep"))
    }

    @Test func reportsAGroupWhoseLeaderHasExitedWithoutAName() throws {
        let proc = try ProcessFixture()
        #expect(
            proc.answer(group: 346, child: Self.runuser, Self.bashThroughRunuser)
                == ForegroundProcess(processGroup: 346, name: nil))
    }

    @Test func reportsAZombieLeaderWithoutAName() throws {
        let proc = try ProcessFixture()
        proc.add(346, parent: Self.bash, name: "sleep", state: "Z")
        #expect(
            proc.answer(group: 346, child: Self.runuser, Self.bashThroughRunuser)
                == ForegroundProcess(processGroup: 346, name: nil))
    }

    /// `exec vim` replaces the shell's program: the leader is the shell's process, but its
    /// command name is not the shell's.
    @Test func reportsAProgramThatTheShellExeced() throws {
        let proc = try ProcessFixture()
        proc.add(Self.bash, parent: Self.runuser, name: "vim")
        #expect(
            proc.answer(group: Self.bash, child: Self.runuser, Self.bashThroughRunuser)
                == ForegroundProcess(processGroup: Self.bash, name: "vim"))

        proc.add(500, parent: 1, name: "vim")
        #expect(
            proc.answer(group: 500, child: 500, Self.bashDirectly)
                == ForegroundProcess(processGroup: 500, name: "vim"))
        proc.add(501, parent: 1, name: "bash")
        #expect(proc.answer(group: 501, child: 501, Self.bashDirectly) == nil)
    }

    /// A command's own program is the session's program, whatever its name.
    @Test func skipsTheExecCheckForSessionsThatAreNotLoginShells() throws {
        let proc = try ProcessFixture()
        proc.add(500, parent: 1, name: "vim")
        #expect(proc.answer(group: 500, child: 500, .child) == nil)
    }

    /// A group led by a process that `runuser` did not start directly, such as a shell started
    /// from the login shell, is a program.
    @Test func reportsAShellStartedFromTheLoginShellAsAProgram() throws {
        let proc = try ProcessFixture()
        proc.add(400, parent: Self.bash, name: "bash")
        #expect(
            proc.answer(group: 400, child: Self.runuser, Self.bashThroughRunuser)
                == ForegroundProcess(processGroup: 400, name: "bash"))
    }

    @Test func readsStatFromTheLastParenthesis() {
        #expect(
            ForegroundProbe.parseStatus("812 (a) (b c) S 300 812 812 34816 812 4194560")
                == ForegroundProbe.Status(state: "S", parent: 300))
        #expect(
            ForegroundProbe.parseStatus("812 (sleep) Z 1 812")
                == ForegroundProbe.Status(state: "Z", parent: 1))
        #expect(ForegroundProbe.parseStatus("812 sleep S 300") == nil)
        #expect(ForegroundProbe.parseStatus("812 (sleep)") == nil)
        #expect(ForegroundProbe.parseStatus("812 (sleep) S x") == nil)
    }

    /// The kernel keeps 15 bytes of a command name, so a shell with a longer name matches its
    /// truncated name.
    @Test func comparesALongShellNameAsTheKernelTruncatesIt() throws {
        let identity = ShellIdentity.loginShell(
            "/usr/local/bin/a-shell-with-a-long-name", position: .child)
        #expect(identity.commandName == "a-shell-with-a-")
        let proc = try ProcessFixture()
        proc.add(500, parent: 1, name: "a-shell-with-a-")
        #expect(proc.answer(group: 500, child: 500, identity) == nil)
    }
}

/// A directory laid out as `/proc`: `<pid>/stat` and `<pid>/comm`. Removed on deinit.
final class ProcessFixture {
    let directory: String
    private var pids: Set<pid_t> = []

    init() throws {
        var template = Array("/tmp/maw-proc.XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else {
            throw FixtureError(message: "mkdtemp failed with errno \(errno)")
        }
        directory = String(cString: created)
    }

    deinit {
        for pid in pids {
            remove(pid)
        }
        rmdir(directory)
    }

    var probe: ForegroundProbe { ForegroundProbe(processDirectory: directory) }

    func answer(group: pid_t, child: pid_t, _ shell: ShellIdentity) -> ForegroundProcess? {
        probe.program(inForegroundGroup: group, child: child, shell: shell)
    }

    /// Adds or replaces a process, as Linux shows it.
    func add(_ pid: pid_t, parent: pid_t, name: String, state: Character = "S") {
        let path = "\(directory)/\(pid)"
        mkdir(path, 0o755)
        pids.insert(pid)
        store(
            "\(pid) (\(name)) \(state) \(parent) \(pid) \(pid) 34816 \(pid) 4194560\n",
            in: path + "/stat")
        store(name + "\n", in: path + "/comm")
    }

    func remove(_ pid: pid_t) {
        let path = "\(directory)/\(pid)"
        unlink(path + "/stat")
        unlink(path + "/comm")
        rmdir(path)
    }

    private func store(_ text: String, in path: String) {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }
}

struct FixtureError: Error {
    var message: String
}
