import MawCore
import Testing

@Suite struct RootFileSystemCheckTests {
    // MARK: e2fsck's exit statuses

    @Test(arguments: [
        (0, RootFileSystemCheck.Outcome.clean, true),
        (1, .repaired, true),
        (2, .repaired, true),
        (3, .repaired, true),
        (4, .errorsLeftUncorrected, false),
        (5, .errorsLeftUncorrected, false),
        (6, .errorsLeftUncorrected, false),
        (7, .errorsLeftUncorrected, false),
        (8, .checkNotCompleted, false),
        (12, .checkNotCompleted, false),
        (16, .checkNotCompleted, false),
        (32, .checkNotCompleted, false),
        (127, .checkNotCompleted, false),
        (128, .checkNotCompleted, false),
        (137, .checkNotCompleted, false),
        (255, .checkNotCompleted, false),
    ])
    func classifiesEachExitStatus(
        _ status: Int, _ outcome: RootFileSystemCheck.Outcome, _ allowsBoot: Bool
    ) {
        let check = RootFileSystemCheck(e2fsckStatus: status)
        #expect(check.outcome == outcome)
        #expect(check.allowsBoot == allowsBoot)
    }

    // MARK: The marker line

    @Test(arguments: [0, 1, 4, 8, 12, 255])
    func readsTheMarkerLine(_ status: Int) {
        let check = RootFileSystemCheck(
            consoleLine: "maw-initramfs: root-check e2fsck-status=\(status)")
        #expect(check == RootFileSystemCheck(e2fsckStatus: status))
    }

    @Test(arguments: [
        "maw-initramfs: root-check e2fsck-status=",
        "maw-initramfs: root-check e2fsck-status=256",
        "maw-initramfs: root-check e2fsck-status=1000",
        "maw-initramfs: root-check e2fsck-status=-1",
        "maw-initramfs: root-check e2fsck-status=4 ",
        "maw-initramfs: root-check e2fsck-status=4x",
        "maw-initramfs: root-check e2fsck-status=٤",
        " maw-initramfs: root-check e2fsck-status=4",
        "[    1.234] maw-initramfs: root-check e2fsck-status=4",
        "maw-initramfs: root-check status=4",
        // The line that /init printed before the marker existed.
        "maw-initramfs: the file system on /dev/vda has errors that e2fsck -p cannot repair "
            + "(exit status 4)",
        // e2fsck's own output is never read, even where it names the status.
        "/dev/vda: UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY.",
        "e2fsck: Bad magic number in super-block while trying to open /dev/vda",
    ])
    func ignoresEveryOtherLine(_ line: String) {
        #expect(RootFileSystemCheck(consoleLine: line) == nil)
    }

    // MARK: Following the console

    /// The console of a failed check, as /init prints it.
    static let failedBoot = [
        "[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x611f0221]",
        "maw-initramfs 1.0 kernel=6.18.57-maw",
        "e2fsck: Bad magic number in super-block while trying to open /dev/vda",
        "maw-initramfs: root-check e2fsck-status=8",
        "maw-initramfs: e2fsck -p could not check /dev/vda (exit status 8)",
        "maw-initramfs: cannot boot from /dev/vda: its file system check failed",
        "maw-initramfs: powering off",
        "[    0.412345] reboot: Power down",
    ]

    @Test func keepsTheCheckOfAFailedBoot() {
        #expect(scan(Self.failedBoot) == RootFileSystemCheck(e2fsckStatus: 8))
    }

    @Test func keepsTheCheckOfABootThatContinues() {
        var scanner = RootFileSystemCheckScanner()
        for line in [
            "maw-initramfs: root-check e2fsck-status=1",
            "maw-initramfs: e2fsck -p corrected errors on /dev/vda (exit status 1)",
            "maw-initramfs: starting systemd at 0.62 s",
        ] {
            scanner.read(line)
        }
        #expect(scanner.check == RootFileSystemCheck(e2fsckStatus: 1))
        #expect(scanner.isFinished)
    }

    /// A marker-like line within e2fsck's output, such as a file name it prints, comes before
    /// the initramfs's marker, which replaces it.
    @Test func keepsTheLastMarkerBeforeSystemdStarts() {
        let lines = [
            "maw-initramfs: root-check e2fsck-status=8",
            "maw-initramfs: root-check e2fsck-status=0",
        ]
        #expect(scan(lines) == RootFileSystemCheck(e2fsckStatus: 0))
    }

    /// Once systemd runs, the console belongs to the distribution; a process there that
    /// prints the marker does not change what the initramfs reported.
    @Test func ignoresMarkersAfterSystemdStarts() {
        let lines = [
            "maw-initramfs: root-check e2fsck-status=0",
            "maw-initramfs: starting systemd at 0.62 s",
            "maw-initramfs: root-check e2fsck-status=8",
        ]
        #expect(scan(lines) == RootFileSystemCheck(e2fsckStatus: 0))
    }

    /// Guest files from before the marker report no check, and the daemon reports the
    /// power-off as it did before.
    @Test func findsNoCheckInTheConsoleOfOlderGuestFiles() {
        let lines = [
            "maw-initramfs 0.9 kernel=6.18.57-maw",
            "/dev/vda: UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY.",
            "maw-initramfs: the file system on /dev/vda has errors that e2fsck -p cannot "
                + "repair (exit status 4)",
            "maw-initramfs: powering off",
        ]
        #expect(scan(lines) == nil)
    }

    private func scan(_ lines: [String]) -> RootFileSystemCheck? {
        var scanner = RootFileSystemCheckScanner()
        for line in lines {
            scanner.read(line)
        }
        return scanner.check
    }
}
