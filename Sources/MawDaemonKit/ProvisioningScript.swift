#if os(macOS)
    import MawCore

    /// The shell script that configures a new distribution's root file system, run by busybox
    /// `sh` in the initramfs machine with the root mounted at `/mnt/root`.
    ///
    /// Its values arrive as positional arguments, never inside the script's text:
    /// `sh -s -- <hostname> <user> <locale> <linger>`. The password is not among them; it goes
    /// to `chpasswd`'s standard input in a separate command. docs/distributions.md lists every
    /// change the script makes and why.
    enum ProvisioningScript {
        /// Units that would run in a maw machine and serve no purpose there. Masking links
        /// them to /dev/null, which `systemctl unmask` reverts.
        static let maskedUnits = [
            // cloud-init configures cloud instances; maw configures the distribution itself.
            "cloud-init-local.service", "cloud-init.service", "cloud-config.service",
            "cloud-final.service", "cloud-init-hotplugd.socket", "cloud-init.target",
            // snapd needs squashfs and AppArmor, which the maw kernel does not have, and its
            // services would wait for a seeding that cannot happen.
            "snapd.service", "snapd.socket", "snapd.seeded.service", "snapd.apparmor.service",
            "snapd.autoimport.service", "snapd.core-fixup.service",
            "snapd.recovery-chooser-trigger.service", "snapd.system-shutdown.service",
            "snapd.snap-repair.timer",
            // The network is up when systemd-networkd has an address; waiting for "online"
            // only delays the end of the boot.
            "systemd-networkd-wait-online.service",
            // Virtual terminal setup: a maw machine has no virtual terminals or keyboard.
            "console-setup.service", "keyboard-setup.service", "setvtrgb.service",
            // Login prompts on the console and on a virtual terminal that nobody can see;
            // sessions come through the guest agent.
            "serial-getty@hvc0.service", "getty@tty1.service",
            // News for a message of the day that maw does not show.
            "motd-news.timer",
            // Crash reports and their upload, which a development machine has no use for.
            "apport.service", "apport-autoreport.path", "apport-autoreport.timer",
            "apport-forward.socket",
            // The Landscape management client (in the WSL image): it is never registered, and
            // its registration check, a Python program, took 456 ms of every boot.
            "landscape-client.service",
            // Scrubbing of LVM snapshots; the disk has no LVM.
            "e2scrub_all.timer", "e2scrub_reap.service",
        ]

        /// The groups a new user joins if the distribution has them: those that WSL's Ubuntu
        /// setup gives the first user, so that `sudo` and hardware-facing tools work.
        static let userGroups = [
            "adm", "dialout", "cdrom", "floppy", "sudo", "audio", "dip", "video", "plugdev",
            "netdev", "users",
        ]

        static let text = """
            set -eu
            root=/mnt/root
            hostname=$1
            user=$2
            locale=$3
            linger=$4

            # The host name names the distribution.
            printf '%s\\n' "$hostname" > "$root/etc/hostname"
            cat > "$root/etc/hosts" << HOSTS
            127.0.0.1\tlocalhost
            127.0.1.1\t$hostname

            ::1\tlocalhost ip6-localhost ip6-loopback
            ff02::1\tip6-allnodes
            ff02::2\tip6-allrouters
            HOSTS

            # The root file system. The initramfs checks and mounts it before systemd starts.
            printf 'LABEL=maw-root\\t/\\text4\\tdefaults\\t0\\t0\\n' > "$root/etc/fstab"

            # The user, with the groups of a first Ubuntu user that this image has.
            groups=
            for group in \(userGroups.joined(separator: " ")); do
                if grep -q "^$group:" "$root/etc/group"; then
                    groups=${groups:+$groups,}$group
                fi
            done
            chroot "$root" /usr/sbin/useradd --create-home --shell /bin/bash \\
                --groups "$groups" "$user"
            if [ "$linger" = yes ]; then
                mkdir -p "$root/var/lib/systemd/linger"
                : > "$root/var/lib/systemd/linger/$user"
            fi
            # Ubuntu's bash prints a hint about sudo at every login until this file exists;
            # sudo creates it after the first successful use. The first prompt stays quiet.
            home=$(chroot "$root" /usr/bin/getent passwd "$user" | cut -d: -f6)
            : > "$root$home/.sudo_as_admin_successful"
            chroot "$root" /usr/bin/chown "$user:" "$home/.sudo_as_admin_successful"
            printf '# maw settings for this distribution. docs/distributions.md describes them.\\n[user]\\ndefault = %s\\n' \\
                "$user" > "$root/etc/maw.conf"

            # The Mac's locale, if the distribution supports it; C.UTF-8 otherwise.
            if [ -n "$locale" ] && [ -f "$root/usr/share/i18n/SUPPORTED" ] \\
                && grep -qx "$locale UTF-8" "$root/usr/share/i18n/SUPPORTED"; then
                chroot "$root" /usr/sbin/locale-gen "$locale" > /dev/null
                printf 'LANG=%s\\n' "$locale" > "$root/etc/default/locale"
            else
                printf 'LANG=C.UTF-8\\n' > "$root/etc/default/locale"
            fi

            # The network: DHCP on the virtual network device through systemd-networkd, and
            # DNS through systemd-resolved.
            mkdir -p "$root/etc/netplan"
            cat > "$root/etc/netplan/50-maw.yaml" << 'NETPLAN'
            # Written by maw: DHCP on the virtual network device. docs/distributions.md
            network:
              version: 2
              renderer: networkd
              ethernets:
                maw:
                  match:
                    driver: virtio_net
                  dhcp4: true
            NETPLAN
            chmod 600 "$root/etc/netplan/50-maw.yaml"
            ln -sfn ../run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"

            # The journal: at most 256 MB, instead of journald's default of 10% of the 256 GiB
            # disk (at most 4 GB), which would stay allocated on the Mac.
            mkdir -p "$root/etc/systemd/journald.conf.d"
            printf '# Written by maw. docs/distributions.md\n[Journal]\nSystemMaxUse=256M\n' \
                > "$root/etc/systemd/journald.conf.d/50-maw.conf"

            # Services that serve no purpose in maw.
            for unit in \(maskedUnits.joined(separator: " ")); do
                ln -sfn /dev/null "$root/etc/systemd/system/$unit"
            done

            # The WSL image prints the message of the day from a profile script once a day.
            # Diverting it keeps the first prompt quiet, and survives package updates.
            if [ -e "$root/etc/profile.d/update-motd.sh" ]; then
                chroot "$root" /usr/bin/dpkg-divert --quiet --local --rename \\
                    --add /etc/profile.d/update-motd.sh
            fi
            """

        /// The arguments after `sh -s --`. Every value is validated, so that none can be read
        /// as an option or contain a line break.
        static func arguments(for configuration: GuestConfiguration, linger: Bool) throws(MawError)
            -> [String]
        {
            let hostname = configuration.hostname
            guard !hostname.isEmpty, hostname.count <= 63,
                hostname.unicodeScalars.allSatisfy({
                    ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
                }),
                !hostname.hasPrefix("-")
            else {
                throw .provisioningFailed(
                    step: "configuring the distribution", reason: "'\(hostname)' is not a host name"
                )
            }
            var locale = ""
            if let candidate = configuration.locale, isLocaleName(candidate) {
                locale = candidate
            }
            return [hostname, configuration.user.rawValue, locale, linger ? "yes" : "no"]
        }

        /// `ll_CC.UTF-8`, the only form `GuestLocale.preferred` produces.
        static func isLocaleName(_ text: String) -> Bool {
            let scalars = Array(text.unicodeScalars)
            guard scalars.count == 11, text.hasSuffix(".UTF-8"), scalars[2] == "_" else {
                return false
            }
            return scalars[0...1].allSatisfy { ("a"..."z").contains($0) }
                && scalars[3...4].allSatisfy { ("A"..."Z").contains($0) }
        }
    }
#endif
