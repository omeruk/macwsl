/// The built-in catalog, decoded by `DistroCatalog.builtIn`. It is a string rather than a
/// package resource so that it is part of the binary: `maw` and `mawd` ship as single files.
///
/// Ubuntu-24.04 is the WSL image of Ubuntu 24.04.5 for arm64
/// (`docs/decisions/0012-ubuntu-image.md`). Its SHA-256 appears in Canonical's `SHA256SUMS`
/// for the release, whose signature by the Ubuntu CD Image Automatic Signing Key
/// (843938DF228D22F7B3742BC0D94AA3F0EFE21092) was verified when it was pinned, and in
/// Microsoft's `DistributionInfo.json` for `wsl --install`. `installedSize` is the space the
/// extracted root file system used on an ext4 disk, from `df`. `reservedNames` are the user and
/// group names in the image's `/etc/passwd` and `/etc/group`.
let catalogJSON = """
    {
      "recommended": "Ubuntu-24.04",
      "entries": [
        {
          "name": "Ubuntu-24.04",
          "aliases": ["Ubuntu"],
          "displayName": "Ubuntu 24.04 LTS",
          "release": "24.04.5",
          "image": {
            "url": "https://cdimages.ubuntu.com/ubuntu/releases/24.04.5/release/ubuntu-24.04.5-wsl-arm64.wsl",
            "format": "tar.gz",
            "size": 388300496,
            "sha256": "74478b5024d9047397ba79d17c27f73caf85ada4988f88cffc2892d65e6a806b",
            "installedSize": 1372721152
          },
          "reservedNames": [
            "_apt", "_ssh", "adm", "admin", "audio", "backup", "bin", "cdrom", "crontab",
            "daemon", "dhcpcd", "dialout", "dip", "disk", "fax", "floppy", "games", "input",
            "irc", "kmem", "kvm", "landscape", "list", "lp", "mail", "man", "messagebus",
            "netdev", "news", "nobody", "nogroup", "operator", "plugdev", "polkitd", "proxy",
            "render", "root", "sasl", "sgx", "shadow", "src", "staff", "sudo", "sync", "sys",
            "syslog", "systemd-journal", "systemd-network", "systemd-resolve",
            "systemd-timesync", "tape", "tty", "users", "utmp", "uucp", "uuidd", "video",
            "voice", "www-data"
          ]
        }
      ]
    }
    """
