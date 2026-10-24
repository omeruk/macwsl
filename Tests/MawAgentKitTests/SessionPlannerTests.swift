import MawProtocol
import Testing

@testable import MawAgentKit

/// The agent plans a session in a guest whose root is the agent (uid 0) and whose files come
/// from Ubuntu.
@Suite struct SessionPlannerTests {
    static let passwd = """
        root:x:0:0:root:/root:/bin/bash
        daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
        ayse:x:1000:1000:Ayşe,,,:/home/ayse:/bin/bash
        bare:x:1001:1001::/home/bare:

        """
    static let group = """
        root:x:0:
        tty:x:5:
        adm:x:4:syslog,ayse
        sudo:x:27:ayse
        users:x:100: ayse , bare
        ayse:x:1000:
        bare:x:1001:

        """
    static let loginDefs = """
        # comment
        ENV_SUPATH\tPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        ENV_PATH\tPATH=/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games

        """

    static func ubuntu(
        mawConf: String? = "[user]\ndefault = ayse\n", initSystem: InitSystem = .systemd,
        locales: [String] = ["C.utf8", "tr_TR.utf8"], runtimeDirectories: Set<String> = []
    ) -> GuestSystem {
        var files = [
            "/etc/passwd": passwd, "/etc/group": group, "/etc/login.defs": loginDefs,
        ]
        files["/etc/maw.conf"] = mawConf
        let fixedFiles = files
        let directories = Set(["/root", "/home/ayse"]).union(runtimeDirectories)
        return GuestSystem(
            readFile: { fixedFiles[$0] },
            isDirectory: { directories.contains($0) },
            isExecutable: { $0 == "/usr/sbin/runuser" },
            exists: { fixedFiles[$0] != nil || directories.contains($0) },
            availableLocales: { locales },
            initSystem: { initSystem },
            currentUserID: 0)
    }

    @Test func runsAsTheDefaultUserFromMawConf() throws {
        let plan = try SessionPlanner.plan(
            ExecRequest(program: .argv(["id"]), locale: "tr_TR.UTF-8"), system: Self.ubuntu())
        #expect(plan.argv == ["id"])
        #expect(plan.path == nil)
        #expect(plan.credentials == Credentials(uid: 1000, gid: 1000, groups: [1000, 4, 27, 100]))
        #expect(plan.workingDirectory == "/home/ayse")
        #expect(
            plan.environment == [
                "HOME": "/home/ayse", "USER": "ayse", "LOGNAME": "ayse", "SHELL": "/bin/bash",
                "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games",
                "LANG": "tr_TR.UTF-8",
            ])
        #expect(!plan.waitsForSystemBus)
    }

    @Test func givesTheTerminalToTheUser() throws {
        let plan = try SessionPlanner.plan(
            ExecRequest(program: .loginShell), system: Self.ubuntu(initSystem: .busybox))
        #expect(plan.terminalOwner == TerminalOwner(uid: 1000, gid: 5))
        let root = try SessionPlanner.plan(
            ExecRequest(program: .loginShell, user: "root"), system: Self.ubuntu())
        // The agent is root already; the terminal stays as it is.
        #expect(root.terminalOwner == nil)
    }

    @Test func runsAsRootWithoutADefaultUser() throws {
        let plan = try SessionPlanner.plan(
            ExecRequest(program: .argv(["id"])), system: Self.ubuntu(mawConf: nil))
        // The agent is root already, so nothing is switched.
        #expect(plan.credentials == nil)
        #expect(plan.environment["USER"] == "root")
        #expect(plan.environment["PATH"] == LoginDefinitions.defaultRootPath)
        #expect(plan.workingDirectory == "/root")
    }

    @Test func runsAsTheRequestedUser() throws {
        let plan = try SessionPlanner.plan(
            ExecRequest(program: .argv(["id"]), user: "root"), system: Self.ubuntu())
        #expect(plan.credentials == nil)
        #expect(plan.environment["HOME"] == "/root")
    }

    @Test func reportsAUserThatDoesNotExist() {
        #expect(
            throws: SpawnFailure(
                code: .userNotFound, message: "there is no user named 'bob' in /etc/passwd",
                user: "bob")
        ) {
            try SessionPlanner.plan(
                ExecRequest(program: .argv(["id"]), user: "bob"), system: Self.ubuntu())
        }
        #expect(throws: SpawnFailure.self) {
            try SessionPlanner.plan(
                ExecRequest(program: .argv(["id"])),
                system: Self.ubuntu(mawConf: "[user]\ndefault = gone\n"))
        }
    }

    @Test func runsAShellCommandWithTheUsersShell() throws {
        let plan = try SessionPlanner.plan(
            ExecRequest(program: .shellCommand("echo $HOME")), system: Self.ubuntu())
        #expect(plan.path == "/bin/bash")
        #expect(plan.argv == ["/bin/bash", "-c", "echo $HOME"])
    }

    @Test func usesBinShForAnAccountWithoutAShell() throws {
        let plan = try SessionPlanner.plan(
            ExecRequest(program: .shellCommand("true"), user: "bare"), system: Self.ubuntu())
        #expect(plan.argv == ["/bin/sh", "-c", "true"])
        // Its home does not exist, so it starts in /.
        #expect(plan.workingDirectory == "/")
    }

    @Test func startsLoginShellsThroughRunuserUnderSystemd() throws {
        let plan = try SessionPlanner.plan(
            ExecRequest(
                program: .loginShell, locale: "tr_TR.UTF-8", environment: ["TERM": "xterm-256color"]
            ),
            system: Self.ubuntu())
        #expect(plan.path == "/usr/sbin/runuser")
        #expect(plan.argv == ["/usr/sbin/runuser", "-l", "ayse", "-w", "LANG,TERM"])
        #expect(plan.credentials == nil)
        #expect(plan.environment["LANG"] == "tr_TR.UTF-8")
        #expect(plan.waitsForSystemBus)
    }

    @Test func startsLoginShellsItselfWithoutSystemd() throws {
        let plan = try SessionPlanner.plan(
            ExecRequest(program: .loginShell), system: Self.ubuntu(initSystem: .busybox))
        #expect(plan.path == "/bin/bash")
        #expect(plan.argv == ["-bash"])
        #expect(plan.credentials?.uid == 1000)
        #expect(plan.workingDirectory == "/home/ayse")
        #expect(!plan.waitsForSystemBus)
    }

    @Test func startsALoginShellInARequestedDirectoryItself() throws {
        // runuser -l always changes to the home directory.
        let plan = try SessionPlanner.plan(
            ExecRequest(program: .loginShell, workingDirectory: "/tmp"), system: Self.ubuntu())
        #expect(plan.argv == ["-bash"])
        #expect(plan.workingDirectory == "/tmp")
    }

    @Test func fallsBackToCUTF8WithoutTheHostsLocale() throws {
        let plan = try SessionPlanner.plan(
            ExecRequest(program: .argv(["locale"]), locale: "en_TR.UTF-8"), system: Self.ubuntu())
        #expect(plan.environment["LANG"] == "C.UTF-8")
    }

    @Test func setsTheRuntimeDirectoryWhenItExists() throws {
        let plan = try SessionPlanner.plan(
            ExecRequest(program: .argv(["true"])),
            system: Self.ubuntu(runtimeDirectories: ["/run/user/1000"]))
        #expect(plan.environment["XDG_RUNTIME_DIR"] == "/run/user/1000")
    }

    @Test func appliesTheRequestsVariablesLast() throws {
        let plan = try SessionPlanner.plan(
            ExecRequest(program: .argv(["env"]), environment: ["LANG": "C", "EDITOR": "vi"]),
            system: Self.ubuntu())
        #expect(plan.environment["LANG"] == "C")
        #expect(plan.environment["EDITOR"] == "vi")
    }
}

@Suite struct UserDatabaseTests {
    @Test func readsAnAccountAndItsGroups() {
        let account = UserDatabase.account(
            named: "ayse", passwd: SessionPlannerTests.passwd, group: SessionPlannerTests.group)
        #expect(
            account
                == Account(
                    name: "ayse", uid: 1000, gid: 1000, home: "/home/ayse", shell: "/bin/bash",
                    groups: [1000, 4, 27, 100]))
    }

    @Test func ignoresMalformedLinesAndPrefixes() {
        let passwd = "ays:x:1:1::/:/bin/sh\nbroken\nayse:x:notanumber:1::/:/bin/sh\n"
        #expect(UserDatabase.account(named: "ayse", passwd: passwd, group: "") == nil)
        #expect(UserDatabase.account(named: "ays", passwd: passwd, group: "")?.uid == 1)
    }

    @Test func readsThePathForLoginSessions() {
        #expect(
            LoginDefinitions.path(forRoot: false, loginDefs: SessionPlannerTests.loginDefs)
                == "/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games")
        #expect(
            LoginDefinitions.path(forRoot: true, loginDefs: nil)
                == LoginDefinitions.defaultRootPath)
    }
}

@Suite struct LocaleArchiveTests {
    /// An archive in glibc's layout with two names and one empty slot.
    static func archive(names: [String]) -> [UInt8] {
        func word(_ value: Int) -> [UInt8] {
            [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: value >> $0) }
        }
        let headerSize = 64
        let tableOffset = headerSize
        let slots = names.count + 1
        let stringsOffset = tableOffset + slots * 12
        var strings: [UInt8] = []
        var table: [UInt8] = []
        for name in names {
            table += word(0x1234) + word(stringsOffset + strings.count) + word(4096)
            strings += Array(name.utf8) + [0]
        }
        table += word(0) + word(0) + word(0)
        var header = word(Int(LocaleArchive.magic)) + word(0) + word(tableOffset)
        header += word(names.count) + word(slots)
        header += [UInt8](repeating: 0, count: headerSize - header.count)
        return header + table + strings
    }

    @Test func listsTheLocalesInAnArchive() {
        let bytes = Self.archive(names: ["tr_TR.utf8", "en_US.utf8"])
        #expect(LocaleArchive.names(in: bytes) == ["tr_TR.utf8", "en_US.utf8"])
    }

    @Test func listsNothingForOtherFiles() {
        #expect(LocaleArchive.names(in: []) == [])
        #expect(LocaleArchive.names(in: Array("not an archive at all".utf8)) == [])
        var truncated = Self.archive(names: ["tr_TR.utf8"])
        truncated.removeLast(20)
        #expect(LocaleArchive.names(in: truncated).allSatisfy { !$0.isEmpty })
    }
}
