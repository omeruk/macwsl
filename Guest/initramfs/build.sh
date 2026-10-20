#!/bin/bash
# Builds the MacWSL initramfs: static busybox with applet symlinks, static e2fsprogs tools,
# and /init, packed as a reproducible gzip-compressed cpio archive. Runs inside the builder
# container; start it through Guest/build.sh.
#
# Usage: build.sh --sources <dir> --work <dir> --headers <dir> --gen-init-cpio <path>
#                 --version <version> --output <file> [--agent <path>]
#
#   --sources        directory with the verified source tarballs
#   --work           scratch directory; its contents are replaced
#   --headers        kernel UAPI headers from `make headers_install`
#   --gen-init-cpio  the kernel's usr/gen_init_cpio, built for this machine
#   --version        version string for the /init banner
#   --output         path of the initramfs.cpio.gz to write
#   --agent          optional binary to install as /sbin/macwsl-agent (phase 04)
#
# SOURCE_DATE_EPOCH must be set. It is the modification time of every archive entry.

set -euo pipefail

initramfs_dir=$(cd "$(dirname "$0")" && pwd)
guest_dir=$(dirname "$initramfs_dir")
# shellcheck source=Guest/initramfs/SOURCES
. "$initramfs_dir/SOURCES"

usage() {
    sed -n '6,18s/^# \{0,1\}//p' "$0" >&2
    exit 64
}

sources= work= headers= gen_init_cpio= version= output= agent=
while [ "$#" -gt 0 ]; do
    case $1 in
        --sources) sources=$2 ;;
        --work) work=$2 ;;
        --headers) headers=$2 ;;
        --gen-init-cpio) gen_init_cpio=$2 ;;
        --version) version=$2 ;;
        --output) output=$2 ;;
        --agent) agent=$2 ;;
        *) usage ;;
    esac
    shift 2 || usage
done
for required in sources work headers gen_init_cpio version output; do
    if [ -z "${!required}" ]; then
        echo "initramfs/build.sh: --${required//_/-} is required." >&2
        usage
    fi
done
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set}"
if [ -n "$agent" ] && [ ! -f "$agent" ]; then
    echo "initramfs/build.sh: agent binary $agent does not exist." >&2
    exit 66
fi

rm -rf "$work"
mkdir -p "$work"
jobs=$(nproc)

# musl-gcc does not search the system include path, so point it at the kernel's UAPI headers.
cc=$work/musl-cc
printf '#!/bin/sh\nexec musl-gcc -isystem %s/include "$@"\n' "$headers" > "$cc"
chmod +x "$cc"

require_static() {
    if readelf --program-headers "$1" | grep -q INTERP; then
        echo "initramfs/build.sh: $1 is dynamically linked." >&2
        exit 1
    fi
}

echo "initramfs: building busybox $BUSYBOX_VERSION"
mkdir "$work/busybox"
tar -xf "$sources/$(basename "$BUSYBOX_URL")" -C "$work/busybox" --strip-components=1
(
    cd "$work/busybox"
    make defconfig > /dev/null
    "$guest_dir/scripts/merge-fragment.sh" .config "$initramfs_dir/busybox.config"
    # `yes` is killed by SIGPIPE when oldconfig exits; that must not fail the pipeline.
    { yes '' || true; } | make oldconfig > /dev/null
    "$guest_dir/scripts/verify-fragment.sh" "$initramfs_dir/busybox.config" .config
    make -j"$jobs" CC="$cc" HOSTCC=gcc busybox > /dev/null
)
require_static "$work/busybox/busybox"

echo "initramfs: building e2fsprogs $E2FSPROGS_VERSION"
mkdir -p "$work/e2fsprogs/src" "$work/e2fsprogs/build"
tar -xf "$sources/$(basename "$E2FSPROGS_URL")" -C "$work/e2fsprogs/src" --strip-components=1
(
    cd "$work/e2fsprogs/build"
    ../src/configure \
        CC="$cc" CFLAGS="-Os" LDFLAGS="-static" \
        --disable-nls --disable-rpath --disable-fuse2fs --disable-uuidd --disable-debugfs \
        --disable-imager --disable-defrag --disable-e2initrd-helper --disable-backtrace \
        --disable-tdb --without-libarchive --enable-libuuid --enable-libblkid \
        --with-udev-rules-dir=no --with-crond-dir=no --with-systemd-unit-dir=no \
        > configure.log 2>&1 || { cat configure.log; exit 1; }
    make -j"$jobs" libs > /dev/null
    make -j"$jobs" -C misc mke2fs > /dev/null
    make -j"$jobs" -C e2fsck e2fsck > /dev/null
    make -j"$jobs" -C resize resize2fs > /dev/null
)
for tool in misc/mke2fs e2fsck/e2fsck resize/resize2fs; do
    require_static "$work/e2fsprogs/build/$tool"
done

echo "initramfs: assembling the root"
root=$work/root
mkdir -p "$root"/{bin,sbin,usr/bin,usr/sbin,etc,dev,proc,sys,run,tmp,root,mnt}

install -m 0755 "$work/busybox/busybox" "$root/bin/busybox"
"$root/bin/busybox" --list-full | while read -r applet; do
    [ "$applet" = bin/busybox ] && continue
    mkdir -p "$root/$(dirname "$applet")"
    ln -sfn /bin/busybox "$root/$applet"
done

for tool in misc/mke2fs e2fsck/e2fsck resize/resize2fs; do
    rm -f "$root/sbin/$(basename "$tool")"
    install -m 0755 "$work/e2fsprogs/build/$tool" "$root/sbin/$(basename "$tool")"
done
ln -sfn mke2fs "$root/sbin/mkfs.ext4"

if [ -n "$agent" ]; then
    install -m 0755 "$agent" "$root/sbin/macwsl-agent"
fi

install -m 0755 "$initramfs_dir/init" "$root/init"
printf '%s\n' "$version" > "$root/etc/macwsl-initramfs-version"
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$root/etc/passwd"
printf 'root:x:0:\n' > "$root/etc/group"
strip --strip-all "$root/bin/busybox" "$root"/sbin/{mke2fs,e2fsck,resize2fs}

# Describe every entry for gen_init_cpio, with normalized modes and owner 0:0, sorted by
# path so that parents precede children and the order never depends on the file system.
echo "initramfs: packing"
spec=$work/initramfs.list
(
    cd "$root"
    find . -mindepth 1 -printf '%P\n' | while read -r path; do
        if [ -L "$path" ]; then
            printf '/%s\tslink /%s %s 0777 0 0\n' "$path" "$path" "$(readlink "$path")"
        elif [ -d "$path" ]; then
            mode=0755
            [ "$path" = tmp ] && mode=1777
            [ "$path" = root ] && mode=0700
            printf '/%s\tdir /%s %s 0 0\n' "$path" "$path" "$mode"
        elif [ -x "$path" ]; then
            printf '/%s\tfile /%s %s/%s 0755 0 0\n' "$path" "$path" "$root" "$path"
        else
            printf '/%s\tfile /%s %s/%s 0644 0 0\n' "$path" "$path" "$root" "$path"
        fi
    done
    printf '/dev/console\tnod /dev/console 0600 0 0 c 5 1\n'
) | LC_ALL=C sort -t "$(printf '\t')" -k1,1 | cut -f 2 > "$spec"

"$gen_init_cpio" -t "$SOURCE_DATE_EPOCH" -o "$work/initramfs.cpio" "$spec"
gzip -n -9 -c "$work/initramfs.cpio" > "$output"
echo "initramfs: $(grep -c . "$spec") entries, $(stat -c %s "$output") bytes compressed"
