import ArgumentParser
import MawCommandLine
import MawCore
import MawXPC
import Testing

@testable import maw

/// The text and exit status of every form of `maw --list` without `--online`.
@Suite struct InstalledListTests {
    static func name(_ text: String) -> DistroName {
        try! DistroName(text)
    }

    /// Two distributions, the first the default and running, as the plan's examples show them.
    static let two = DistributionList(
        distributions: [
            DistributionEntry(name: name("Ubuntu-24.04"), state: .running),
            DistributionEntry(name: name("maw-test-work"), state: .stopped),
        ],
        defaultDistribution: name("Ubuntu-24.04"))

    /// One distribution in each state, with a default that is stopped.
    static let everyState = DistributionList(
        distributions: [
            DistributionEntry(name: name("a-running"), state: .running),
            DistributionEntry(name: name("b-starting"), state: .starting),
            DistributionEntry(name: name("c-stopped"), state: .stopped),
            DistributionEntry(name: name("d-stopping"), state: .stopping),
        ],
        defaultDistribution: name("c-stopped"))

    static let noneRunning = DistributionList(
        distributions: [
            DistributionEntry(name: name("Ubuntu-24.04"), state: .stopped),
            DistributionEntry(name: name("maw-test-work"), state: .stopped),
        ],
        defaultDistribution: name("Ubuntu-24.04"))

    static let nothing = DistributionList(distributions: [], defaultDistribution: nil)

    /// What `maw` prints for `list` and `options`, and the exit status it ends with.
    private func run(_ list: DistributionList, _ options: ListOptions) -> (
        output: String, status: Int32
    ) {
        do {
            return (try Reports.installed(list, options), 0)
        } catch {
            let failure = Maw.failure(for: error)
            return (failure?.output ?? "", failure?.exitCode.rawValue ?? 0)
        }
    }

    private func expectWithinEightyColumns(
        _ text: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for line in text.split(separator: "\n") {
            #expect(line.count <= 80, "\(line.count): \(line)", sourceLocation: sourceLocation)
        }
    }

    // MARK: With distributions installed

    @Test func listsTheNamesWithTheDefaultMarked() {
        let result = run(Self.two, ListOptions())
        #expect(
            result.output == """
                The installed distributions. * marks the default, which maw opens without -d.

                    NAME
                  * Ubuntu-24.04
                    maw-test-work

                """)
        #expect(result.status == 0)
        expectWithinEightyColumns(result.output)
    }

    @Test func addsTheStateWhenVerbose() {
        let result = run(Self.two, ListOptions(verbose: true))
        #expect(
            result.output == """
                The installed distributions. * marks the default, which maw opens without -d.

                    NAME           STATE
                  * Ubuntu-24.04   Running
                    maw-test-work  Stopped

                """)
        #expect(result.status == 0)
        expectWithinEightyColumns(result.output)
    }

    @Test func namesEveryState() {
        #expect(
            run(Self.everyState, ListOptions(verbose: true)).output == """
                The installed distributions. * marks the default, which maw opens without -d.

                    NAME        STATE
                    a-running   Running
                    b-starting  Starting
                  * c-stopped   Stopped
                    d-stopping  Stopping

                """)
    }

    @Test func listsEveryMachineThatIsNotStoppedAsRunning() {
        #expect(
            run(Self.everyState, ListOptions(running: true)) == (
                """
                The running distributions. * marks the default, which maw opens without -d.

                    NAME
                    a-running
                    b-starting
                    d-stopping

                """, 0
            ))
        #expect(
            run(Self.two, ListOptions(verbose: true, running: true)) == (
                """
                The running distributions. * marks the default, which maw opens without -d.

                    NAME          STATE
                  * Ubuntu-24.04  Running

                """, 0
            ))
    }

    @Test func printsNamesOnlyWhenQuiet() {
        #expect(run(Self.two, ListOptions(quiet: true)) == ("Ubuntu-24.04\nmaw-test-work\n", 0))
        #expect(
            run(Self.everyState, ListOptions(running: true, quiet: true))
                == ("a-running\nb-starting\nd-stopping\n", 0))
    }

    @Test func keepsTheOrderOfTheReply() {
        let list = DistributionList(
            distributions: [
                DistributionEntry(name: Self.name("Alpha"), state: .stopped),
                DistributionEntry(name: Self.name("beta"), state: .stopped),
            ],
            defaultDistribution: nil)
        #expect(run(list, ListOptions(quiet: true)).output == "Alpha\nbeta\n")
        // Without a default, no row is marked; the header still explains the marker.
        #expect(!run(list, ListOptions()).output.contains("  * "))
    }

    /// The longest name that maw accepts still fits in 80 columns with its state.
    @Test func fitsTheLongestNameInEightyColumns() {
        let longest = Self.name(String(repeating: "n", count: DistroName.maximumLength))
        let list = DistributionList(
            distributions: [DistributionEntry(name: longest, state: .stopping)],
            defaultDistribution: longest)
        for options in [ListOptions(), ListOptions(verbose: true), ListOptions(running: true)] {
            expectWithinEightyColumns(run(list, options).output)
        }
    }

    // MARK: With none running

    @Test(arguments: [ListOptions(running: true), ListOptions(verbose: true, running: true)])
    func saysThatNoneIsRunning(_ options: ListOptions) {
        #expect(run(Self.noneRunning, options) == ("No distribution is running.\n", 0))
    }

    @Test func printsNothingWhenQuietAndNoneIsRunning() {
        #expect(run(Self.noneRunning, ListOptions(running: true, quiet: true)) == ("", 0))
    }

    @Test(arguments: [ListOptions(), ListOptions(verbose: true), ListOptions(quiet: true)])
    func listsStoppedDistributionsWithoutRunning(_ options: ListOptions) {
        let result = run(Self.noneRunning, options)
        #expect(result.status == 0)
        #expect(result.output.contains("maw-test-work"))
    }

    // MARK: With nothing installed

    @Test(arguments: [
        ListOptions(), ListOptions(verbose: true), ListOptions(running: true),
        ListOptions(verbose: true, running: true),
    ])
    func reportsThatNothingIsInstalled(_ options: ListOptions) {
        #expect(
            run(Self.nothing, options) == (
                """
                maw: No Linux distribution is installed.
                Install Ubuntu with maw --install.

                """, 1
            ))
    }

    @Test(arguments: [ListOptions(quiet: true), ListOptions(running: true, quiet: true)])
    func printsNothingWhenQuietAndNothingIsInstalled(_ options: ListOptions) {
        #expect(run(Self.nothing, options) == ("", 0))
    }
}
