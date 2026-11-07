#!/bin/sh
# Runs the tests in three groups, so that a test that generates heavy load never runs at the
# same time as a test that asserts latency (docs/decisions/0018-test-groups.md).
#
# A test's group follows from the name of its suite. Tests in a suite named `Latency`, such as
# `ExecSessionTests.Latency`, assert latency; tests in a suite named `Load` generate heavy
# load; every other test is in the general group. The pinned toolchain's `swift test` cannot
# select tests by tag, so the groups are selected by name:
#
#   general  every other test, in parallel
#   latency  the tests in `Latency` suites, one at a time
#   load     the tests in `Load` suites, one at a time
#
# Usage:
#   scripts/test-groups.sh run <group> <results directory> [<swift test arguments>...]
#   scripts/test-groups.sh check <results directory>
#   scripts/test-groups.sh all <results directory> [<swift test arguments>...]
#
# `run` runs one group with `swift test --skip-build`, so build the tests first with
# `swift build --build-tests`, and writes the group's xUnit results into the results directory.
# The arguments that follow are passed to `swift test`; they must not select tests.
#
# `check` compares the results of the three groups with `swift test list`. It fails unless
# every listed test ran, as a test or as a skipped one, in exactly one group, and each group ran
# at least one test. A test that belongs to no group's selection, or to two, therefore fails the
# check instead of going unnoticed.
#
# `all` runs the three groups one after the other and then the check, and fails if any of them
# fails.

set -eu

cd "$(dirname "$0")/.."

groups="general latency load"
latency='/Latency/'
load='/Load/'

usage() {
    echo "usage: scripts/test-groups.sh run <group> <results directory> [<swift test arguments>...]" >&2
    echo "       scripts/test-groups.sh check <results directory>" >&2
    echo "       scripts/test-groups.sh all <results directory> [<swift test arguments>...]" >&2
    exit 64
}

# The xUnit file that `swift test --xunit-output <directory>/<group>.xml` writes for
# swift-testing.
results_file() {
    echo "$1/$2-swift-testing.xml"
}

run_group() {
    group=$1
    results=$2
    shift 2
    mkdir -p "$results"
    rm -f "$results/$group.xml" "$(results_file "$results" "$group")"
    case "$group" in
        general)
            set -- --skip "/(Latency|Load)/" "$@"
            ;;
        latency)
            set -- --filter "$latency" --no-parallel "$@"
            ;;
        load)
            set -- --filter "$load" --no-parallel "$@"
            ;;
        *)
            echo "test-groups.sh: unknown group '$group'; the groups are: $groups" >&2
            exit 64
            ;;
    esac
    echo "test-groups.sh: running the $group group"
    swift test --skip-build --xunit-output "$results/$group.xml" "$@"
}

check_groups() {
    results=$1
    listed="$results/listed.txt"
    ran="$results/ran.txt"
    # `swift test list` also prints the warnings of frameworks it loads; only test IDs count.
    # A test ID such as `MawAgentKitTests.ExecSessionTests/Latency/deliversASignal(terminal:)`
    # becomes the xUnit form `MawAgentKitTests.ExecSessionTests.Latency/deliversASignal(terminal:)`.
    swift test list --skip-build 2> /dev/null |
        grep -E '^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_.]*(/[A-Za-z_][A-Za-z0-9_]*)*/[^ /]+\)$' |
        awk '{
            slash = match($0, /\/[^\/]*$/)
            suite = substr($0, 1, slash - 1)
            gsub(/\//, ".", suite)
            print suite "/" substr($0, slash + 1)
        }' > "$listed" || true
    if [ ! -s "$listed" ]; then
        echo "test-groups.sh: swift test list listed no tests." >&2
        return 1
    fi

    failed=0
    : > "$ran"
    for group in $groups; do
        file=$(results_file "$results" "$group")
        if [ ! -f "$file" ]; then
            echo "test-groups.sh: the $group group left no results in $file." >&2
            failed=1
            continue
        fi
        count=$(grep -c '<testcase ' "$file" || true)
        if [ "$count" -eq 0 ]; then
            echo "test-groups.sh: the $group group ran no tests." >&2
            failed=1
        fi
        echo "test-groups.sh: the $group group ran $count tests."
        sed -n -E 's|.*<testcase classname="([^"]*)" name="([^"]*)".*|\1/\2|p' "$file" |
            sed "s|^|$group |" >> "$ran"
    done

    awk '
        NR == FNR { listed[$0] = 1; total++; next }
        {
            test = substr($0, index($0, " ") + 1)
            runs[test]++
            in_groups[test] = in_groups[test] " " $1
        }
        END {
            problems = 0
            for (test in listed) {
                if (!(test in runs)) {
                    print "test-groups.sh: ran in no group: " test > "/dev/stderr"
                    problems++
                } else if (runs[test] > 1) {
                    print "test-groups.sh: ran in more than one group (" substr(in_groups[test], 2) "): " \
                        test > "/dev/stderr"
                    problems++
                }
            }
            for (test in runs) {
                if (!(test in listed)) {
                    print "test-groups.sh: ran, but swift test list does not list it: " test \
                        > "/dev/stderr"
                    problems++
                }
            }
            if (problems == 0) {
                print "test-groups.sh: each of the " total " tests ran in exactly one group."
            }
            exit (problems > 0 ? 1 : 0)
        }
    ' "$listed" "$ran" || failed=1
    return "$failed"
}

[ $# -ge 2 ] || usage
command=$1
shift
case "$command" in
    run)
        [ $# -ge 2 ] || usage
        run_group "$@"
        ;;
    check)
        [ $# -eq 1 ] || usage
        check_groups "$1"
        ;;
    all)
        results=$1
        shift
        status=0
        for group in $groups; do
            run_group "$group" "$results" "$@" || status=$?
        done
        check_groups "$results" || status=1
        exit "$status"
        ;;
    *)
        usage
        ;;
esac
