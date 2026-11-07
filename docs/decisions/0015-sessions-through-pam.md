# 0015: Login shells start through `runuser -l`; commands switch user in the agent

- Status: Accepted
- Date: 2026-10-22

## Context

From phase 05, sessions run as the distribution's user, not as root. A session should look
like an ssh session: the user's groups, a login environment, and, for an interactive shell, a
session that `systemd-logind` knows, so that `XDG_RUNTIME_DIR` and `systemctl --user` work.
Commands (`maw -e`, `maw <command>`) must stay within the warm latency target of 50 ms.

Registering a session with `systemd-logind` takes its `CreateSession` D-Bus call, which only
root may make and which `pam_systemd` makes during a PAM session. The agent is a static musl
binary and cannot load PAM modules.

The options considered for shells:

1. **The agent calls `CreateSession` over D-Bus itself.** About 500 lines of D-Bus
   marshalling, authentication, and descriptor passing in the agent, and the session would skip
   the distribution's PAM stack (limits, keyring), which ssh applies.
2. **The agent starts the shell through the distribution's `runuser -l`.** Its PAM service,
   `runuser-l`, includes `pam_systemd`, `pam_limits`, and `pam_keyinit`, and `runuser` is part of
   util-linux, which every distribution has.

## Decision

Option 2 for login shells, and the agent's own identity switch for everything else:

- **Commands** (`argv`, and a command line for the user's shell): the agent reads the account
  from `/etc/passwd` and its groups from `/etc/group` before it forks; the child sets the groups,
  the group ID, and the user ID, then changes to the working directory and executes. No PAM
  session is opened.
- **Login shells** under systemd: the agent runs `runuser -l <user> -w LANG,TERM,...` as root,
  which opens the PAM session, switches to the user, changes to the home directory, and starts
  the user's shell as a login shell. Right after boot it first waits up to 2 seconds for the
  system bus's socket; `pam_systemd` then waits for `systemd-logind` itself.
- A login shell in a requested working directory (`--cd`), or on a machine without systemd,
  starts directly from the agent, as `-<shell>`, without a logind session, because
  `runuser -l` always changes to the home directory.
- New users **linger** (`/var/lib/systemd/linger/<user>`), so that their user manager runs from
  boot and a shell does not wait for it to start.

The environment is a login environment in both cases: `HOME`, `USER`, `LOGNAME`, `SHELL`,
`PATH` from `/etc/login.defs` (`ENV_PATH`, or `ENV_SUPATH` for root, which `runuser -l` and
`su -l` also use), `LANG`, and `XDG_RUNTIME_DIR` when it exists. `LANG` is the Mac's language and
region when the distribution has that locale, and `C.UTF-8` otherwise.

## Measurements

Median of 5, warm machine, M1 Pro, 2026-10-22.

| Measurement | Median | Slowest |
|-------------|--------|---------|
| `maw -e true` (identity switch in the agent) | 29.0 ms | 31.8 ms |
| `maw` to a prompt, through `runuser -l`, with linger | 131.8 ms | 150.4 ms |
| A login shell started directly by the agent (`--cd /home/<user>`) | 86.9 ms | 107.7 ms |
| `maw` to a prompt, 12 s apart, with linger | 129.1 ms | 153.5 ms |
| `maw` to a prompt, 12 s apart, without linger | 160.4 ms | 272.2 ms |

`runuser -l` and its PAM stack add about 45 ms to a prompt. Without linger, the user manager
stops 10 seconds after the last session and the next shell waits for it to start again, which
misses the 150 ms target; linger keeps it running, at the cost of the user manager's memory,
about 10 MB.

## Consequences

- `maw` shells are logind sessions (`loginctl list-sessions` lists them), with
  `XDG_RUNTIME_DIR=/run/user/<uid>` and a working `systemctl --user`.
- Commands are not logind sessions. They get `XDG_RUNTIME_DIR` when the user's runtime
  directory exists, which linger provides.
- A user who removes linger (`loginctl disable-linger`) gets slower shells, as measured above.

## Consequence for phase 07

Phase 07 will send the Mac's working directory with every `maw` call. Under this decision, a
login shell with a working directory (`--cd`) skips `runuser -l`, because `runuser -l` always
changes to the home directory, and so starts without a logind session. Once every call carries
a working directory, no shell would be registered with `systemd-logind`, and `loginctl` would
list no session for it. `XDG_RUNTIME_DIR` and `systemctl --user` would then rest on linger
alone, which keeps the runtime directory and the user manager without a session: a user who
disables linger would have neither in any shell. Whether everything that expects a logind
session works with linger alone has not been tested. `DistributionIntegrationTests`'s
`registersShellsWithLogind` checks the logind session today, for a shell without `--cd`.

Phase 07 therefore has to change how a shell with a working directory starts. The options seen
so far, of which none is chosen here:

1. **Open the PAM session without `runuser -l`'s change of directory.** `runuser` without
   `-l` keeps the directory, but its PAM service differs: on Ubuntu 24.04, `runuser-l`
   includes `pam_systemd` and `runuser` does not (both files in the image that maw installs),
   so `runuser` alone opens no logind session. A PAM service of maw's own would need a file in
   the distribution's `/etc/pam.d`, against this record's requirement that maw never changes
   an installed distribution to start sessions.
2. **Change the directory after the session is open.** `runuser -l` with `-s` naming a helper
   in place of the user's shell, for example the agent in a mode of its own: `runuser` opens
   the PAM session and changes to the home directory, and the helper changes to the requested
   directory and executes the user's shell as a login shell. The shell's startup files then
   run in the requested directory, and a directory that the user cannot enter has to be
   reported by the helper.
3. **Register the session with logind from the agent**, option 1 of the context above. It no
   longer depends on `runuser`, but it brings the D-Bus code and skips the distribution's PAM
   stack, as described there.

Each option changes the time to a prompt, which phase 07 must measure against the 150 ms
target.
