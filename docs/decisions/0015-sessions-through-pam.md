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
