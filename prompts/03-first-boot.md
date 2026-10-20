# Phase 03: First boot

Read `CLAUDE.md` and `docs/decisions/` first. Work on branch `phase/03-first-boot` from the
latest `main`.

## Goal

Boot the phase 02 kernel and initramfs on a real Mac with Virtualization.framework. At the
end of this phase, a developer can run the command below and get the initramfs shell in
their terminal:

```sh
macwsld debug-boot --interactive
```

The command must also shut the VM down cleanly. This phase builds the virtual machine layer
that every later phase uses. The XPC service and the CLI integration come later.

The phase 02 files are installed by `scripts/fetch-guest.sh` into
`~/Library/Application Support/MacWSL/kernel/`:
- `Image`
- `initramfs.cpio.gz`
- `manifest.json`

## Tasks

1. **VM configuration** (`MacWSLVirtualization`)

   `VMConfiguration` is a plain `Sendable` value type that does not import Virtualization
   types into its public interface. It holds:
   - CPU count and memory size
   - Kernel URL, initramfs URL, and kernel command line
   - Zero or more disk image URLs, each read-write or read-only
   - The console log URL

   Defaults:
   - CPUs: `min(4, host cores)`
   - Memory: 2 GiB
   - Command line: `console=hvc0`

   A function builds and validates a `VZVirtualMachineConfiguration` from it with:
   - `VZLinuxBootLoader`
   - A virtio console port on `hvc0` (`VZVirtioConsoleDeviceSerialPortConfiguration`)
   - A virtio entropy device
   - A traditional memory balloon
   - A virtio socket device (phase 04 uses it)
   - One virtio block device per disk

   CPU and memory are clamped to the limits that `VZVirtualMachineConfiguration` reports.
   `validate()` errors are mapped to `MacWSLError` cases with a recovery suggestion.

   Networking and file sharing are out of scope.

2. **VM lifecycle** (`MacWSLVirtualization`)
   - `VirtualMachine` is an actor that owns one `VZVirtualMachine`. `VZVirtualMachine`
     requires every call to come from the queue it was created with. Use one
     `DispatchSerialQueue` both as that queue and as the actor's custom executor (through
     `unownedExecutor`), so that actor isolation and the framework's queue requirement are
     the same thing. Record this design in `docs/decisions/0004-vm-actor-executor.md`.
   - States: `stopped`, `starting`, `running`, `stopping`, and `error(MacWSLError)`, exposed
     as an `AsyncStream` of state changes.
   - `start()` throws a typed error on failure.
   - `stop(timeout:)` first calls `requestStop()` (a guest power-off request). If the guest
     has not stopped within the timeout, it calls `stop()` and records in the log that the
     shutdown was forced.
   - `VZVirtualMachineDelegate` callbacks (`guestDidStop`, `didStopWithError`) drive the
     state.
   - Console output:
     - Written to the console log, `~/Library/Logs/MacWSL/<name>-console.log`. Create the
       file if needed and rotate it once at 10 MB.
     - Also exposed as an `AsyncStream` of lines, so that callers can wait for a line such as
       the initramfs banner.
   - Interactive console: an option attaches the console to a pair of `FileHandle`s instead
     of the log only, so that `debug-boot --interactive` can connect it to the terminal.

3. **Sparse disk images** (`MacWSLVirtualization`)
   - `DiskImage.createSparse(at:size:)` creates a raw disk image as a sparse file. APFS
     allocates no blocks for the file, it does not overwrite an existing file, and it throws
     a typed error if the volume does not support sparse files.
   - Phase 05 formats these images inside the guest. This phase only creates them and
     attaches them.

4. **`macwsld debug-boot`**

   A developer subcommand on the daemon executable. Use `swift-argument-parser`, which is
   already an approved dependency. Running `macwsld` with no arguments keeps its current
   placeholder behavior.

   Options:
   - `--kernel-dir <dir>`: defaults to `MacWSLPaths.kernelDirectory`.
   - `--cmdline <string>`: appended to `console=hvc0`.
   - `--cpus <n>` and `--memory <size>`: memory accepts `512M` or `4G`.
   - `--disk <path>`: repeatable. With `--create-disk <size>`, a missing image is created
     sparse.
   - `--interactive`: puts the terminal in raw mode and connects it to the guest console.
     The terminal state is restored on every exit path, including signals and errors.
     Ctrl-] detaches and stops the VM, like `telnet`. Ctrl-C is passed to the guest.
   - `--timeout <seconds>`: non-interactive mode only. Fails if the guest has not stopped
     within the timeout.

   Behavior:
   - Prints the `manifest.json` kernel version and commit before booting.
   - Prints the time from `start()` to the initramfs banner line, as
     `boot: banner after <n> ms`.
   - SIGINT and SIGTERM in non-interactive mode stop the VM cleanly through `stop(timeout:)`.

   Error messages follow the `macwsl:` format from PR #4, with these suggestions:
   - A missing kernel directory suggests `scripts/fetch-guest.sh`.
   - A missing virtualization entitlement suggests `scripts/sign-dev.sh`. Detect this
     specifically: map the Virtualization.framework error, do not show it raw.

5. **Tests**
   - Unit tests, which run in CI:
     - `VMConfiguration` defaults, clamping, and command-line assembly.
     - Memory size parsing.
     - Sparse disk creation: the allocated size is far smaller than the logical size, and an
       existing file is refused.
     - Mapping of Virtualization.framework errors to `MacWSLError`.
     - `debug-boot` argument parsing.
   - Integration tests, tagged `.integration`:
     - They run only when `MACWSL_INTEGRATION=1` is set, and are otherwise skipped with a
       message saying so.
     - The `swift test` runner is not signed with the virtualization entitlement, so the
       tests do not create VMs in-process. Instead they launch the signed `macwsld
       debug-boot` as a subprocess.
     - They boot with `macwsl.test=poweroff` and assert three things: the banner appears,
       the VM reaches `stopped` within 10 seconds, and the exit status is 0.
     - A second test boots without the poweroff flag and checks that `stop(timeout:)` shuts
       the VM down, and that the log records whether the shutdown was clean or forced.
     - A third test attaches a sparse disk and checks that `/dev/vda` exists in the guest.
       Pass `macwsl.test=lsblk` and extend `/init` to print `ls /dev/vd*` for it. Keep that
       change minimal and leave the rest of `/init` unchanged.
     - Changing `/init` triggers the Guest workflow. Once that run is green, install its
       artifact with `scripts/fetch-guest.sh phase/03-first-boot` before running the
       integration tests.
   - Add `scripts/integration-test.sh`. It builds, runs `scripts/sign-dev.sh`, and runs
     `swift test` with `MACWSL_INTEGRATION=1`.
   - GitHub-hosted macOS runners are virtual machines and cannot run nested Apple
     virtualization. CI therefore runs the unit tests only. Say this explicitly in the PR.

6. **Docs**
   - `docs/decisions/0004-vm-actor-executor.md`, as described in task 2.
   - A "Booting the guest on your Mac" section in `README.md`:
     1. `scripts/fetch-guest.sh`
     2. `scripts/sign-dev.sh`
     3. `.build/debug/macwsld debug-boot --interactive`

## Out of scope

- XPC
- The `macwsl` CLI actions
- The guest agent and vsock traffic. The device is configured, but nothing listens on it.
- Networking
- virtiofs
- Formatting disks
- Distribution root file systems

## Acceptance criteria

All of these are verified on the owner's Apple Silicon Mac, except the CI check.

- `swift build -Xswiftc -warnings-as-errors`, `swift test`, and
  `swift format lint --strict` pass, and CI is green.
- `scripts/integration-test.sh` passes all three integration tests.
- `macwsld debug-boot --cmdline macwsl.test=poweroff` exits 0 and prints the banner and
  `boot: banner after <n> ms`. The PR records the median of 5 runs.
- `macwsld debug-boot --interactive` gives a working shell. In that shell:
  - `uname -a` shows the 6.18 kernel.
  - Ctrl-] stops the VM and restores the terminal. Afterwards `stty -a` matches the
    state before the run.
- Running an unsigned `macwsld` fails with a `macwsl:` message that suggests
  `scripts/sign-dev.sh`.
- The PR description includes the boot time, the memory used by the `macwsld` process
  while the VM idles (from Activity Monitor or `footprint`), and the console log path.

## How to work

1. Present a short plan first. It must cover:
   - How the actor and the dispatch queue are tied together.
   - How raw terminal mode is restored on every exit path.
   - How the integration tests obtain a signed binary.

   Wait for approval.
2. Ask the owner to run the interactive acceptance check and report the result. You cannot
   observe a raw terminal session yourself.
3. Finish with the PR, as described in the Workflow section of `CLAUDE.md`.
