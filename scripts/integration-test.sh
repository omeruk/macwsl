#!/bin/sh
# Runs the test suite including the integration tests, which boot real virtual machines.
#
# The `swift test` runner is not signed with the virtualization entitlement, so the integration
# tests run the signed maw and mawd as subprocesses. This script builds everything first, signs
# both, and then runs `swift test --skip-build`, so that the tests cannot relink them and drop
# their signatures.
#
# The tests that need a client of the daemon in their own code, such as the foreground-program
# report, run the integration probe (Tests/maw-integration-probe) as a subprocess, because the
# daemon accepts only clients signed with maw's identifiers. This script is the only thing that
# signs the probe: it signs it in the build directory with the identifier dev.maw.maw after
# scripts/sign-dev.sh, which does not sign it, and nothing installs it. The probe refuses to run
# unless MAW_DAEMON_LABEL names the test daemon below.
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
# The test daemon shares the owner's state.json, which names the default distribution, and tests
# change the default. The script saves the file before the tests and puts it back on exit, also
# when a test fails or the run is interrupted: the same bytes, or no file if there was none.
#
# On exit the script also checks that nothing the run started outlives it: the test daemon, a
# `mawd debug-boot`, a virtual machine's process, or a test distribution. Virtual machine
# processes that were already running when the run started are not counted. Anything left
# behind makes the run fail.
#
# It also fails the run if the guest agent started more than once during one boot of any
# machine, according to the console logs: the test daemon's, and what `mawd debug-boot` added
# to its own during the run. Each boot starts the agent once, from busybox init on the
# initramfs machine and from systemd on a distribution machine, and each start prints
# "maw-agent ready". A second start means the agent exited, which ends every session it served.
#
# When a test fails or the check above finds a restart, the script saves the agent's journal
# from the test distribution into the test daemon's log directory, keeps that directory (the
# daemon's log and every console log, without the image cache), and prints where it is. It
# also keeps the directory when the run left something behind. Otherwise it deletes it.
#
# Requires an Apple silicon Mac that is not itself a virtual machine, the guest files from
# scripts/fetch-guest.sh, and a network connection for apt and, on a first run, the download.
#
# Without arguments, the tests run in the three groups of scripts/test-groups.sh, one test at a
# time, and the run fails unless every test ran in exactly one group. Arguments, such as a
# `--filter`, are passed to a single `swift test` instead, without the groups and the check.
#
# Usage: scripts/integration-test.sh [<swift test arguments>...]

set -eu

cd "$(dirname "$0")/.."

label="dev.maw.mawd.integration-test"
machine_idle_timeout=3

swift build --build-tests
scripts/sign-dev.sh
bin_path=$(swift build --show-bin-path)
probe="$bin_path/maw-integration-probe"
codesign --force --sign - --identifier dev.maw.maw "$probe"

log_directory=$(mktemp -d "${TMPDIR:-/tmp}/maw-integration.XXXXXX")
image_cache="$log_directory/images"
owner_cache="$HOME/Library/Caches/maw/images"
distros="$HOME/Library/Application Support/maw/distros"
# The daemon's settings, such as the default distribution (MawPaths.stateFile).
state_file="$HOME/Library/Application Support/maw/state.json"
state_saved="$log_directory/state.json.before"
# Whether state.json existed before the run: "present", "absent", or "" until it is saved.
state_before=""
# The test daemon's staging directories (MawPaths.stagingDirectory(label:)).
staging="$distros/.staging/$label"
prefix="maw-it-$(date +%s)"
test_distribution="$prefix-shared"
test_user=maw
test_password="maw-integration-$$"

# The process IDs of Virtualization.framework's virtual machine processes, one per line.
virtual_machine_processes() {
    pgrep -f 'com[.]apple[.]Virtualization[.]VirtualMachine' || true
}
machines_before=" $(virtual_machine_processes | tr '\n' ' ') "

debug_boot_log="$HOME/Library/Logs/maw/debug-boot-console.log"
debug_boot_log_start=$(wc -c < "$debug_boot_log" 2> /dev/null || echo 0)

# Runs a command, and kills it after $1 seconds. Returns its status.
run_with_time_limit() {
    limit=$1
    shift
    "$@" &
    command_pid=$!
    (sleep "$limit" && kill "$command_pid" 2> /dev/null) &
    watchdog_pid=$!
    command_status=0
    wait "$command_pid" || command_status=$?
    kill "$watchdog_pid" 2> /dev/null || true
    wait "$watchdog_pid" 2> /dev/null || true
    return "$command_status"
}

# Prints each boot in the console log on standard input that started the agent more than once,
# with its start lines; $1 names the log. A boot begins at mawd's "starting" note. Returns
# non-zero if there is one.
check_agent_starts_in() {
    awk -v log_name="$1" '
        function finish() {
            if (starts > 1) {
                printf "integration-test.sh: in %s, the boot from line %d", log_name, boot_line
                printf " started the agent %d times:\n%s", starts, lines
                found = 1
            }
        }
        /^\[mawd\] [^ ]+ starting / { finish(); boot_line = NR; starts = 0; lines = "" }
        /maw-agent ready / { starts++; lines = lines "  line " NR ": " $0 "\n" }
        END { finish(); exit found }
    '
}

# Checks every console log of the run, the installations' in install/ included. Returns
# non-zero if a boot started the agent twice.
check_agent_starts() {
    restarted=0
    for console_log in "$log_directory"/*.log "$log_directory"/install/*.log; do
        case "$console_log" in
            */mawd.log) continue ;;
        esac
        [ -f "$console_log" ] || continue
        check_agent_starts_in "${console_log#"$log_directory"/}" < "$console_log" || restarted=1
    done
    if [ -f "$debug_boot_log" ]; then
        size=$(wc -c < "$debug_boot_log")
        # A log rotated during the run is read from its start.
        start=$debug_boot_log_start
        if [ "$size" -lt "$start" ]; then
            start=0
        fi
        tail -c "+$((start + 1))" "$debug_boot_log" |
            check_agent_starts_in "debug-boot-console.log (this run)" || restarted=1
    fi
    return "$restarted"
}

# Saves the agent's journal from the test distribution into the log directory.
save_agent_journal() {
    run_with_time_limit 60 env MAW_DAEMON_LABEL="$label" "$bin_path/maw" -d "$test_distribution" \
        -u root -e journalctl --no-pager -o short-precise -u maw-agent.service \
        > "$log_directory/agent-journal-$test_distribution.txt" 2>&1 || true
}

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
        for directory in "$distros/$prefix"* "$staging/$prefix"*; do
            if [ -e "$directory" ] || [ -L "$directory" ]; then
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

# Puts state.json back as it was before the run, through a rename, so that the daemons never
# read a partial file. Does nothing if the run ended before it was saved. Returns non-zero if
# the file could not be put back.
restore_state_file() {
    case "$state_before" in
        present)
            temporary="$state_file.integration-test.$$"
            if cp -p "$state_saved" "$temporary" && mv -f "$temporary" "$state_file"; then
                return 0
            fi
            rm -f "$temporary"
            echo "integration-test.sh: could not restore $state_file; the saved copy is" \
                "$state_saved." >&2
            return 1
            ;;
        absent)
            rm -f "$state_file"
            ;;
    esac
}

cleanup() {
    exit_status=$?
    keep_logs=false
    if [ "$exit_status" -ne 0 ]; then
        keep_logs=true
        save_agent_journal
    fi
    MAW_DAEMON_LABEL="$label" "$bin_path/maw" --shutdown > /dev/null 2>&1 || true
    # With every machine stopped, the console logs are complete.
    if ! check_agent_starts; then
        echo "integration-test.sh: the guest agent restarted during the run." >&2
        if [ "$keep_logs" = false ]; then
            keep_logs=true
            save_agent_journal
            MAW_DAEMON_LABEL="$label" "$bin_path/maw" --shutdown > /dev/null 2>&1 || true
        fi
        exit_status=1
    fi
    "$bin_path/mawd" uninstall --label "$label" > /dev/null 2>&1 || true
    # With the test daemon gone, nothing of this run writes state.json any more.
    if ! restore_state_file; then
        keep_logs=true
        exit_status=1
    fi
    for directory in "$distros/$prefix"* "$staging/$prefix"*; do
        if [ -e "$directory" ] || [ -L "$directory" ]; then
            rm -rf "$directory"
        fi
    done
    # The test daemon's own staging directory, once empty; another label's is never touched.
    rmdir "$staging" 2> /dev/null || true
    # Keep a verified image that this run downloaded, for the next run and for the owner.
    mkdir -p "$owner_cache"
    for image in "$image_cache"/*.tar.gz; do
        if [ -f "$image" ] && [ ! -e "$owner_cache/$(basename "$image")" ]; then
            cp -c "$image" "$owner_cache/"
        fi
    done
    # The image cache is not a log, and an image this run downloaded was copied above.
    rm -rf "$image_cache"
    nothing_left=true
    if ! check_nothing_left; then
        nothing_left=false
        keep_logs=true
        exit_status=1
    fi
    if [ "$keep_logs" = true ]; then
        echo "integration-test.sh: kept the daemon's log, the console logs, and the agent's" \
            "journal in $log_directory" >&2
    else
        rm -rf "$log_directory"
    fi
    if [ "$nothing_left" = true ]; then
        echo "integration-test.sh: nothing was left behind."
    fi
    exit "$exit_status"
}
if [ -f "$state_file" ]; then
    cp -p "$state_file" "$state_saved"
    state_before=present
else
    state_before=absent
fi
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
#
# Without arguments, the tests run in the groups of scripts/test-groups.sh, each one test at a
# time, followed by its check that every test ran in exactly one group. With arguments, which
# may select tests, they run in one `swift test` without the check.
with_test_environment() {
    env MAW_INTEGRATION=1 MAWD_PATH="$bin_path/mawd" MAW_PATH="$bin_path/maw" \
        MAW_INTEGRATION_PROBE_PATH="$probe" \
        MAW_DAEMON_LABEL="$label" MAW_TEST_LOG_DIRECTORY="$log_directory" \
        MAW_TEST_MACHINE_IDLE_TIMEOUT="$machine_idle_timeout" \
        MAW_TEST_DISTRIBUTION="$test_distribution" MAW_TEST_USER="$test_user" \
        MAW_TEST_PASSWORD="$test_password" MAW_TEST_IMAGE_CACHE="$image_cache" \
        MAW_TEST_PREFIX="$prefix" "$@"
}
status=0
if [ "$#" -eq 0 ]; then
    with_test_environment scripts/test-groups.sh all "$log_directory/test-results" \
        --no-parallel || status=$?
else
    with_test_environment swift test --skip-build --no-parallel "$@" || status=$?
fi

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
for signed in "$bin_path/maw" "$probe"; do
    if ! codesign --display --verbose "$signed" 2>&1 | grep -q '^Identifier=dev.maw.maw$'; then
        echo "integration-test.sh: $signed lost its signature during the run." >&2
        exit 1
    fi
done

exit "$status"
