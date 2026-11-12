#!/bin/sh
# The owner's official measurements of the distribution figures (prompts/11c-distribution-figures.md,
# "Speed targets" and "Limits on cost"). Run them on a restarted, idle Mac on AC power, with Low
# Power Mode off, under `caffeinate -dims`, and with only Terminal open.
#
# The measurements are the FigureMeasurements suite in Tests/mawdTests. This script runs it through
# scripts/integration-test.sh, which registers the test daemon, installs a test distribution,
# protects state.json, and removes everything on exit; the suite runs only here, never with the
# other integration tests, because it keeps a machine running for minutes. Each measurement runs
# 5 times and prints its median and its 95th percentile on lines that start with "measurement:".
# The agent's CPU time per sample runs on the test daemon registered again with the hidden
# `mawd serve --sample-interval-ms 100`, so that its batch of 1,000 samples takes 100 seconds;
# the other measurements use the daemon's 1.5 s.
#
# Usage: scripts/measure-figures.sh

set -eu

cd "$(dirname "$0")/.."

manifest="$HOME/Library/Application Support/maw/kernel/manifest.json"
guest=$(plutil -extract guestVersion raw -o - "$manifest" 2> /dev/null || echo unknown)
echo "measure-figures.sh: $(date -u +%Y-%m-%dT%H:%M:%SZ), commit $(git rev-parse --short=12 HEAD)," \
    "guest files $guest, load average $(sysctl -n vm.loadavg)"
MAW_MEASURE=1 exec scripts/integration-test.sh --filter FigureMeasurements
