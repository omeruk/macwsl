import Darwin
import Foundation
import MawCore
import Testing

/// A distribution installed from the cached image, as a user meets it: the account, `sudo`,
/// systemd, the network, the terminal, and the installation itself, including cancelling it.
///
/// Every test removes the distributions it creates; scripts/integration-test.sh removes the
/// shared test distribution, and anything else under `MAW_TEST_PREFIX`, at the end.
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized
)
struct DistributionIntegrationTests {
    let maw: MawIntegration
    static let catalog = DistroCatalog.builtIn.recommendedEntry

    init() throws {
        maw = try MawIntegration()
    }

    var distribution: String { maw.distribution }

    // MARK: The account

    @Test func runsAsTheNewUserInTheHomeDirectory() async throws {
        let result = try await maw.session(["--", "id -un; pwd; echo $SHELL; hostname"])
        #expect(result.status == 0, "\(result.standardError)")
        #expect(
            result.output
                == "\(maw.user)\n/home/\(maw.user)\n/bin/bash\n\(maw.hostname(of: distribution))\n")
    }

    @Test func runsAsRootWithDashURoot() async throws {
        let result = try await maw.session(["-u", "root", "--", "id", "-u"])
        #expect(result.output == "0\n", "\(result.standardError)")
    }

    @Test func requiresThePasswordForSudo() async throws {
        let withoutPassword = try await maw.session(["-e", "sudo", "-n", "true"])
        #expect(withoutPassword.status == 1)
        #expect(withoutPassword.standardError.contains("a password is required"))
        let withPassword = try await maw.sudo("true")
        #expect(withPassword.status == 0, "\(withPassword.standardError)")
    }

    /// The agent runs commands as root, so a process inside the guest must not reach it: the
    /// kernel has no vsock loopback, and the agent refuses peers other than the host.
    @Test func keepsTheAgentOutOfReachOfGuestProcesses() async throws {
        let probe = """
            import json, socket, struct
            def frame(kind, payload): return struct.pack(">IB", len(payload), kind) + payload
            s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            s.settimeout(3)
            try:
                s.connect((1, 0x4D57))
                s.sendall(frame(1, struct.pack(">I", 2)))
                request = {"exec": {"program": {"argv": ["id", "-u"]}, "user": "root"}}
                s.sendall(frame(2, json.dumps(request).encode()))
                print("received", s.recv(4096))
            except OSError as error:
                print("refused", error)
            """
        let result = try await maw.session(
            ["-e", "python3", "-I", "-"], standardInput: Data(probe.utf8))
        #expect(result.status == 0, "\(result.standardError)")
        #expect(!result.output.contains("started"), "\(result.output)")
        #expect(
            result.output.hasPrefix("refused") || result.output.hasPrefix("received b''"),
            "\(result.output)")
    }

    @Test func reportsAUserThatDoesNotExist() async throws {
        let result = try await maw.session(["-u", "nobody-here", "-e", "true"])
        #expect(result.status == 1)
        #expect(
            result.standardError.hasPrefix(
                "maw: There is no user named 'nobody-here' in \(distribution)."),
            "\(result.standardError)")
    }

    // MARK: The system

    @Test func bootsSystemdToRunningOrDegraded() async throws {
        let result = try await maw.session([
            "--", "systemctl is-system-running --wait; systemctl --failed --no-legend",
        ])
        let state = result.lines.first ?? ""
        print("systemd state: \(result.output)")
        #expect(["running", "degraded"].contains(state), "\(result.output)")
    }

    @Test func updatesThePackageLists() async throws {
        let first = try await maw.sudo("apt-get update -q")
        #expect(first.status == 0, "\(first.output)\(first.standardError)")
        // A second update finds the lists current; it measures apt over maw's network.
        let started = ContinuousClock.now
        let second = try await maw.sudo("apt-get update -q")
        #expect(second.status == 0)
        MawIntegration.report(
            "apt-get update with a warm cache",
            [(ContinuousClock.now - started).fractionalMilliseconds])
    }

    @Test func keepsTheImagesCapabilitiesAndOwners() async throws {
        let image = maw.imageCache.appending(path: Self.catalog.image.cacheFileName)
        let entries = try PaxEntry.read(image: image)
        try #require(entries.count > 10_000, "the image has \(entries.count) entries")

        // File capabilities, such as ping's cap_net_raw, byte for byte.
        let capabilities = entries.filter { $0.capability != nil }
        try #require(!capabilities.isEmpty)
        let script = capabilities.map { entry in
            "python3 -c \"import base64,os;print(base64.b64encode(os.getxattr('/\(entry.path)', "
                + "'security.capability')).decode())\""
        }.joined(separator: "; ")
        let result = try await maw.session(["-u", "root", "--", script])
        let found = result.lines.filter { !$0.isEmpty }
        #expect(
            found == capabilities.map { $0.capability!.base64EncodedString() },
            "\(result.output)\(result.standardError)")
        let listed = try await maw.session([
            "-u", "root", "--", "getcap -r /usr /etc /opt 2>/dev/null | cut -d ' ' -f 1",
        ])
        #expect(
            Set(listed.lines.filter { !$0.isEmpty })
                == Set(capabilities.map { "/" + $0.path }), "\(listed.output)")

        // Owners and groups of regular files that belong to system users, which only a
        // numeric extraction as root keeps.
        let owned = entries.filter {
            $0.isRegularFile && ($0.uid != 0 || $0.gid != 0)
                && ($0.path.hasPrefix("usr/") || $0.path.hasPrefix("etc/"))
        }.prefix(50)
        try #require(!owned.isEmpty)
        let stat = try await maw.session(
            ["-u", "root", "--", "xargs stat -c '%u %g %n'"],
            standardInput: Data(owned.map { "/\($0.path)\n" }.joined().utf8))
        #expect(
            stat.lines.filter { !$0.isEmpty } == owned.map { "\($0.uid) \($0.gid) /\($0.path)" },
            "\(stat.output)\(stat.standardError)")
    }

    // MARK: The terminal

    @Test func echoesTurkishCharactersIntact() async throws {
        let session = try maw.interactive(["-d", distribution])
        let host = maw.hostname(of: distribution)
        try #require(await session.waitForPrompt(user: maw.user, host: host))
        let text = "çğıöşü ÇĞİÖŞÜ"
        session.type("echo '\(text)'\r")
        // Once as typed, once as printed.
        #expect(
            await session.waitForOutput(containing: text, count: 2), "\(session.plainOutput)")
        session.type("exit\r")
        #expect(await session.waitForExit(timeout: .seconds(30)) == 0)
    }

    @Test func registersShellsWithLogind() async throws {
        let session = try maw.interactive(["-d", distribution])
        let host = maw.hostname(of: distribution)
        try #require(await session.waitForPrompt(user: maw.user, host: host))
        session.type("echo runtime=$XDG_RUNTIME_DIR; systemctl --user is-system-running\r")
        #expect(
            await session.waitForOutput(containing: "runtime=/run/user/"),
            "\(session.plainOutput)")
        #expect(await session.waitForOutput(containing: "running"), "\(session.plainOutput)")
        session.type("exit\r")
        _ = await session.waitForExit(timeout: .seconds(30))
    }

    // MARK: Installing

    @Test func refusesANameThatIsInstalled() async throws {
        let before = try Data(
            contentsOf: maw.paths.metadataFile(for: try DistroName(distribution)))
        let result = await (try maw.install(distribution)).waitForExit(timeout: .seconds(60))
        #expect(result.status == 1)
        #expect(
            result.standardError.hasPrefix("maw: \(distribution) is already installed."),
            "\(result.standardError)")
        let after = try Data(
            contentsOf: maw.paths.metadataFile(for: try DistroName(distribution)))
        #expect(before == after)
        #expect(try await maw.session(["-e", "true"]).status == 0)
    }

    @Test(arguments: [
        "Verifying the image", "Creating the virtual disk", "Formatting the disk",
        "Extracting the root file system", "Configuring", "Writing the disk",
    ])
    func cancelsDuringAStepAndLeavesNothing(_ step: String) async throws {
        let name = "\(maw.prefix)-cancel"
        let install = try maw.install(name)
        let reached = await install.waitForLine(
            where: { $0.hasPrefix(step) }, timeout: .seconds(60))
        try #require(reached, "\(install.output)")
        let interrupted = ContinuousClock.now
        install.signal(SIGINT)
        let result = await install.waitForExit(timeout: .seconds(10))
        let elapsed = ContinuousClock.now - interrupted
        #expect(result.status == 130, "\(result.output)\(result.standardError)")
        #expect(elapsed < .seconds(1), "maw took \(elapsed) to exit after Ctrl-C")
        #expect(
            result.standardError.contains("maw: The installation of \(name) was cancelled."),
            "\(result.standardError)")
        #expect(maw.traces(of: name).isEmpty, "\(maw.traces(of: name))")
        try await maw.remove(name)
    }

    @Test func cancelsDuringTheDownloadAndKeepsThePartialFile() async throws {
        let name = "\(maw.prefix)-download"
        let image = maw.imageCache.appending(path: Self.catalog.image.cacheFileName)
        let aside = maw.imageCache.appending(path: "aside")
        try FileManager.default.moveItem(at: image, to: aside)
        let partial = maw.imageCache.appending(path: Self.catalog.image.cacheFileName + ".partial")
        defer {
            try? FileManager.default.removeItem(at: partial)
            try? FileManager.default.removeItem(
                at: maw.imageCache.appending(
                    path: Self.catalog.image.cacheFileName + ".partial.validator"))
            try? FileManager.default.moveItem(at: aside, to: image)
        }
        let install = try maw.install(name)
        let downloading = await install.waitForLine(
            where: { $0.hasPrefix("Downloading") }, timeout: .seconds(60))
        try #require(downloading, "\(install.output)\(install.standardError)")
        try await Task.sleep(for: .seconds(2))
        install.signal(SIGINT)
        let result = await install.waitForExit(timeout: .seconds(10))
        #expect(result.status == 130, "\(result.output)\(result.standardError)")
        #expect(maw.traces(of: name).isEmpty)
        // The partial download stays, for the next attempt to resume.
        let size =
            try FileManager.default.attributesOfItem(
                atPath: partial.path(percentEncoded: false))[.size] as? Int
        #expect((size ?? 0) > 0)
    }

    // MARK: Measurements

    @Test func measuresInstallToFirstPrompt() async throws {
        var times: [Double] = []
        for run in 1...5 {
            let name = "\(maw.prefix)-measure-\(run)"
            let started = ContinuousClock.now
            let install = await (try maw.install(name)).waitForExit(timeout: .seconds(300))
            try #require(install.status == 0, "\(install.output)\(install.standardError)")
            let session = try maw.interactive(["-d", name])
            #expect(await session.waitForPrompt(user: maw.user, host: maw.hostname(of: name)))
            times.append((ContinuousClock.now - started).fractionalMilliseconds)
            print("install steps of \(name):\n\(install.output)")
            session.type("exit\r")
            _ = await session.waitForExit(timeout: .seconds(30))
            try await maw.remove(name)
        }
        let median = MawIntegration.report(
            "install from the cached image to the first prompt", times)
        #expect(median < 45_000)
    }

    @Test func measuresColdStart() async throws {
        var times: [Double] = []
        for _ in 0..<5 {
            _ = try await maw.run(["--shutdown"])
            try await Task.sleep(for: .seconds(2))
            let (status, elapsed) = try maw.timed(["-d", distribution, "-e", "true"])
            #expect(status == 0)
            times.append(elapsed)
        }
        let median = MawIntegration.report(
            "cold start of maw -e true, machine stopped, daemon running", times)
        #expect(median < 1_500)
    }

    @Test func measuresColdStartToAPrompt() async throws {
        var times: [Double] = []
        for _ in 0..<5 {
            _ = try await maw.run(["--shutdown"])
            try await Task.sleep(for: .seconds(2))
            let started = ContinuousClock.now
            let session = try maw.interactive(["-d", distribution])
            #expect(
                await session.waitForPrompt(user: maw.user, host: maw.hostname(of: distribution)))
            times.append((ContinuousClock.now - started).fractionalMilliseconds)
            session.type("exit\r")
            _ = await session.waitForExit(timeout: .seconds(30))
        }
        let median = MawIntegration.report("cold start of maw to a prompt", times)
        #expect(median < 2_000)
    }

    @Test func measuresWarmLatency() async throws {
        #expect(try await maw.session(["-e", "true"]).status == 0)
        var times: [Double] = []
        for _ in 0..<100 {
            let (status, elapsed) = try maw.timed(["-d", distribution, "-e", "true"])
            times.append(elapsed)
            #expect(status == 0)
        }
        MawIntegration.report("warm maw -e true, the first 5 of 100", Array(times.prefix(5)))
        let median = MawIntegration.report("warm maw -e true", times)
        #expect(median < 50)
    }

    @Test func measuresWarmPrompt() async throws {
        #expect(try await maw.session(["-e", "true"]).status == 0)
        var times: [Double] = []
        for _ in 0..<5 {
            let started = ContinuousClock.now
            let session = try maw.interactive(["-d", distribution])
            #expect(
                await session.waitForPrompt(user: maw.user, host: maw.hostname(of: distribution)))
            times.append((ContinuousClock.now - started).fractionalMilliseconds)
            session.type("exit\r")
            _ = await session.waitForExit(timeout: .seconds(30))
        }
        let median = MawIntegration.report("warm maw to a prompt", times)
        #expect(median < 150)
    }
}
