#!/bin/sh
# The measurements of DNS through the Mac (prompts/08-networking.md, "Speed targets", pull
# request B). For the owner's official run, restart the Mac, connect it to AC power, turn Low
# Power Mode off, leave only Terminal open, wait until the one-minute load average is under 2,
# and run:
#
#   caffeinate -dims scripts/measure-dns.sh
#
# The measurements are the DNSMeasurements suite in Tests/mawdTests. This script runs them
# through scripts/integration-test.sh, so they use the same arrangement as the integration
# tests: the test daemon under the label dev.maw.mawd.integration-test, never dev.maw.mawd; its
# logs in a temporary directory; the test distribution installed from the cached image and
# removed on exit; state.json restored; and the same check on exit that nothing is left behind.
# The comparison without DNS through the Mac registers the test daemon again with the hidden
# `mawd serve --without-dns`. The lookups go to public names, through the test distribution and
# through the Mac's resolver in the test process; nothing changes the Mac's DNS configuration.
# The suite runs only here, never with the other integration tests. Each measurement runs 5
# times and prints its median and its slowest run on lines that start with "measurement:".
#
# Usage: scripts/measure-dns.sh [<measurement>]
#
# With <measurement>, the name of one test of the suite, such as measuresAWarmLookup, it runs
# only that test.

set -eu

cd "$(dirname "$0")/.."

suite=DNSMeasurements
filter=$suite
only=""
if [ $# -gt 1 ]; then
    echo "usage: scripts/measure-dns.sh [<measurement>]" >&2
    exit 64
elif [ $# -eq 1 ]; then
    # A Swift name, and a test of the suite: an @Test function, not a helper or a comment.
    case "$1" in
        *[!A-Za-z0-9_]* | [!A-Za-z_]*) known=false ;;
        *) known=true ;;
    esac
    if [ "$known" = false ] ||
        ! grep -Eq "^[[:space:]]*@Test func $1\(\)" "Tests/mawdTests/$suite.swift"; then
        echo "measure-dns.sh: no measurement is named $1" >&2
        exit 64
    fi
    # The suite's whole name and the parentheses, so that no other test whose name starts or
    # ends the same way runs.
    filter="(^|\.)$suite/$1\(\)"
    only=", only $1"
fi

load=$(sysctl -n vm.loadavg)
manifest="$HOME/Library/Application Support/maw/kernel/manifest.json"
guest=$(plutil -extract guestVersion raw -o - "$manifest" 2> /dev/null || echo unknown)
echo "measure-dns.sh: $(date -u +%Y-%m-%dT%H:%M:%SZ), commit $(git rev-parse --short=12 HEAD)," \
    "guest files $guest, load average $load$only"
# vm.loadavg prints "{ 1.23 1.45 1.67 }"; the first number is the one-minute average.
one_minute=$(echo "$load" | awk '{ print $2 }')
if ! awk -v load="$one_minute" 'BEGIN { exit !(load < 2) }'; then
    echo "measure-dns.sh: the one-minute load average is $one_minute, not under 2; this run" \
        "does not meet the rule for the official measurements." >&2
fi
MAW_MEASURE=1 exec scripts/integration-test.sh --filter "$filter"
