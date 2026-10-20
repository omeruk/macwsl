import ArgumentParser
import Testing

@testable import macwsl

@Suite struct ValidationTests {
    /// The message `macwsl` prints for `arguments`, or `nil` if they are valid.
    private func failure(_ arguments: String...) -> String? {
        failure(arguments)
    }

    private func failure(_ arguments: [String]) -> String? {
        do {
            _ = try MacWSL.parse(ArgumentNormalizer.normalize(arguments))
            return nil
        } catch {
            #expect(MacWSL.exitCode(for: error) == .validationFailure)
            return MacWSL.message(for: error)
        }
    }

    // MARK: Conflicting actions

    @Test func rejectsShutdownWithADistribution() {
        #expect(
            failure("--shutdown", "-d", "Ubuntu")
                == "--shutdown cannot be combined with --distribution (-d).")
    }

    @Test func rejectsTwoActions() {
        #expect(failure("--status", "--version") == "--status cannot be combined with --version.")
        #expect(
            failure("-s", "Ubuntu", "-t", "Debian")
                == "--set-default (-s) cannot be combined with --terminate (-t).")
        #expect(failure("--install", "-l") == "--install cannot be combined with --list (-l).")
    }

    @Test func rejectsDashVBeforeList() {
        #expect(failure("-v", "-l") == "--list (-l) cannot be combined with --version.")
    }

    @Test func rejectsAnActionWithACommand() {
        #expect(
            failure("--shutdown", "--", "ls") == "--shutdown cannot be combined with a command.")
        #expect(failure("--status", "-e", "ls") == "--status cannot be combined with --exec (-e).")
    }

    // MARK: Session options

    @Test func rejectsUserAndDirectoryOutsideASession() {
        #expect(failure("-l", "-u", "root") == "--list (-l) cannot be combined with --user (-u).")
        #expect(failure("--install", "--cd", "/") == "--install cannot be combined with --cd.")
        #expect(
            failure("-t", "Ubuntu", "-d", "Debian")
                == "--terminate (-t) cannot be combined with --distribution (-d).")
    }

    @Test func rejectsExecWithoutACommand() {
        let expected = "--exec (-e) needs a command to run: macwsl -e <command> [<argument>...]."
        #expect(failure("-e") == expected)
        #expect(failure("-d", "Ubuntu", "--exec") == expected)
    }

    @Test func rejectsAMissingOptionValue() {
        #expect(failure("--cd")?.hasPrefix("Missing value for '--cd <directory>'") == true)
        #expect(failure("-d")?.hasPrefix("Missing value for '-d <distro>'") == true)
    }

    @Test func reportsAttachedShortOptionValuesAsUnknownOptions() {
        // ArgumentParser may add an "or:" line naming letters of the cluster; only the first line
        // depends on how `ArgumentNormalizer` reads the cluster.
        func firstLine(_ arguments: String...) -> String? {
            failure(arguments).flatMap { $0.split(separator: "\n").first.map(String.init) }
        }
        #expect(firstLine("-dUbuntu") == "Unknown option '-dUbuntu'")
        #expect(firstLine("-dUbuntu", "ls", "-la") == "Unknown option '-dUbuntu'")
        #expect(firstLine("-uroot", "ls") == "Unknown option '-uroot'")
        #expect(firstLine("-lx", "-v") == "Unknown option '-x'")
    }

    // MARK: List modifiers

    @Test func rejectsListModifiersWithoutList() {
        #expect(failure("--online") == "--online (-o) can only be used with --list (-l).")
        #expect(failure("--verbose") == "--verbose (-v) can only be used with --list (-l).")
    }

    @Test func rejectsVerboseWithOnline() {
        #expect(
            failure("-l", "-o", "-v") == "--verbose (-v) cannot be combined with --online (-o).")
    }

    // MARK: Operands

    @Test func rejectsTwoNamesForInstall() {
        #expect(
            failure("--install", "Ubuntu", "-d", "Debian")
                == "Name the distribution to install either after --install or with "
                + "--distribution (-d), not both.")
    }

    @Test func rejectsExtraInstallOperands() {
        #expect(failure("--install", "a", "b") == "Unexpected argument 'b'")
    }

    @Test func rejectsExportAndImportWithoutAFile() {
        #expect(
            failure("--export", "Ubuntu")
                == "--export needs a file to write: macwsl --export <distro> <file>.")
        #expect(
            failure("--import", "Ubuntu")
                == "--import needs a file to read: macwsl --import <distro> <file>.")
    }

    @Test func rejectsOperandsForActionsThatTakeNone() {
        #expect(failure("--shutdown", "now") == "Unexpected argument 'now' after --shutdown.")
        #expect(failure("-l", "x") == "Unexpected argument 'x' after --list (-l).")
    }

    // MARK: Distribution names

    @Test func explainsInvalidDistributionNames() {
        #expect(
            failure("-d", "-v")
                == "The value '-v' is invalid for '-d <distro>': '-v' is not a valid "
                + "distribution name: the name must start with a letter or digit.")
        #expect(failure("-t", "a/b")?.contains("the character '/' is not allowed") == true)
        #expect(failure("--install", "../etc")?.hasPrefix("'../etc' is not a valid") == true)
    }
}

@Suite struct HelpTests {
    @Test func documentsEveryOption() {
        let help = MacWSL.helpMessage(columns: 100)
        for option in CLIOption.all where option != .generateCompletionScript {
            #expect(help.contains("--\(option.long)"), "help does not mention --\(option.long)")
            if let short = option.short {
                #expect(help.contains("-\(short), --\(option.long)"))
            }
        }
    }

    @Test func showsEveryActionInTheUsage() {
        let usage = MacWSL.usageString()
        for form in [
            "-- <command>", "-e <command>", "--install [<distro>]", "--list [--verbose | --online]",
            "--set-default <distro>", "--terminate <distro>", "--shutdown",
            "--export <distro> <file>", "--import <distro> <file>", "--unregister <distro>",
            "--status", "--version",
        ] {
            #expect(usage.contains(form), "usage does not show \(form)")
        }
    }
}
