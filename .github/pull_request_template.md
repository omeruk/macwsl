## Summary

<!-- Two to four sentences: what this pull request delivers and why. Reference the phase
prompt (for example `prompts/01-scaffold.md`) where applicable. This section becomes the
body of the squash commit. -->

## Changes

<!-- The substantive changes, grouped by module or area. One bullet per change, each a
complete sentence. -->

## Design decisions

<!-- Decisions taken in this pull request, the alternatives considered, and the reason for
the choice. Link any new record in `docs/decisions/`. Write "Not applicable." if none. -->

## Verification

<!-- Copy each acceptance criterion from the phase prompt and record the observed result.
Include the exact commands run and the toolchain version. -->

| Check | Command | Result |
|-------|---------|--------|
| Build without warnings | `swift build -Xswiftc -warnings-as-errors` | |
| Unit tests | `swift test` | |
| Lint | `swift format lint --strict --recursive Sources Tests` | |

Toolchain: <!-- output of `swift --version` -->

## Known limitations and follow-up work

<!-- Anything not done, not verified, or deferred, and where it will be addressed. Write
"None." if there is nothing to report. -->

## Notes for reviewers

<!-- Areas that deserve particular attention, and any context a reviewer needs. -->
