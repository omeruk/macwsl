import Foundation
import MawCore
import MawXPC
import Testing
import os

@testable import MawDaemonKit

/// The installer against a fake image source and a fake provisioning machine.
@Suite struct InstallerTests {
    let home: URL
    let store: DistributionStore
    let images = FakeImageSource()
    let machine = FakeProvisioningMachine()
    let started = OSAllocatedUnfairLock(initialState: [MachineID]())

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(
            path: "maw-installer-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = DistributionStore(paths: MawPaths(homeDirectory: home))
        try FileManager.default.createDirectory(
            at: store.paths.distrosDirectory, withIntermediateDirectories: true)
    }

    func installer(freeSpace: UInt64 = 100 << 30) -> Installer {
        let machine = self.machine
        let started = self.started
        return Installer(
            store: store, images: images,
            makeMachine: { (_: DistroName) throws(MawError) -> any ProvisioningMachine in machine },
            freeSpace: { _ in (freeSpace, "Macintosh HD") },
            startMachine: { machine throws(MawError) in started.withLock { $0.append(machine) } },
            makeMACAddress: { "02:00:00:00:00:01" })
    }

    func request(
        _ distribution: String? = nil, name: String? = nil, user: String = "ayse",
        password: String = "secret"
    ) -> InstallRequest {
        InstallRequest(
            distribution: distribution, name: name.map { try! DistroName($0) }, user: user,
            password: Secret(password), locale: "tr_TR.UTF-8")
    }

    var stagingDirectories: [String] {
        ((try? FileManager.default.contentsOfDirectory(
            atPath: store.paths.distrosDirectory.path(percentEncoded: false))) ?? [])
            .filter { $0.hasPrefix(MawPaths.stagingPrefix) }
    }

    // MARK: Success

    @Test func installsTheRecommendedDistributionStepByStep() async throws {
        let events = Events()
        let summary = try await installer().install(request(), progress: events.record)
        let name = try DistroName("Ubuntu-24.04")
        #expect(summary.name == name)
        #expect(summary.defaultUser == "ayse")
        #expect(summary.isDefault)
        #expect(
            events.steps == [
                .download, .verify, .prepare, .format, .extract, .configure, .finish, .start,
            ])
        #expect(events.sawDownloadProgress)
        #expect(machine.calls == ["boot", "format", "extract", "configure", "finish"])
        #expect(machine.configuration?.hostname == "ubuntu-24-04")
        #expect(machine.configuration?.user.rawValue == "ayse")
        #expect(machine.configuration?.password == Secret("secret"))
        #expect(machine.configuration?.locale == "tr_TR.UTF-8")
        #expect(store.isInstalled(name))
        #expect(store.defaultDistribution() == name)
        let metadata = try #require(try store.metadata(for: name))
        #expect(metadata.defaultUser == "ayse")
        #expect(metadata.release == "24.04.5")
        #expect(metadata.diskSize == 256 << 30)
        #expect(stagingDirectories.isEmpty)
        // The disk is sparse: its size is virtual.
        let disk = store.paths.diskImage(for: name)
        let values = try disk.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        #expect(values.fileSize == 256 << 30)
        #expect((values.totalFileAllocatedSize ?? 0) < 1 << 20)
        #expect(started.withLock { $0 } == [.distribution(name)])
    }

    @Test func skipsTheDownloadOfACachedImageButStillVerifiesIt() async throws {
        images.cached = true
        let events = Events()
        _ = try await installer().install(request(), progress: events.record)
        #expect(events.steps.first == .verify)
        #expect(images.downloads == 0)
        #expect(images.verifications == 1)
    }

    @Test func installsUnderAnotherName() async throws {
        _ = try await installer().install(request("Ubuntu", name: "Work"), progress: { _ in })
        #expect(store.isInstalled(try DistroName("Work")))
        #expect(!store.isInstalled(try DistroName("Ubuntu-24.04")))
        #expect(machine.configuration?.hostname == "work")
        #expect(
            try store.metadata(for: try DistroName("Work"))?.catalogEntry.rawValue == "Ubuntu-24.04"
        )
    }

    @Test func keepsTheFirstDistributionAsTheDefault() async throws {
        _ = try await installer().install(request(), progress: { _ in })
        let second = try await installer().install(request(name: "Second"), progress: { _ in })
        #expect(!second.isDefault)
        #expect(store.defaultDistribution()?.rawValue == "Ubuntu-24.04")
    }

    // MARK: Refusals before anything happens

    @Test func refusesAnUnknownDistribution() async {
        await #expect(throws: MawError.unknownDistribution("Debian")) {
            try await installer().install(request("Debian"), progress: { _ in })
        }
    }

    @Test func refusesANameThatIsInstalled() async throws {
        _ = try await installer().install(request(), progress: { _ in })
        await #expect(throws: MawError.distributionAlreadyInstalled(try DistroName("Ubuntu-24.04")))
        {
            try await installer().install(request(), progress: { _ in })
        }
    }

    @Test func refusesTheInitramfsMachinesName() async {
        await #expect(
            throws: MawError.invalidDistroName("Initramfs", reason: "the name is reserved for maw")
        ) {
            try await installer().install(request(name: "Initramfs"), progress: { _ in })
        }
    }

    @Test func refusesAnInvalidUserOrPassword() async {
        await #expect(
            throws: MawError.invalidUserName(
                "sudo", reason: "the distribution already has a user or group with that name")
        ) {
            try await installer().install(request(user: "sudo"), progress: { _ in })
        }
        await #expect(throws: MawError.invalidPassword(reason: "it is empty")) {
            try await installer().install(request(password: ""), progress: { _ in })
        }
        await #expect(
            throws: MawError.invalidPassword(
                reason: "it contains a line break or a control character")
        ) {
            try await installer().install(request(password: "a\nb"), progress: { _ in })
        }
        #expect(machine.calls.isEmpty)
        #expect(images.downloads == 0)
    }

    @Test func checksTheFreeSpaceBeforeTheDownload() async throws {
        let entry = DistroCatalog.builtIn.recommendedEntry
        let required = InstallSpace.required(for: entry.image, alreadyDownloaded: 0)
        await #expect(
            throws: MawError.insufficientDiskSpace(
                required: required.bytes, available: 1 << 30, volume: "Macintosh HD")
        ) {
            try await installer(freeSpace: 1 << 30).install(request(), progress: { _ in })
        }
        #expect(images.downloads == 0)
    }

    // MARK: Failure and cancellation

    @Test func removesEverythingWhenAStepFails() async throws {
        machine.failingStep = "extract"
        await #expect(
            throws: MawError.provisioningFailed(step: "extracting", reason: "the fake failed")
        ) {
            try await installer().install(request(), progress: { _ in })
        }
        #expect(machine.calls.last == "discard")
        #expect(!store.isInstalled(try DistroName("Ubuntu-24.04")))
        #expect(stagingDirectories.isEmpty)
        #expect(started.withLock { $0 }.isEmpty)
    }

    @Test(arguments: ["download", "format", "extract", "configure"])
    func removesEverythingWhenCancelled(during step: String) async throws {
        machine.blockingStep = step
        images.blocksDownload = step == "download"
        let installer = installer()
        let request = request()
        let task = Task { () async throws -> InstallSummary in
            try await installer.install(request, progress: { _ in })
        }
        // Wait until the step runs, then cancel as a disconnecting client would.
        let images = self.images
        let machine = self.machine
        try await eventually("the \(step) step") {
            step == "download" ? images.downloads > 0 : machine.calls.contains(step)
        }
        task.cancel()
        let result = await task.result
        #expect(throws: MawError.installationCancelled(try DistroName("Ubuntu-24.04"))) {
            try result.get()
        }
        #expect(!store.isInstalled(try DistroName("Ubuntu-24.04")))
        #expect(stagingDirectories.isEmpty)
        if step != "download" {
            #expect(machine.calls.contains("discard"))
        }
    }

    @Test func refusesASecondInstallationOfTheSameName() async throws {
        machine.blockingStep = "extract"
        let installer = installer()
        let first = Task { () async throws -> InstallSummary in
            try await installer.install(request(), progress: { _ in })
        }
        let machine = self.machine
        try await eventually("the extract step") { machine.calls.contains("extract") }
        await #expect(throws: MawError.installationInProgress(try DistroName("Ubuntu-24.04"))) {
            try await installer.install(request(), progress: { _ in })
        }
        // APFS ignores case, so another spelling would end in the same directory.
        await #expect(throws: MawError.installationInProgress(try DistroName("ubuntu-24.04"))) {
            try await installer.install(request(name: "ubuntu-24.04"), progress: { _ in })
        }
        first.cancel()
        _ = await first.result
    }

    // MARK: Rules

    @Test(arguments: [
        ("Ubuntu-24.04", "ubuntu-24-04"), ("Work", "work"), ("a__b..c", "a-b-c"),
        ("x-", "x"), ("1", "1"),
    ])
    func derivesTheHostNameFromTheDistributionsName(_ name: String, _ hostname: String) throws {
        #expect(Installer.hostname(for: try DistroName(name)) == hostname)
    }
}

/// Install progress, in order.
final class Events: Sendable {
    private let recorded = OSAllocatedUnfairLock(initialState: [InstallProgress]())

    var record: @Sendable (InstallProgress) -> Void {
        { [recorded] progress in recorded.withLock { $0.append(progress) } }
    }

    /// The steps that finished.
    var steps: [InstallStep] {
        recorded.withLock {
            $0.compactMap { if case .finished(let step, _) = $0 { step } else { nil } }
        }
    }

    var sawDownloadProgress: Bool {
        recorded.withLock { $0.contains { if case .download = $0 { true } else { false } } }
    }
}

final class FakeImageSource: ImageSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _cached = false
    private var _downloads = 0
    private var _verifications = 0
    private var _blocksDownload = false

    var cached: Bool {
        get { lock.withLock { _cached } }
        set { lock.withLock { _cached = newValue } }
    }
    var blocksDownload: Bool {
        get { lock.withLock { _blocksDownload } }
        set { lock.withLock { _blocksDownload = newValue } }
    }
    var downloads: Int { lock.withLock { _downloads } }
    var verifications: Int { lock.withLock { _verifications } }

    func downloadedBytes(of image: CatalogImage) -> UInt64 { cached ? image.size : 0 }
    func isComplete(_ image: CatalogImage) -> Bool { cached }

    func download(
        _ image: CatalogImage, progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws(MawError) {
        lock.withLock { _downloads += 1 }
        progress(
            DownloadProgress(
                receivedBytes: 1, totalBytes: image.size, bytesPerSecond: 0, resumedFromBytes: 0))
        if blocksDownload {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            throw .downloadFailed(url: image.url.absoluteString, reason: "it was cancelled")
        }
        cached = true
    }

    func verify(_ image: CatalogImage) async throws(MawError) -> URL {
        lock.withLock { _verifications += 1 }
        return URL(filePath: "/cache/\(image.cacheFileName)")
    }
}

final class FakeProvisioningMachine: ProvisioningMachine, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _configuration: GuestConfiguration?
    private var _failingStep: String?
    private var _blockingStep: String?

    var calls: [String] { lock.withLock { _calls } }
    var configuration: GuestConfiguration? { lock.withLock { _configuration } }
    var failingStep: String? {
        get { lock.withLock { _failingStep } }
        set { lock.withLock { _failingStep = newValue } }
    }
    var blockingStep: String? {
        get { lock.withLock { _blockingStep } }
        set { lock.withLock { _blockingStep = newValue } }
    }

    private func step(_ name: String) async throws(MawError) {
        lock.withLock { _calls.append(name) }
        if failingStep == name {
            throw .provisioningFailed(step: name + "ing", reason: "the fake failed")
        }
        if blockingStep == name {
            // Blocks until discard() stops the machine, as a real machine's step ends when the
            // machine stops.
            while !calls.contains("discard") {
                try? await Task.sleep(for: .milliseconds(10))
            }
            throw .provisioningFailed(step: name, reason: "the machine stopped")
        }
    }

    func boot(disk: URL) async throws(MawError) { try await step("boot") }
    func format() async throws(MawError) { try await step("format") }
    func extract(image: URL, format: CatalogImage.Format) async throws(MawError) {
        try await step("extract")
    }
    func configure(_ configuration: GuestConfiguration) async throws(MawError) {
        lock.withLock { _configuration = configuration }
        try await step("configure")
    }
    func finish() async throws(MawError) { try await step("finish") }
    func discard() async { lock.withLock { _calls.append("discard") } }
}
