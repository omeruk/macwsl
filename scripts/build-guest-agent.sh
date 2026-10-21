#!/bin/sh
# Builds the guest agent (maw-agent) for aarch64 Linux with the Swift Static Linux SDK:
# a fully static, stripped musl binary for Guest/build.sh --agent.
#
# Usage: scripts/build-guest-agent.sh [--output <path>]   (default: .build/guest-agent/maw-agent)
#
# The toolchain and SDK are pinned in Guest/agent/SWIFT. On macOS, the script uses the
# swift.org toolchain installed in ~/Library/Developer/Toolchains (or /Library/...) and selects
# it with TOOLCHAINS for this build only; the `swift` on PATH stays Xcode's. Guest/README.md
# describes the one-time installation. Local agent builds are optional: scripts/fetch-guest.sh
# installs guest files that the Guest workflow built.
#
# Environment:
#   MAW_SWIFT  the swift executable to use instead (the Guest workflow sets it on Linux)

set -eu

cd "$(dirname "$0")/.."
# shellcheck source=Guest/agent/SWIFT
. Guest/agent/SWIFT

usage() {
    sed -n '5s/^# \{0,1\}//p' "$0" >&2
    exit 64
}

output=.build/guest-agent/maw-agent
case ${1:-} in
    '') ;;
    --output)
        [ "$#" -eq 2 ] || usage
        output=$2
        ;;
    *) usage ;;
esac

fail() {
    printf 'build-guest-agent: %s\n' "$1" >&2
    shift
    if [ "$#" -gt 0 ]; then
        printf '%s\n' "$@" >&2
    fi
    exit 1
}

# swift_cmd <arguments>: runs the selected swift.
if [ -n "${MAW_SWIFT:-}" ]; then
    swift_cmd() { "$MAW_SWIFT" "$@"; }
elif [ "$(uname -s)" = Darwin ]; then
    toolchain=
    for directory in "$HOME/Library/Developer/Toolchains" /Library/Developer/Toolchains; do
        candidate=$directory/swift-$SWIFT_VERSION-RELEASE.xctoolchain
        if [ -f "$candidate/Info.plist" ]; then
            toolchain=$candidate
            break
        fi
    done
    [ -n "$toolchain" ] || fail "the Swift $SWIFT_VERSION toolchain from swift.org is not installed." \
        "Xcode's toolchain cannot use the Static Linux SDK. Install the toolchain for this user" \
        "as Guest/README.md describes (\"Building the agent locally\"), or use" \
        "scripts/fetch-guest.sh, which needs no toolchain."
    toolchain_id=$(plutil -extract CFBundleIdentifier raw "$toolchain/Info.plist")
    swift_cmd() { TOOLCHAINS=$toolchain_id xcrun swift "$@"; }
else
    swift_cmd() { swift "$@"; }
fi

version=$(swift_cmd --version 2>&1 | head -n 1)
case $version in
    *"Swift version $SWIFT_VERSION "*) ;;
    *) fail "expected Swift $SWIFT_VERSION, but the selected toolchain reports: $version" ;;
esac

if ! swift_cmd sdk list 2> /dev/null | grep -qx "$SWIFT_SDK_ID"; then
    fail "the Static Linux SDK $SWIFT_SDK_ID is not installed. Install it with:" \
        "  TOOLCHAINS=<toolchain id> swift sdk install $SWIFT_SDK_URL \\" \
        "      --checksum $SWIFT_SDK_SHA256" \
        "(on Linux, without TOOLCHAINS)."
fi

echo "build-guest-agent: $version, SDK $SWIFT_SDK_ID"
# --strip-all at link time leaves no symbols or debug information, independent of which
# strip tool the host has.
build_args="--configuration release --swift-sdk $SWIFT_SDK_TRIPLE --product maw-agent"
# shellcheck disable=SC2086
swift_cmd build $build_args -Xlinker --strip-all
# shellcheck disable=SC2086
bin_path=$(swift_cmd build $build_args --show-bin-path)

mkdir -p "$(dirname "$output")"
cp "$bin_path/maw-agent" "$output"
size=$(wc -c < "$output" | tr -d ' ')
if command -v sha256sum > /dev/null 2>&1; then
    sha=$(sha256sum "$output" | cut -d ' ' -f 1)
else
    sha=$(shasum -a 256 "$output" | cut -d ' ' -f 1)
fi
echo "build-guest-agent: wrote $output ($size bytes, sha256 $sha)"
