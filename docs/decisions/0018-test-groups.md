# 0018: Tests run in groups, so that load never meets a latency limit

- Status: Accepted
- Date: 2026-11-07

## Context

`swift test` starts every suite at once. A few tests generate heavy load by design: one starts
6,000 programs on four threads, and the fuzz test opens about a thousand connections, each on
a thread of its own. Other tests assert latency: a signal must reach a process within 100 ms, a
resize within 1 second, and a nonce must be used within 300 ms of its registration. On a
three-core CI runner, the load generators delayed the latency tests by up to 10 seconds: in
run 42295680340, the Launchctl test took 30 seconds, nearly every other test finished about 13
seconds after the run started, and the signal test measured 10.14 seconds against its 100 ms
limit. Raising the limits would hide real regressions.

The options considered:

1. **Tags.** swift-testing tags (`.tags(.latency)`) would mark the tests, but the pinned
   toolchain's `swift test` cannot select or skip tests by tag: `--filter tag:latency` runs no
   test, and `--skip tag:latency` skips none.
2. **Separate test targets.** The latency and load tests use the helpers and the `@testable`
   imports of their own targets, which would have to be duplicated or moved into a shared
   module.
3. **Name filters.** `--filter` and `--skip` take a regular expression that is matched against
   each test's ID, which includes the names of the suites that contain the test.

## Decision

Option 3. A test that asserts latency sits in a nested suite named `Latency`, and a test that
generates heavy load in a nested suite named `Load`, such as `ExecSessionTests.Latency` and
`LaunchctlTests.Load`. `scripts/test-groups.sh` runs three groups one after the other:

- **general**: every other test, in parallel (`--skip "/(Latency|Load)/"`).
- **latency**: the tests in `Latency` suites, one at a time (`--filter /Latency/ --no-parallel`).
- **load**: the tests in `Load` suites, one at a time (`--filter /Load/ --no-parallel`). The
  6,000-program test itself asserts that each program returns within 2 seconds, so the load
  generators do not run beside each other either.

The CI workflow runs each group as a step of its own, and `scripts/integration-test.sh` runs
all three with `--no-parallel`, since its suites boot virtual machines.

A name filter that matches nothing makes `swift test` print a warning and succeed, and a test
that matched both groups would run twice. So each group writes xUnit results, and
`scripts/test-groups.sh check` compares them with `swift test list`. It fails unless every
listed test ran, or was skipped, in exactly one group, and each group ran at least one test. A
test added to a group later therefore cannot drop out of every run unnoticed.

A test belongs in `Latency` when its outcome depends on a wall-clock limit: an upper bound on a
measured duration, a wait or receive window whose expiry fails the test, or a pause after which
the test expects something to have happened. A test that only checks that at least some time
passed does not belong there, and neither does a deadline of 5 seconds or more that only keeps
a hung test from running for ever. A test belongs in `Load` when it keeps several cores busy or
starts many processes or threads on purpose.

## Consequences

- Plain `swift test` still runs everything in parallel, as before. On a developer's Mac that
  is normally fast enough; the groups are what CI and the integration script rely on.
- A new test that asserts latency or generates load must be placed in the matching nested
  suite. A test placed elsewhere still runs, in the general group; the check cannot tell
  whether a test asserts latency.
- The integration tests are not grouped. Under `scripts/integration-test.sh`, every group runs
  one test at a time, so none of them runs beside another test, and on CI they are skipped.
- When the pinned toolchain can select tests by tag, the suites can give way to tags, and the
  check can stay.
