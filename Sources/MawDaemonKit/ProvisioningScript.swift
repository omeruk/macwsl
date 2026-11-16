#if os(macOS)
    import MawCore

    /// The shell script that configures a distribution's root file system, run by busybox `sh`
    /// in the initramfs machine with the root mounted at `root`.
    ///
    /// Its values arrive as positional arguments, never inside the script's text:
    /// `sh -s -- <root> <mode> <hostname> <user> <locale> <linger>`. The password is not among
    /// them; it goes to `chpasswd`'s standard input in a separate command, and `/etc/maw.conf`
    /// is written by `mawConfWriter`. docs/distributions.md lists every change the script makes
    /// and why.
    ///
    /// In the `install` mode it configures a new distribution from the catalog and creates its
    /// user. In the `import` mode it writes only the system files that a root file system needs
    /// to boot in maw, creates no user, and keeps the archive's locale (docs/distributions.md,
    /// "What --import configures").
    ///
    /// Every path that it writes, removes, or creates is resolved inside the root first
    /// (`functions`), so that a link in an imported archive can never make it write outside
    /// the root. A path that cannot be resolved ends the script with status 3 and a line
    /// `maw-unresolvable<TAB><path><TAB><reason>` on standard output.
    enum ProvisioningScript {
        /// What the script configures.
        enum Mode: String, Sendable {
            /// A new distribution from the catalog, with its user.
            case install
            /// An imported root file system: system files only.
            case `import`
        }

        /// Where the provisioning machine mounts the distribution's root file system.
        static let root = "/mnt/root"
        /// The script's exit status when a path cannot be resolved inside the root.
        static let unresolvableStatus: Int32 = 3
        /// The first field of the line that names a path that cannot be resolved.
        static let unresolvableMarker = "maw-unresolvable"

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

        /// Shell functions that find paths inside `$root`, shared by the scripts that read or
        /// write a root file system.
        ///
        /// `resolve` follows every link of a path as the kernel would if `$root` were `/`: an
        /// absolute target starts again at `$root`, and `..` stops at `$root`. It prints the
        /// result, starting with `/`, or `!` and a reason, and always succeeds, so that `set -e`
        /// does not end the script before the reason is reported.
        static let functions = #"""
            # Prints the path that $1 names inside $root, following its links inside $root, or
            # "!" and the reason it cannot be resolved. The last component need not exist. Its
            # callers run it in a command substitution, so that its variables stay its own.
            resolve() {
                rest=$1
                resolved=
                links=0
                while [ -n "$rest" ]; do
                    case $rest in
                    /*)
                        rest=${rest#/}
                        continue
                        ;;
                    esac
                    component=${rest%%/*}
                    case $rest in
                    */*) rest=${rest#*/} ;;
                    *) rest= ;;
                    esac
                    case $component in
                    . | '') continue ;;
                    ..)
                        resolved=${resolved%/*}
                        continue
                        ;;
                    esac
                    if [ -L "$root$resolved/$component" ]; then
                        links=$((links + 1))
                        if [ "$links" -gt 40 ]; then
                            printf '!%s\n' "it has more than 40 links, or a loop"
                            return 0
                        fi
                        if ! target=$(readlink "$root$resolved/$component"); then
                            printf '!%s\n' "the link $resolved/$component cannot be read"
                            return 0
                        fi
                        case $target in
                        /*) resolved= ;;
                        esac
                        rest=$target${rest:+/$rest}
                    else
                        resolved=$resolved/$component
                        if [ -n "$rest" ] && [ -e "$root$resolved" ] && [ ! -d "$root$resolved" ]
                        then
                            printf '!%s\n' "$resolved is not a directory"
                            return 0
                        fi
                    fi
                done
                printf '%s\n' "${resolved:-/}"
            }

            # Ends the script with a line that names a path that cannot be resolved.
            unresolvable() {
                printf 'maw-unresolvable\t%s\t%s\n' "$1" "$2"
                exit 3
            }

            # Sets $place to where $1, an absolute path, is inside $root: its directory resolved
            # inside $root, and its last component as it is, so that the caller replaces
            # whatever is there, a link included, instead of writing through it. Besides $place
            # it sets only $located, which no caller uses.
            locate() {
                located=$(resolve "${1%/*}")
                case $located in
                /*) ;;
                *) unresolvable "$1" "${located#!}" ;;
                esac
                place=$root${located%/}/${1##*/}
            }

            # locate, and creates the directory if it is missing. Every directory it creates is
            # below the resolved part of the path, so none is a link.
            prepare() {
                locate "$1"
                mkdir -p "${place%/*}"
            }

            # Writes standard input to $1 inside $root, replacing whatever is there.
            write() {
                prepare "$1"
                rm -f "$place"
                cat > "$place"
            }
            """#

        static let text = #"""
            set -eu
            root=$1
            mode=$2
            hostname=$3
            user=$4
            locale=$5
            linger=$6
            tab=$(printf '\t')

            \#(functions)

            # The host name names the distribution.
            write /etc/hostname << HOSTNAME
            $hostname
            HOSTNAME
            write /etc/hosts << HOSTS
            127.0.0.1${tab}localhost
            127.0.1.1${tab}$hostname

            ::1${tab}localhost ip6-localhost ip6-loopback
            ff02::1${tab}ip6-allnodes
            ff02::2${tab}ip6-allrouters
            HOSTS

            # The root file system. The initramfs checks and mounts it before systemd starts.
            write /etc/fstab << FSTAB
            LABEL=maw-root${tab}/${tab}ext4${tab}defaults${tab}0${tab}0
            FSTAB

            if [ "$mode" = install ]; then
                # The user, with the groups of a first Ubuntu user that this image has.
                groups=
                for group in \#(userGroups.joined(separator: " ")); do
                    if grep -q "^$group:" "$root/etc/group"; then
                        groups=${groups:+$groups,}$group
                    fi
                done
                chroot "$root" /usr/sbin/useradd --create-home --shell /bin/bash \
                    --groups "$groups" "$user"
                # Ubuntu's bash prints a hint about sudo at every login until this file exists;
                # sudo creates it after the first successful use. The first prompt stays quiet.
                home=$(chroot "$root" /usr/bin/getent passwd "$user" | cut -d: -f6)
                : > "$root$home/.sudo_as_admin_successful"
                chroot "$root" /usr/bin/chown "$user:" "$home/.sudo_as_admin_successful"

                # The Mac's locale, if the distribution supports it; C.UTF-8 otherwise.
                if [ -n "$locale" ] && [ -f "$root/usr/share/i18n/SUPPORTED" ] \
                    && grep -qx "$locale UTF-8" "$root/usr/share/i18n/SUPPORTED"; then
                    chroot "$root" /usr/sbin/locale-gen "$locale" > /dev/null
                    printf 'LANG=%s\n' "$locale" | write /etc/default/locale
                else
                    printf 'LANG=C.UTF-8\n' | write /etc/default/locale
                fi
            fi

            # The default user lingers, so that its user manager keeps running between sessions
            # and a login shell does not wait for it to start.
            if [ "$linger" = yes ]; then
                write "/var/lib/systemd/linger/$user" < /dev/null
            fi

            # The network: DHCP on the virtual network device through systemd-networkd, and
            # DNS through systemd-resolved.
            write /etc/netplan/50-maw.yaml << 'NETPLAN'
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
            chmod 600 "$place"
            prepare /etc/resolv.conf
            rm -f "$place"
            ln -s ../run/systemd/resolve/stub-resolv.conf "$place"

            # The journal: at most 256 MB, instead of journald's default of 10% of the 256 GiB
            # disk (at most 4 GB), which would stay allocated on the Mac.
            write /etc/systemd/journald.conf.d/50-maw.conf << 'JOURNAL'
            # Written by maw. docs/distributions.md
            [Journal]
            SystemMaxUse=256M
            JOURNAL

            # Services that serve no purpose in maw.
            for unit in \#(maskedUnits.joined(separator: " ")); do
                prepare "/etc/systemd/system/$unit"
                rm -f "$place"
                ln -s /dev/null "$place"
            done

            # The WSL image prints the message of the day from a profile script once a day.
            # Diverting it keeps the first prompt quiet, and survives package updates. An
            # imported root file system may have it diverted already.
            motd=$(resolve /etc/profile.d/update-motd.sh)
            divert=$(resolve /usr/bin/dpkg-divert)
            if [ -f "$root$motd" ] && [ -x "$root$divert" ] \
                && [ "$(chroot "$root" /usr/bin/dpkg-divert --truename \
                    /etc/profile.d/update-motd.sh)" = /etc/profile.d/update-motd.sh ]; then
                chroot "$root" /usr/bin/dpkg-divert --quiet --local --rename \
                    --add /etc/profile.d/update-motd.sh
            fi

            if [ "$mode" = import ]; then
                # A new identity: systemd generates a machine ID at the first boot, so that two
                # distributions imported from one archive do not send the same DHCP client ID.
                write /etc/machine-id < /dev/null
                chmod 444 "$place"
                locate /var/lib/dbus/machine-id
                rm -f "$place"

                # The mount points that the initramfs moves its file systems to.
                for directory in dev proc sys run; do
                    if [ ! -e "$root/$directory" ] && [ ! -L "$root/$directory" ]; then
                        mkdir "$root/$directory"
                    fi
                done

                # Without netplan, nothing configures systemd-networkd: it gets a configuration
                # of its own, and it and systemd-resolved start with the system.
                generator=$(resolve /usr/lib/systemd/system-generators/netplan)
                other_generator=$(resolve /lib/systemd/system-generators/netplan)
                if [ ! -e "$root$generator" ] && [ ! -e "$root$other_generator" ]; then
                    write /etc/systemd/network/50-maw.network << 'NETWORK'
            # Written by maw: DHCP on the virtual network device. docs/distributions.md
            [Match]
            Driver=virtio_net

            [Network]
            DHCP=ipv4
            NETWORK
                    for unit in systemd-networkd.service systemd-resolved.service; do
                        for directory in /usr/lib/systemd/system /lib/systemd/system; do
                            found=$(resolve "$directory/$unit")
                            if [ -f "$root$found" ]; then
                                prepare "/etc/systemd/system/multi-user.target.wants/$unit"
                                rm -f "$place"
                                ln -s "$directory/$unit" "$place"
                                break
                            fi
                        done
                    done
                fi
            fi
            """#

        /// Writes its standard input to `/etc/maw.conf` inside the root, replacing whatever is
        /// there: `sh -c <writer> sh <root>`. The text comes from `MawConf`, so that what is
        /// written is what `MawConf` reads back.
        static let mawConfWriter = #"""
            set -eu
            root=$1

            \#(functions)

            write /etc/maw.conf
            chmod 644 "$place"
            """#

        /// The arguments after `sh -s --`. Every value is validated, so that none can be read
        /// as an option or contain a line break.
        static func arguments(for configuration: GuestConfiguration, linger: Bool) throws(MawError)
            -> [String]
        {
            var locale = ""
            if let candidate = configuration.locale, isLocaleName(candidate) {
                locale = candidate
            }
            return try arguments(
                mode: .install, hostname: configuration.hostname, user: configuration.user,
                locale: locale, linger: linger)
        }

        /// The arguments of the `import` mode for the default user that the import chose. It
        /// lingers unless it is `root`.
        static func importArguments(hostname: String, defaultUser: DefaultUserChoice)
            throws(MawError) -> [String]
        {
            try arguments(
                mode: .import, hostname: hostname, user: try UserName(defaultUser.user),
                locale: "", linger: defaultUser.lingers)
        }

        private static func arguments(
            mode: Mode, hostname: String, user: UserName, locale: String, linger: Bool
        ) throws(MawError) -> [String] {
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
            return [root, mode.rawValue, hostname, user.rawValue, locale, linger ? "yes" : "no"]
        }

        /// The path and the reason of the line that a script prints when a path cannot be
        /// resolved, or `nil` if `output` has no such line.
        static func unresolvablePath(in output: String) -> (path: String, reason: String)? {
            for line in output.split(separator: "\n") {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                if fields.count == 3, fields[0] == unresolvableMarker {
                    return (String(fields[1]), String(fields[2]))
                }
            }
            return nil
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
