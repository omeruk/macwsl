# Phase 11a: Terminal app foundation

Read `CLAUDE.md`, `docs/decisions/`, and `docs/design/terminal/` first. Work on branch
`phase/11a-terminal-app` from the latest `main`.

This phase runs in parallel with the virtualization phases (03 to 06) in a separate git
worktree. Keep changes outside `App/`, `Sources/MawTerminalKit/`, and
`Tests/MawTerminalKitTests/` to the minimum stated below, so that the two lines of work
merge without conflicts.

## Goal

Build the native terminal app, named **maw**, as designed in `docs/design/terminal/`. At the
end of this phase:
- The app opens on the owner's Mac.
- It runs the local login shell in tabs and split panes.
- It has the command palette, the theme gallery, and persistent settings.
- It matches the design.

The app connects to Linux distributions in a later phase. This phase builds the session
abstraction that makes that a drop-in addition.

## Architecture

- **`Sources/MawTerminalKit/`** is a new macOS-only library target.
  - It contains all app logic and views: SwiftUI views, the window model, the session
    abstraction, themes, settings, and the command registry.
  - It depends on `SwiftTerm`, which is already approved in `CLAUDE.md`. Pin an exact
    version.
  - Wrap its sources in `#if os(macOS)`, like the other macOS-only modules.
- **`App/`** holds a thin app target: the `@main` `App` struct, `Info.plist`, entitlements,
  the asset catalog, and the bundled font.
  - The Xcode project is generated with XcodeGen from `App/project.yml`. Commit
    `project.yml`, and git-ignore the generated `.xcodeproj`.
  - Record the XcodeGen choice in `docs/decisions/0005-xcodegen.md`. XcodeGen is a build
    tool, not a runtime dependency. The ADR explains why: a hand-maintained `project.pbxproj`
    cannot be reviewed or edited reliably.
  - Product name `maw`, bundle identifier `dev.maw.app`, deployment target macOS 14.
- **`TerminalSession` protocol:** a session provides the following, plus a stable
  identifier and a display name:
  - an output byte stream;
  - input;
  - resize;
  - termination with exit status;
  - title and working-directory updates (OSC 0/2 and OSC 7).

  This phase implements one session type, `LocalShellSession`, which runs the user's login
  shell in a PTY through SwiftTerm's local process support. A `LinuxSession` arrives after
  phase 04. Nothing outside the session layer may depend on which kind of session it is.
- **`DistributionProvider` protocol:** the sidebar reads distributions from this protocol.
  The only implementation in this phase returns no distributions.
  - The sidebar then shows the "This Mac" section and an empty state: "No Linux
    distributions installed yet."
  - The empty state has a disabled "Install a distribution…" control, with help text saying
    that installation arrives in a later version.
  - Never show invented distributions in the running app. Sample data is allowed in SwiftUI
    previews and tests only.
- **Command registry:** one registry defines every command, with its identifier, title,
  group, default shortcut, and enabled state. The menu bar, the keyboard shortcuts, the
  new-tab menu, and the command palette all read it, so they cannot drift apart.

## Features

1. **Window and tabs**
   - The title bar is hidden, with the tab strip drawn in the title-bar area, as in
     `Main.dc.html`.
     - Traffic lights stay in their standard position.
     - The left side has the sidebar toggle.
     - The right side has the "Commands ⌘⇧P" button.
   - Tab behavior:
     - Each tab shows the colored session dot, the session name, and the working directory
       when known.
     - ⌘T opens a new tab, ⌘W closes the focused pane (and its tab with its last pane), and
       ⌘1 to ⌘9 select tabs.
     - ⌘⇧[ and ⌘⇧] move to the previous and next tab.
     - Tabs can be reordered by dragging.
   - The `+` button opens a new tab with the default profile. The chevron opens the menu in
     `NewTab.dc.html`, built from the command registry.
   - Multiple windows (⌘N) are supported. Each window has its own tabs.
2. **Split panes**
   - ⌘D splits right and ⌘⇧D splits down. ⌥⌘ with the arrow keys moves focus between panes.
   - Dividers can be dragged, and a double-click on a divider equalizes the panes.
   - Model the layout as a binary split tree, with unit tests.
   - The active pane carries the accent ring described in the design README.
3. **Sidebar**
   - ⌘⇧S toggles the sidebar, which is 236 pt wide.
   - It contains the distributions section (empty state in this phase), the "This Mac"
     section with the local shell, a memory bar slot that is hidden when there is no data,
     and the Settings button.
4. **Status bar**
   - Shows the session name, the working directory from OSC 7 when the shell reports it,
     and the grid size (`cols×rows`, one value per pane).
   - The right-hand slot for port-forwarding chips stays empty until phase 08.
5. **Command palette** (⌘⇧P)
   - As in `CommandPalette.dc.html`: fuzzy search over the registry, grouped results,
     ↑↓ and ↩ to run, and esc to close.
   - Ranks prefix and word-start matches above substring matches. Unit-test the matcher.
6. **Settings window** (⌘,)
   - Navigation as in `Themes.dc.html`. Build three pages fully:
     - **Appearance:** the theme gallery with a live preview, font family and size, cursor
       style (block, bar, underline), background opacity (window translucency through
       `NSVisualEffectView`), and the accent color.
     - **General:** default profile, the shell for the local profile, and confirmation when
       closing a tab with a running process.
     - **Keyboard:** a read-only list of every shortcut, taken from the command registry.
   - "Profiles" and "Distributions" show a short placeholder that names the version in which
     they arrive.
7. **Themes**
   - The six built-in themes listed in the design README, each with the full 16-color ANSI
     palette, foreground, background, cursor, and selection.
   - Themes are `Codable`, so that the settings file can define custom ones.
8. **Settings persistence**
   - Settings are stored as JSON at `~/Library/Application Support/maw/settings.json`.
   - When the file is edited on disk, the app reloads it within one second, as Windows
     Terminal does. An invalid file shows a non-blocking banner with the decoding error and
     keeps the last valid settings.
   - Version the settings file format and add a migration hook.
9. **Behavior and quality**
   - Selection, copy (⌘C), and paste (⌘V), with a warning before pasting multiple lines into
     a running process.
   - ⌘+, ⌘-, and ⌘0 control the font size.
   - Running `yes | head -n 2000000` and `cat` on a 50 MB file must not freeze the UI.
   - VoiceOver labels on every icon-only control, and full keyboard navigation of the
     sidebar, menus, palette, and settings.
   - Quitting with running processes asks for confirmation, unless the user has turned that
     off.

## Tests

- **Unit tests** (`Tests/MawTerminalKitTests/`, run in CI):
  - The split tree: split, close, focus movement, and equalize.
  - Tab model operations.
  - The command registry and the fuzzy matcher's ranking.
  - Theme decoding and the completeness of every built-in theme.
  - The settings round trip, migration, and the invalid-file behavior.
  - Parsing of OSC 7 working-directory URLs.
- **CI builds the app** by installing XcodeGen with Homebrew, then running `xcodegen` and
  `xcodebuild build` for the `maw` scheme with code signing disabled. Add this as a job in
  `.github/workflows/ci.yml`. This is one of the few changes outside the app directories
  allowed by this phase.

## Allowed changes outside the app directories

- **`Package.swift`:** the `MawTerminalKit` target, its test target, and the `SwiftTerm`
  dependency. Nothing else.
- **`.github/workflows/ci.yml`:** the app build job.
- **`.gitignore`:** the generated Xcode project and derived data.
- **`docs/ROADMAP.md`:** the phase 11a status.
- **`README.md`:** a short "Running the terminal app" section:
  1. `brew install xcodegen`
  2. `cd App && xcodegen`
  3. open `maw.xcodeproj` and run.

Do not rename anything else from MacWSL to maw in this phase. A separate pull request does
the rename.

## Out of scope

- Connecting to Linux distributions, and distribution management actions.
- Port forwarding.
- Quake-style drop-down mode.
- Auto-update.
- Code signing beyond local development.
- Profiles beyond the local shell.

## Acceptance criteria

- `swift build -Xswiftc -warnings-as-errors`, `swift test`, and
  `swift format lint --strict` pass, and CI is green, including the new app build job.
- On the owner's Mac, `cd App && xcodegen` followed by building and running the `maw`
  scheme in Xcode opens the app. The owner confirms each of the following:
  - The window matches `Main.dc.html`, apart from the sidebar's empty state.
  - Tabs, split panes, the command palette, and the settings window all work.
  - Changing the theme updates open terminals immediately.
  - `vim`, `htop` (if installed), and `less` render correctly, and resizing the window
    reflows them.
  - Editing `settings.json` by hand changes the app within one second.
- The PR includes screenshots of the main window, the new-tab menu, the command palette,
  and the Appearance settings page. Ask the owner to take them if you cannot.

## How to work

1. Present a short plan first. It must cover:
   - How the SwiftUI views host SwiftTerm's `NSView`.
   - How the tab strip is placed in the title bar.
   - The shape of `TerminalSession`.
   - How the command registry feeds menus and shortcuts.

   Wait for approval.
2. Ask the owner to run the app and check the visual acceptance items. You cannot see the
   screen.
3. Finish with the PR, as described in the Workflow section of `CLAUDE.md`.
