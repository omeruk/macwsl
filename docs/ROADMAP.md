# Roadmap

Each phase has a matching prompt in `prompts/`. A phase is done when its acceptance criteria
pass on a real Apple Silicon Mac.

| #  | Phase                          | Outcome                                                                  | Status  |
|----|--------------------------------|--------------------------------------------------------------------------|---------|
| 01 | Scaffold                       | Package layout, CLI skeleton with all commands stubbed, CI, lint         | Done    |
| 02 | Kernel and initramfs           | Reproducible build of a minimal arm64 kernel and initramfs in CI         | Done    |
| 03 | First boot                     | `mawd` boots a VM, serial console logged, clean shutdown                 | Done    |
| 04 | Guest agent                    | `debug-boot --exec` and `--shell` run commands in the guest over vsock; clean shutdown | Done    |
| 04b | CLI and daemon (XPC)          | `maw -- uname -a` works through the daemon over XPC                      | Done    |
| 05 | Distro install                 | `maw --install Ubuntu-24.04`: download, verify, provision, first user    | Done    |
| 06a | Distro management             | list, set-default, terminate                                             | Done    |
| 06b | Distro removal and transfer   | unregister, export, import                                               | Planned |
| 07 | File sharing and paths         | `/mnt/mac` via virtiofs, cwd translation, `mawpath`                      | Planned |
| 08 | Networking                     | Port forwarding and `localhost` access from macOS, DNS under VPNs (NAT and DHCP arrived in 05) | Planned |
| 09 | Interop                        | Run macOS commands from Linux, clipboard, `open`                         | Planned |
| 10 | Rosetta                        | Run x86_64 Linux binaries through Rosetta                                 | Planned |
| 11a | Terminal app foundation      | maw app: title-bar tabs, split panes, command palette, themes, settings (local shell) | Done    |
| 11b | Linux sessions in the app    | Distribution tabs and profiles, the distributions screen's list and actions, through the daemon | Done    |
| 11c | Distributions screen figures | Live memory, CPU, disk, uptime, and kernel, the details box, and the memory chart | Done    |
| 11 | Terminal app                   | SwiftUI + SwiftTerm app: tabs, distro profiles, themes, settings         | Done    |
| 12 | Configuration and lifecycle    | `.mawconfig`, `maw.conf`, idle shutdown, sleep/wake clock sync, a `.mawconfig` setting to choose `.fsync` disk synchronization ([0013](decisions/0013-systemd-and-the-agent.md)) | Planned |
| 12b | Hardening                    | Close the limitations recorded in [`docs/known-limitations.md`](known-limitations.md), long-running and sleep/wake soak tests, `docs/security.md` review, beta testing | Planned |
| 13 | Packaging and release          | Signed, notarized app; Homebrew cask; auto-update                        | Planned |

Phase 11 is delivered as phases 11a, 11b, and 11c. Phase 11b is delivered in two pull
requests: the first (#25) adds Linux tabs in the app, and the second (#26) adds the profiles
per installed distribution and the distributions screen's list and actions. Phase 11c is
delivered in two pull requests: the first (#29) adds the figures in the daemon, and the
second (#30) shows them on the distributions screen.
