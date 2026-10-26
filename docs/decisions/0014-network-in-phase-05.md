# 0014: Distributions reach the network through NAT from phase 05

- Status: Accepted
- Date: 2026-10-22

## Context

The roadmap placed networking in phase 08. A distribution without a network cannot run
`apt update`, which makes an installed Ubuntu of little use, and the phase 05 acceptance
criteria include `sudo apt install htop`. Phase 08 also covers what a user needs beyond
outbound connections: forwarding ports and reaching the guest's services as `localhost` from
macOS, and DNS behavior under VPNs.

## Decision

1. Each distribution's machine has one virtio network device attached to
   `VZNATNetworkDeviceAttachment`: the guest reaches the network through the Mac with NAT, and
   the Mac provides DHCP and DNS on that network.
2. The device's MAC address is a random locally administered address generated at installation
   and stored in `distro.json`, so that the guest keeps its DHCP address across boots.
3. In the guest, provisioning writes `/etc/netplan/50-maw.yaml`, which configures DHCP through
   systemd-networkd on the device that the `virtio_net` driver serves, and links
   `/etc/resolv.conf` to systemd-resolved's stub resolver. `systemd-networkd-wait-online` is
   masked, so that the boot does not wait for the network.
4. Port forwarding, `localhost` access from macOS, and DNS under VPNs remain in phase 08.

## Reasons

- NAT through Virtualization.framework needs no privileges, no helper, and no configuration on
  the Mac, and the network follows the Mac's (Wi-Fi, Ethernet, VPN) without maw's involvement.
- Ubuntu's own network stack configures the guest, so that its tools and logs behave as on any
  Ubuntu system.

## Security

The guest can open outbound connections, as any program on the Mac can. Nothing listens on
the Mac for the guest, and the guest has no access to the Mac's files in this phase. Inbound
connections from other machines cannot reach the guest: the NAT network is private to this
Mac. docs/security.md describes the network as an entry point.

## Measurements

On the NAT network the guest received `192.168.64.3/24` and an IPv6 address, with DNS at
`192.168.64.1`. The first `apt-get update` fetched 39.9 MB in 16.6 s; the integration tests
report a second update with a warm cache.
