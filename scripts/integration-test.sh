#!/bin/sh
# Runs the test suite including the integration tests, which boot real virtual machines.
#
# The `swift test` runner is not signed with the virtualization entitlement, so the integration
# tests run the signed mawd as a subprocess. This script builds everything first, signs
# mawd, and then runs `swift test --skip-build`, so that the tests cannot relink mawd and
# drop its signature.
#
# Requires an Apple silicon Mac that is not itself a virtual machine, and the guest files from
# scripts/fetch-guest.sh.
#
# Usage: scripts/integration-test.sh [<swift test arguments>...]

set -eu

cd "$(dirname "$0")/.."

swift build --build-tests
scripts/sign-dev.sh
bin_path=$(swift build --show-bin-path)

MAW_INTEGRATION=1 MAWD_PATH="$bin_path/mawd" swift test --skip-build "$@"

# The tests must have used the signed binary; confirm that nothing relinked it.
if ! codesign --display --entitlements - "$bin_path/mawd" 2> /dev/null |
    grep -q com.apple.security.virtualization; then
    echo "integration-test.sh: $bin_path/mawd lost its signature during the run." >&2
    exit 1
fi
