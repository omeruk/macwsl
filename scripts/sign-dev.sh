#!/bin/sh
# Builds mawd and ad-hoc signs it with the virtualization entitlement, which
# Virtualization.framework requires before it will create a VM. Run it again after every
# `swift build` that relinks mawd, since relinking drops the signature.
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
binary="$(swift build --configuration "$configuration" --show-bin-path)/mawd"

codesign --force --sign - --entitlements "$entitlements" "$binary"

if ! codesign --display --entitlements - "$binary" 2>/dev/null \
    | grep -q "com.apple.security.virtualization"; then
    echo "sign-dev.sh: $binary is signed but lacks the virtualization entitlement." >&2
    exit 1
fi

echo "Signed $binary with $entitlements."
