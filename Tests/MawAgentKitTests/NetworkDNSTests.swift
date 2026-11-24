import MawProtocol
import Testing

@testable import MawAgentKit

/// The drop-ins that keep the network's DNS servers out of systemd-resolved, and the console
/// line about servers that maw does not configure.
@Suite struct NetworkDNSTests {
    /// Directories and files in memory.
    final class FakeFiles: @unchecked Sendable {
        let lock = ConditionLock()
        var directories: [String: [String]] = [:]
        var contents: [String: String] = [:]
        var failing: Set<String> = []

        var files: NetworkDNS.Files {
            NetworkDNS.Files(
                entries: { directory in self.lock.withLock { self.directories[directory] ?? [] } },
                read: { path in self.lock.withLock { self.contents[path] } },
                write: { directory, name, text in
                    self.lock.withLock {
                        guard !self.failing.contains(directory) else { return 13 }
                        self.contents["\(directory)/\(name)"] = text
                        return 0
                    }
                })
        }
    }

    @Test func picksTheNetworkFilesOfADirectory() {
        #expect(
            NetworkDNS.networkFiles([
                "10-netplan-maw.network", "25-own.network", "x.netdev", ".hidden.network",
                ".network", "10-netplan-maw.network.d", "99-default.link",
            ]) == ["10-netplan-maw.network", "25-own.network"])
    }

    @Test func writesADropInForEveryNetworkFileWhateverItIsCalled() {
        let fake = FakeFiles()
        fake.directories = [
            "/etc/systemd/network": ["25-own.network", "notes.txt"],
            "/run/systemd/network": ["10-netplan-maw.network"],
            "/usr/lib/systemd/network": ["80-container-ve.network", "25-own.network"],
        ]
        let (written, failures) = NetworkDNS.writeDropIns(files: fake.files)
        #expect(written == ["10-netplan-maw.network", "25-own.network", "80-container-ve.network"])
        #expect(failures.isEmpty)
        #expect(
            fake.contents["/run/systemd/network/25-own.network.d/99-maw-dns.conf"]
                == NetworkDNS.dropIn)
        // Nothing to write the second time; a file that appears later gets its drop-in.
        #expect(NetworkDNS.writeDropIns(files: fake.files).written.isEmpty)
        fake.directories["/etc/systemd/network"]?.append("15-later.network")
        #expect(NetworkDNS.writeDropIns(files: fake.files).written == ["15-later.network"])
    }

    @Test func rewritesADropInThatWasChangedAndReportsFailures() {
        let fake = FakeFiles()
        fake.directories = ["/etc/systemd/network": ["a.network", "b.network"]]
        fake.contents["/run/systemd/network/a.network.d/99-maw-dns.conf"] = "[DHCPv4]\nUseDNS=yes\n"
        fake.failing = ["/run/systemd/network/b.network.d"]
        let (written, failures) = NetworkDNS.writeDropIns(files: fake.files)
        #expect(written == ["a.network"])
        #expect(failures.count == 1)
        #expect(failures.first?.hasPrefix("b.network: ") == true)
    }

    @Test func turnsOffEverySourceOfTheNetworksDNS() {
        for line in [
            "DNSDefaultRoute=no", "[DHCPv4]", "[DHCPv6]", "[IPv6AcceptRA]", "UseDNS=no",
            "UseDomains=no",
        ] {
            #expect(NetworkDNS.dropIn.contains(line))
        }
        #expect(NetworkDNS.dropInName == "99-maw-dns.conf")
    }

    @Test func findsServersOtherThanTheAgentsInResolvConf() {
        let text = """
            # This is /run/systemd/resolve/resolv.conf managed by man:systemd-resolved(8).
            nameserver 169.254.77.53
            nameserver 192.168.64.1
            nameserver\tfe80::1%2
            nameserver 192.168.64.1
            search example.org
            """
        #expect(NetworkDNS.otherServers(inResolvConf: text) == ["192.168.64.1", "fe80::1%2"])
        #expect(NetworkDNS.otherServers(inResolvConf: "nameserver 169.254.77.53\n").isEmpty)
        #expect(NetworkDNS.serversLine(["192.168.64.1"]).contains("192.168.64.1"))
        #expect(NetworkDNS.serversLine([]).contains("only the agent's DNS server"))
    }

    @Test func runsTheBootStepAsASubcommand() {
        #expect(AgentCommand(argv: ["maw-agent", "network-dns"]) == .networkDNS)
        #expect(AgentCommand(argv: ["maw-agent", "network-dns", "x"]) == .usage(status: 64))
    }
}
