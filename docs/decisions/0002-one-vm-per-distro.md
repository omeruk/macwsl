# 0002: One VM per distribution (for v1)

- Status: Accepted
- Date: 2026-10-20

## Context

WSL2 runs all distributions in a single shared "utility" VM. Each distribution gets its own
root file system and Linux namespaces (PID, mount, and so on), but every distribution shares
one kernel, one pool of memory and one network stack.

MacWSL has to choose between that model and giving each distribution its own VM.

## Decision

For v1, each distribution runs in its own VM. All VMs boot the same kernel and initramfs, and
each one gets that distribution's disk image as its root file system.

## Reasons

- **Isolation is simpler and stronger.** Distributions share no kernel, memory or file system
  state. A kernel panic, an out-of-memory condition or a misbehaving service in one distribution
  cannot affect another. Isolation comes from the hypervisor, not from namespaces we would have
  to configure correctly.
- **Lifecycle is simpler.** `--terminate <distro>` stops one VM, and `--shutdown` stops all of
  them. There is no in-guest container runtime and no need to track which distributions are
  "running" inside a VM that stays up anyway.
- **The guest stays minimal.** The initramfs mounts one root and starts one agent. In a shared
  VM it would also have to set up namespaces, cgroups and per-distribution init.
- **Per-distribution settings come for free.** Memory, CPU count and kernel command line can
  differ per distribution later without extra machinery.
- **Starting a distribution is cheap.** Booting a second VM takes about a second, the same as the
  first.

## Trade-off: memory

This is the main cost. Each running VM has:

- its own kernel and agent, which is a small fixed overhead (tens of MB);
- its own page cache, so files read in two distributions are cached twice;
- its own memory ceiling, which with several distributions running can add up to more than one
  shared VM would need.

WSL2's shared VM avoids all three. We reduce the cost by:

- returning free guest memory to macOS with a virtio memory balloon;
- shutting down idle VMs after a timeout (phase 12);
- using a modest default memory size that `~/.macwslconfig` can raise.

Most users run one distribution at a time, and for them the two models cost about the same.

## Other differences from WSL2

- Each distribution gets its own IP address on the NAT network instead of sharing one. Port
  forwarding (phase 08) is per VM.
- Two distributions cannot see each other's processes or share a mount without going through
  the network or `/mnt/mac`.

## Keeping a shared VM possible

A shared VM may come later if memory use turns out to be the main complaint. To keep that
option open:

- Public APIs in `MacWSLDaemonKit` talk about distributions, not VMs. The mapping from
  distribution to VM stays an internal detail of the daemon.
- The host/guest protocol (phase 04) names the target distribution explicitly, so that one agent
  could later serve several distributions.
