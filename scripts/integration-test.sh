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
# and Mach service name, with its logs in a temporary directory, a short machine idle timeout,
# and an image cache of its own, and removes it on exit, including when a test fails or the
# script is interrupted.
#
# Before the tests, the script installs a test distribution under a name of its own
# (maw-it-<run>-shared), which the tests use; tests that install more use the same prefix. On
# exit it removes every distribution with that prefix. The test daemon's image cache starts as
# an APFS clone of the verified images in ~/Library/Caches/maw/images, so that only a run
# without a cached image downloads it; a downloaded image is cloned back for the next run.
#
# On exit the script also checks that nothing the run started outlives it: the test daemon, a
# `mawd debug-boot`, a virtual machine's process, or a test distribution. Virtual machine
# processes that were already running when the run started are not counted. Anything left
# behind makes the run fail.
#
# Requires an Apple silicon Mac that is not itself a virtual machine, the guest files from
# scripts/fetch-guest.sh, and a network connection for apt and, on a first run, the download.
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
image_cache="$log_directory/images"
owner_cache="$HOME/Library/Caches/maw/images"
distros="$HOME/Library/Application Support/maw/distros"
prefix="maw-it-$(date +%s)"
test_distribution="$prefix-shared"
test_user=maw
test_password="maw-integration-$$"

# The process IDs of Virtualization.framework's virtual machine processes, one per line.
virtual_machine_processes() {
    pgrep -f 'com[.]apple[.]Virtualization[.]VirtualMachine' || true
}
machines_before=" $(virtual_machine_processes | tr '\n' ' ') "

# Prints what the run left behind, after waiting up to ten seconds for it to go. Returns
# non-zero if anything is left.
check_nothing_left() {
    attempt=0
    while :; do
        left=""
        if launchctl print "gui/$(id -u)/$label" > /dev/null 2>&1; then
            left="$left the daemon $label is still loaded;"
        fi
        daemons=$(pgrep -f -- "--label $label" | tr '\n' ' ' || true)
        if [ -n "$daemons" ]; then
            left="$left test daemon processes: $daemons;"
        fi
        boots=$(pgrep -f -- "mawd debug-boot" | tr '\n' ' ' || true)
        if [ -n "$boots" ]; then
            left="$left debug-boot processes: $boots;"
        fi
        machines=""
        for pid in $(virtual_machine_processes); do
            case "$machines_before" in
                *" $pid "*) ;;
                *) machines="$machines $pid" ;;
            esac
        done
        if [ -n "$machines" ]; then
            left="$left virtual machine processes:$machines;"
        fi
        for directory in "$distros/$prefix"* "$distros/.staging-$prefix"*; do
            if [ -e "$directory" ]; then
                left="$left $directory;"
            fi
        done
        if [ -z "$left" ]; then
            return 0
        fi
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 20 ]; then
            echo "integration-test.sh: the run left behind:$left" >&2
            return 1
        fi
        sleep 0.5
    done
}

cleanup() {
    MAW_DAEMON_LABEL="$label" "$bin_path/maw" --shutdown > /dev/null 2>&1 || true
    "$bin_path/mawd" uninstall --label "$label" > /dev/null 2>&1 || true
    for directory in "$distros/$prefix"* "$distros/.staging-$prefix"*; do
        if [ -e "$directory" ]; then
            rm -rf "$directory"
        fi
    done
    # Keep a verified image that this run downloaded, for the next run and for the owner.
    mkdir -p "$owner_cache"
    for image in "$image_cache"/*.tar.gz; do
        if [ -f "$image" ] && [ ! -e "$owner_cache/$(basename "$image")" ]; then
            cp -c "$image" "$owner_cache/"
        fi
    done
    rm -rf "$log_directory"
    if ! check_nothing_left; then
        exit 1
    fi
    echo "integration-test.sh: nothing was left behind."
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$image_cache"
for image in "$owner_cache"/*.tar.gz; do
    if [ -f "$image" ]; then
        cp -c "$image" "$image_cache/"
    fi
done

"$bin_path/mawd" install --label "$label" --log-directory "$log_directory" \
    --machine-idle-timeout "$machine_idle_timeout" --image-cache-directory "$image_cache" \
    > /dev/null

echo "integration-test.sh: installing the test distribution $test_distribution"
if ! printf '%s\n' "$test_password" | MAW_DAEMON_LABEL="$label" "$bin_path/maw" --install \
    --name "$test_distribution" -u "$test_user"; then
    echo "integration-test.sh: the test distribution could not be installed." >&2
    tail -n 50 "$log_directory/mawd.log" >&2 || true
    exit 1
fi

# --no-parallel: the integration suites boot virtual machines and measure latency, and suites
# that run at the same time would compete for the CPU and distort the measurements.
status=0
MAW_INTEGRATION=1 MAWD_PATH="$bin_path/mawd" MAW_PATH="$bin_path/maw" \
    MAW_DAEMON_LABEL="$label" MAW_TEST_LOG_DIRECTORY="$log_directory" \
    MAW_TEST_MACHINE_IDLE_TIMEOUT="$machine_idle_timeout" \
    MAW_TEST_DISTRIBUTION="$test_distribution" MAW_TEST_USER="$test_user" \
    MAW_TEST_PASSWORD="$test_password" MAW_TEST_IMAGE_CACHE="$image_cache" \
    MAW_TEST_PREFIX="$prefix" \
    swift test --skip-build --no-parallel "$@" || status=$?

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
