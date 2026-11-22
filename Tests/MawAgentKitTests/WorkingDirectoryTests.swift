import Foundation
import MawCore
import MawProtocol
import Testing

@testable import MawAgentKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The working directory that the agent chooses, its fallback to the home directory, and the
/// login shell's helper (docs/decisions/0022-working-directory-and-logind.md).
@Suite struct WorkingDirectoryPlanTests {
    static func ubuntu(withAgent: Bool = true, initSystem: InitSystem = .systemd) -> GuestSystem {
        let base = SessionPlannerTests.ubuntu(initSystem: initSystem)
        let executables: Set<String> =
            withAgent ? ["/usr/sbin/runuser", SessionPlanner.agentPath] : ["/usr/sbin/runuser"]
        return GuestSystem(
            readFile: base.readFile, isDirectory: base.isDirectory,
            isExecutable: { executables.contains($0) }, exists: base.exists,
            availableLocales: base.availableLocales, initSystem: base.initSystem,
            currentUserID: base.currentUserID)
    }

    @Test func expandsTheHomeDirectoryOfTheUser() throws {
        for (requested, expected) in [
            ("~", "/home/ayse"), ("~/src/app", "/home/ayse/src/app"), ("~other", "~other"),
            ("/tmp", "/tmp"),
        ] {
            let plan = try SessionPlanner.plan(
                ExecRequest(program: .argv(["pwd"]), workingDirectory: requested),
                system: Self.ubuntu())
            #expect(plan.workingDirectory == expected)
        }
        #expect(SessionPlanner.expandingHome("~/a", home: "/") == "/a")
    }

    @Test func fallsBackOnlyForADirectoryThatTheHostChose() throws {
        for program in [ExecProgram.argv(["pwd"]), .shellCommand("pwd")] {
            let chosen = try SessionPlanner.plan(
                ExecRequest(
                    program: program, workingDirectory: "/mnt/mac/src", fallsBackToHome: true),
                system: Self.ubuntu())
            #expect(chosen.workingDirectory == "/mnt/mac/src")
            #expect(chosen.fallbackDirectory == "/home/ayse")
            let named = try SessionPlanner.plan(
                ExecRequest(program: program, workingDirectory: "/mnt/mac/src"),
                system: Self.ubuntu())
            #expect(named.fallbackDirectory == nil)
        }
        let home = try SessionPlanner.plan(
            ExecRequest(program: .argv(["pwd"]), fallsBackToHome: true), system: Self.ubuntu())
        #expect(home.fallbackDirectory == nil)
    }

    @Test func startsALoginShellInADirectoryThroughRunuserAndTheHelper() throws {
        for fallsBack in [true, false] {
            let plan = try SessionPlanner.plan(
                ExecRequest(
                    program: .loginShell, environment: ["TERM": "xterm"],
                    workingDirectory: "/mnt/mac/My Projects", fallsBackToHome: fallsBack),
                system: Self.ubuntu())
            #expect(plan.path == "/usr/sbin/runuser")
            #expect(
                plan.argv == [
                    "/usr/sbin/runuser", "-l", "ayse", "-w", "LANG,TERM", "-s",
                    SessionPlanner.agentPath, "--", "login-shell", "/mnt/mac/My Projects",
                    fallsBack ? "fall-back" : "exact", "/bin/bash",
                ])
            #expect(plan.workingDirectory == "/")
            #expect(plan.credentials == nil)
            #expect(plan.waitsForSystemBus)
            #expect(plan.reportsThroughHelper)
            #expect(plan.shell == ShellIdentity(position: .childOfChild, commandName: "bash"))
        }
    }

    @Test func startsALoginShellInTheHomeDirectoryThroughRunuserAlone() throws {
        let plan = try SessionPlanner.plan(ExecRequest(program: .loginShell), system: Self.ubuntu())
        #expect(plan.argv == ["/usr/sbin/runuser", "-l", "ayse", "-w", "LANG"])
        #expect(!plan.reportsThroughHelper)
    }

    @Test func startsALoginShellItselfWithoutTheHelperOrSystemd() throws {
        for system in [Self.ubuntu(withAgent: false), Self.ubuntu(initSystem: .busybox)] {
            let plan = try SessionPlanner.plan(
                ExecRequest(
                    program: .loginShell, workingDirectory: "/mnt/mac", fallsBackToHome: true),
                system: system)
            #expect(plan.argv == ["-bash"])
            #expect(plan.workingDirectory == "/mnt/mac")
            #expect(plan.fallbackDirectory == "/home/ayse")
            #expect(!plan.reportsThroughHelper)
        }
    }

    @Test func keepsMawpathsDirectoryOnThePath() {
        #expect(
            SessionPlanner.including("/usr/local/bin", in: "/usr/bin:/bin")
                == "/usr/bin:/bin:/usr/local/bin")
        #expect(
            SessionPlanner.including("/usr/local/bin", in: "/usr/local/bin:/bin")
                == "/usr/local/bin:/bin")
        #expect(SessionPlanner.including("/usr/local/bin", in: "") == "/usr/local/bin")
        #expect(
            SessionPlanner.including("/usr/local/bin", in: "/usr/local/bin/x:/bin")
                == "/usr/local/bin/x:/bin:/usr/local/bin")
    }

    @Test func namesTheReasonForAFallback() {
        func reason(_ error: Int32, _ directory: String, mounted: Bool) -> WorkingDirectoryFallback
        {
            WorkingDirectoryFallback(error: error, directory: directory, shareMounted: { mounted })
        }
        #expect(reason(ENOENT, "/mnt/mac/a", mounted: false) == .shareNotMounted)
        #expect(reason(ENOENT, "/mnt/mac", mounted: false) == .shareNotMounted)
        #expect(reason(ENOENT, "/mnt/mac/a", mounted: true) == .notFound)
        #expect(reason(ENOENT, "/mnt/macx", mounted: false) == .notFound)
        #expect(reason(EACCES, "/mnt/mac/a", mounted: true) == .permissionDenied)
        #expect(reason(EPERM, "/mnt/mac/a", mounted: true) == .permissionDenied)
        #expect(reason(ENOTDIR, "/mnt/mac/a", mounted: true) == .notADirectory)
        #expect(reason(EIO, "/mnt/mac/a", mounted: true) == .other)
    }
}

/// The login shell's helper, with its system calls recorded.
@Suite struct LoginShellHelperTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        var all: [String] { lock.withLock { calls } }
        func record(_ call: String) { lock.withLock { calls.append(call) } }
    }

    static func system(
        _ calls: Calls, changeError: Int32 = 0, isPipe: Bool = true, execError: Int32 = ENOENT
    ) -> LoginShellHelper.System {
        LoginShellHelper.System(
            changeDirectory: {
                calls.record("chdir \($0)")
                return changeError
            },
            reportDescriptorIsPipe: { isPipe },
            write: {
                calls.record("report \(LoginShellHelper.Report(bytes: $0).map { "\($0)" } ?? "?")")
            },
            closeReportDescriptor: { calls.record("close 3") },
            setEnvironment: { calls.record("setenv \($0)=\($1)") },
            execute: {
                calls.record("exec \($0) \($1)")
                return execError
            },
            printError: { calls.record("error \($0)") })
    }

    @Test func reportsAndClosesItsDescriptorBeforeTheShellStarts() {
        let calls = Calls()
        let status = LoginShellHelper.run(
            ["/mnt/mac/src", "fall-back", "/bin/bash"], system: Self.system(calls))
        #expect(status == 127)
        #expect(
            calls.all == [
                "chdir /mnt/mac/src", "report entered", "close 3", "setenv SHELL=/bin/bash",
                "exec /bin/bash [\"-bash\"]",
                "error maw-agent: cannot start /bin/bash: No such file or directory",
            ])
    }

    @Test func staysInTheHomeDirectoryWhenItMayFallBack() {
        let calls = Calls()
        _ = LoginShellHelper.run(
            ["/mnt/mac/gone", "fall-back", "/bin/zsh"],
            system: Self.system(calls, changeError: ENOENT))
        #expect(
            calls.all.prefix(3) == ["chdir /mnt/mac/gone", "report fellBack(\(ENOENT))", "close 3"])
        #expect(calls.all.contains("exec /bin/zsh [\"-zsh\"]"))
    }

    @Test func exitsWithoutAShellForADirectoryThatTheUserNamed() {
        let calls = Calls()
        let status = LoginShellHelper.run(
            ["/root", "exact", "/bin/bash"], system: Self.system(calls, changeError: EACCES))
        #expect(status == 1)
        #expect(calls.all == ["chdir /root", "report failed(\(EACCES))", "close 3"])
    }

    @Test func writesNoReportWhenDescriptorThreeIsNotAPipe() {
        let calls = Calls()
        _ = LoginShellHelper.run(
            ["/tmp", "exact", "/bin/sh"], system: Self.system(calls, isPipe: false))
        #expect(calls.all.prefix(2) == ["chdir /tmp", "close 3"])
    }

    @Test func refusesMalformedArguments() {
        for operands in [
            [], ["/tmp", "exact"], ["/tmp", "maybe", "/bin/sh"], ["tmp", "exact", "/bin/sh"],
            ["/tmp", "exact", "sh"],
        ] {
            let calls = Calls()
            #expect(LoginShellHelper.run(operands, system: Self.system(calls)) == 64)
            #expect(calls.all.count == 1)
            #expect(calls.all.first?.hasPrefix("error usage:") == true)
        }
    }

    @Test func encodesItsReportInEightBytes() {
        for report in [LoginShellHelper.Report.entered, .fellBack(ENOENT), .failed(EACCES)] {
            #expect(report.bytes.count == 8)
            #expect(LoginShellHelper.Report(bytes: report.bytes) == report)
        }
        #expect(LoginShellHelper.Report(bytes: [9, 0, 0, 0, 0, 0, 0, 0]) == nil)
        #expect(LoginShellHelper.Report(bytes: [1, 0, 0]) == nil)
    }

    /// The agent never waits for ever: end-of-file without a report, and a helper that never
    /// writes, both end the wait.
    @Test func stopsWaitingAtEndOfFileOrTheDeadline() throws {
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        let report = LoginShellHelper.Report.fellBack(ENOENT).bytes
        #expect(write(fds[1], report, 4) == 4)
        #expect(write(fds[1], Array(report[4...]), 4) == 4)
        #expect(
            LoginShellHelper.awaitReport(on: fds[0], until: .now + .seconds(5))
                == (.fellBack(ENOENT), false))
        close(fds[1])
        #expect(LoginShellHelper.awaitReport(on: fds[0], until: .now + .seconds(5)) == (nil, false))
        close(fds[0])

        try #require(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        #expect(
            LoginShellHelper.awaitReport(on: fds[0], until: .now + .milliseconds(50)) == (nil, true)
        )
    }
}

/// The fallback and the inherited descriptor in the spawn itself.
@Suite(.timeLimit(.minutes(1))) struct SpawnDirectoryTests {
    let agent = TestAgent()

    @Test func fallsBackToTheHomeDirectoryAndSaysWhy() async throws {
        let output = Output()
        let process = try await agent.client.exec(
            ExecRequest(
                program: .argv(["/bin/pwd"]), workingDirectory: "/no/such/directory",
                fallsBackToHome: true),
            output: output.handler)
        #expect(process.workingDirectoryFallback == .notFound)
        #expect(try await process.waitForExit() == .exited(code: 0))
        // The test system's home directory is /tmp, which macOS resolves to /private/tmp.
        #expect(output.standardOutput.hasSuffix("/tmp\n"))
    }

    @Test func reportsNoFallbackForADirectoryItEntered() async throws {
        let process = try await agent.client.exec(
            ExecRequest(program: .argv(["true"]), workingDirectory: "/usr", fallsBackToHome: true),
            output: Output().handler)
        #expect(process.workingDirectoryFallback == nil)
        #expect(try await process.waitForExit() == .exited(code: 0))
    }

    @Test func failsForAMissingDirectoryWithoutTheFallback() async throws {
        await #expect(
            throws: MawError.guestCommandNotStarted(
                command: "true",
                reason: "cannot change to the working directory /no/such/directory: "
                    + "No such file or directory")
        ) {
            _ = try await agent.client.exec(
                ExecRequest(program: .argv(["true"]), workingDirectory: "/no/such/directory"),
                output: Output().handler)
        }
    }

    /// Exactly descriptor 3 reaches the program when the plan names one, and no descriptor
    /// above 2 otherwise.
    @Test func passesOnlyTheInheritedDescriptor() throws {
        let script =
            "for fd in 3 4 5 6 7 8 9 10 11 12; do [ -e /dev/fd/$fd ] && echo $fd; done; true"
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        for inherited in [Optional(fds[1]), nil] {
            let plan = SpawnPlan(
                path: "/bin/sh", argv: ["sh", "-c", script], environment: [:],
                workingDirectory: "/", credentials: nil, waitsForSystemBus: false,
                inheritedDescriptor: inherited)
            let child = try ChildProcess.spawn(plan, terminal: nil)
            #expect(Self.readOutput(of: child) == (inherited == nil ? "" : "3\n"))
            child.terminate()
        }
    }

    static func readOutput(of child: ChildProcess) -> String {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let descriptor = child.outputs[0].descriptor.rawValue
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&request, 1, 100) >= 0 else { break }
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                bytes += buffer[..<count]
            } else if count == 0 {
                break
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
