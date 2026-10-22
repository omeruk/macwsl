#!/bin/sh
# Builds maw and mawd and ad-hoc signs them for development:
#
# - mawd with the virtualization entitlement, which Virtualization.framework requires before it
#   will create a VM, and the code signing identifier dev.maw.mawd;
# - maw with the identifier dev.maw.maw.
#
# The daemon accepts only clients signed with these identifiers (docs/daemon.md). Run the
# script again after every `swift build` that relinks either executable, since relinking
# replaces the signature with the linker's, whose identifier is derived from the file name.
#
# Usage: scripts/sign-dev.sh [debug|release]

set -eu

configuration="${1:-debug}"
case "$configuration" in
    debug | release) ;;
    *)
        echo "usage: $0 [debug|release]" >&2
        exit 64
        ;;
esac

cd "$(dirname "$0")/.."

entitlements="Resources/mawd.entitlements"

swift build --configuration "$configuration" --product mawd
swift build --configuration "$configuration" --product maw
bin_path="$(swift build --configuration "$configuration" --show-bin-path)"

codesign --force --sign - --identifier dev.maw.mawd --entitlements "$entitlements" \
    "$bin_path/mawd"
codesign --force --sign - --identifier dev.maw.maw "$bin_path/maw"

if ! codesign --display --entitlements - "$bin_path/mawd" 2>/dev/null \
    | grep -q "com.apple.security.virtualization"; then
    echo "sign-dev.sh: $bin_path/mawd is signed but lacks the virtualization entitlement." >&2
    exit 1
fi
for name in maw mawd; do
    if ! codesign --display --verbose "$bin_path/$name" 2>&1 | grep -q "^Identifier=dev.maw.$name$"; then
        echo "sign-dev.sh: $bin_path/$name is not signed as dev.maw.$name." >&2
        exit 1
    fi
done

echo "Signed $bin_path/mawd (dev.maw.mawd, with $entitlements) and $bin_path/maw (dev.maw.maw)."
