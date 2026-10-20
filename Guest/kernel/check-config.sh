#!/bin/sh
# Checks a built kernel configuration against two lists of required options:
#
#   1. MacWSL's own list, below: what the guest needs to boot under Virtualization.framework,
#      run the agent, share files, run systemd, and run Docker or Podman.
#   2. The "Generally Necessary" section of moby's contrib/check-config.sh, pinned by commit
#      and sha256. Its "Optional Features" are reported but do not fail the check.
#
# Exits with status 1 if any required option is missing.
#
# Usage: Guest/kernel/check-config.sh [<config>]    (default: Guest/out/kernel.config)

set -eu

guest_dir=$(cd "$(dirname "$0")/.." && pwd)
config=${1:-$guest_dir/out/kernel.config}
cache_dir=${MACWSL_GUEST_CACHE:-$guest_dir/.cache/sources}

MOBY_COMMIT=a4c5b2be6f69f86fe7b13eb4822676f8d273cf8b
MOBY_SHA256=fda4343e9b50c47896653ca774ccbe9614bfcdb60f080d2b6277baf27efc0a71
MOBY_URL=https://raw.githubusercontent.com/moby/moby/$MOBY_COMMIT/contrib/check-config.sh

# One option per line: NAME=y (must be built in) or NAME=n (must not be set).
REQUIRED_OPTIONS='
# Boot and platform: Virtualization.framework and QEMU virt.
ARM64_4K_PAGES=y
SMP=y
ARM_ARCH_TIMER=y
ARM_GIC=y
ARM_GIC_V3=y
ARM_PSCI_FW=y
PCI=y
PCI_HOST_GENERIC=y
SERIAL_AMBA_PL011=y
SERIAL_AMBA_PL011_CONSOLE=y
SERIAL_EARLYCON=y
MODULES=n
BLK_DEV_INITRD=y
RD_GZIP=y
BINFMT_ELF=y
BINFMT_SCRIPT=y
TTY=y
UNIX98_PTYS=y

# Virtio devices.
VIRTIO_PCI=y
VIRTIO_BLK=y
VIRTIO_NET=y
VIRTIO_CONSOLE=y
VIRTIO_BALLOON=y
HW_RANDOM_VIRTIO=y
FUSE_FS=y
VIRTIO_FS=y
VSOCKETS=y
VIRTIO_VSOCKETS=y

# Filesystems.
EXT4_FS=y
TMPFS=y
DEVTMPFS=y
DEVTMPFS_MOUNT=y
PROC_FS=y
SYSFS=y
OVERLAY_FS=y
AUTOFS_FS=y

# Rosetta for Linux (phase 10).
BINFMT_MISC=y

# Networking.
NET=y
INET=y
IPV6=y
UNIX=y
PACKET=y

# Containers.
NAMESPACES=y
UTS_NS=y
IPC_NS=y
USER_NS=y
PID_NS=y
NET_NS=y
CGROUPS=y
CGROUP_SCHED=y
CPUSETS=y
BLK_CGROUP=y
MEMCG=y
CGROUP_HUGETLB=y
CGROUP_PIDS=y
CGROUP_RDMA=y
CGROUP_MISC=y
CGROUP_PERF=y
CGROUP_DMEM=y
CGROUP_BPF=y
SECCOMP=y
SECCOMP_FILTER=y
BPF_SYSCALL=y
BRIDGE=y
VETH=y
TUN=y
NETFILTER=y
NF_CONNTRACK=y
NF_NAT=y
NF_TABLES=y
NF_TABLES_INET=y
NFT_CT=y
NFT_NAT=y
NFT_MASQ=y
NFT_COMPAT=y

# systemd v262.1 README, "REQUIREMENTS": kernel config options.
DEVTMPFS=y
CGROUPS=y
INOTIFY_USER=y
SIGNALFD=y
TIMERFD=y
EPOLL=y
UNIX=y
SYSFS=y
PROC_FS=y
FHANDLE=y
SYSFS_DEPRECATED=n
# UEVENT_HELPER_PATH="" is satisfied by disabling the uevent helper entirely.
UEVENT_HELPER=n
FW_LOADER_USER_HELPER=n
BLK_DEV_BSG=y
NET_NS=y
USER_NS=y
IPV6=y
AUTOFS_FS=y
TMPFS_XATTR=y
TMPFS_POSIX_ACL=y
EXT4_FS_POSIX_ACL=y
SECCOMP=y
SECCOMP_FILTER=y
NET_SCHED=y
NET_SCH_FQ_CODEL=y
CGROUP_SCHED=y
FAIR_GROUP_SCHED=y
CFS_BANDWIDTH=y
BPF=y
BPF_SYSCALL=y
BPF_JIT=y
HAVE_EBPF_JIT=y
CGROUP_BPF=y
EFI_PARTITION=y
RT_GROUP_SCHED=n
PSI=y
MEMCG=y
'
# Items in the systemd README that are not on the list above, and why:
# - DMIID, DMI, DMI_SYSFS: on arm64, DMI depends on EFI. VZLinuxBootLoader boots the kernel
#   without firmware, so there are no SMBIOS tables.
# - EFIVAR_FS: depends on EFI, for the same reason.
# - KCMP: the README states it is not needed after Linux 6.10.
# - DEVPTS_MULTIPLE_INSTANCES: removed from the kernel in Linux 4.7.
# - DM_VERITY_VERIFY_ROOTHASH_SIG and its keyring variants, IMA_ARCH_POLICY,
#   INTEGRITY_MACHINE_KEYRING: needed only for signed dm-verity images and firmware or
#   Machine Owner Key keyrings. The guest boots a plain ext4 disk without device-mapper or
#   secure boot, and INTEGRITY_MACHINE_KEYRING depends on LOAD_UEFI_KEYS on arm64.
# - BPF_LSM, DEBUG_INFO_BTF, and LSM="...,bpf": needed only for RestrictFileSystems=.
#   DEBUG_INFO_BTF requires building with DWARF debug information and pahole, which the
#   guest build does not include. Tracked as follow-up work in Guest/README.md.

if [ ! -f "$config" ]; then
    echo "check-config: $config not found. Build the guest first with Guest/build.sh." >&2
    exit 66
fi

sha256() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 "$1" | cut -d ' ' -f 1
    fi
}

failed=0

# 1. MacWSL's required list.
echo "MacWSL required options:"
printf '%s\n' "$REQUIRED_OPTIONS" | awk -v config="$config" '
    BEGIN {
        while ((getline line < config) > 0) {
            if (match(line, /^CONFIG_[A-Za-z0-9_]+=/)) {
                value[substr(line, 8, RLENGTH - 8)] = substr(line, RLENGTH + 1)
            }
        }
    }
    /^[A-Z0-9_]+=[yn]$/ {
        split($0, part, "=")
        name = part[1]; want = part[2]
        if (seen[name]++) next
        got = (name in value) ? value[name] : "n"
        if (got == want) {
            ok++
        } else {
            printf "  - CONFIG_%s: required %s, got %s\n", name, want, got
            missing++
        }
    }
    END {
        printf "  %d of %d options as required.\n", ok, ok + missing
        exit missing > 0
    }
' || failed=1

# 2. moby's check-config.sh, pinned by commit.
moby_script=$cache_dir/moby-check-config-$MOBY_COMMIT.sh
if [ ! -f "$moby_script" ]; then
    mkdir -p "$cache_dir"
    curl --fail --silent --show-error --location --output "$moby_script.part" "$MOBY_URL"
    mv "$moby_script.part" "$moby_script"
fi
actual_sha256=$(sha256 "$moby_script")
if [ "$actual_sha256" != "$MOBY_SHA256" ]; then
    echo "check-config: $moby_script has sha256 $actual_sha256, expected $MOBY_SHA256." >&2
    rm -f "$moby_script"
    exit 1
fi

# moby's script also inspects the machine it runs on. Two commands are replaced so that its
# result depends only on the configuration file:
# - `uname -r` drives its version-dependent checks; report the configured kernel's version.
# - `stat` detects the cgroup mount; report cgroup v2. Otherwise, on macOS the script takes
#   its cgroup v1 path, whose GNU-only sed expression aborts it.
kernel_version=$(sed -n 's/^# Linux\/[^ ]* \([0-9][0-9.]*\)[^ ]* Kernel Configuration$/\1/p' \
    "$config" | head -n 1)
if [ -z "$kernel_version" ]; then
    echo "check-config: cannot read the kernel version from $config." >&2
    exit 65
fi
shim_dir=$(mktemp -d)
trap 'rm -rf "$shim_dir"' EXIT
printf '#!/bin/sh\necho %s\n' "$kernel_version" > "$shim_dir/uname"
printf '#!/bin/sh\necho 63677270\n' > "$shim_dir/stat"
chmod +x "$shim_dir/uname" "$shim_dir/stat"

moby_output=$(NO_COLOR=1 PATH="$shim_dir:$PATH" sh "$moby_script" "$config" 2>&1 || true)

# Only CONFIG_* lines describe the kernel configuration. The script's other lines (cgroup
# hierarchy, AppArmor, storage driver summaries) describe the machine it runs on.
echo
echo "moby contrib/check-config.sh @ ${MOBY_COMMIT%"${MOBY_COMMIT#????????????}"}, required:"
printf '%s\n' "$moby_output" | awk '
    /^Generally Necessary:/ { section = "required"; next }
    /^Optional Features:/ { section = "optional"; next }
    section == "required" && /^- CONFIG_[A-Z0-9_]+: / {
        if ($0 ~ /: enabled$/) { ok++ } else { print "  " $0; missing++ }
    }
    END {
        if (ok + missing == 0) {
            print "  No results found. The output format of the pinned script is not as expected."
            exit 1
        }
        printf "  %d of %d options enabled.\n", ok, ok + missing
        exit missing > 0
    }
' || failed=1

echo
echo "moby contrib/check-config.sh, optional (reported only):"
printf '%s\n' "$moby_output" | awk '
    /^Optional Features:/ { section = "optional"; next }
    section == "optional" && /^ *- CONFIG_[A-Z0-9_]+: / {
        if ($0 ~ /: enabled/) { ok++ } else { sub(/^ */, ""); print "  " $0; missing++ }
    }
    END { printf "  %d of %d optional options enabled.\n", ok, ok + missing }
'

echo
if [ "$failed" -ne 0 ]; then
    echo "check-config: required options are missing."
    exit 1
fi
echo "check-config: every required option is set."
