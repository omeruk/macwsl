#!/bin/sh
# Measures how much of a guest's output the host side of a Virtualization.framework vsock
# connection holds while the host does not read it, and whether SO_RCVBUF on the host's
# descriptor changes that. See scripts/measure-vsock-buffer.swift for the method.
#
# With --guest-initiated, the guest opens the connections that carry output, and the script
# also measures the cost of a dial-back. It compiles scripts/measure-vsock-guest.c for the
# guest with the Static Linux SDK's musl and the swift.org toolchain's clang, both pinned in
# Guest/agent/SWIFT (Guest/README.md describes their installation).
#
# A development tool: it is built into a temporary directory, ad-hoc signed with the
# virtualization entitlement, and is not part of maw. It boots the guest kernel and initramfs
# from scripts/fetch-guest.sh, without a disk or a network.
#
# Usage: scripts/measure-vsock-buffer.sh [--guest-initiated] [--runs <n>] [--kernel-dir <dir>]
#        scripts/measure-vsock-buffer.sh --inspect <pid>...

set -eu

cd "$(dirname "$0")/.."

kernel_dir="$HOME/Library/Application Support/maw/kernel"
runs=3
inspect=""
guest_initiated=false
while [ $# -gt 0 ]; do
    case "$1" in
        --guest-initiated) guest_initiated=true; shift ;;
        --runs) runs="$2"; shift 2 ;;
        --kernel-dir) kernel_dir="$2"; shift 2 ;;
        --inspect) shift; inspect="$*"; break ;;
        *)
            echo "usage: $0 [--guest-initiated] [--runs <n>] [--kernel-dir <dir>] | --inspect <pid>..." >&2
            exit 64
            ;;
    esac
done

work=$(mktemp -d "${TMPDIR:-/tmp}/maw-vsock-buffer.XXXXXX")
trap 'rm -rf "$work"' EXIT

xcrun swiftc -O -swift-version 5 -o "$work/measure-vsock-buffer" scripts/measure-vsock-buffer.swift
codesign --force --sign - --entitlements Resources/mawd.entitlements "$work/measure-vsock-buffer" \
    2> /dev/null
if [ -n "$inspect" ]; then
    # shellcheck disable=SC2086
    "$work/measure-vsock-buffer" --inspect $inspect
    exit
fi
sw_vers | sed 's/^/# /'
echo "# $(sysctl -n hw.model), load average $(sysctl -n vm.loadavg)"
if [ "$guest_initiated" = false ]; then
    "$work/measure-vsock-buffer" --kernel-dir "$kernel_dir" --console "$work/console.log" \
        --runs "$runs"
    exit
fi

# shellcheck source=Guest/agent/SWIFT
. Guest/agent/SWIFT
toolchain=
for directory in "$HOME/Library/Developer/Toolchains" /Library/Developer/Toolchains; do
    if [ -x "$directory/swift-$SWIFT_VERSION-RELEASE.xctoolchain/usr/bin/clang" ]; then
        toolchain=$directory/swift-$SWIFT_VERSION-RELEASE.xctoolchain
        break
    fi
done
sdk=$HOME/Library/org.swift.swiftpm/swift-sdks/$SWIFT_SDK_ID.artifactbundle/$SWIFT_SDK_ID
sysroot=$sdk/swift-linux-musl/musl-1.2.5.sdk/aarch64
if [ -z "$toolchain" ] || [ ! -d "$sysroot" ]; then
    echo "$0: --guest-initiated needs the Swift $SWIFT_VERSION toolchain and $SWIFT_SDK_ID" >&2
    exit 1
fi
# A static musl executable, linked without the toolchain's Linux runtime files, which only
# the SDK has.
"$toolchain/usr/bin/clang" --target=aarch64-unknown-linux-musl --sysroot="$sysroot" -static \
    -fuse-ld=lld -nostdlib -O2 -Wall -Werror -o "$work/measure-vsock-guest" \
    "$sysroot/usr/lib/crt1.o" "$sysroot/usr/lib/crti.o" scripts/measure-vsock-guest.c -lc \
    "$sysroot/usr/lib/swift_static/clang/lib/linux/libclang_rt.builtins-aarch64.a" \
    "$sysroot/usr/lib/crtn.o"
"$work/measure-vsock-buffer" --kernel-dir "$kernel_dir" --console "$work/console.log" \
    --runs "$runs" --guest-initiated "$work/measure-vsock-guest"
