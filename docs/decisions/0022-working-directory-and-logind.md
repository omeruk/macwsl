# 0022: Sessions start in the Mac's working directory; login shells reach it through a shell helper

- Status: Accepted
- Date: 2026-11-22
- Resolves the "Consequence for phase 07" of [decision record 0015](0015-sessions-through-pam.md).

## Context

Phase 07 makes `maw` started in a directory of the Mac start the Linux side in the same
directory, under `/mnt/mac` ([prompt](../../prompts/07-file-sharing-and-paths.md),
[decision record 0021](0021-mac-share.md)). Nearly every session then has a working
directory. Under decision record 0015, a login shell with a working directory skipped
`runuser -l`, because `runuser -l` always changes to the home directory, and so was not
registered with `systemd-logind`. Once every shell has a working directory, no shell would be a
logind session, and `XDG_RUNTIME_DIR` and `systemctl --user` would rest on linger alone.

Decision record 0015 lists three options:

1. **A PAM session without `runuser -l`'s change of directory.** `runuser` without `-l` keeps
   the directory, but its PAM service on Ubuntu 24.04 does not include `pam_systemd`; a PAM
   service of maw's own would be a file in the distribution's `/etc/pam.d`.
2. **The agent as `runuser -l`'s shell helper.** `runuser -l <user> -s <helper>` opens the
   PAM session and changes to the home directory; the helper enters the requested directory
   and executes the user's shell as a login shell.
3. **The agent registers the session with logind over D-Bus**, about 500 lines that skip the
   distribution's PAM stack.

## Decision

### The login shell: option 2

A login shell with a working directory, under systemd, starts as

```
runuser -l <user> -w <variables> -s /run/maw/maw-agent -- login-shell <directory> fall-back|exact <shell>
```

- `runuser` opens the PAM session, which registers the shell with `systemd-logind`, and changes
  to the home directory.
- The helper runs as the user inside that session. It enters the directory and reports the
  result to the agent in 8 bytes on descriptor 3: entered, fell back with an errno value, or
  failed with one. It then closes descriptor 3, sets `SHELL` to the account's shell (runuser
  sets it to the helper), and executes the shell with `-<name>` as `argv[0]`.
- With `exact`, which `--cd` gives, a directory that the user cannot enter makes the helper
  exit, and the agent answers the request with an error instead of `started`. With
  `fall-back`, the helper stays in the home directory.
- The agent's spawn keeps exactly one descriptor open across `execve`, the helper's pipe, as
  descriptor 3. runuser passes it on to the helper. The helper closes it before the shell
  starts, so no descriptor of the agent's reaches the user's programs.
- The agent waits for the report before it sends `started`, at most 5 seconds. If runuser
  ends first, the pipe reaches end-of-file, and the agent fails the request with "runuser -l
  ended before the shell helper entered the working directory". After 5 seconds, it kills
  runuser and fails the request. The host waits 10 seconds for `started`.
- A shell without a working directory (`--cd '~'`, or `maw` started outside the home
  directory) starts through `runuser -l` alone, as before.
- Without systemd, or without `/run/maw/maw-agent`, the agent starts the shell itself in the
  directory, without a logind session, as before.

Option 2 keeps the distribution's PAM stack (limits, keyring) and adds no file to the
distribution. The helper is the agent's binary, which `/init` already copies to `/run/maw`.

### The working directory

`maw` chooses the directory. The agent only expands `~` and applies the fallback.

| What `maw` is given | Where the session starts |
|---------------------|--------------------------|
| No `--cd`, in the home directory or under it | `/mnt/mac` or `/mnt/mac/<the rest>`; may fall back |
| No `--cd`, outside the home directory, such as `/tmp` | The Linux home directory, with a notice |
| No `--cd`, `getcwd` fails | The Linux home directory, with a notice |
| `--cd '~'`, `--cd '~/<path>'` | The Linux home directory, a path under it |
| `--cd <absolute Linux path>` | That path |
| `--cd <Mac path under the home directory>` | Its `/mnt/mac` path |
| `--cd <Mac path outside the home directory>` | An error: not shared |
| `--cd <relative path>` | Resolved against the current directory, then translated |

- `getcwd` and the home directory are compared after both are resolved with `realpath`, so a
  home directory reached through a link still matches. The paths as written are compared
  after that.
- A path is a Mac path when it lies under `/Users`, `/Volumes`, `/Applications`, `/Library`,
  `/System`, or `/private`; any other absolute path is a Linux path.
- The Mac's shell expands an unquoted `~`, so `--cd ~` reaches `maw` as the Mac home directory
  and starts in `/mnt/mac`.
- The notice, on standard error only, is
  `maw: /tmp is not shared with Linux; starting in the home directory.`, or, when `getcwd`
  fails, `maw: the current directory no longer exists; starting in the home directory.`
- **The fallback applies only to the directory that `maw` translated** from its own:
  `exec`'s `fallsBackToHome` (protocol version 7, [docs/protocol.md](../protocol.md)). When
  the session cannot enter it, it starts in the user's home directory, and `started`'s
  `workingDirectoryFallback` says why, as a code: the share is not mounted, the directory does
  not exist, the user may not enter it, a component is not a directory, or another error.
  While the share is not mounted, a directory under `/mnt/mac`, `/mnt/mac` itself included,
  falls back before the spawn, because the empty mount point could be entered.
  `maw` words the line itself and names the console log when the share is not mounted. A
  `--cd` directory never falls back.
- **Commands** (`maw <command>`, `maw -- <command>`, `-e`) follow the same rules. The fallback
  happens in the spawn itself, which enters the home directory and records the errno value on
  its report pipe before `execve`.

### `mawpath`

- `mawpath` is the agent's binary, recognized when the last component of `argv[0]` is
  exactly `mawpath`. The helper's login name, `-maw-agent`, never is.
- When the agent starts in a distribution, as `/run/maw/maw-agent`, it links
  `/usr/local/bin/mawpath` to that path, as WSL links `/usr/bin/wslpath` to `/init`.
  `/usr`, `/usr/local`, and `/usr/local/bin` must be directories, not links. An existing
  `mawpath` that is not this link is left as it is, and the console says so.
- Every session's PATH includes `/usr/local/bin`.
- The Mac home directory reaches the guest on the kernel command line, as `maw.home=<path>`,
  with every byte other than a letter, a digit, and `/ . _ ~ -` percent-encoded. A path longer
  than 1,024 bytes once encoded is left out. An absent or invalid value makes `mawpath` report
  that the home directory is not known.

## Measurements

Development figures, measured through the test daemon on a test distribution, on an M1 Pro
with 16 GB running macOS 27.0.1, with `maw` started in a directory under
`~/Library/Caches/maw`. Each is the median and the slowest of 5 runs.

**Before** (`ba372a1`, 2026-11-22 13:18Z, load average 3.29 at the start and 3.33 at the end):

| Measurement | Runs | Median | Slowest |
|-------------|------|--------|---------|
| Warm start to a prompt | 124, 111, 117, 109, 123 ms | 117 ms | 124 ms |
| `maw -- pwd`, warm | 54, 40, 34, 35, 34 ms | 35 ms | 54 ms |

**What option 2 costs**, measured in the guest at the same time, as root, with
`date +%s%N` around each command:

| Measurement | Median | Slowest |
|-------------|--------|---------|
| `runuser -l <user> -c true` | 10 ms | 15 ms |
| `runuser -l <user> -s /run/maw/maw-agent -- --version` | 5 ms | 5 ms |
| `/run/maw/maw-agent --version`, as root | 1 ms | 1 ms |
| `/run/maw/maw-agent --version`, as the user | 1 ms | 3 ms |

- In the same run, `runuser -l <user> -s /bin/sh` started its shell with
  `XDG_SESSION_ID` and `XDG_RUNTIME_DIR=/run/user/1000` set, in the home directory, as `-sh`.
- runuser passed descriptors 3 and 7 on to its shell. That is how the helper receives its
  pipe.
- The helper adds one execution of the agent's binary to a prompt, about 1 ms.

**After:** recorded in pull request #35 with the official measurements.

## Consequences

- Every `maw` shell under systemd is a logind session again, whatever its directory.
- The helper's report comes before `started`, so the first bytes of a shell's output reach
  the host after the line that says it fell back.
- Distributions get one link on their disk, `/usr/local/bin/mawpath`. An export contains it;
  outside maw it dangles, and an import into maw makes it work again.
- A distribution whose `/usr/local/bin` is missing, or is a link, has no `mawpath` on PATH;
  the console log says why.
- A Mac home directory whose own name has non-ASCII letters reaches `maw.home` decomposed
  (NFD), as `URL` gives it, so `mawpath -m` prints the home directory's name in that form
  ([docs/known-limitations.md](../known-limitations.md)).
