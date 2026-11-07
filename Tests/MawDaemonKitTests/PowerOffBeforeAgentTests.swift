import Foundation
import MawCore
import Testing

@testable import MawDaemonKit

/// The error that a machine's start reports when the guest powers off before its agent
/// answers, from what the initramfs reported on the console.
@Suite struct PowerOffBeforeAgentTests {
    static let ubuntu = MachineID.distribution(try! DistroName("Ubuntu"))
    static let disk = URL(filePath: "/maw/distros/Ubuntu/disk.img")
    static let consoleLog = URL(filePath: "/logs/Ubuntu.log")
    /// What the daemon reported for every such power-off before the initramfs reported its
    /// check, and still reports when it reports none.
    static let generic = MawError.vmFailed(
        reason: "the guest powered off before its agent answered")

    func error(
        on machine: MachineID = ubuntu, _ check: RootFileSystemCheck?, disk: URL? = disk
    ) -> MawError {
        VirtualMachineHandle.powerOffBeforeAgent(
            machine: machine, rootCheck: check, diskImage: disk, consoleLog: Self.consoleLog)
    }

    @Test(arguments: [4, 7, 8, 12, 16, 127])
    func reportsAFailedCheck(_ status: Int) throws {
        #expect(
            error(RootFileSystemCheck(e2fsckStatus: status))
                == .rootFileSystemCheckFailed(
                    distribution: try DistroName("Ubuntu"), e2fsckStatus: status,
                    diskImage: "/maw/distros/Ubuntu/disk.img", consoleLog: "/logs/Ubuntu.log"))
    }

    /// Guest files from before the marker report no check; the error is the one they always
    /// had.
    @Test func reportsThePowerOffAsBeforeWithoutACheck() {
        #expect(error(nil) == Self.generic)
    }

    /// A check that let the distribution boot did not cause the power-off.
    @Test(arguments: [0, 1, 2, 3])
    func reportsThePowerOffAsBeforeAfterACheckThatAllowedTheBoot(_ status: Int) {
        #expect(error(RootFileSystemCheck(e2fsckStatus: status)) == Self.generic)
    }

    @Test func reportsNoCheckForTheInitramfsMachine() {
        #expect(
            error(on: .initramfs, RootFileSystemCheck(e2fsckStatus: 8), disk: nil) == Self.generic)
    }
}
