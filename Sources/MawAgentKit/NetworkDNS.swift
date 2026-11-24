import CMawSystem
import Logging
import MawProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Keeps the DNS servers of the NAT's DHCP and router advertisements out of systemd-resolved
/// (docs/decisions/0024-dns-through-the-mac.md), whatever a distribution's network files are
/// called: a drop-in for every `.network` file of systemd-networkd turns them off. The
/// initramfs runs `maw-agent network-dns` at every boot, before systemd-networkd starts, and
/// the agent writes the drop-in for a file that appears later and reloads systemd-networkd.
///
/// A link that another network manager configures is not covered. The agent watches
/// systemd-resolved's list of servers and writes a line to the console when it holds one
/// other than the agent's, so that such a server is never used without a trace.
public enum NetworkDNS {
    /// systemd-networkd's directories of `.network` files, in its order.
    public static let networkDirectories = [
        "/etc/systemd/network", "/run/systemd/network", "/usr/local/lib/systemd/network",
        "/usr/lib/systemd/network", "/lib/systemd/network",
    ]
    /// Where the drop-ins go: `<directory>/<name>.network.d/<dropInName>`.
    public static let dropInDirectory = "/run/systemd/network"
    /// Last in lexical order, so that a distribution's own drop-in cannot turn the servers on
    /// again: drop-ins apply in the order of their names across all directories.
    public static let dropInName = "99-maw-dns.conf"
    /// The list of servers that systemd-resolved writes whenever it changes.
    public static let resolvedServers = "/run/systemd/resolve/resolv.conf"
    public static let networkctl = ["/usr/bin/networkctl", "/bin/networkctl"]
    /// systemd-networkd writes this file once it runs. Before it does, the boot's unit writes
    /// the drop-ins, and the agent leaves them to it.
    public static let networkdState = "/run/systemd/netif/state"

    public static let dropIn = """
        # Written by maw at every boot: DNS through the Mac's resolver, never the DHCP or
        # router-advertised server. docs/distributions.md
        [Network]
        DNSDefaultRoute=no

        [DHCPv4]
        UseDNS=no
        UseDomains=no

        [DHCPv6]
        UseDNS=no
        UseDomains=no

        [IPv6AcceptRA]
        UseDNS=no
        UseDomains=no

        """

    /// The `.network` files among a directory's entries.
    public static func networkFiles(_ entries: [String]) -> [String] {
        entries.filter {
            $0.hasSuffix(".network") && $0.count > ".network".count && !$0.hasPrefix(".")
                && !$0.contains("/")
        }
    }

    /// The servers of a `resolv.conf` other than the agent's, in order.
    public static func otherServers(inResolvConf text: String) -> [String] {
        var servers: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "nameserver" else { continue }
            let server = String(fields[1])
            if server != AgentProtocol.dnsAddressText, !servers.contains(server) {
                servers.append(server)
            }
        }
        return servers
    }

    /// The console line when the servers other than the agent's change.
    public static func serversLine(_ servers: [String]) -> String {
        servers.isEmpty
            ? "dns: systemd-resolved has only the agent's DNS server again"
            : """
            dns: systemd-resolved also has the DNS server \(servers.joined(separator: ", ")), \
            which maw does not configure; queries may reach it instead of the Mac's resolver \
            (docs/known-limitations.md)
            """
    }

    /// What writing the drop-ins needs; `live` in the guest, a directory in tests.
    public struct Files: Sendable {
        public var entries: @Sendable (_ directory: String) -> [String]
        public var read: @Sendable (_ path: String) -> String?
        /// Creates the directory if needed and writes the file in its place atomically.
        public var write: @Sendable (_ directory: String, _ name: String, _ text: String) -> Int32

        public init(
            entries: @escaping @Sendable (String) -> [String],
            read: @escaping @Sendable (String) -> String?,
            write: @escaping @Sendable (String, String, String) -> Int32
        ) {
            self.entries = entries
            self.read = read
            self.write = write
        }
    }

    /// Writes the drop-in for every `.network` file in `directories` that lacks it, under
    /// `dropIns`. Returns the names it wrote, and the failures.
    public static func writeDropIns(
        files: Files, directories: [String] = networkDirectories,
        dropIns: String = dropInDirectory
    ) -> (written: [String], failures: [String]) {
        var names: [String] = []
        for directory in directories {
            for name in networkFiles(files.entries(directory)) where !names.contains(name) {
                names.append(name)
            }
        }
        var written: [String] = []
        var failures: [String] = []
        for name in names.sorted() {
            let directory = "\(dropIns)/\(name).d"
            guard files.read("\(directory)/\(dropInName)") != dropIn else { continue }
            let code = files.write(directory, dropInName, dropIn)
            if code == 0 {
                written.append(name)
            } else {
                failures.append("\(name): \(SystemError.message(for: code))")
            }
        }
        return (written, failures)
    }
}

extension NetworkDNS.Files {
    /// The guest's files.
    public static let live = NetworkDNS.Files(
        entries: { directoryEntries($0) },
        read: { path in readBytes(path, limit: 64 << 10).map { String(decoding: $0, as: UTF8.self) }
        },
        write: { directory, name, text in
            if mkdir(directory, 0o755) != 0 && errno != EEXIST {
                return errno
            }
            // The boot's unit and the agent may write at once; each writes its own file.
            let temporary = "\(directory)/.\(name).\(getpid()).tmp"
            let descriptor = open(
                temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o644)
            guard descriptor >= 0 else { return errno }
            do throws(SystemError) {
                try writeAll(Array(text.utf8), to: descriptor)
            } catch {
                close(descriptor)
                unlink(temporary)
                return error.code
            }
            close(descriptor)
            guard rename(temporary, "\(directory)/\(name)") == 0 else {
                let code = errno
                unlink(temporary)
                return code
            }
            return 0
        })
}

/// Watches systemd-networkd's directories and systemd-resolved's list of servers while the
/// agent runs (`NetworkDNS`). Linux only: it needs inotify.
public final class NetworkDNSWatch: @unchecked Sendable {
    private let logger: Logger
    private let files: NetworkDNS.Files
    private var watched: Set<String> = []
    private var reportedServers: [String] = []

    public init(logger: Logger, files: NetworkDNS.Files = .live) {
        self.logger = logger
        self.files = files
    }

    /// Starts the watch on a thread of its own. Returns false if it could not start.
    public func start() -> Bool {
        let descriptor = maw_inotify_open()
        guard descriptor >= 0 else {
            logger.warning("dns: cannot watch the network files: \(SystemError("inotify_init1"))")
            return false
        }
        let inotify = OwnedDescriptor(descriptor)
        return startDetachedThread { [self] in run(inotify) }
    }

    private func run(_ inotify: OwnedDescriptor) {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            // Directories that appear later, such as /run/systemd/resolve, are watched from the
            // next pass; a pass also runs every 5 seconds without an event.
            for directory in NetworkDNS.networkDirectories + ["/run/systemd/resolve"]
            where !watched.contains(directory) {
                if maw_inotify_watch(inotify.rawValue, directory) == 0 {
                    watched.insert(directory)
                }
            }
            check()
            var request = [pollfd(fd: inotify.rawValue, events: Int16(POLLIN), revents: 0)]
            _ = try? pollDescriptors(&request, timeout: 5_000)
            // Let a burst of changes, such as netplan's, settle before the next pass.
            if request[0].revents != 0 {
                usleep(50_000)
                while read(inotify.rawValue, &buffer, buffer.count) > 0 {}
            }
        }
    }

    private func check() {
        if files.read(NetworkDNS.networkdState) != nil {
            writeDropIns()
        }
        guard let text = files.read(NetworkDNS.resolvedServers) else { return }
        let servers = NetworkDNS.otherServers(inResolvConf: text)
        if servers != reportedServers {
            reportedServers = servers
            logger.warning("\(NetworkDNS.serversLine(servers))")
        }
    }

    /// Writes the drop-ins that are missing, and reloads systemd-networkd if it wrote any.
    private func writeDropIns() {
        let (written, failures) = NetworkDNS.writeDropIns(files: files)
        for failure in failures {
            logger.warning("dns: cannot write the drop-in for \(failure)")
        }
        if !written.isEmpty {
            logger.notice(
                """
                dns: turned off DHCP and router-advertised DNS for \
                \(written.joined(separator: ", ")); reloading systemd-networkd
                """)
            reloadNetwork()
        }
    }

    private func reloadNetwork() {
        guard let path = NetworkDNS.networkctl.first(where: { access($0, X_OK) == 0 }) else {
            logger.warning("dns: networkctl is not installed; the drop-ins apply at the next boot")
            return
        }
        var status: Int32 = 0
        let code = withArrayOfCStrings([path, "reload"]) { maw_run_quietly($0, &status) }
        if code != 0 || status != 0 {
            logger.warning(
                "dns: networkctl reload failed (\(code == 0 ? "status \(status)" : SystemError.message(for: code)))"
            )
        }
    }
}

/// Calls `body` with a NULL-terminated array of C strings.
func withArrayOfCStrings<Result>(
    _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) } + [nil]
    defer {
        for pointer in pointers { free(pointer) }
    }
    return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}
