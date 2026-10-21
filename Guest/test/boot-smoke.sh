#!/usr/bin/env bash
# Boots the guest kernel and initramfs under QEMU and checks that /init runs. Each boot must
# print the banner line and power off on its own within 120 seconds:
#
# 1. With macwsl.test=poweroff, "macwsl-initramfs: poweroff" must appear.
# 2. If the initramfs contains the guest agent (manifest.json names its sha256), a second boot
#    with macwsl.test=agent runs the agent's self-test, and "macwsl-agent self-test: ok" must
#    appear. QEMU has no vsock here, so the self-test covers everything but the transport.
#
# On failure, prints the full console log of the failing boot.
#
# QEMU is only a test harness. MacWSL itself boots these files with Virtualization.framework
# (phase 03), and the settings below mirror that machine where QEMU allows it.
#
# Usage: Guest/test/boot-smoke.sh [--require-agent] [<dir>]   (default: Guest/out)
#
#   --require-agent  fail if the initramfs does not contain the agent
#
# Environment: QEMU (default: qemu-system-aarch64)

set -euo pipefail

guest_dir=$(cd "$(dirname "$0")/.." && pwd)
require_agent=false
if [ "${1:-}" = --require-agent ]; then
    require_agent=true
    shift
fi
dir=${1:-$guest_dir/out}
qemu=${QEMU:-qemu-system-aarch64}
timeout_seconds=120

fail() {
    echo "boot-smoke: $*" >&2
    exit 1
}

command -v "$qemu" > /dev/null 2>&1 || fail "$qemu is not installed."
timeout_command=$(command -v timeout || command -v gtimeout || true)
[ -n "$timeout_command" ] || fail "GNU timeout is not installed (coreutils)."
for file in Image initramfs.cpio.gz manifest.json; do
    [ -f "$dir/$file" ] || fail "$dir/$file not found. Build the guest first with Guest/build.sh."
done

release=$(sed -n 's/^ *"release": "\(.*\)",\{0,1\}$/\1/p' "$dir/manifest.json")
[ -n "$release" ] || fail "cannot read the kernel release from $dir/manifest.json."

# container-build.sh writes `"agent": null` without an agent and `"agent": { "sha256": ... }`
# with one.
has_agent=false
if grep -q '"agent": {' "$dir/manifest.json"; then
    has_agent=true
fi
if [ "$require_agent" = true ] && [ "$has_agent" = false ]; then
    fail "manifest.json records no agent; build with Guest/build.sh --agent <path>."
fi

log=$(mktemp)
trap 'rm -f "$log"' EXIT

# boot <name> <kernel arguments> <expected line>: boots once and checks the console.
boot() {
    local name=$1 arguments=$2 expected=$3
    # - virt with a GICv3, like Virtualization.framework.
    # - TCG with an implementation-defined pointer authentication algorithm, which is much
    #   faster to emulate than the architected one.
    # - The console is a virtio console (hvc0) on a virtio-serial PCI device, the same
    #   transport Virtualization.framework uses. No network, no graphics, no other default
    #   devices.
    local qemu_args=(
        -nodefaults
        -no-user-config
        -machine virt,gic-version=3
        -accel tcg
        -cpu max,pauth-impdef=on
        -smp 2
        -m 512M
        -display none
        -nic none
        -chardev stdio,id=console
        -device virtio-serial-pci
        -device virtconsole,chardev=console
        -kernel "$dir/Image"
        -initrd "$dir/initramfs.cpio.gz"
        -append "console=hvc0 $arguments"
        -no-reboot
    )

    echo "boot-smoke: $name: booting $release with '$arguments' (timeout ${timeout_seconds}s)"
    local start end elapsed status
    start=${EPOCHREALTIME:-$SECONDS}
    set +e
    "$timeout_command" --kill-after=5 "$timeout_seconds" "$qemu" "${qemu_args[@]}" \
        < /dev/null > "$log" 2>&1
    status=$?
    set -e
    end=${EPOCHREALTIME:-$SECONDS}
    elapsed=$(awk -v start="$start" -v end="$end" 'BEGIN { printf "%.1f", end - start }')

    # The console may end lines with CR LF.
    local console banner found
    console=$(tr -d '\r' < "$log")
    banner=$(printf '%s\n' "$console" | grep -E "^macwsl-initramfs [^ ]+ kernel=$release\$" || true)
    found=$(printf '%s\n' "$console" | grep -Fx "$expected" || true)

    local problems=()
    if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
        problems+=("QEMU did not exit within ${timeout_seconds} seconds.")
    elif [ "$status" -ne 0 ]; then
        problems+=("QEMU exited with status $status.")
    fi
    [ -n "$banner" ] || problems+=("The banner 'macwsl-initramfs <version> kernel=$release' did not appear.")
    [ -n "$found" ] || problems+=("'$expected' did not appear.")

    if [ "${#problems[@]}" -ne 0 ]; then
        echo "boot-smoke: $name: FAILED after ${elapsed}s"
        printf '  %s\n' "${problems[@]}"
        echo "----- console log -----"
        printf '%s\n' "$console"
        echo "-----------------------"
        exit 1
    fi

    echo "$banner"
    echo "$found"
    echo "boot-smoke: $name: passed; QEMU powered off after ${elapsed}s"
}

boot poweroff "macwsl.test=poweroff" "macwsl-initramfs: poweroff"
if [ "$has_agent" = true ]; then
    boot agent "macwsl.test=agent" "macwsl-agent self-test: ok"
else
    echo "boot-smoke: the initramfs has no agent; skipping the agent self-test"
fi
echo "boot-smoke: passed"
