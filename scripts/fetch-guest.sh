#!/bin/sh
# Downloads the guest kernel and initramfs built by the Guest workflow, verifies them, and
# installs them where mawd looks for them.
#
# Usage: scripts/fetch-guest.sh [<branch>]   (default: main)
#
# Takes the maw-guest artifact of the latest successful Guest workflow run on <branch>,
# verifies every file against its SHA256SUMS, and installs the files into
# ~/Library/Application Support/maw/kernel/. Requires the GitHub CLI (`gh`), signed in.
#
# Environment:
#   MAW_KERNEL_DIR  install directory (default: ~/Library/Application Support/maw/kernel)

set -eu

branch=${1:-main}
if [ "$#" -gt 1 ] || [ "$branch" = -h ] || [ "$branch" = --help ]; then
    sed -n '5,13s/^# \{0,1\}//p' "$0" >&2
    exit 64
fi
kernel_dir=${MAW_KERNEL_DIR:-$HOME/Library/Application Support/maw/kernel}
files="Image initramfs.cpio.gz kernel.config manifest.json SHA256SUMS"

fail() {
    echo "fetch-guest: $*" >&2
    exit 1
}

command -v gh > /dev/null 2>&1 ||
    fail "the GitHub CLI (gh) is not installed. Install it from https://cli.github.com."
gh auth status > /dev/null 2>&1 || fail "the GitHub CLI is not signed in. Run 'gh auth login'."

# Query the runs API and filter by workflow file rather than using `gh run list --workflow`,
# which only finds workflows that exist on the default branch.
run=$(gh api --method GET 'repos/{owner}/{repo}/actions/runs' \
    -f branch="$branch" -f status=success -f per_page=100 \
    --jq '[.workflow_runs[] | select(.path == ".github/workflows/guest.yml")][0]
          | select(.) | "\(.id) \(.head_sha) \(.created_at) \(.html_url)"') ||
    fail "could not list workflow runs for branch '$branch'."
[ -n "$run" ] || fail "no successful Guest workflow run found on branch '$branch'."
set -- $run
run_id=$1 head_sha=$2 created_at=$3 run_url=$4
echo "fetch-guest: run $run_id on '$branch', commit ${head_sha%"${head_sha#????????????}"}, $created_at"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh run download "$run_id" --name maw-guest --dir "$work/download" ||
    fail "could not download the maw-guest artifact of run $run_id ($run_url)."

for file in $files; do
    [ -f "$work/download/$file" ] || fail "the artifact of run $run_id has no $file."
done
(cd "$work/download" && shasum -a 256 --check --strict SHA256SUMS) ||
    fail "the files from run $run_id do not match their SHA256SUMS."

# Stage the files next to their destination, then move each one into place. A rename within
# one directory is atomic, so a reader never sees a partially written file.
mkdir -p "$kernel_dir"
staging=$(mktemp -d "$kernel_dir/.fetch-guest.XXXXXX")
trap 'rm -rf "$work" "$staging"' EXIT
for file in $files; do
    cp "$work/download/$file" "$staging/$file"
done
for file in $files; do
    mv -f "$staging/$file" "$kernel_dir/$file"
done

(cd "$kernel_dir" && shasum -a 256 --check --strict SHA256SUMS > /dev/null) ||
    fail "the installed files in $kernel_dir do not match their SHA256SUMS."
echo "fetch-guest: installed and verified in $kernel_dir:"
(cd "$kernel_dir" && ls -l $files | awk '{ printf "  %-20s %12s bytes\n", $NF, $5 }')
