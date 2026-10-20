/// Rewrites raw `macwsl` arguments into a form ArgumentParser can parse, reproducing the parts of
/// `wsl.exe` syntax that a declarative parser cannot express:
///
/// - `-v` means `--verbose` only after `-l`/`--list`; anywhere else it means `--version`.
/// - A bare command runs in the distribution: when no action has been given, `--` is inserted
///   before the first token that is neither an option nor an option's value, so
///   `macwsl -d Ubuntu ls -la` becomes `macwsl -d Ubuntu -- ls -la`.
///
/// Scanning stops at `--` and at `-e`/`--exec`; everything after them belongs to the command and
/// is passed through untouched. A `--` is also inserted after `-e`, so the parser collects that
/// command in the same place as any other.
///
/// The value of an option that takes one is passed through unexamined, so `-d -v` names a
/// distribution called `-v` (which then fails name validation) rather than asking for the
/// version.
enum ArgumentNormalizer {
    static func normalize(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var sawList = false
        var sawAction = false
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let token = arguments[index]

            if token == "--" {
                return result + arguments[index...]
            }
            guard isOption(token) else {
                if sawAction {
                    // An operand of the action, such as the file in `--export <distro> <file>`.
                    result.append(token)
                    index += 1
                    continue
                }
                return result + ["--"] + arguments[index...]
            }

            let matched = options(in: token)
            if matched.contains(where: { $0.role == .command }) {
                let rest = arguments[(index + 1)...]
                return result + [token] + (rest.first == "--" ? [] : ["--"]) + rest
            }
            if token == "-v" && !sawList {
                result.append("--\(CLIOption.version.long)")
                sawAction = true
                index += 1
                continue
            }

            sawList = sawList || matched.contains(CLIOption.list)
            sawAction = sawAction || matched.contains { $0.role == .action }
            result.append(token)
            index += 1

            // Pass an option's value through unexamined, unless it was attached with `=`.
            if let last = matched.last, last.takesValue, !token.contains("="),
                index < arguments.endIndex
            {
                result.append(arguments[index])
                index += 1
            }
        }
        return result
    }

    /// Whether `token` is spelled like an option. A lone `-` is an operand (conventionally stdin
    /// or stdout), not an option.
    private static func isOption(_ token: String) -> Bool {
        token.hasPrefix("-") && token != "-"
    }

    /// The known options `token` names: one for `--long`, `--long=value` or `-s`, several for a
    /// cluster of short flags such as `-lv`. Unknown names are skipped; the parser reports them.
    private static func options(in token: String) -> [CLIOption] {
        if token.hasPrefix("--") {
            let name = token.dropFirst(2).prefix { $0 != "=" }
            return CLIOption.all.filter { $0.long == name }
        }
        return token.dropFirst().compactMap { character in
            CLIOption.all.first { $0.short == character }
        }
    }
}
