#!/bin/sh
# Measures how much of a guest's output the host side of a Virtualization.framework vsock
# connection holds while the host does not read it, and whether SO_RCVBUF on the host's
# descriptor changes that. See scripts/measure-vsock-buffer.swift for the method.
#
# A development tool: it is built into a temporary directory, ad-hoc signed with the
# virtualization entitlement, and is not part of maw. It boots the guest kernel and initramfs
# from scripts/fetch-guest.sh, without a disk or a network.
#
# Usage: scripts/measure-vsock-buffer.sh [--runs <n>] [--kernel-dir <dir>]
#        scripts/measure-vsock-buffer.sh --inspect <pid>...

set -eu

cd "$(dirname "$0")/.."

kernel_dir="$HOME/Library/Application Support/maw/kernel"
runs=3
inspect=""
while [ $# -gt 0 ]; do
    case "$1" in
        --runs) runs="$2"; shift 2 ;;
        --kernel-dir) kernel_dir="$2"; shift 2 ;;
        --inspect) shift; inspect="$*"; break ;;
        *)
            echo "usage: $0 [--runs <n>] [--kernel-dir <dir>] | --inspect <pid>..." >&2
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
"$work/measure-vsock-buffer" --kernel-dir "$kernel_dir" --console "$work/console.log" --runs "$runs"
