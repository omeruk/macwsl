# 0012: Ubuntu is installed from its WSL image, pinned by SHA-256

- Status: Accepted
- Date: 2026-10-22

## Context

`maw --install Ubuntu-24.04` needs a root file system archive for arm64. Canonical publishes
three for Ubuntu 24.04:

1. the **cloud image root** (`ubuntu-24.04-server-cloudimg-arm64-root.tar.xz`), a new serial
   every few weeks;
2. the **WSL image** (`ubuntu-24.04.5-wsl-arm64.wsl`), a gzip tar archive per point release,
   which `wsl --install Ubuntu-24.04` installs;
3. **Ubuntu Base** (`ubuntu-base-24.04.5-base-arm64.tar.gz`), a minimal system without systemd.

The image has to give a developer an ordinary Ubuntu at once (`sudo`, `bash-completion`,
`man`, `curl`, `ca-certificates`), install quickly from a cached copy, and boot quickly.

## Measurements

Measured on an M1 Pro (8 CPUs, 16 GiB), macOS 27.0.1, on 2026-10-22.

| | Cloud root `release-20261017` | WSL `24.04.5` | Ubuntu Base `24.04.5` |
|---|---|---|---|
| Download | 216.2 MB, xz | 388.3 MB, gzip | 29.9 MB, gzip |
| Unpacked archive, entries | 1.13 GB, 47,170 | 1.30 GB, 49,344 | 103 MB, 3,413 |
| Decompression on the Mac (libarchive) | 10.6 s | 2.0 s | 0.2 s |
| Decompression in the guest (busybox) | 15.7 s | 10.1 s | – |
| Decompressed on the Mac and streamed to the guest | 11.4 s | 5.35 s | – |
| Extraction step of `maw --install` | 11.4 s | 5.0 to 5.2 s | – |
| `sudo`, `bash-completion`, `man`, `curl`, `ca-certificates` | all | all | none, and no systemd |
| Extra services enabled at boot, besides cloud-init and snapd | multipath, iSCSI, LVM, ModemManager, open-vm-tools, ufw, ssh, udisks2, sysstat | landscape-client; WSL's own units skip themselves (`ConditionVirtualization=wsl`) | – |

With the same units masked (docs/distributions.md), median of 5 cold boots each:

| | WSL image | Cloud root |
|---|---|---|
| Cold boot to a prompt | 827.8 ms (slowest 864.1 ms) | 870.4 ms (slowest 890.3 ms) |
| Memory used 30 s after boot | 205 MB | 220 MB |
| systemd's userspace startup | 416 ms | 447 ms |
| Services running at idle | 12 | 15 (adds ModemManager, polkit, udisks2) |

Before `landscape-client` was masked, the WSL image measured 852.9 ms to a prompt and 228 MB;
its 456 ms registration check made systemd's userspace startup 745 ms.

## Decision

The catalog's `Ubuntu-24.04` entry, alias `Ubuntu`, is the WSL image of Ubuntu 24.04.5:

```
https://cdimages.ubuntu.com/ubuntu/releases/24.04.5/release/ubuntu-24.04.5-wsl-arm64.wsl
size    388300496
sha256  74478b5024d9047397ba79d17c27f73caf85ada4988f88cffc2892d65e6a806b
```

## Reasons

- **It is built for this.** It has no kernel, boot loader, or partitioning to undo; it boots
  systemd as PID 1, and its first user is created interactively, as maw does.
- **It installs fastest.** Decompressing gzip on the Mac takes 2.0 s against 10.6 s for xz;
  the extraction step takes about 5 s against 11.4 s.
- **It boots faster and uses less memory** than the cloud root with the same masks, and runs
  fewer services, because it lacks the cloud root's storage and network management daemons.
- **Its URL is stable.** Point release images stay in `releases/24.04.5/` for the life of the
  release; Microsoft pins the same URL and SHA-256 in `DistributionInfo.json`.
- **Ubuntu Base** would need about 300 packages from the network during every installation,
  which would make an installation depend on the network and take minutes.

## Trade-offs

- The download is 172 MB larger than the cloud root's, about 31 s at the 5.5 MB/s measured.
  Only the first installation downloads it.
- Its packages date from the 24.04.5 release, so the first `apt upgrade` installs more than it
  would on a recent cloud serial.
- It carries WSL-specific parts. maw neutralizes those that would run or print anything, and
  lists them in docs/distributions.md: `landscape-client` is masked, and the profile script
  that prints the message of the day is diverted. `/etc/wsl.conf` and `/etc/wsl-distribution.conf`
  stay; nothing in maw reads them.

## Verification

- The catalog pins the SHA-256 of one specific image. `ImageCache.verify` checks the size and
  the SHA-256 of the cached file before every installation; a file that fails is removed.
  Nothing reads an image before it has been verified.
- Downloads use HTTPS only, also after a redirect. A partial download is kept and resumed with
  `Range` and `If-Range`, conditional on the `ETag` of the first response, so that a changed file
  is downloaded afresh rather than spliced together.
- **OpenPGP is not checked at installation.** Canonical signs `SHA256SUMS` with the Ubuntu CD
  Image Automatic Signing Key. maw has no OpenPGP implementation and adds no dependency for one.
  The signature is checked once, when an image is pinned, and the pinned SHA-256 then protects
  every installation: an attacker would have to break SHA-256 or change maw's binary. The cost
  is that maw cannot accept a new image without a new release of maw.

### Pinning a new image

When Canonical publishes a new point release, or to move to a newer image:

1. Download the release's `SHA256SUMS` and `SHA256SUMS.gpg` from
   `https://cdimages.ubuntu.com/ubuntu/releases/<release>/release/`, and verify the signature
   with `gpg --verify` against the key `843938DF228D22F7B3742BC0D94AA3F0EFE21092`, fetched over
   HTTPS from `keyserver.ubuntu.com`.
2. Download the image, and check that its SHA-256 matches the signed list and Microsoft's
   `DistributionInfo.json`.
3. Extract it, and update the entry's `size`, `sha256`, `release`, `installedSize` (the space it
   uses on an ext4 disk, from `df`), and `reservedNames` (the names in its `/etc/passwd` and
   `/etc/group`) in `Sources/MawCore/CatalogData.swift`.
4. Run the integration tests, which install it, and open a pull request that records the
   verification.

## Extraction

The image is decompressed on the Mac by `/usr/bin/tar` (libarchive), re-encoded as an
uncompressed pax archive, and extracted in the initramfs machine by `bsdtar`. busybox `tar`
drops extended attributes, so `/usr/bin/ping`, `/usr/lib/snapd/snap-confine`, and
`gst-ptp-helper` would lose their file capabilities. `bsdtar` from libarchive 3.8.10 is built
static into the initramfs (`Guest/initramfs/SOURCES`), pinned by SHA-256; the tarball's OpenPGP
signature was verified against the key of libarchive's release maintainer,
`659C84C0E23EA1FA97E0B58CC040B508D63D2B36`, and the same SHA-256 was obtained from github.com and
libarchive.org. It is built without compression libraries, because the Mac decompresses. It
runs as root with `--numeric-owner`, because the initramfs has no `/etc/passwd` that matches
Ubuntu's. The integration tests compare the installed capabilities and the owners of system
files with the image.
