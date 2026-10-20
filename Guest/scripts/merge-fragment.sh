#!/bin/sh
# Merges a configuration fragment into a Kconfig-style .config: removes every line that sets
# an option named in the fragment, then appends the fragment. This is what the kernel's
# scripts/kconfig/merge_config.sh -m does; busybox ships no equivalent.
#
# Run the project's `oldconfig` afterwards, then Guest/scripts/verify-fragment.sh.
#
# Usage: merge-fragment.sh <config> <fragment>

set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <config> <fragment>" >&2
    exit 64
fi
config=$1
fragment=$2

merged=$(mktemp)
trap 'rm -f "$merged"' EXIT

awk '
    function option_name(line) {
        if (match(line, /^CONFIG_[A-Za-z0-9_]+=/)) return substr(line, 1, RLENGTH - 1)
        if (line ~ /^# CONFIG_[A-Za-z0-9_]+ is not set$/) { split(line, f, " "); return f[2] }
        return ""
    }
    FNR == NR { name = option_name($0); if (name != "") requested[name] = 1; next }
    { name = option_name($0); if (name == "" || !(name in requested)) print }
' "$fragment" "$config" > "$merged"
cat "$fragment" >> "$merged"
cat "$merged" > "$config"
