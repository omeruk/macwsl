#!/bin/bash
# Configures and builds the maw guest kernel. Runs inside the builder container; start it
# through Guest/build.sh.
#
# Usage: build-kernel.sh <source-tarball> <work-dir>
#
# Leaves these in <work-dir>:
#   linux/arch/arm64/boot/Image   the uncompressed kernel
#   linux/.config                 the final configuration
#   kernel-headers/               the kernel's UAPI headers, used to build the initramfs
#   gen_init_cpio                 the kernel's cpio generator, used to pack the initramfs

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <source-tarball> <work-dir>" >&2
    exit 64
fi
tarball=$1
work_dir=$2
kernel_dir=$(cd "$(dirname "$0")" && pwd)
guest_dir=$(dirname "$kernel_dir")
fragment=$kernel_dir/maw.config

src=$work_dir/linux
rm -rf "$src"
mkdir -p "$src"
tar -xf "$tarball" -C "$src" --strip-components=1
cd "$src"

# maw's patches, in name order. Each must apply with no fuzz: every line of a hunk's context
# must match, although the hunk may have moved, so that a kernel bump that changes the patched
# code fails here instead of building something else. Guest/README.md, "Bumping the kernel",
# describes how to refresh them.
for patch_file in "$kernel_dir"/patches/*.patch; do
    [ -e "$patch_file" ] || continue
    echo "build-kernel: applying $(basename "$patch_file")"
    if ! patch -p1 --fuzz=0 --forward --batch --no-backup-if-mismatch < "$patch_file"; then
        echo "build-kernel: $(basename "$patch_file") does not apply cleanly to this kernel" >&2
        exit 1
    fi
done

make_kernel() {
    make ARCH=arm64 "$@"
}

echo "build-kernel: configuring from allnoconfig and $(basename "$fragment")"
make_kernel allnoconfig > /dev/null
scripts/kconfig/merge_config.sh -m .config "$fragment"
make_kernel olddefconfig > /dev/null
"$guest_dir/scripts/verify-fragment.sh" "$fragment" .config

echo "build-kernel: building Image with $(nproc) jobs"
make_kernel -j"$(nproc)" Image

echo "build-kernel: installing UAPI headers"
make_kernel headers_install INSTALL_HDR_PATH="$work_dir/kernel-headers" > /dev/null

gcc -O2 -o "$work_dir/gen_init_cpio" usr/gen_init_cpio.c
