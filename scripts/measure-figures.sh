#!/bin/sh
# The owner's official measurements of the distribution figures (prompts/11c-distribution-figures.md,
# "Speed targets" and "Limits on cost"). Run them on a restarted, idle Mac on AC power, with Low
# Power Mode off, under `caffeinate -dims`, and with only Terminal open.
#
# The measurements are the FigureMeasurements suite in Tests/mawdTests, for the daemon, and the
# AppFigureMeasurements suite there, for the terminal app. This script runs them through
# scripts/integration-test.sh, which registers the test daemon, installs a test distribution,
# protects state.json, and removes everything on exit; the suite runs only here, never with the
# other integration tests, because it keeps a machine running for minutes. Each measurement runs
# 5 times and prints its median and its 95th percentile on lines that start with "measurement:".
# The agent's CPU time per sample runs on the test daemon registered again with the hidden
# `mawd serve --sample-interval-ms 100`, so that its batch of 1,000 samples takes 100 seconds;
# the other measurements use the daemon's 1.5 s.
#
# The app's measurements run its harness (App/MawTerminalKit/Tests/FiguresHarness), which shows
# the distributions screen in real windows, in-process, against the test daemon. The script builds
# it and signs it ad hoc with the app's identifier, dev.maw.app, which the daemon requires of its
# clients; nothing installs it. Its windows appear on screen while it runs: leave them uncovered.
#
# Usage: scripts/measure-figures.sh [<measurement>]
#
# With <measurement>, the name of one test in either suite, such as measuresTheFirstFigures or
# measuresTheAppsFirstFigures, it runs only that test.

set -eu

cd "$(dirname "$0")/.."

filter=FigureMeasurements
only=""
if [ $# -gt 1 ]; then
    echo "usage: scripts/measure-figures.sh [<measurement>]" >&2
    exit 64
elif [ $# -eq 1 ]; then
    # A Swift name, and a test of the suite: an @Test function, not a helper or a comment.
    case "$1" in
        *[!A-Za-z0-9_]* | [!A-Za-z_]*) known=false ;;
        *) known=true ;;
    esac
    suite=""
    if [ "$known" = true ]; then
        for candidate in FigureMeasurements AppFigureMeasurements; do
            if grep -Eq "^[[:space:]]*@Test func $1\(\)" "Tests/mawdTests/$candidate.swift"; then
                suite=$candidate
            fi
        done
    fi
    if [ -z "$suite" ]; then
        echo "measure-figures.sh: no measurement is named $1" >&2
        exit 64
    fi
    # The suite's whole name and the parentheses, so that no other test whose name starts or
    # ends the same way runs.
    filter="(^|\.)$suite/$1\(\)"
    only=", only $1"
fi

# The app's harness, built and signed as the app.
harness_bin=$(swift build --package-path App/MawTerminalKit --show-bin-path)
swift build --package-path App/MawTerminalKit --product maw-figures-harness
harness="$harness_bin/maw-figures-harness"
codesign --force --sign - --identifier dev.maw.app "$harness"
export MAW_FIGURES_HARNESS_PATH="$harness"

manifest="$HOME/Library/Application Support/maw/kernel/manifest.json"
guest=$(plutil -extract guestVersion raw -o - "$manifest" 2> /dev/null || echo unknown)
echo "measure-figures.sh: $(date -u +%Y-%m-%dT%H:%M:%SZ), commit $(git rev-parse --short=12 HEAD)," \
    "guest files $guest, load average $(sysctl -n vm.loadavg)$only"
MAW_MEASURE=1 exec scripts/integration-test.sh --filter "$filter"
