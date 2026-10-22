#!/bin/sh
# Runs the test suite including the integration tests, which boot real virtual machines.
#
# The `swift test` runner is not signed with the virtualization entitlement, so the integration
# tests run the signed maw and mawd as subprocesses. This script builds everything first, signs
# both, and then runs `swift test --skip-build`, so that the tests cannot relink them and drop
# their signatures.
#
# The daemon tests need a daemon registered with launchd. So that they never disturb the
# installed daemon (dev.maw.mawd), the script registers one of its own under a separate label
# and Mach service name, with its logs in a temporary directory and a short machine idle
# timeout, and removes it on exit, including when a test fails or the script is interrupted.
#
# Requires an Apple silicon Mac that is not itself a virtual machine, and the guest files from
# scripts/fetch-guest.sh.
#
# Usage: scripts/integration-test.sh [<swift test arguments>...]

set -eu

cd "$(dirname "$0")/.."

label="dev.maw.mawd.integration-test"
machine_idle_timeout=3

swift build --build-tests
scripts/sign-dev.sh
bin_path=$(swift build --show-bin-path)

log_directory=$(mktemp -d "${TMPDIR:-/tmp}/maw-integration.XXXXXX")
cleanup() {
    "$bin_path/mawd" uninstall --label "$label" > /dev/null 2>&1 || true
    rm -rf "$log_directory"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

"$bin_path/mawd" install --label "$label" --log-directory "$log_directory" \
    --machine-idle-timeout "$machine_idle_timeout" > /dev/null

status=0
MAW_INTEGRATION=1 MAWD_PATH="$bin_path/mawd" MAW_PATH="$bin_path/maw" \
    MAW_DAEMON_LABEL="$label" MAW_TEST_LOG_DIRECTORY="$log_directory" \
    MAW_TEST_MACHINE_IDLE_TIMEOUT="$machine_idle_timeout" \
    swift test --skip-build "$@" || status=$?

if [ "$status" -ne 0 ]; then
    echo "integration-test.sh: the daemon's log follows." >&2
    tail -n 50 "$log_directory/mawd.log" >&2 || true
fi

# The tests must have used the signed binaries; confirm that nothing relinked them.
if ! codesign --display --entitlements - "$bin_path/mawd" 2> /dev/null |
    grep -q com.apple.security.virtualization; then
    echo "integration-test.sh: $bin_path/mawd lost its signature during the run." >&2
    exit 1
fi
if ! codesign --display --verbose "$bin_path/maw" 2>&1 | grep -q '^Identifier=dev.maw.maw$'; then
    echo "integration-test.sh: $bin_path/maw lost its signature during the run." >&2
    exit 1
fi

exit "$status"
