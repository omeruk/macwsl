import Foundation
import Testing

@testable import MawDaemonKit

@Suite struct StreamingProcessTests {
    @Test func streamsTheOutputAndReportsTheStatus() throws {
        var output = Data()
        let outcome = try StreamingProcess.run(
            "/bin/sh", ["-c", "printf hello; printf oops >&2; exit 3"]
        ) { chunk in
            output.append(chunk)
            return true
        }
        #expect(String(decoding: output, as: UTF8.self) == "hello")
        #expect(outcome == StreamingProcess.Outcome(status: 3, errors: "oops"))
    }

    @Test func endsWhenTheProgramExitsEvenIfItLeftNothingBehind() throws {
        // `yes` would run for ever; head ends the pipeline, and the read must see end-of-file.
        var count = 0
        let outcome = try StreamingProcess.run("/bin/sh", ["-c", "yes | head -c 3000000"]) {
            count += $0.count
            return true
        }
        #expect(count == 3_000_000)
        #expect(outcome.status == 0)
    }

    @Test func terminatesTheProgramWhenTheConsumerStops() throws {
        let started = ContinuousClock.now
        let outcome = try StreamingProcess.run("/usr/bin/yes", []) { _ in false }
        #expect(outcome.status == 128 + SIGTERM)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func givesTheProgramOnlyItsStandardDescriptors() throws {
        // A descriptor of this process without close-on-exec must not reach the child. A high
        // number keeps it apart from the descriptors the shell opens itself.
        let opened = open("/dev/null", O_RDONLY)
        let leaked = fcntl(opened, F_DUPFD, 57)
        close(opened)
        defer { close(leaked) }
        var output = Data()
        _ = try StreamingProcess.run(
            "/bin/sh", ["-c", "if [ -e /dev/fd/\(leaked) ]; then echo open; else echo closed; fi"]
        ) {
            output.append($0)
            return true
        }
        #expect(String(decoding: output, as: UTF8.self) == "closed\n")
    }

    @Test func reportsAProgramThatCannotStart() {
        #expect(throws: POSIXError.self) {
            try StreamingProcess.run("/no/such/program", []) { _ in true }
        }
    }
}
