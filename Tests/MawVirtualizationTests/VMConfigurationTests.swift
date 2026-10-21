import Foundation
import MawCore
import Testing
import Virtualization

@testable import MawVirtualization

@Suite struct VMConfigurationTests {
    private let limits = VMConfiguration.Limits(
        cpuCount: 1...8, memorySize: ByteSize.mebibytes(64)...ByteSize.gibibytes(8))

    private func configuration(
        cpuCount: Int = 2, memorySize: ByteSize = .gibibytes(1)
    ) -> VMConfiguration {
        VMConfiguration(
            kernelURL: URL(filePath: "/k/Image"),
            initramfsURL: URL(filePath: "/k/initramfs.cpio.gz"),
            consoleLogURL: URL(filePath: "/logs/test-console.log"),
            cpuCount: cpuCount,
            memorySize: memorySize)
    }

    // MARK: Defaults

    @Test(arguments: [(1, 1), (2, 2), (4, 4), (8, 4), (24, 4), (0, 1)])
    func defaultsToAtMostFourCPUs(host: Int, expected: Int) {
        #expect(VMConfiguration.defaultCPUCount(hostCPUCount: host) == expected)
    }

    @Test func hasDocumentedDefaults() {
        let defaults = VMConfiguration(
            kernelURL: URL(filePath: "/k/Image"),
            initramfsURL: URL(filePath: "/k/initramfs.cpio.gz"),
            consoleLogURL: URL(filePath: "/logs/test-console.log"))
        #expect(defaults.memorySize == .gibibytes(2))
        #expect(defaults.commandLine == "console=hvc0")
        #expect(defaults.cpuCount == min(4, ProcessInfo.processInfo.processorCount))
        #expect(defaults.disks.isEmpty)
    }

    // MARK: Command line

    @Test(
        arguments: [
            (nil, "console=hvc0"),
            ("", "console=hvc0"),
            ("   ", "console=hvc0"),
            ("maw.test=poweroff", "console=hvc0 maw.test=poweroff"),
            ("  quiet   loglevel=3 ", "console=hvc0 quiet loglevel=3"),
        ] as [(String?, String)])
    func appendsToTheBaseCommandLine(extra: String?, expected: String) {
        #expect(VMConfiguration.commandLine(appending: extra) == expected)
    }

    // MARK: Clamping

    @Test func keepsValuesWithinTheLimits() {
        #expect(configuration().clamped(to: limits) == configuration())
    }

    @Test func clampsTheCPUCount() {
        #expect(configuration(cpuCount: 64).clamped(to: limits).cpuCount == 8)
        #expect(configuration(cpuCount: 0).clamped(to: limits).cpuCount == 1)
    }

    @Test func clampsTheMemorySize() {
        #expect(
            configuration(memorySize: .gibibytes(64)).clamped(to: limits).memorySize
                == .gibibytes(8))
        #expect(
            configuration(memorySize: .mebibytes(1)).clamped(to: limits).memorySize
                == .mebibytes(64))
    }

    @Test func roundsTheMemorySizeDownToMebibytes() {
        let odd = ByteSize(bytes: ByteSize.mebibytes(100).bytes + 12_345)
        #expect(configuration(memorySize: odd).clamped(to: limits).memorySize == .mebibytes(100))
    }

    @Test func reportsTheHostLimits() {
        let host = VMConfiguration.Limits.host
        #expect(host.cpuCount.lowerBound >= 1)
        #expect(host.memorySize.upperBound > host.memorySize.lowerBound)
    }

    // MARK: Virtualization.framework configuration

    @Test func buildsTheDevicesOfAMawMachine() throws {
        let directory = try TemporaryDirectory()
        let kernel = directory.file("Image")
        let initramfs = directory.file("initramfs.cpio.gz")
        FileManager.default.createFile(atPath: kernel.path(percentEncoded: false), contents: Data())
        FileManager.default.createFile(
            atPath: initramfs.path(percentEncoded: false), contents: Data())
        let disk = directory.file("disk.img")
        try DiskImage.createSparse(at: disk, size: .mebibytes(16))

        var configuration = configuration(cpuCount: 2, memorySize: .mebibytes(512))
        configuration.kernelURL = kernel
        configuration.initramfsURL = initramfs
        configuration.commandLine = "console=hvc0 quiet"
        configuration.disks = [.init(url: disk), .init(url: disk, isReadOnly: true)]

        let built = try configuration.makeVirtualizationConfiguration(
            consoleAttachment: VZFileHandleSerialPortAttachment(
                fileHandleForReading: nil, fileHandleForWriting: nil),
            validate: false)

        let bootLoader = try #require(built.bootLoader as? VZLinuxBootLoader)
        #expect(bootLoader.kernelURL == kernel)
        #expect(bootLoader.initialRamdiskURL == initramfs)
        #expect(bootLoader.commandLine == "console=hvc0 quiet")
        #expect(built.cpuCount == 2)
        #expect(built.memorySize == ByteSize.mebibytes(512).bytes)
        #expect(built.serialPorts.count == 1)
        #expect(built.serialPorts.first is VZVirtioConsoleDeviceSerialPortConfiguration)
        #expect(built.entropyDevices.first is VZVirtioEntropyDeviceConfiguration)
        #expect(
            built.memoryBalloonDevices.first is VZVirtioTraditionalMemoryBalloonDeviceConfiguration)
        #expect(built.socketDevices.first is VZVirtioSocketDeviceConfiguration)
        let readOnly = built.storageDevices.map {
            (($0 as? VZVirtioBlockDeviceConfiguration)?.attachment
                as? VZDiskImageStorageDeviceAttachment)?.isReadOnly
        }
        #expect(readOnly == [false, true])
    }

    @Test func reportsAMissingKernel() throws {
        let directory = try TemporaryDirectory()
        var configuration = configuration()
        configuration.kernelURL = directory.file("Image")
        configuration.initramfsURL = directory.file("initramfs.cpio.gz")
        let attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil, fileHandleForWriting: nil)
        let expected = MawError.kernelNotFound(
            path: directory.file("Image").path(percentEncoded: false))
        #expect(expected.errorDescription?.contains("//") == false)
        #expect(throws: expected) {
            try configuration.makeVirtualizationConfiguration(
                consoleAttachment: attachment, validate: false)
        }
    }

    @Test func reportsAMissingDiskImage() throws {
        let directory = try TemporaryDirectory()
        var configuration = configuration()
        configuration.kernelURL = directory.file("Image")
        configuration.initramfsURL = directory.file("initramfs.cpio.gz")
        for url in [configuration.kernelURL, configuration.initramfsURL] {
            FileManager.default.createFile(
                atPath: url.path(percentEncoded: false), contents: Data())
        }
        let missing = directory.file("missing.img")
        configuration.disks = [.init(url: missing)]
        let attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil, fileHandleForWriting: nil)
        #expect(throws: MawError.diskImageNotFound(path: missing.path(percentEncoded: false))) {
            try configuration.makeVirtualizationConfiguration(
                consoleAttachment: attachment, validate: false)
        }
    }
}
