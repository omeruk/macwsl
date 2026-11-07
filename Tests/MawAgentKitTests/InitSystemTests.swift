import Testing

@testable import MawAgentKit

@Suite struct InitSystemTests {
    @Test func recognizesSystemdByItsRuntimeDirectory() {
        #expect(InitSystem.detect { $0 == "/run/systemd/system" } == .systemd)
        #expect(InitSystem.detect { _ in false } == .busybox)
    }

    @Test func powersOffWithTheSignalEachInitExpects() {
        // Linux numbers: SIGUSR2 is 12; glibc's SIGRTMIN + 4 is 38.
        #expect(InitSystem.busybox.powerOffSignal == 12)
        #expect(InitSystem.systemd.powerOffSignal == 38)
    }
}
