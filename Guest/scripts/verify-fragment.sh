#!/bin/sh
# Verifies that every option requested in a configuration fragment ended up with the requested
# value in a final kernel .config.
#
# scripts/kconfig/merge_config.sh only warns when `make olddefconfig` drops or changes a
# requested option (usually because a dependency is missing). This script turns those cases
# into a build failure.
#
# Usage: verify-fragment.sh <fragment> <config>

set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <fragment> <config>" >&2
    exit 64
fi
fragment=$1
config=$2

awk '
    # First file: the final .config. Record each option and its value; "n" for "is not set".
    FNR == NR {
        if (match($0, /^CONFIG_[A-Za-z0-9_]+=/)) {
            actual[substr($0, 1, RLENGTH - 1)] = substr($0, RLENGTH + 1)
        } else if ($0 ~ /^# CONFIG_[A-Za-z0-9_]+ is not set$/) {
            actual[$2] = "n"
        }
        next
    }

    # Second file: the fragment.
    match($0, /^CONFIG_[A-Za-z0-9_]+=/) {
        check(substr($0, 1, RLENGTH - 1), substr($0, RLENGTH + 1))
        next
    }
    /^# CONFIG_[A-Za-z0-9_]+ is not set$/ {
        check($2, "n")
    }

    function check(name, want,    got) {
        requested++
        if (!(name in actual)) {
            # An option that is absent from .config is not visible, which counts as "n".
            if (want == "n") return
            printf "  %s: requested %s, but it is not in the final configuration " \
                "(a dependency is not enabled)\n", name, want
            failed++
            return
        }
        got = actual[name]
        if (got != want) {
            printf "  %s: requested %s, got %s\n", name, want, got
            failed++
        }
    }

    END {
        if (failed > 0) {
            printf "verify-fragment: %d of %d requested options did not end up set.\n", \
                failed, requested
            exit 1
        }
        printf "verify-fragment: all %d requested options are set.\n", requested
    }
' "$config" "$fragment"
