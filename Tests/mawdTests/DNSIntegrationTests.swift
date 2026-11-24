import Foundation
import Testing

/// DNS through the Mac (docs/decisions/0024-dns-through-the-mac.md) on test distributions: the
/// guest's lookups are answered by the Mac's resolver through the agent, and no query leaves
/// the guest for the NAT network's own server, whatever the distribution's network files are
/// called. Lookups go to public names; nothing here changes the Mac's DNS configuration.
@Suite(.tags(.integration), .enabled(if: MawIntegration.isEnabled), .serialized)
struct DNSIntegrationTests {
    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    /// systemd-resolved has the agent's server and nothing else, and the drop-in for maw's own
    /// network file is in place.
    @Test func pointsSystemdResolvedAtTheAgentOnly() async throws {
        let result = try await maw.asRoot(
            """
            resolvectl status --no-pager
            echo "resolv.conf: $(grep '^nameserver' /run/systemd/resolve/resolv.conf | tr '\\n' ' ')"
            test -f /run/systemd/network/10-netplan-maw.network.d/99-maw-dns.conf && echo drop-in
            """)
        let lines = result.lines.map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains("DNS Servers: \(MawIntegration.dnsServer)"), "\(result.output)")
        #expect(lines.filter { $0.hasPrefix("DNS Servers:") }.count == 1, "\(result.output)")
        #expect(lines.contains("resolv.conf: nameserver \(MawIntegration.dnsServer) "))
        #expect(lines.contains("drop-in"))
    }

    /// A, AAAA, CNAME, MX, TXT, SRV, and PTR answered through systemd-resolved; TXT's answer
    /// is larger than UDP carries and arrives over TCP.
    @Test func answersEveryTypeThroughSystemdResolved() async throws {
        /// resolvectl's output, after it reported where the answer came from.
        func query(_ arguments: String) async throws -> String {
            let result = try await maw.session([
                "-e", "sh", "-c", "resolvectl query --cache=no \(arguments) 2>&1",
            ])
            #expect(
                result.output.contains("-- Information acquired via protocol DNS"),
                "\(result.output)")
            return result.output
        }
        let address = try await maw.session(["-e", "getent", "hosts", "github.com"])
        #expect(address.status == 0, "\(address.output)\(address.standardError)")
        #expect(try await query("-t MX gmail.com").contains("gmail-smtp-in.l.google.com"))
        #expect(try await query("-t TXT google.com").contains("v=spf1"))
        #expect(try await query("-t SRV _imaps._tcp.gmail.com").contains("imap.gmail.com"))
        #expect(try await query("-t CNAME www.github.com").contains("CNAME github.com"))
        #expect(try await query("-t AAAA google.com").contains("IN AAAA"))
        let pointer = try await maw.session(["-e", "getent", "hosts", "1.1.1.1"])
        #expect(pointer.output.contains("one.one.one.one"), "\(pointer.output)")
    }

    /// The agent's server answers NXDOMAIN only for a name that does not exist, NODATA for a
    /// name without the type, and the rest itself.
    @Test func answersEachCodeAsTheResolverExpects() async throws {
        let missing = "nx-\(UInt32.random(in: 0...UInt32.max))-maw.example.com"
        #expect(try await maw.queryAgent(missing, type: 1).code == 3)
        // github.com has had A records and no AAAA records for years.
        let noData = try await maw.queryAgent("github.com", type: 28)
        #expect(noData.code == 0 && noData.answers == 0, "\(noData)")
        let found = try await maw.queryAgent("github.com", type: 1)
        #expect(found.code == 0 && found.answers > 0, "\(found)")
        #expect(try await maw.queryAgent("google.com", type: 257).code == 4)
        #expect(try await maw.queryAgent("printer.local", type: 1).code == 5)
        #expect(try await maw.queryAgent("github.com", type: 1, malformed: true).code == 1)
        // A TXT answer larger than 512 bytes, asked without EDNS: truncated.
        let large = try await maw.queryAgent("google.com", type: 16)
        #expect(large.truncated, "\(large)")
    }

    /// No packet to port 53 leaves the guest's network interface while it looks names up.
    @Test func sendsNoQueryToTheNATNetwork() async throws {
        #expect(try await maw.packetsToPort53() == [])
    }

    /// A distribution whose network files have names of their own: maw's netplan file removed
    /// and a file named `25-own.network` in its place. At the boot, the drop-in covers it; while
    /// the machine runs, a new `15-later.network` gets its drop-in after `networkctl reload`,
    /// and no query reaches the NAT's server or the IPv6 router afterwards, also after a
    /// renewal of the DHCP lease.
    @Test func keepsTheNetworksDNSOutWhateverItsFilesAreCalled() async throws {
        try await maw.withDistribution("dnsnet") { name in
            let network =
                "[Match]\\nDriver=virtio_net\\n\\n[Network]\\nDHCP=yes\\nIPv6AcceptRA=yes\\n"
            let prepared = try await maw.asRoot(
                """
                rm -f /etc/netplan/50-maw.yaml
                printf '\(network)' > /etc/systemd/network/25-own.network
                """, in: name)
            #expect(prepared.status == 0, "\(prepared.output)\(prepared.standardError)")
            _ = try await maw.run(["--terminate", name])

            let booted = try await maw.asRoot(
                """
                \(MawIntegration.defaultInterface)
                ls /run/systemd/network
                test -f /run/systemd/network/25-own.network.d/99-maw-dns.conf && echo drop-in
                networkctl status "$IF" --no-pager | grep 'Network File'
                echo "link servers: $(resolvectl dns "$IF")"
                """, in: name)
            #expect(booted.output.contains("drop-in"), "\(booted.output)\(booted.standardError)")
            #expect(booted.output.contains("25-own.network"), "\(booted.output)")
            #expect(!booted.output.contains("10-netplan-maw.network"), "\(booted.output)")
            #expect(try await maw.packetsToPort53(in: name) == [])

            // Step 2: a network file that appears while the machine runs.
            let added = try await maw.asRoot(
                """
                \(MawIntegration.defaultInterface)
                printf '\(network)' > /etc/systemd/network/15-later.network
                networkctl reload
                for i in $(seq 100); do
                    [ -f /run/systemd/network/15-later.network.d/99-maw-dns.conf ] && break
                    sleep 0.1
                done
                test -f /run/systemd/network/15-later.network.d/99-maw-dns.conf && echo drop-in
                sleep 2
                networkctl status "$IF" --no-pager | grep 'Network File'
                echo "link servers: $(resolvectl dns "$IF" | cut -d: -f2- | tr -d ' ')."
                """, in: name)
            #expect(added.output.contains("drop-in"), "\(added.output)\(added.standardError)")
            #expect(added.output.contains("15-later.network"), "\(added.output)")
            #expect(added.output.contains("link servers: ."), "\(added.output)")
            #expect(try await maw.packetsToPort53(in: name) == [])

            let renewed = try await maw.asRoot(
                """
                \(MawIntegration.defaultInterface)
                networkctl renew "$IF"; sleep 2
                echo "link servers: $(resolvectl dns "$IF" | cut -d: -f2- | tr -d ' ')."
                """, in: name)
            #expect(renewed.output.contains("link servers: ."), "\(renewed.output)")
            #expect(try await maw.packetsToPort53(in: name) == [])
        }
    }

    /// A server that maw does not configure, given to the link by hand as another network
    /// manager would, makes the agent write a line to the console log, and another when it
    /// goes.
    @Test func writesAConsoleLineForAServerThatMawDoesNotConfigure() async throws {
        let added = try await maw.asRoot(
            """
            \(MawIntegration.defaultInterface)
            resolvectl dns "$IF" 192.168.64.1
            """)
        #expect(added.status == 0, "\(added.output)\(added.standardError)")
        #expect(
            await maw.eventually(within: .seconds(15)) {
                maw.consoleLogLines(of: maw.distribution).contains {
                    $0.contains("systemd-resolved also has the DNS server 192.168.64.1")
                }
            })
        let reverted = try await maw.asRoot(
            """
            \(MawIntegration.defaultInterface)
            resolvectl revert "$IF"
            """)
        #expect(reverted.status == 0, "\(reverted.output)\(reverted.standardError)")
        #expect(
            await maw.eventually(within: .seconds(15)) {
                maw.consoleLogLines(of: maw.distribution).contains {
                    $0.contains("systemd-resolved has only the agent's DNS server again")
                }
            })
    }

    /// A program's UDP socket on the wildcard address and port 53 binds with SO_REUSEADDR and
    /// leaves the agent its queries; its TCP socket there does not bind, as beside
    /// systemd-resolved's stub. A network namespace over a veth pair, as a container has,
    /// reaches the agent's server.
    @Test func sharesPort53AndAnswersContainers() async throws {
        let binds = try await maw.asRoot(
            """
            python3 - << 'PY'
            import socket
            for kind, name in ((socket.SOCK_DGRAM, "udp"), (socket.SOCK_STREAM, "tcp")):
                s = socket.socket(socket.AF_INET, kind)
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                try:
                    s.bind(("0.0.0.0", 53)); print(name, "bound")
                    if name == "udp": held = s
                except OSError as e:
                    print(name, "errno", e.errno)
            PY
            """)
        #expect(binds.output.contains("udp bound"), "\(binds.output)\(binds.standardError)")
        #expect(binds.output.contains("tcp errno 98"), "\(binds.output)")
        let reachable = try await maw.asRoot(
            """
            python3 - << 'PY' &
            import socket, time
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("0.0.0.0", 53)); time.sleep(10)
            PY
            P=$!
            sleep 1
            cat > /tmp/maw-query.py << 'PY'
            \(MawIntegration.queryScript)
            PY
            echo "beside: $(python3 /tmp/maw-query.py github.com 1)"
            ip netns add maw-dns-test
            ip link add maw-v0 type veth peer name maw-v1
            ip link set maw-v1 netns maw-dns-test
            ip addr add 10.99.0.1/24 dev maw-v0; ip link set maw-v0 up
            ip netns exec maw-dns-test ip addr add 10.99.0.2/24 dev maw-v1
            ip netns exec maw-dns-test ip link set maw-v1 up
            ip netns exec maw-dns-test ip route add default via 10.99.0.1
            echo "container: $(ip netns exec maw-dns-test python3 /tmp/maw-query.py github.com 1)"
            ip netns del maw-dns-test; ip link del maw-v0 2>/dev/null; rm -f /tmp/maw-query.py
            kill $P 2>/dev/null
            """)
        let lines = reachable.lines
        #expect(
            lines.contains { $0.hasPrefix("beside: rcode=0") && !$0.contains("answers=0") },
            "\(reachable.output)\(reachable.standardError)")
        #expect(
            lines.contains { $0.hasPrefix("container: rcode=0") && !$0.contains("answers=0") },
            "\(reachable.output)\(reachable.standardError)")
    }

    /// The first lookup of a cold start is answered within a second.
    @Test func answersTheFirstLookupAfterAColdStart() async throws {
        _ = try await maw.run(["--terminate", maw.distribution])
        let result = try await maw.session([
            "-e", "sh", "-c",
            "a=$(date +%s%N); getent hosts github.com > /dev/null; s=$?; b=$(date +%s%N);"
                + " echo \"status=$s microseconds=$(( (b - a) / 1000 ))\"",
        ])
        let line = try #require(result.lines.first { $0.hasPrefix("status=") }, "\(result.output)")
        #expect(line.hasPrefix("status=0 "), "\(line)")
        let microseconds = try #require(Int(line.split(separator: "=").last ?? ""))
        #expect(microseconds < 1_000_000, "\(line)")
    }

    /// A name that only a scoped resolver on the Mac knows, if the owner has added
    /// `/etc/resolver/maw-check.internal` for the run (scripts/dns-test-responder.py says how).
    @Test(
        .enabled(
            if: FileManager.default.fileExists(atPath: "/etc/resolver/maw-check.internal"),
            "No scoped resolver for maw-check.internal is installed on this Mac."))
    func resolvesANameThatOnlyAScopedResolverKnows() async throws {
        let script = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../scripts/dns-test-responder.py").standardizedFileURL
        let responder = try DebugBootProcess(
            executable: URL(filePath: "/usr/bin/python3"), arguments: ["-I", script.path],
            separateStandardError: true)
        defer { responder.signal(SIGTERM) }
        try await Task.sleep(for: .seconds(1))
        let result = try await maw.session([
            "-e", "getent", "hosts", "probe-\(UInt16.random(in: 0...9999)).maw-check.internal",
        ])
        #expect(result.output.contains("192.0.2.53"), "\(result.output)\(result.standardError)")
    }
}
