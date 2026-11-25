# 0024: A distribution's DNS queries are answered by the Mac's resolver through the agent

- Status: Accepted
- Date: 2026-11-24

## Context

Phase 08 ([prompt](../../prompts/08-networking.md)), pull request B, makes the guest's DNS
follow the Mac's resolver configuration, as WSL's `dnsTunneling` does. The owner decided that
DNS goes through the Mac's resolver for every distribution, with no switch in this phase
([0023](0023-localhost-forwarding.md), "Context", decision 3); a switch belongs to phase 12's
`.mawconfig`. The network device stays NAT through `VZNATNetworkDeviceAttachment`
([0014](0014-network-in-phase-05.md)).

Until this pull request, systemd-resolved in the guest asked the NAT's DNS server at
`192.168.64.1`, which the DHCP lease named, and the IPv6 router that router advertisements named.

## What the platform does

**Part 1 of the phase,** before pull request A, measured on the owner's Mac (M1 Pro, macOS
27.0.1, guest files `217aabb`), through the test daemon:

- `DNSServiceQueryRecord` (`dns_sd.h`) returned `kDNSServiceErr_NoSuchRecord` (-65554) both for
  a name that does not exist and for a name without the requested type: the API does not tell
  NXDOMAIN from NODATA.
- `192.168.64.1` answered NOERROR for names that do not exist, truncated TXT answers, and
  already followed the Mac's scoped resolvers (`/etc/resolver/`).
- The first lookup after a cold start took about 5.5 s ("The first DNS query after the DHCP
  lease is not answered" in [docs/known-limitations.md](../known-limitations.md) before this
  pull request).
- No VPN was measured: the one available, WARP, failed with an IPC error.

**Routing in systemd-resolved,** measured on 2026-11-24 with a throwaway test on a test
distribution (systemd 255.4-1ubuntu8.17): a server on `169.254.77.53` answered every query
with a fixed address, and a packet capture on the guest's network interface counted the packets
to port 53 that left it, during the same eight lookups of several kinds in each case.

| Configuration | Packets to `192.168.64.1` or the IPv6 router | Queries at `169.254.77.53` |
|---|---|---|
| As before this pull request | 17 to `192.168.64.1`, 2 to the router | 0 |
| Global `DNS=169.254.77.53` and `Domains=~.`; the link keeps its DHCP server | 12 | 12 |
| The same after `networkctl renew` | 12 | 11 |
| Global `DNS=169.254.77.53` without `Domains=~.` | 20 | 11 |
| A drop-in for every `.network` file: `UseDNS=no` and `UseDomains=no` for DHCPv4, DHCPv6, and router advertisements, `DNSDefaultRoute=no` | 0 | 18 |

- A global server, even with the routing domain `~.`, does not keep systemd-resolved from
  asking the link's server as well: it sends each query to both.
- The NAT's DHCP gives the link the Mac's search domain as a link domain. A name under it would
  go to the link's server alone.
- `netplan generate` left the drop-in directories under `/run/systemd/network` in place.

**Port 53 in the guest,** measured in the same way with a server bound to `169.254.77.53` with
`SO_REUSEADDR` on UDP and TCP, against one with systemd-resolved's stub alone:

| A program binds | Beside the agent's server | Beside systemd-resolved's stub |
|---|---|---|
| UDP `0.0.0.0:53` or `[::]:53`, without `SO_REUSEADDR` | `EADDRINUSE` | `EADDRINUSE` |
| UDP `0.0.0.0:53` or `[::]:53`, with `SO_REUSEADDR` | bound; queries to `169.254.77.53` still reach the server | bound |
| TCP `0.0.0.0:53` or `[::]:53` | `EADDRINUSE`, with or without `SO_REUSEADDR` | `EADDRINUSE` |
| UDP `169.254.77.53:53` with `SO_REUSEADDR` | bound, and it receives the queries | not applicable |
| TCP `169.254.77.53:53` | `EADDRINUSE` | not applicable |

- With `SO_BINDTODEVICE` to `lo`, the server kept its queries beside a program on
  `169.254.77.53`, but a network namespace over a veth pair, as a container has, could no
  longer reach it. `SO_REUSEPORT` and `IP_FREEBIND` changed nothing.
- A server bound without `SO_REUSEADDR` left connections in `TIME_WAIT` that made the next
  bind of the same address and port fail.

## Decision

1. **The API is `DNSServiceQueryRecord`,** on one shared connection to mDNSResponder per daemon
   (`kDNSServiceFlagsShareConnection`), with `kDNSServiceFlagsReturnIntermediates`, so that the
   CNAMEs on the way arrive, and `kDNSServiceFlagsTimeout` (`MacDNSResolver`). It is the Mac's
   system resolver: it applies scoped resolvers, VPN and NetworkExtension DNS settings, and the
   Mac's cache, and it returns any record type with its TTL and its data on the wire.
   `getaddrinfo` returns addresses only, without TTLs, and blocks; `res_query` and `dns_query`
   read the primary resolver's configuration and miss VPN and NetworkExtension DNS;
   Network.framework has no API for records. Lookups only query: nothing registers,
   reconfirms, or flushes a record. Each has a deadline of 3.5 s.

2. **NXDOMAIN needs evidence.** When the Mac reports no record of the requested type, the
   daemon looks up the end of the CNAME chain for A, AAAA, TXT, MX, SRV, NS, and SOA, without
   the requested type, at once (`DNSAnswerer`). A record of any of them, a probe that fails or
   times out, or no room for the probes gives NODATA; only when every probe reports no record
   is the answer NXDOMAIN. `kDNSServiceErr_NoSuchName`, if mDNSResponder reports it, is NXDOMAIN
   at once. An NXDOMAIN for a name that exists, such as AAAA for a name with A records only,
   the most common negative lookup, would tell the guest's resolver that the name has no
   records of any type. The cost is a name whose only records are of a type outside the probes,
   such as CAA, which is answered NXDOMAIN for the seven types
   ([docs/known-limitations.md](../known-limitations.md)). Responses carry no SOA, so the guest
   does not cache negative answers; the Mac's cache does.

3. **The agent answers on `169.254.77.53`, UDP and TCP port 53** (`AgentProtocol.dnsAddress`,
   `DNSServer`), an address that it adds to the loopback interface with rtnetlink at its start.
   It is not in `127.0.0.0/8` because Docker drops loopback nameservers and gives containers on
   its default bridge `8.8.8.8` instead, which would bypass the Mac; a non-loopback address on
   `lo` is reachable from a container's network namespace (measured above). A link-local
   address does not collide with a VPN's or a LAN's ranges; 77 is "M", as in the agent's vsock
   ports. Port 53 because a `resolv.conf` cannot name another port. The sockets have
   `SO_REUSEADDR` and no `SO_BINDTODEVICE` (measured above). The agent listens from its start,
   which comes early in the boot, without systemd's default dependencies
   ([0013](0013-systemd-and-the-agent.md)), and binds again every second until it succeeds. Forwarding ignores the listener: its address is neither a wildcard nor a loopback
   address, and the agent leaves out its own sockets
   ([0023](0023-localhost-forwarding.md)).

4. **How systemd-resolved is pointed at it, at every boot,** without a write to the
   distribution's `/etc` (`Guest/initramfs/init`):
   - `/run/systemd/resolved.conf.d/99-maw-dns.conf`: `DNS=169.254.77.53`, `Domains=~.`, and
     `ResolveUnicastSingleLabel=yes`.
   - The runtime unit `maw-network-dns.service`, ordered before systemd-networkd and
     systemd-resolved, runs `maw-agent network-dns`, which writes
     `/run/systemd/network/<name>.network.d/99-maw-dns.conf` for every `.network` file in
     systemd-networkd's directories, whatever it is called: `DNSDefaultRoute=no`, and
     `UseDNS=no` and `UseDomains=no` for DHCPv4, DHCPv6, and router advertisements. Generators,
     netplan's included, run before units, so its files are there. Both drop-ins are named to
     apply after the distribution's own, since drop-ins apply in the order of their names
     across all directories. Every DHCP renewal then follows the configuration; nothing
     reacts to it.
   - While the machine runs, the agent watches systemd-networkd's directories with inotify.
     For a `.network` file without the drop-in, it writes the drop-in and runs
     `networkctl reload`. Between the user's reload and the agent's, milliseconds, the new
     file's DHCP server is configured ([docs/known-limitations.md](../known-limitations.md)).
   - The agent also watches `/run/systemd/resolve/resolv.conf`, systemd-resolved's list of
     every server. When it holds a server other than `169.254.77.53`, as one that another
     network manager, such as NetworkManager, gives a link, the agent writes a line to the
     console log naming it, and another when it is gone, so that no other server is ever used
     without a trace. Such a link is outside the drop-ins
     ([docs/known-limitations.md](../known-limitations.md)).
   - A distribution without systemd-resolved: maw links its `/etc/resolv.conf` to
     systemd-resolved's stub at installation and import, and the stub file that the initramfs
     writes (decision 7) is never replaced, so glibc asks `169.254.77.53` directly. It never
     reaches `192.168.64.1` unless its user writes that server into a file of its own.

5. **Search domains and single-label names.** The guest's resolver has no search domains: the
   link's DHCP domain is turned off with its server. glibc sends a single-label name, such as
   `buildhost`, as it is, and `ResolveUnicastSingleLabel=yes` lets systemd-resolved pass it on.
   For a single-label A or AAAA query, the daemon tries the Mac's current search domains in
   order, at most 6, from SystemConfiguration (`State:/Network/Global/DNS`, `SearchDomains`):
   the first name that has records is answered as a CNAME from the single label to it, followed
   by its records, so that `getent hosts buildhost` shows the canonical name, as `getaddrinfo`
   on the Mac does. Otherwise, and for other types and multi-label names, the name is looked up
   as it is. The search domains thus follow a VPN's connection and disconnection without a
   change in the guest; systemd-resolved's own search list could only be changed at run time by
   racing systemd-networkd.

6. **What is answered without the Mac** (`DNSQueryPolicy`, applied by the agent and again by
   the daemon):

   | Query | Answer |
   |---|---|
   | A, AAAA, CNAME, MX, TXT, SRV, PTR, class IN | The Mac's records and TTLs, or NODATA, or NXDOMAIN |
   | Another type, `ANY` included, another class, or an opcode other than QUERY | NOTIMP |
   | Malformed, larger than 512 bytes, not one question, a compressed question, an additional record other than one OPT, EDNS version other than 0 | FORMERR |
   | Fewer than 12 bytes, or a response | Nothing |
   | `.local`, `254.169.in-addr.arpa`, `8.e.f.ip6.arpa` to `b.e.f.ip6.arpa` | REFUSED: the Mac would ask multicast DNS, which needs the Local Network permission |

   DNSSEC is not validated: a response never sets AD and never carries an RRSIG. A name that
   the daemon builds, from a search domain or the end of a CNAME chain, gets the same check
   against the multicast zones before it reaches the Mac's resolver.

   systemd-resolved retries a transaction that gets NOTIMP once at the lower feature level UDP,
   without EDNS, and then returns NOTIMP; its debug log in the integration run showed the next
   transactions at UDP+EDNS0 again, so the server is not downgraded for later queries. Each
   query of an unsupported type costs that one retry.

7. **The first query of a boot.** The path no longer depends on DHCP or on the NAT network:
   it crosses `lo` and vsock. The daemon opens the DNS channel as soon as the agent answers
   `info`, before the forwarding channel. A query that arrives before the channel is open waits
   for it for up to 500 ms, at most 64 queries, and is then answered SERVFAIL.

   A session can also begin before systemd-resolved has started: the daemon reports the machine
   running when the agent answers, and the console log of the integration run shows the agent
   ready before systemd starts systemd-resolved. glibc then finds nss-resolve unavailable and
   reads `/etc/resolv.conf`, whose target, `/run/systemd/resolve/stub-resolv.conf`, did not
   exist yet, so it asked `127.0.0.1` and failed within 2 ms. The initramfs therefore writes
   `stub-resolv.conf` and `resolv.conf` there with `nameserver 169.254.77.53`, and
   systemd-resolved replaces both when it starts. The alternative, holding the machine's
   readiness until systemd-resolved runs, would delay every cold start.

8. **Failure.** A query passed to the host and not answered within 5 seconds by the agent's
   clock, or within 4 seconds by the daemon's, is answered SERVFAIL, and so is every query
   in flight when the channel ends. The daemon opens a channel that ended again after 1 second,
   and the next query uses it. There is no fallback to `192.168.64.1` or to any other server,
   and none is offered. The console log records when the channel opens and ends, and the
   agent's count of SERVFAIL answers given for want of a channel, at most once every
   10 seconds. systemd-resolved may answer SERVFAIL by asking again at a lower feature level,
   UDP without EDNS or TCP; the agent serves both.

9. **Limits.**

   | Limit | Value | Beyond it |
   |---|---|---|
   | A query | 512 bytes | FORMERR |
   | Queries in flight per distribution, in the agent and in the daemon | 128 (`AgentProtocol.maximumDNSQueriesInFlight`) | REFUSED |
   | Queries waiting for the channel | 64, for 500 ms | SERVFAIL |
   | Rate per distribution, in the daemon | 500 per second, bursts of 1,000 | REFUSED |
   | Lookups of the Mac's resolver per distribution, the probes included | 256 | A query: SERVFAIL; a probe: none, so NODATA |
   | Records kept from one lookup | 256 | The rest are dropped |
   | Search domains tried | 6 | The rest are not tried |
   | A UDP response | the query's EDNS payload size within 512 to 4,096 bytes, 512 without EDNS | The question alone, with the TC bit: the resolver asks again over TCP |
   | A TCP response | 65,535 bytes | SERVFAIL |
   | TCP connections to the agent's server | 16; idle for 10 s, closed | Closed at once |
   | Queries in flight on one TCP connection | 16 | Its input waits |
   | A `dnsQuery` or `dnsAnswer` frame | a 4-byte tag and 1 to 65,535 bytes | A protocol violation closes the channel |

   A query repeated over UDP from the same source with the same ID while the first is in
   flight is passed on once.

10. **The answers are counted, never named.** Every 60 seconds in which it answered queries,
    and when the machine stops, the daemon writes one line to `mawd.log` and to the machine's
    console log, such as `dns: answered 42 queries in 60 s: 30 with records, 8 NODATA,
    3 NXDOMAIN, 1 SERVFAIL, 0 refused, not supported, or malformed`. Names, addresses, and
    types are never logged.

11. **The protocol, version 9.** The DNS channel is a connection that the agent dials, as the
    forwarding channel is, with the request `dns`; it carries `dnsQuery` and `dnsAnswer`
    frames, each a 4-byte tag that the agent chooses and one DNS message
    ([docs/protocol.md](../protocol.md), "DNS"). It does not take one of the agent's 64
    session slots, and the agent allows one at a time. The daemon interface does not change.

## Measurements of the implementation

To be added from the development runs of `scripts/measure-dns.sh`.

## Consequences

- The guest's DNS follows the Mac's scoped resolvers and VPNs, and gets NXDOMAIN for a name
  that does not exist, which `192.168.64.1` did not give.
- `192.168.64.1` is no longer a DNS server in any distribution whose links systemd-networkd
  configures; a link that another network manager configures is reported on the console.
- A program in the distribution that binds TCP port 53 on a wildcard address fails, as beside
  systemd-resolved's stub, now also when the stub is turned off
  ([docs/known-limitations.md](../known-limitations.md)).
- The guest can ask the Mac's resolver for any name, as any program on the Mac can
  ([docs/security.md](../security.md)).
