import Testing

@testable import macwsl

@Suite struct ArgumentNormalizerTests {
    private func normalize(_ arguments: String...) -> [String] {
        ArgumentNormalizer.normalize(arguments)
    }

    @Test func leavesEmptyArgumentsAlone() {
        #expect(normalize() == [])
    }

    // MARK: -v

    @Test func treatsLoneDashVAsVersion() {
        #expect(normalize("-v") == ["--version"])
    }

    @Test(arguments: [["-l", "-v"], ["--list", "-v"], ["-l", "-o", "-v"]])
    func treatsDashVAfterListAsVerbose(_ arguments: [String]) {
        #expect(ArgumentNormalizer.normalize(arguments) == arguments)
    }

    @Test func treatsDashVBeforeListAsVersion() {
        #expect(normalize("-v", "-l") == ["--version", "-l"])
    }

    @Test func leavesShortFlagClustersToTheParser() {
        #expect(normalize("-lv") == ["-lv"])
    }

    @Test func leavesLongVerboseAlone() {
        #expect(normalize("--verbose") == ["--verbose"])
    }

    // MARK: Stopping at -e and --

    @Test func stopsAtExecAndInsertsTerminator() {
        #expect(normalize("-e", "grep", "-v", "foo") == ["-e", "--", "grep", "-v", "foo"])
        #expect(normalize("--exec", "grep", "-v") == ["--exec", "--", "grep", "-v"])
    }

    @Test func doesNotDoubleTheTerminatorAfterExec() {
        #expect(normalize("-e", "--", "ls", "-v") == ["-e", "--", "ls", "-v"])
    }

    @Test func passesALoneExecThrough() {
        #expect(normalize("-e") == ["-e", "--"])
    }

    @Test func stopsAtTerminator() {
        #expect(normalize("--", "grep", "-v", "x") == ["--", "grep", "-v", "x"])
        #expect(normalize("-l", "--", "-v") == ["-l", "--", "-v"])
    }

    // MARK: Option values

    @Test(arguments: [
        "-d", "--distribution", "-u", "--user", "--cd", "-s", "--set-default",
        "-t", "--terminate", "--export", "--import", "--unregister",
    ])
    func skipsTheValueOfOptionsThatTakeOne(_ option: String) {
        #expect(ArgumentNormalizer.normalize([option, "-v"]) == [option, "-v"])
    }

    @Test func doesNotSkipAfterAnAttachedValue() {
        #expect(normalize("--distribution=Ubuntu", "-v") == ["--distribution=Ubuntu", "--version"])
    }

    @Test func treatsAValueThatLooksLikeListAsAValue() {
        // `-l` here is a user name, so the following -v is still --version.
        #expect(normalize("-u", "-l", "-v") == ["-u", "-l", "--version"])
    }

    @Test func keepsATrailingValueOptionForTheParserToReport() {
        #expect(normalize("--cd") == ["--cd"])
    }

    // MARK: Bare commands

    @Test func insertsTerminatorBeforeABareCommand() {
        #expect(normalize("ls", "-la") == ["--", "ls", "-la"])
    }

    @Test func insertsTerminatorAfterSessionOptions() {
        #expect(
            normalize("-d", "Ubuntu", "-u", "root", "ls", "-la")
                == ["-d", "Ubuntu", "-u", "root", "--", "ls", "-la"])
        #expect(
            normalize("--cd", "/tmp", "-d", "Ubuntu", "pwd")
                == ["--cd", "/tmp", "-d", "Ubuntu", "--", "pwd"])
    }

    @Test func passesEverythingAfterABareCommandThrough() {
        #expect(
            normalize("ls", "-v", "--list", "-d", "x") == ["--", "ls", "-v", "--list", "-d", "x"])
    }

    @Test func treatsADashAsABareOperand() {
        #expect(normalize("-") == ["--", "-"])
    }

    @Test func leavesOperandsOfActionsInPlace() {
        #expect(normalize("--install", "Ubuntu") == ["--install", "Ubuntu"])
        #expect(normalize("--export", "Ubuntu", "u.tar") == ["--export", "Ubuntu", "u.tar"])
        #expect(normalize("-l", "extra") == ["-l", "extra"])
        #expect(normalize("--shutdown", "ls") == ["--shutdown", "ls"])
    }

    @Test func treatsDashVAsAnActionForBareCommands() {
        #expect(normalize("-v", "extra") == ["--version", "extra"])
    }

    @Test func treatsHelpAsAnAction() {
        #expect(normalize("--help", "extra") == ["--help", "extra"])
    }
}
