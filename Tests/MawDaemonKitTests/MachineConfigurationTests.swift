import Foundation
import MawCore
import MawVirtualization
import Testing

@testable import MawDaemonKit

/// Which machines get the share of the home directory (docs/decisions/0021-mac-share.md): every
/// distribution's machine, and never the provisioning machine, which runs programs of a root
/// file system that may come from outside maw.
@Suite struct MachineConfigurationTests {
    static let home = URL(filePath: "/Users/ayse", directoryHint: .isDirectory)

    static let metadata = DistroMetadata(
        name: try! DistroName("Ubuntu-24.04"), catalogEntry: try! DistroName("Ubuntu-24.04"),
        release: "24.04.5", imageSHA256: String(repeating: "a", count: 64),
        createdAt: Date(timeIntervalSince1970: 0), defaultUser: "ayse", diskSize: 1 << 30,
        macAddress: "02:00:00:00:00:01")

    static let base = VMConfiguration(
        kernelURL: URL(filePath: "/k/Image"), initramfsURL: URL(filePath: "/k/initramfs.cpio.gz"),
        consoleLogURL: URL(filePath: "/logs/Ubuntu-24.04.log"))

    @Test func sharesTheHomeDirectoryWithADistribution() {
        let configuration = VirtualMachineHandle.distributionConfiguration(
            Self.base, disk: URL(filePath: "/d/disk.img"), metadata: Self.metadata,
            macHome: Self.home, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(configuration.directoryShares == [.init(url: Self.home, tag: "maw-mac")])
        #expect(configuration.directoryShares.first?.isReadOnly == false)
        #expect(
            configuration.commandLine
                == "console=hvc0 maw.root=/dev/vda maw.clock=1800000000 maw.share=maw-mac"
                + " maw.home=/Users/ayse")
    }

    /// The home directory's path reaches `mawpath` intact, spaces and non-ASCII letters
    /// included, and one too long for the kernel command line is left out.
    @Test func putsTheHomeDirectoryOnTheCommandLineForMawpath() throws {
        let home = URL(filePath: "/Users/Ayşe Öz/", directoryHint: .isDirectory)
        let configuration = VirtualMachineHandle.distributionConfiguration(
            Self.base, disk: URL(filePath: "/d/disk.img"), metadata: Self.metadata,
            macHome: home, now: Date(timeIntervalSince1970: 1_800_000_000))
        // URL gives the name decomposed (NFD), as the file system stores it.
        #expect(configuration.commandLine.contains(" maw.home=/Users/Ays%CC%A7e%20O%CC%88z"))
        let decoded = try #require(MacShare.home(fromCommandLine: configuration.commandLine))
        #expect(Array(decoded.utf8) == Array(VirtualMachineHandle.displayPath(home).utf8))
        let long = URL(
            filePath: "/" + String(repeating: "ü", count: 200), directoryHint: .isDirectory)
        let without = VirtualMachineHandle.distributionConfiguration(
            Self.base, disk: URL(filePath: "/d/disk.img"), metadata: Self.metadata,
            macHome: long, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(!without.commandLine.contains("maw.home"))
        #expect(without.commandLine.hasSuffix("maw.share=maw-mac"))
    }

    /// `mawd serve --without-mac-share`, for the measurements: no device and no argument.
    @Test func leavesTheShareOutWhenAskedTo() {
        let configuration = VirtualMachineHandle.distributionConfiguration(
            Self.base, disk: URL(filePath: "/d/disk.img"), metadata: Self.metadata,
            macHome: nil, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(configuration.directoryShares.isEmpty)
        #expect(configuration.commandLine == "console=hvc0 maw.root=/dev/vda maw.clock=1800000000")
    }

    /// The snapshot shows the home directory without a trailing slash, so that the app
    /// shortens it to `~`.
    @Test func showsTheSharedDirectoryWithoutATrailingSlash() {
        #expect(VirtualMachineHandle.displayPath(Self.home) == "/Users/ayse")
        #expect(VirtualMachineHandle.displayPath(URL(filePath: "/Users/ayse")) == "/Users/ayse")
        #expect(VirtualMachineHandle.displayPath(URL(filePath: "/")) == "/")
    }

    @Test func neverSharesAnythingWithTheProvisioningMachine() throws {
        let kernel = FileManager.default.temporaryDirectory.appending(
            path: "maw-kernel-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: kernel, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: kernel) }
        for file in ["Image", "initramfs.cpio.gz", "manifest.json"] {
            try Data().write(to: kernel.appending(path: file))
        }
        let configuration = VirtualProvisioningMachine.configuration(
            guest: try GuestFiles(directory: kernel), consoleLog: URL(filePath: "/logs/i.log"),
            disk: URL(filePath: "/d/disk.img"), now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(configuration.directoryShares.isEmpty)
        #expect(!configuration.commandLine.contains(MacShare.kernelArgument))
        #expect(configuration.disks == [.init(url: URL(filePath: "/d/disk.img"))])
    }
}
