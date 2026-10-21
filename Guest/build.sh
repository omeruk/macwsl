#!/usr/bin/env bash
# Builds the maw guest kernel and initramfs inside a pinned Linux container.
#
# Usage:
#   Guest/build.sh [--agent <path>]   build into Guest/out/; optionally install <path> as
#                                     /sbin/maw-agent in the initramfs
#   Guest/build.sh --prepare-builder  build the builder image only, if it is not present
#   Guest/build.sh --print-runtime    print the container runtime that would be used
#   Guest/build.sh --print-builder-image
#                                     print the builder image tag
#
# Output in Guest/out/: Image, initramfs.cpio.gz, kernel.config, manifest.json, SHA256SUMS.
# Source tarballs are cached in Guest/.cache/sources/ and verified against their pinned
# sha256 sums before use.
#
# Environment:
#   MAW_CONTAINER_RUNTIME  "container" (Apple's container CLI) or "docker". By default the
#                             first one that is installed and running is used, in that order.
#   MAW_GUEST_CACHE        source cache directory (default: Guest/.cache/sources)
#
# Runs with the bash 3.2 that ships with macOS.

set -euo pipefail

guest_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(dirname "$guest_dir")
out_dir=$guest_dir/out
cache_dir=${MAW_GUEST_CACHE:-$guest_dir/.cache/sources}

# EX_USAGE, EX_NOINPUT, EX_UNAVAILABLE, EX_SOFTWARE from sysexits.h.
EX_USAGE=64
EX_NOINPUT=66
EX_UNAVAILABLE=69

# die <status> <line>...: print the message, prefixed on its first line, and exit.
die() {
    local status=$1
    printf 'build.sh: %s\n' "$2" >&2
    shift 2
    if [ "$#" -gt 0 ]; then
        printf '%s\n' "$@" >&2
    fi
    exit "$status"
}

usage() {
    sed -n '4,11s/^# \{0,1\}//p' "$0" >&2
    exit "$EX_USAGE"
}

# --- Container runtime detection ---------------------------------------------------------

runtime_ready() {
    case $1 in
        container) container system status > /dev/null 2>&1 ;;
        docker) docker info > /dev/null 2>&1 ;;
    esac
}

runtime_not_running() {
    case $1 in
        container)
            die "$EX_UNAVAILABLE" \
                "Apple's container CLI is installed, but its system service is not running." \
                "Start it with 'container system start', then run Guest/build.sh again."
            ;;
        docker)
            die "$EX_UNAVAILABLE" \
                "Docker is installed, but the Docker daemon is not responding." \
                "Start Docker Desktop (or the docker service), then run Guest/build.sh again."
            ;;
    esac
}

detect_runtime() {
    local requested=${MAW_CONTAINER_RUNTIME:-}
    if [ -n "$requested" ]; then
        case $requested in
            container | docker) ;;
            *)
                die "$EX_USAGE" \
                    "MAW_CONTAINER_RUNTIME is '$requested'; use 'container' or 'docker'."
                ;;
        esac
        if ! command -v "$requested" > /dev/null 2>&1; then
            die "$EX_UNAVAILABLE" \
                "MAW_CONTAINER_RUNTIME is '$requested', but '$requested' is not installed."
        fi
        runtime_ready "$requested" || runtime_not_running "$requested"
        echo "$requested"
        return
    fi

    local candidate installed=
    for candidate in container docker; do
        if command -v "$candidate" > /dev/null 2>&1; then
            if runtime_ready "$candidate"; then
                echo "$candidate"
                return
            fi
            installed=${installed:-$candidate}
        fi
    done
    if [ -n "$installed" ]; then
        runtime_not_running "$installed"
    fi
    die "$EX_UNAVAILABLE" \
        "no container runtime found." \
        "The guest kernel and initramfs are built inside a Linux container. Install one of" \
        "these, then run Guest/build.sh again:" \
        "  - Apple's container CLI (recommended on macOS): https://github.com/apple/container" \
        "  - Docker: https://docs.docker.com/get-docker/"
}

# --- Builder image ------------------------------------------------------------------------

sha256_of() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 "$1" | cut -d ' ' -f 1
    fi
}

builder_image() {
    local hash
    hash=$(sha256_of "$guest_dir/Containerfile")
    echo "maw-guest-builder:${hash:0:16}"
}

prepare_builder() {
    local runtime=$1 image=$2
    case $runtime in
        docker)
            if ! docker image inspect "$image" > /dev/null 2>&1; then
                echo "build.sh: building $image"
                # No build context: the Containerfile copies nothing in.
                docker build --tag "$image" - < "$guest_dir/Containerfile"
            fi
            ;;
        container)
            if ! container image inspect "$image" > /dev/null 2>&1; then
                echo "build.sh: building $image"
                local context
                context=$(mktemp -d)
                container build --tag "$image" --file "$guest_dir/Containerfile" "$context"
                rmdir "$context"
            fi
            ;;
    esac
}

# --- Sources ------------------------------------------------------------------------------

# fetch <url> <sha256>: download into the cache unless a verified copy is already there.
fetch() {
    local url=$1 expected=$2
    local file
    file=$cache_dir/$(basename "$url")
    if [ -f "$file" ] && [ "$(sha256_of "$file")" = "$expected" ]; then
        return
    fi
    echo "build.sh: downloading $url"
    mkdir -p "$cache_dir"
    curl --fail --silent --show-error --location --retry 3 --output "$file.part" "$url"
    local actual
    actual=$(sha256_of "$file.part")
    if [ "$actual" != "$expected" ]; then
        rm -f "$file.part"
        die 1 "sha256 mismatch for $url:" "  expected $expected" "  got      $actual"
    fi
    mv "$file.part" "$file"
}

# --- Main ---------------------------------------------------------------------------------

agent=
case ${1:-} in
    '') ;;
    --agent)
        [ "$#" -eq 2 ] || usage
        agent=$2
        [ -f "$agent" ] || die "$EX_NOINPUT" "agent binary $agent does not exist."
        ;;
    --print-runtime)
        detect_runtime
        exit 0
        ;;
    --print-builder-image)
        builder_image
        exit 0
        ;;
    --prepare-builder)
        # Assign first: a failing command substitution inside an argument list would not stop
        # the script under `set -e`.
        runtime=$(detect_runtime)
        prepare_builder "$runtime" "$(builder_image)"
        exit 0
        ;;
    *) usage ;;
esac

runtime=$(detect_runtime)
image=$(builder_image)
echo "build.sh: using $runtime with $image"

# shellcheck source=Guest/kernel/VERSION
. "$guest_dir/kernel/VERSION"
# shellcheck source=Guest/initramfs/SOURCES
. "$guest_dir/initramfs/SOURCES"
fetch "$LINUX_URL" "$LINUX_SHA256"
fetch "$BUSYBOX_URL" "$BUSYBOX_SHA256"
fetch "$E2FSPROGS_URL" "$E2FSPROGS_SHA256"

prepare_builder "$runtime" "$image"

# Two builds of the same commit must be byte-identical, so every input that could vary comes
# from git: the commit time is the timestamp of every file in the output.
source_date_epoch=$(git -C "$repo_dir" log -1 --format=%ct)
git_commit=$(git -C "$repo_dir" rev-parse HEAD)
guest_version=$(git -C "$repo_dir" describe --tags --match 'guest-v*' --always --dirty)
guest_version=${guest_version#guest-v}

rm -rf "$out_dir"
mkdir -p "$out_dir"
container_args=()
if [ -n "$agent" ]; then
    # Pass the agent through the output directory, which is already shared with the container.
    mkdir "$out_dir/.agent"
    cp "$agent" "$out_dir/.agent/maw-agent"
    container_args=(--agent /out/.agent/maw-agent)
fi

run_args=(
    --rm
    --env "SOURCE_DATE_EPOCH=$source_date_epoch"
    --env "GUEST_VERSION=$guest_version"
    --env "GIT_COMMIT=$git_commit"
    --env "BUILDER_IMAGE=$image"
    --env "HOST_UID=$(id -u)"
    --env "HOST_GID=$(id -g)"
)
case $runtime in
    docker)
        run_args+=(
            --mount "type=bind,source=$guest_dir,target=/guest,readonly"
            --mount "type=bind,source=$cache_dir,target=/sources,readonly"
            --mount "type=bind,source=$out_dir,target=/out"
        )
        ;;
    container)
        # Apple's container runs each container in its own lightweight VM, whose default size
        # is too small to link the kernel.
        run_args+=(
            --cpus "$(sysctl -n hw.ncpu 2> /dev/null || echo 4)"
            --memory 8G
            --volume "$guest_dir:/guest"
            --volume "$cache_dir:/sources"
            --volume "$out_dir:/out"
        )
        ;;
esac

"$runtime" run "${run_args[@]}" "$image" /guest/container-build.sh ${container_args[@]+"${container_args[@]}"}
rm -rf "$out_dir/.agent"
echo "build.sh: wrote $out_dir"
