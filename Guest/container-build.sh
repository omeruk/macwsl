#!/bin/bash
# Builds the guest kernel and initramfs. Runs inside the builder container, which
# Guest/build.sh starts with these mounts:
#
#   /guest     the repository's Guest/ directory (read-only)
#   /sources   verified source tarballs (read-only)
#   /out       output directory
#
# and these environment variables: SOURCE_DATE_EPOCH, GUEST_VERSION, GIT_COMMIT,
# BUILDER_IMAGE, HOST_UID, HOST_GID.
#
# Usage: container-build.sh [--agent <path>]

set -euo pipefail

guest=/guest
sources=/sources
out=/out
# A fixed build directory outside the repository: the kernel embeds no host-specific path,
# and its version script does not see a git tree and append "+" to the release.
work=/build

agent=
case ${1:-} in
    '') ;;
    --agent) agent=${2:?--agent needs a path} ;;
    *) echo "usage: $0 [--agent <path>]" >&2; exit 64 ;;
esac

: "${SOURCE_DATE_EPOCH:?}" "${GUEST_VERSION:?}" "${GIT_COMMIT:?}" "${BUILDER_IMAGE:?}"
# shellcheck source=Guest/kernel/VERSION
. "$guest/kernel/VERSION"
# shellcheck source=Guest/initramfs/SOURCES
. "$guest/initramfs/SOURCES"

# Everything that would otherwise vary between two builds of the same commit.
export SOURCE_DATE_EPOCH
KBUILD_BUILD_TIMESTAMP=$(date --utc --date="@$SOURCE_DATE_EPOCH" '+%a %b %e %H:%M:%S UTC %Y')
export KBUILD_BUILD_TIMESTAMP
export KBUILD_BUILD_USER=maw
export KBUILD_BUILD_HOST=maw
export KBUILD_BUILD_VERSION=1
export TZ=UTC
export LC_ALL=C.UTF-8

rm -rf "$work"
mkdir -p "$work"

"$guest/kernel/build-kernel.sh" "$sources/$(basename "$LINUX_URL")" "$work"
release=$(make -s -C "$work/linux" ARCH=arm64 kernelrelease)
if [ "$release" != "$LINUX_VERSION-maw" ]; then
    echo "container-build: kernel release is $release, expected $LINUX_VERSION-maw." >&2
    exit 1
fi

initramfs_args=(
    --sources "$sources"
    --work "$work/initramfs"
    --headers "$work/kernel-headers"
    --gen-init-cpio "$work/gen_init_cpio"
    --version "$GUEST_VERSION"
    --output "$out/initramfs.cpio.gz"
)
if [ -n "$agent" ]; then
    initramfs_args+=(--agent "$agent")
fi
"$guest/initramfs/build.sh" "${initramfs_args[@]}"

cp "$work/linux/arch/arm64/boot/Image" "$out/Image"
cp "$work/linux/.config" "$out/kernel.config"

agent_json=null
if [ -n "$agent" ]; then
    agent_json="{ \"sha256\": \"$(sha256sum "$agent" | cut -d ' ' -f 1)\" }"
fi
cat > "$out/manifest.json" << EOF
{
  "schemaVersion": 1,
  "guestVersion": "$GUEST_VERSION",
  "gitCommit": "$GIT_COMMIT",
  "sourceDateEpoch": $SOURCE_DATE_EPOCH,
  "builderImage": "$BUILDER_IMAGE",
  "kernel": {
    "version": "$LINUX_VERSION",
    "release": "$release",
    "sourceSha256": "$LINUX_SHA256"
  },
  "initramfs": {
    "busybox": { "version": "$BUSYBOX_VERSION", "sourceSha256": "$BUSYBOX_SHA256" },
    "e2fsprogs": { "version": "$E2FSPROGS_VERSION", "sourceSha256": "$E2FSPROGS_SHA256" },
    "libarchive": { "version": "$LIBARCHIVE_VERSION", "sourceSha256": "$LIBARCHIVE_SHA256" },
    "agent": $agent_json
  }
}
EOF

(cd "$out" && sha256sum Image initramfs.cpio.gz kernel.config manifest.json > SHA256SUMS)

# Files created in a bind mount belong to root inside the container. Give them to the user
# who started the build, so that a later build or `rm` can replace them.
chown -R "${HOST_UID:-0}:${HOST_GID:-0}" "$out" 2> /dev/null || true

echo "container-build: done"
cat "$out/SHA256SUMS"
