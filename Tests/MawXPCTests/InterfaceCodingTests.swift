import Foundation
import MawCore
import Testing
import XPC

@testable import MawXPC

@Suite struct InterfaceCodingTests {
    static let info = DaemonInfo(version: "0.1.0", processID: 4242, interfaceVersion: 1)

    static let requests: [DaemonRequest] = [
        .hello(clientVersion: "0.1.0"),
        .openSession(.initramfs),
        .openSession(.distribution(try! DistroName("Ubuntu-24.04"))),
        .openSession(nil),
        .status,
        .shutdown,
        .install(
            InstallRequest(
                distribution: "Ubuntu", name: try! DistroName("Work"), user: "ayse",
                password: Secret("correct horse"), locale: "tr_TR.UTF-8")),
        .install(
            InstallRequest(distribution: nil, user: "ayse", password: Secret("x"), locale: nil)),
        .checkInstall(distribution: "Ubuntu", name: try! DistroName("Work")),
        .checkInstall(distribution: nil, name: nil),
        .cancel,
        .listDistributions,
        .setDefault(try! DistroName("ubuntu-24.04")),
        .terminate(try! DistroName("Ubuntu-24.04")),
        .watchDistributions(after: 0),
        .watchDistributions(after: .max),
        .checkUnregister(try! DistroName("copy")),
        .unregister(try! DistroName("Copy")),
        .checkExport(try! DistroName("ubuntu-24.04")),
        .export(ExportRequest(name: try! DistroName("Ubuntu-24.04"), format: .tar)),
        .export(ExportRequest(name: try! DistroName("Ubuntu-24.04"), format: .tarGzip)),
        .export(ExportRequest(name: try! DistroName("Ubuntu-24.04"), format: .tarXz)),
        .import(
            ImportRequest(
                name: try! DistroName("Copy"), user: "ayse",
                archive: "/Users/ayse/Desktop/ubuntu.tar")),
        .import(
            ImportRequest(
                name: try! DistroName("Copy"), user: nil,
                archive: DistroMetadata.ImportOrigin.standardInput)),
    ]

    static let replies: [DaemonReply] = [
        .welcome(info),
        .sessionOpened(SessionInfo(sessionID: 7, machine: .initramfs)),
        .status(
            DaemonStatus(
                daemon: info, uptimeMilliseconds: 12_000, canRunVirtualMachines: true,
                machines: [
                    MachineStatus(
                        machine: .initramfs, state: .running, uptimeMilliseconds: 9_000,
                        cpuCount: 4, memoryBytes: 2 << 30, sessionCount: 2),
                    MachineStatus(
                        machine: .distribution(try! DistroName("Debian")), state: .starting,
                        uptimeMilliseconds: nil, cpuCount: 2, memoryBytes: 1 << 30,
                        sessionCount: 0),
                ])),
        .installed(
            InstallSummary(
                name: try! DistroName("Ubuntu-24.04"), displayName: "Ubuntu 24.04 LTS",
                defaultUser: "ayse", isDefault: true, milliseconds: 15_000)),
        .installPossible,
        .cancelled(wasRunning: true),
        .shutdownComplete(ShutdownSummary(stoppedMachines: [.initramfs], endedSessions: 2)),
        .distributions(
            DistributionList(
                distributions: DistributionState.allCases.enumerated().map { index, state in
                    DistributionEntry(name: try! DistroName("Distro-\(index)"), state: state)
                },
                defaultDistribution: try! DistroName("Distro-1"))),
        .distributions(DistributionList(distributions: [], defaultDistribution: nil)),
        .defaultSet(try! DistroName("Ubuntu-24.04")),
        .terminated(TerminateSummary(wasRunning: true, endedSessions: 3)),
        .terminated(TerminateSummary(wasRunning: false, endedSessions: 0)),
        .distributionSnapshot(
            DistributionSnapshot(sequence: 7, distributions: [], defaultDistribution: nil)),
        .distributionSnapshot(
            DistributionSnapshot(
                sequence: 8, distributions: [InterfaceCodingTests.runningFigures],
                defaultDistribution: try! DistroName("Ubuntu-24.04"))),
        .unregisterPossible(try! DistroName("Copy")),
        .unregistered(
            UnregisterSummary(
                name: try! DistroName("Copy"), newDefault: try! DistroName("Ubuntu-24.04"),
                endedSessions: 1)),
        .unregistered(
            UnregisterSummary(name: try! DistroName("Copy"), newDefault: nil, endedSessions: 0)),
        .exportPossible(try! DistroName("Ubuntu-24.04")),
        .exported(
            ExportSummary(
                name: try! DistroName("Ubuntu-24.04"), format: .tarXz, bytes: 1_300_000_000,
                milliseconds: 9_800)),
        .imported(
            ImportSummary(
                name: try! DistroName("Copy"), defaultUser: "ayse", defaultUserSource: .mawConf,
                isDefault: false, extractedBytes: 1_350_625_280, milliseconds: 12_400,
                firstStartFailure: nil)),
        .imported(
            ImportSummary(
                name: try! DistroName("Copy"), defaultUser: "root", defaultUserSource: .fallback,
                isDefault: true, extractedBytes: 1_024, milliseconds: 40_000,
                firstStartFailure: .importStartFailed(
                    try! DistroName("Copy"), consoleLog: "/Users/ayse/Library/Logs/maw/Copy.log",
                    reason: "the guest agent did not answer"))),
        .failure(.distributionBusy(try! DistroName("Copy"), operation: .removal)),
        .failure(.distributionBusy(try! DistroName("Copy"), operation: .import)),
        .failure(.installationInProgress(try! DistroName("Copy"), by: .import)),
        .failure(
            .insufficientDiskSpace(
                required: 5 << 30, available: 1 << 30, volume: "Macintosh HD", for: .import)),
        .failure(.importNotARootFileSystem(try! DistroName("Copy"), found: "rootfs/")),
        .failure(.distributionRunning(try! DistroName("Ubuntu-24.04"))),
        .failure(.virtualizationEntitlementMissing),
        .failure(.distributionNotInstalled(try! DistroName("Ubuntu"))),
    ]

    static let events: [DaemonEvent] = [
        .sessionEnded(
            SessionEnded(sessionID: 7, machine: .initramfs, reason: "maw --shutdown was run")),
        .installProgress(.started(.extract)),
        .installProgress(.finished(.extract, milliseconds: 5_512)),
        .installProgress(.started(.check)),
        .installProgress(.finished(.archive, milliseconds: 9_100)),
        .installProgress(.started(.inspect)),
        .installProgress(.finished(.inspect, milliseconds: 310)),
        .installProgress(
            .download(
                DownloadProgress(
                    receivedBytes: 1_000, totalBytes: 388_300_496, bytesPerSecond: 5_000_000,
                    resumedFromBytes: 0))),
    ]

    @Test func neverDescribesAPassword() throws {
        let request = DaemonRequest.install(
            InstallRequest(
                distribution: nil, user: "ayse", password: Secret("hunter2-secret"), locale: nil))
        for text in [
            String(describing: request), String(reflecting: request), "\(request)",
            String(describing: Mirror(reflecting: request).children.map(\.value)),
        ] {
            #expect(!text.contains("hunter2-secret"), "\(text)")
        }
        // The encoded message carries it, for the daemon only.
        let message = try InterfaceCoding.encode(request)
        #expect(
            try InterfaceCoding.decode(DaemonRequest.self, from: message, as: .daemon) == request)
    }

    @Test(arguments: requests)
    func roundTripsARequest(_ request: DaemonRequest) throws {
        let message = try InterfaceCoding.encode(request)
        #expect(
            try InterfaceCoding.decode(DaemonRequest.self, from: message, as: .daemon) == request)
    }

    @Test(arguments: replies)
    func roundTripsAReply(_ reply: DaemonReply) throws {
        let message = try InterfaceCoding.encode(reply)
        #expect(try InterfaceCoding.decode(DaemonReply.self, from: message, as: .client) == reply)
    }

    @Test(arguments: events)
    func roundTripsAnEvent(_ event: DaemonEvent) throws {
        let message = try InterfaceCoding.encode(event)
        #expect(try InterfaceCoding.decode(DaemonEvent.self, from: message, as: .client) == event)
    }

    /// Version 8 adds `macShare` to each distribution's figures.
    @Test func isInterfaceVersion8() {
        #expect(DaemonInterface.version == 8)
    }

    /// A snapshot without `macShare` reads as a distribution without the share mounted.
    @Test func carriesTheMacShareOfADistribution() throws {
        let encoded = try JSONEncoder().encode(Self.runningFigures)
        let decoded = try JSONDecoder().decode(DistributionFigures.self, from: encoded)
        #expect(decoded.macShare == SharedDirectory(macPath: "/Users/ayse", linuxPath: "/mnt/mac"))
        var without = Self.runningFigures
        without.macShare = nil
        let text = String(decoding: try JSONEncoder().encode(without), as: UTF8.self)
        #expect(!text.contains("macShare"))
        #expect(
            try JSONDecoder().decode(DistributionFigures.self, from: Data(text.utf8)).macShare
                == nil)
    }

    /// The installation's steps are unchanged; an export and an import have steps of their
    /// own.
    @Test func ordersEachOperationsSteps() {
        #expect(
            InstallStep.installation.map(\.rawValue) == [
                "download", "verify", "prepare", "format", "extract", "configure", "finish",
                "start",
            ])
        #expect(InstallStep.export == [.prepare, .check, .archive, .finish])
        #expect(
            InstallStep.import == [
                .prepare, .format, .extract, .inspect, .configure, .finish, .start,
            ])
        #expect(
            Set(InstallStep.installation + InstallStep.export + InstallStep.import)
                == Set(InstallStep.allCases))
    }

    /// A running distribution with every figure.
    static var runningFigures: DistributionFigures {
        var figures = DistributionFigures(
            name: try! DistroName("Ubuntu-24.04"), state: .running, defaultUser: "ayse",
            diskImagePath:
                "/Users/ayse/Library/Application Support/maw/distros/Ubuntu-24.04/disk.img")
        figures.diskAllocatedBytes = 2_376_101_888
        figures.diskSizeBytes = 274_877_906_944
        figures.kernelRelease = "6.18.57-maw"
        figures.run = 3
        figures.uptimeMilliseconds = 37_000
        figures.bootMilliseconds = 271
        figures.memoryLimitBytes = 8 << 30
        figures.memoryUsedBytes = 412 << 20
        figures.ipv4Address = "192.168.64.3"
        figures.cpuPercent = 0.4
        figures.hostMemoryBytes = 710 << 20
        figures.lastSampleMicroseconds = 1_250
        figures.sampleNumber = 12
        figures.macShare = SharedDirectory(macPath: "/Users/ayse", linuxPath: "/mnt/mac")
        return figures
    }

    @Test func namesTheNewRequestsInErrorMessages() throws {
        let name = try DistroName("Ubuntu-24.04")
        #expect(DaemonRequest.listDistributions.displayName == "listing the distributions")
        #expect(DaemonRequest.setDefault(name).displayName == "setting the default distribution")
        #expect(DaemonRequest.terminate(name).displayName == "terminating the distribution")
        #expect(
            DaemonRequest.watchDistributions(after: 0).displayName == "watching the distributions")
        #expect(DaemonRequest.checkUnregister(name).displayName == "checking the removal")
        #expect(DaemonRequest.unregister(name).displayName == "the removal")
        #expect(DaemonRequest.checkExport(name).displayName == "checking the export")
        #expect(
            DaemonRequest.export(ExportRequest(name: name, format: .tar)).displayName
                == "the export")
        #expect(
            DaemonRequest.import(ImportRequest(name: name, user: nil, archive: "/a.tar"))
                .displayName == "the import")
        #expect(DaemonRequest.cancel.displayName == "the cancellation")
    }

    /// The states travel as their names, so that the terminal app and later versions can read
    /// them without a table.
    @Test func encodesTheStatesByName() throws {
        let data = try JSONEncoder().encode(DistributionState.allCases)
        #expect(
            String(decoding: data, as: UTF8.self) == #"["stopped","starting","running","stopping"]"#
        )
    }

    @Test func carriesTheVersionOutsideTheBody() throws {
        let message = try InterfaceCoding.encode(DaemonRequest.status)
        #expect(InterfaceCoding.version(of: message) == DaemonInterface.version)
        #expect(
            xpc_dictionary_get_uint64(message.raw, "interfaceVersion")
                == UInt64(DaemonInterface.version))
    }

    @Test func reportsANewerDaemonToTheClient() throws {
        let current = DaemonInterface.version
        let message = try InterfaceCoding.encode(
            DaemonReply.welcome(Self.info), version: current + 1)
        #expect(throws: MawError.daemonVersionMismatch(client: current, daemon: current + 1)) {
            try InterfaceCoding.decode(DaemonReply.self, from: message, as: .client)
        }
    }

    @Test func reportsANewerClientToTheDaemon() throws {
        let current = DaemonInterface.version
        let message = try InterfaceCoding.encode(
            DaemonRequest.hello(clientVersion: "9.9.9"), version: current + 1)
        #expect(throws: MawError.daemonVersionMismatch(client: current + 1, daemon: current)) {
            try InterfaceCoding.decode(DaemonRequest.self, from: message, as: .daemon)
        }
    }

    @Test func checksTheVersionBeforeTheBody() throws {
        // A body from another version may not decode at all; the version must win.
        let current = DaemonInterface.version
        let message = try InterfaceCoding.encode(
            ["unknownRequest": [String: String]()], version: current + 2)
        #expect(throws: MawError.daemonVersionMismatch(client: current, daemon: current + 2)) {
            try InterfaceCoding.decode(DaemonReply.self, from: message, as: .client)
        }
    }

    @Test func rejectsAMessageWithoutAVersion() {
        let message = XPCObject(xpc_dictionary_create_empty())
        #expect(throws: MawError.daemonProtocolError(reason: "a message has no interface version"))
        {
            try InterfaceCoding.decode(DaemonRequest.self, from: message, as: .daemon)
        }
    }

    @Test func rejectsABodyItCannotDecode() throws {
        let message = try InterfaceCoding.encode(["unknownRequest": [String: String]()])
        #expect {
            try InterfaceCoding.decode(DaemonRequest.self, from: message, as: .daemon)
        } throws: { error in
            guard case .daemonProtocolError = error as? MawError else { return false }
            return true
        }
    }

    @Test func carriesADescriptor() throws {
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        let message = try InterfaceCoding.encode(
            DaemonReply.sessionOpened(SessionInfo(sessionID: 1, machine: .initramfs)),
            descriptor: fds[1])
        let received = try #require(try InterfaceCoding.descriptor(in: message))
        #expect(received.rawValue != fds[1], "The message must hold a duplicate.")
        #expect(fcntl(received.rawValue, F_GETFD) & FD_CLOEXEC != 0)

        var byte: UInt8 = 42
        #expect(write(received.rawValue, &byte, 1) == 1)
        byte = 0
        #expect(read(fds[0], &byte, 1) == 1)
        #expect(byte == 42)
    }

    /// An export request carries the client's descriptor of the archive, which the daemon
    /// writes: the duplicate it receives writes into the client's file.
    @Test func carriesTheArchiveDescriptorOfAnExport() throws {
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        let request = DaemonRequest.export(
            ExportRequest(name: try DistroName("Ubuntu-24.04"), format: .tarGzip))
        let message = try InterfaceCoding.encode(request, descriptor: fds[1])
        #expect(
            try InterfaceCoding.decode(DaemonRequest.self, from: message, as: .daemon) == request)
        let received = try #require(try InterfaceCoding.descriptor(in: message))
        #expect(received.rawValue != fds[1], "The message must hold a duplicate.")
        #expect(fcntl(received.rawValue, F_GETFD) & FD_CLOEXEC != 0)
        #expect(fcntl(received.rawValue, F_GETFL) & O_ACCMODE == O_WRONLY)

        var byte: UInt8 = 7
        #expect(write(received.rawValue, &byte, 1) == 1)
        byte = 0
        #expect(read(fds[0], &byte, 1) == 1)
        #expect(byte == 7)
    }

    /// An import request carries the client's descriptor of the archive, which the daemon
    /// reads: the duplicate it receives reads from the client's file.
    @Test func carriesTheArchiveDescriptorOfAnImport() throws {
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        let request = DaemonRequest.import(
            ImportRequest(name: try DistroName("Copy"), user: nil, archive: "standard input"))
        let message = try InterfaceCoding.encode(request, descriptor: fds[0])
        #expect(
            try InterfaceCoding.decode(DaemonRequest.self, from: message, as: .daemon) == request)
        let received = try #require(try InterfaceCoding.descriptor(in: message))
        #expect(received.rawValue != fds[0], "The message must hold a duplicate.")
        #expect(fcntl(received.rawValue, F_GETFD) & FD_CLOEXEC != 0)
        #expect(fcntl(received.rawValue, F_GETFL) & O_ACCMODE == O_RDONLY)

        var byte: UInt8 = 9
        #expect(write(fds[1], &byte, 1) == 1)
        byte = 0
        #expect(read(received.rawValue, &byte, 1) == 1)
        #expect(byte == 9)
    }

    /// The daemon records standard input or an absolute path of at most 1,024 bytes.
    @Test func acceptsOnlyAnAbsolutePathOrStandardInputAsTheArchive() throws {
        let name = try DistroName("Copy")
        func isValid(_ archive: String) -> Bool {
            ImportRequest(name: name, user: nil, archive: archive).hasValidArchive
        }
        #expect(isValid("standard input"))
        #expect(isValid("/Users/ayse/Desktop/ubuntu.tar"))
        #expect(isValid("/" + String(repeating: "a", count: 1_023)))
        #expect(!isValid("/" + String(repeating: "a", count: 1_024)))
        #expect(!isValid("ubuntu.tar"))
        #expect(!isValid(""))
        #expect(!isValid("-"))
    }

    @Test func hasNoDescriptorUnlessOneWasAdded() throws {
        let message = try InterfaceCoding.encode(DaemonRequest.status)
        #expect(try InterfaceCoding.descriptor(in: message) == nil)
    }

    @Test func readsTheLabelFromTheEnvironment() {
        #expect(DaemonInterface.label(environment: [:]) == "dev.maw.mawd")
        #expect(DaemonInterface.label(environment: ["MAW_DAEMON_LABEL": ""]) == "dev.maw.mawd")
        #expect(
            DaemonInterface.label(environment: ["MAW_DAEMON_LABEL": "dev.maw.mawd.test"])
                == "dev.maw.mawd.test")
    }
}

@Suite struct PeerRequirementTests {
    @Test func namesMawsExecutablesAndTheApp() {
        #expect(
            PeerRequirement.codeSigningRequirement
                == #"identifier "dev.maw.maw" or identifier "dev.maw.mawd" or identifier "dev.maw.app""#
        )
    }

    /// The requirement, evaluated as libxpc evaluates it, against copies of a program signed ad
    /// hoc, as `scripts/sign-dev.sh` and Xcode sign maw's executables and the app.
    @Test(arguments: [
        ("dev.maw.maw", true), ("dev.maw.mawd", true), ("dev.maw.app", true),
        ("dev.maw.app.helper", false), ("dev.maw", false), ("maw-5555", false),
        ("com.example.app", false),
    ])
    func acceptsOnlyMawsIdentifiers(identifier: String, isAccepted: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "maw-peer-requirement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let program = directory.appending(path: "program")
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: program)
        let codesign = Process()
        codesign.executableURL = URL(filePath: "/usr/bin/codesign")
        codesign.arguments = [
            "--force", "--sign", "-", "--identifier", identifier,
            program.path(percentEncoded: false),
        ]
        codesign.standardError = FileHandle.nullDevice
        // The test suspends until `codesign` exits rather than blocking in `waitUntilExit()`,
        // which would hold a thread of the cooperative pool (docs/known-limitations.md).
        let (exit, exited) = AsyncStream.makeStream(of: Void.self)
        codesign.terminationHandler = { _ in exited.finish() }
        try codesign.run()
        for await _ in exit {}
        try #require(codesign.terminationStatus == 0)

        var code: SecStaticCode?
        try #require(SecStaticCodeCreateWithPath(program as CFURL, [], &code) == errSecSuccess)
        var requirement: SecRequirement?
        try #require(
            SecRequirementCreateWithString(
                PeerRequirement.codeSigningRequirement as CFString, [], &requirement)
                == errSecSuccess)
        let status = SecStaticCodeCheckValidity(try #require(code), [], requirement)
        #expect(status == (isAccepted ? errSecSuccess : errSecCSReqFailed), "\(status)")
    }

    @Test func rejectsATestRunnerThatIsNotSignedAsMaw() {
        let identifier = PeerRequirement.currentIdentifier()
        #expect(identifier != nil)
        #expect(throws: MawError.clientSignatureRejected(identifier: identifier ?? "")) {
            try PeerRequirement.checkCurrentProcess()
        }
    }
}
