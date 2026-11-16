#if os(macOS)
    import MawCore

    /// The checks of an extracted archive before it is configured (docs/distributions.md, "What
    /// --import configures"): that its top level holds a root file system, that its
    /// `/sbin/init` is systemd, and where the files are that choose its default user.
    ///
    /// `script` runs in the provisioning machine with busybox `sh`, as
    /// `sh -s -- <root>`, and prints one line per finding. Every path is resolved inside the
    /// root with `ProvisioningScript.functions`, so that a link in the archive is followed as
    /// the imported system would follow it, never into the provisioning machine's own files.
    /// `Report` reads the lines, and `evaluate(for:)` decides.
    enum ImportInspection {
        /// How many of the top level's entries the script names, for the error message, and
        /// how many characters of each name the message shows, so that its line fits in 80
        /// columns.
        static let namedEntries = 3
        static let nameLength = 12

        static let script = #"""
            set -eu
            root=$1
            newline='
            '
            tab=$(printf '\t')

            \#(ProvisioningScript.functions)

            # The top level: how many entries it has, and the first few, with / after a directory.
            # lost+found is the formatting's, not the archive's.
            count=0
            for entry in "$root"/* "$root"/.[!.]* "$root"/..?*; do
                if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
                    continue
                fi
                if [ "${entry##*/}" = lost+found ]; then
                    continue
                fi
                count=$((count + 1))
                if [ "$count" -le \#(namedEntries) ]; then
                    # One record per line, with tabs between fields: a line break or a tab in a
                    # name is shown as ?.
                    name=$(printf '%s' "${entry##*/}" | tr '\n\t' '??')
                    if [ -d "$entry" ] && [ ! -L "$entry" ]; then
                        name=$name/
                    fi
                    printf 'entry\t%s\n' "$name"
                fi
            done
            printf 'entries\t%s\n' "$count"

            # Each path that the import needs, resolved inside the root, and what it is there;
            # and whether the path itself, before it is resolved, ends in a link.
            for path in \#(Path.allCases.map(\.rawValue).joined(separator: " ")); do
                parent=$(resolve "${path%/*}")
                link=plain
                if [ -L "$root${parent%/}/${path##*/}" ]; then
                    link=link
                fi
                found=$(resolve "$path")
                case $found in
                /*)
                    if [ -d "$root$found" ]; then
                        kind=directory
                    elif [ -f "$root$found" ] && [ -x "$root$found" ]; then
                        kind=executable
                    elif [ -f "$root$found" ]; then
                        kind=file
                    elif [ -e "$root$found" ]; then
                        kind=other
                    else
                        kind=missing
                    fi
                    ;;
                *)
                    kind=unresolvable
                    found=${found#!}
                    ;;
                esac
                case $found in
                *"$newline"* | *"$tab"*)
                    kind=unresolvable
                    found="a name on its way contains a line break or a tab"
                    ;;
                esac
                printf 'path\t%s\t%s\t%s\t%s\n' "$path" "$kind" "$link" "$found"
            done
            """#

        /// The paths that the inspection resolves.
        enum Path: String, CaseIterable, Sendable {
            case passwd = "/etc/passwd"
            case usr = "/usr"
            case initProgram = "/sbin/init"
            case mawConf = "/etc/maw.conf"
            case wslConf = "/etc/wsl.conf"
        }

        /// What a resolved path is inside the root.
        enum Kind: String, Sendable {
            case directory, executable, file, other, missing, unresolvable
        }

        /// A path, resolved: where it leads inside the root and what is there, or the reason it
        /// cannot be resolved.
        struct Finding: Equatable, Sendable {
            var kind: Kind
            /// The resolved path, starting with `/`; for `unresolvable`, the reason.
            var found: String
            /// Whether the path's last component, where the path's directory leads, is a link.
            var isLink = false

            var isRegularFile: Bool { kind == .file || kind == .executable }
        }

        /// The script's output, read.
        struct Report: Equatable, Sendable {
            /// The first entries of the top level, a directory with `/` after its name.
            var entries: [String] = []
            var entryCount = 0
            var findings: [Path: Finding] = [:]

            init(entries: [String] = [], entryCount: Int = 0, findings: [Path: Finding] = [:]) {
                self.entries = entries
                self.entryCount = entryCount
                self.findings = findings
            }

            /// Reads the script's output. Lines it does not know are ignored; a path that the
            /// output does not name reads as missing.
            init(parsing output: String) {
                for line in output.split(separator: "\n") {
                    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                        .map(String.init)
                    switch fields.first {
                    case "entry" where fields.count >= 2:
                        entries.append(fields[1...].joined(separator: "\t"))
                    case "entries" where fields.count == 2:
                        entryCount = Int(fields[1]) ?? 0
                    case "path" where fields.count >= 5:
                        guard let path = Path(rawValue: fields[1]),
                            let kind = Kind(rawValue: fields[2])
                        else { continue }
                        findings[path] = Finding(
                            kind: kind, found: fields[4...].joined(separator: "\t"),
                            isLink: fields[3] == "link")
                    default:
                        continue
                    }
                }
            }

            func finding(_ path: Path) -> Finding {
                findings[path] ?? Finding(kind: .missing, found: path.rawValue)
            }

            /// The files to read: the resolved paths of `/etc/passwd`, `/etc/maw.conf`, and
            /// `/etc/wsl.conf` that are regular files.
            var files: [Path: String] {
                var files: [Path: String] = [:]
                for path in [Path.passwd, .mawConf, .wslConf] where finding(path).isRegularFile {
                    files[path] = finding(path).found
                }
                return files
            }

            /// Throws the error that refuses the import of `name`, or returns if the root file
            /// system may be configured.
            func evaluate(for name: DistroName) throws(MawError) {
                for path in [Path.passwd, .usr, .mawConf, .wslConf] {
                    let finding = finding(path)
                    if finding.kind == .unresolvable {
                        throw .importPathNotResolvable(
                            name, path: path.rawValue, reason: finding.found)
                    }
                }
                let hasPasswd = finding(.passwd).isRegularFile
                let hasUsr = finding(.usr).kind == .directory
                if !hasPasswd || !hasUsr {
                    throw .importNotARootFileSystem(
                        name, found: topLevel(missingPasswd: !hasPasswd, missingUsr: !hasUsr))
                }
                if let reason = initReason() {
                    throw .importInitNotSystemd(name, reason: reason)
                }
            }

            /// Why `/sbin/init` is not systemd, or `nil` if it is: a regular, executable file
            /// named `systemd`, such as `/usr/lib/systemd/systemd`, after every link.
            func initReason() -> String? {
                let finding = finding(.initProgram)
                let path = Path.initProgram.rawValue
                let found = Self.printable(finding.found, limit: 36)
                switch finding.kind {
                case .unresolvable:
                    return "\(path) cannot be followed: \(found)"
                case .missing where !finding.isLink:
                    return "the archive has no \(path)"
                case .missing:
                    return "\(path) leads to \(found), which does not exist"
                case .directory, .other:
                    return "\(path) leads to \(found), which is not a file"
                case .file:
                    return "\(path) leads to \(found), which is not executable"
                case .executable:
                    if finding.found.split(separator: "/").last == "systemd" {
                        return nil
                    }
                    return finding.found == path
                        ? "\(path) is a program of its own"
                        : "\(path) leads to \(found)"
                }
            }

            /// What the top level holds, for `importNotARootFileSystem`.
            func topLevel(missingPasswd: Bool, missingUsr: Bool) -> String {
                if entryCount == 0 {
                    return "the archive is empty"
                }
                let names = entries.prefix(namedEntries).map {
                    Self.printable($0, limit: nameLength)
                }
                if entryCount == 1, let only = names.first, only.hasSuffix("/") {
                    return "its top level holds only the directory \(only)"
                }
                var listed = names.joined(separator: ", ")
                if entryCount > names.count {
                    listed += ", and \(entryCount - names.count) more"
                }
                let missing = [missingPasswd ? "etc/passwd" : nil, missingUsr ? "usr/" : nil]
                    .compactMap { $0 }.joined(separator: " or ")
                return "its top level holds \(listed),\nbut no \(missing)"
            }

            /// `text` with every control character replaced by `?`, and shortened to `limit`
            /// characters with `…` at the end, for a line of an error message.
            static func printable(_ text: String, limit: Int) -> String {
                var result = String(
                    String.UnicodeScalarView(
                        text.unicodeScalars.map {
                            $0.properties.generalCategory == .control ? "?" : $0
                        }))
                if result.count > limit {
                    result = String(result.prefix(limit - 1)) + "…"
                }
                return result
            }
        }
    }
#endif
