import Foundation
import MawProtocol
import Testing

@testable import MawDaemonKit

@Suite struct StreamingProcessTests {
    /// `StreamingProcess.run` on a thread of its own, since it waits for the program, with
    /// the output that the consumer received.
    static func run(
        _ path: String, _ arguments: [String], consumeAtMost limit: Int = .max
    ) async throws -> (StreamingProcess.Outcome, Data) {
        try await runOnDedicatedThread { () throws -> (StreamingProcess.Outcome, Data) in
            var output = Data()
            let outcome = try StreamingProcess.run(path, arguments) { chunk in
                guard output.count < limit else { return false }
                output.append(chunk)
                return true
            }
            return (outcome, output)
        }
    }

    @Test func streamsTheOutputAndReportsTheStatus() async throws {
        let (outcome, output) = try await Self.run(
            "/bin/sh", ["-c", "printf hello; printf oops >&2; exit 3"])
        #expect(String(decoding: output, as: UTF8.self) == "hello")
        #expect(outcome == StreamingProcess.Outcome(status: 3, errors: "oops"))
    }

    @Test func endsWhenTheProgramExitsEvenIfItLeftNothingBehind() async throws {
        // `yes` would run for ever; head ends the pipeline, and the read must see end-of-file.
        let (outcome, output) = try await Self.run("/bin/sh", ["-c", "yes | head -c 3000000"])
        #expect(output.count == 3_000_000)
        #expect(outcome.status == 0)
    }

    @Test func terminatesTheProgramWhenTheConsumerStops() async throws {
        let started = ContinuousClock.now
        let (outcome, _) = try await Self.run("/usr/bin/yes", [], consumeAtMost: 0)
        #expect(outcome.status == 128 + SIGTERM)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func givesTheProgramOnlyItsStandardDescriptors() async throws {
        // A descriptor of this process without close-on-exec must not reach the child. A high
        // number keeps it apart from the descriptors the shell opens itself.
        let opened = open("/dev/null", O_RDONLY)
        let leaked = fcntl(opened, F_DUPFD, 57)
        close(opened)
        defer { close(leaked) }
        let (_, output) = try await Self.run(
            "/bin/sh", ["-c", "if [ -e /dev/fd/\(leaked) ]; then echo open; else echo closed; fi"])
        #expect(String(decoding: output, as: UTF8.self) == "closed\n")
    }

    @Test func reportsAProgramThatCannotStart() {
        #expect(throws: POSIXError.self) {
            try StreamingProcess.run("/no/such/program", []) { _ in true }
        }
    }
}
