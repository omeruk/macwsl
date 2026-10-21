#!/bin/sh
# Tests the container runtime detection in Guest/build.sh. Each case runs build.sh with stub
# `docker` and `container` commands on an otherwise empty PATH, so no real container runtime
# is needed and an installed one cannot affect the result. Runs on macOS and Linux.
#
# Usage: Guest/test/runtime-detection.sh

set -eu

guest_dir=$(cd "$(dirname "$0")/.." && pwd)
bash_path=$(command -v bash)
dirname_path=$(command -v dirname)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

count=0
failures=0

# sandbox <name> [<tool>=ready|stopped ...]: create a PATH directory with bash, dirname, and
# one stub per argument. A stub exits 0 ("ready") or 1 ("stopped") for every command,
# including the readiness probes `docker info` and `container system status`.
sandbox() {
    dir=$work/$1
    shift
    mkdir -p "$dir"
    ln -s "$bash_path" "$dir/bash"
    ln -s "$dirname_path" "$dir/dirname"
    for spec in "$@"; do
        tool=${spec%%=*}
        status=0
        [ "${spec#*=}" = stopped ] && status=1
        printf '#!/bin/sh\nexit %s\n' "$status" > "$dir/$tool"
        chmod +x "$dir/$tool"
    done
    echo "$dir"
}

# check <description> <sandbox> <expected status> <expected output> [<arguments>] [-- <VAR=value>...]
# A zero status expects the output to match exactly; otherwise the output must contain the
# expected text.
check() {
    description=$1 dir=$2 want_status=$3 want_output=$4
    shift 4
    arguments=--print-runtime
    if [ "$#" -gt 0 ] && [ "$1" != -- ]; then
        arguments=$1
        shift
    fi
    [ "$#" -gt 0 ] && [ "$1" = -- ] && shift
    count=$((count + 1))

    set +e
    # shellcheck disable=SC2086
    output=$(env -i PATH="$dir" "$@" "$dir/bash" "$guest_dir/build.sh" $arguments 2>&1)
    status=$?
    set -e

    passed=false
    if [ "$status" -eq "$want_status" ]; then
        if [ "$want_status" -eq 0 ]; then
            [ "$output" = "$want_output" ] && passed=true
        else
            printf '%s\n' "$output" | grep -qF -- "$want_output" && passed=true
        fi
    fi
    if [ "$passed" = true ]; then
        echo "ok $count - $description"
    else
        failures=$((failures + 1))
        echo "not ok $count - $description"
        echo "    expected status $want_status and output: $want_output"
        echo "    got status $status and output:"
        printf '%s\n' "$output" | sed 's/^/      /'
    fi
}

none=$(sandbox none)
docker_ready=$(sandbox docker-ready docker=ready)
docker_stopped=$(sandbox docker-stopped docker=stopped)
container_ready=$(sandbox container-ready container=ready)
container_stopped=$(sandbox container-stopped container=stopped)
both_ready=$(sandbox both-ready container=ready docker=ready)
both_stopped=$(sandbox both-stopped container=stopped docker=stopped)
container_stopped_docker_ready=$(sandbox mixed container=stopped docker=ready)

check "no runtime: explains what to install" "$none" 69 "no container runtime found"
check "no runtime: recommends Apple's container CLI" "$none" 69 \
    "Apple's container CLI (recommended on macOS): https://github.com/apple/container"
check "no runtime: also offers Docker" "$none" 69 "Docker: https://docs.docker.com/get-docker/"
check "no runtime: a build stops before doing any work" "$none" 69 "no container runtime found" ""
check "Docker only" "$docker_ready" 0 docker
check "container only" "$container_ready" 0 container
check "both: prefers Apple's container CLI" "$both_ready" 0 container
check "container stopped, Docker running: uses Docker" "$container_stopped_docker_ready" 0 docker
check "Docker installed but not running" "$docker_stopped" 69 \
    "Docker is installed, but the Docker daemon is not responding."
check "container installed but not running" "$container_stopped" 69 \
    "Start it with 'container system start'"
check "both installed, neither running: reports the preferred one" "$both_stopped" 69 \
    "Apple's container CLI is installed, but its system service is not running."
check "override selects Docker" "$both_ready" 0 docker -- MAW_CONTAINER_RUNTIME=docker
check "override rejects an unknown runtime" "$both_ready" 64 \
    "MAW_CONTAINER_RUNTIME is 'podman'; use 'container' or 'docker'." \
    -- MAW_CONTAINER_RUNTIME=podman
check "override names a runtime that is not installed" "$container_ready" 69 \
    "MAW_CONTAINER_RUNTIME is 'docker', but 'docker' is not installed." \
    -- MAW_CONTAINER_RUNTIME=docker
check "override names a runtime that is not running" "$container_stopped" 69 \
    "Start it with 'container system start'" -- MAW_CONTAINER_RUNTIME=container

echo
if [ "$failures" -ne 0 ]; then
    echo "runtime-detection: $failures of $count checks failed."
    exit 1
fi
echo "runtime-detection: all $count checks passed."
