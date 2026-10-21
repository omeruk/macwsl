# Phase 11a: Terminal app foundation

Read `CLAUDE.md`, `docs/decisions/`, and `docs/design/terminal/` first. Work on branch
`phase/11a-terminal-app` from the latest `main`.

Keep changes outside `App/` to the minimum stated below.

## Goal

Build the native terminal app, named **maw**, as designed in `docs/design/terminal/`. At the
end of this phase:
- The app opens on the owner's Mac.
- It runs the local login shell in tabs and split panes.
- It has the command palette, the distributions screen (empty state), themes, and
  persistent settings.
- It matches the design.

The app connects to Linux distributions in a later phase. This phase builds the session
abstraction that makes that a drop-in addition.

## Architecture

- **`App/MawTerminalKit/`** is a separate Swift package, not a target of the root
  `Package.swift`.
  - It contains all app logic and views: SwiftUI views, the window model, the session
    abstraction, themes, settings, and the command registry.
  - It depends on `SwiftTerm`, which is already approved in `CLAUDE.md`. Pin exact version
    `1.20.0`. The 1.99.x line is a preview of 2.0.
  - SwiftTerm compiles a Metal shader, so building the package requires Xcode's Metal
    Toolchain. Keeping the package out of the root package means the root build and the
    guest agent build do not need it.
  - Record this choice in `docs/decisions/0008-app-package.md`. A later `LinuxSession` will
    depend on the root package's modules through `.package(path: "../..")`.
- **`App/`** holds a thin app target: the `@main` `App` struct, `Info.plist`, entitlements,
  the asset catalog, and the bundled font.
  - The Xcode project is generated with XcodeGen from `App/project.yml`. Commit
    `project.yml`, and git-ignore the generated `.xcodeproj`.
  - Record the XcodeGen choice in `docs/decisions/0007-xcodegen.md`. XcodeGen is a build
    tool, not a runtime dependency. The record explains why: a hand-maintained
    `project.pbxproj` cannot be reviewed or edited reliably.
  - Product name `maw`, bundle identifier `dev.maw.app`, deployment target macOS 14.
- **`TerminalSession` protocol:** a session provides the following, plus a stable
  identifier and a display name:
  - an output byte stream;
  - input;
  - resize;
  - termination with exit status;
  - title and working-directory updates (OSC 0/2 and OSC 7).

  This phase implements one session type, `LocalShellSession`, which runs the user's login
  shell in a PTY. A `LinuxSession` arrives after phase 04b. Nothing outside the session layer
  may depend on which kind of session it is.
- **Working directory:** prefer OSC 7 when the shell reports it. Otherwise read the
  foreground process's working directory with `proc_pidinfo` (`PROC_PIDVNODEPATHINFO`).
  Poll only while the session is visible, at most once per second, and after output goes
  idle. Unit-test the selection logic.
- **`DistributionProvider` protocol:** the distributions screen reads distributions from
  this protocol. The only implementation in this phase returns no distributions, so the
  screen shows the empty state described in the design README. Never show invented
  distributions in the running app. Sample data is allowed in SwiftUI previews and tests
  only.
- **Command registry:** one registry defines every command, with its identifier, title,
  group, default shortcut, and enabled state. The menu bar, the keyboard shortcuts, the
  key-hint bar, the command palette, and the keyboard settings page all read it, so they
  cannot drift apart.

## Features

1. **Window and title bar**
   - The window draws its own title-bar content, as in `Main.dc.html`.
     - Do not move the traffic lights by hand. Attach an empty `NSToolbar` with the unified
       compact style, so that AppKit sizes the title bar and centers the traffic lights.
       Draw the tab strip in that area.
     - The design's title bar is 38 pt. If AppKit's height differs, follow AppKit and record
       the difference in the PR. If the toolbar approach fails, keep the standard position
       and explain why.
   - The tab strip shows text tabs (`<n> <name>  <directory>`). The selected tab is reverse
     video. A plain `+` follows the last tab, and `maw` sits at the right end.
   - There is no sidebar.
2. **Tabs**
   - ⌘T opens a new tab with the default profile. ⌘W closes the focused pane, and the tab
     with its last pane. A middle-click on a tab and the tab's context menu also close it.
   - ⌘1 to ⌘9 select tabs. ⌘⇧[ and ⌘⇧] move to the previous and next tab.
   - Tabs can be reordered by dragging.
   - Other profiles open from the command palette (`new tab: <profile>`).
   - Multiple windows (⌘N) are supported. Each window has its own tabs.
3. **Split panes**
   - ⌘D splits right and ⌘⇧D splits down. ⌥⌘ with the arrow keys moves focus between panes.
   - Each pane is a box with its title on the top border (`<n> <name> <directory>`). The
     active pane uses `line.strong` and `text`. Inactive panes use `line` and
     `text.secondary`.
   - Dividers can be dragged, and a double-click on a divider equalizes the panes.
   - Model the layout as a binary split tree, with unit tests.
4. **Key-hint bar and status**
   - As in `Main.dc.html`. The hints are built from the command registry.
   - The status shows the focused session's name, its working directory when known, and its
     grid size (`cols×rows`).
   - The status slot for port forwarding stays empty until phase 08.
5. **Command palette** (⌘⇧P)
   - As in `CommandPalette.dc.html`: fuzzy search over the registry, ↑↓ and ↩ to run, and
     esc to close. The box title shows `commands`, and the right side of the border shows
     the match count.
   - Matched letters are underlined, SemiBold, and in the accent color, or black on the
     selected row.
   - Ranks prefix and word-start matches above substring matches. Unit-test the matcher.
6. **Distributions screen** (⌘⇧L)
   - Opens as a tab named `distributions`, as in `Distributions.dc.html`.
   - In this phase it shows the empty state from the design README, and the host summary
     from real system values.
   - Build the table, details box, and memory chart as views that take their data from
     `DistributionProvider`, and cover them with SwiftUI previews using sample data. They
     are not shown in the running app until a provider returns distributions.
7. **Settings** (⌘,)
   - Settings open as a tab named `settings`, laid out as described in the design README.
     There is no board for it. Present a text sketch of the layout before building it.
   - Build three pages fully:
     - **Appearance:** theme, with a live preview box, font family and size, cursor style
       (block, bar, underline), and background opacity (window translucency).
     - **General:** default profile, the shell for the local profile, showing the key hints,
       and confirmation when closing a tab with a running process.
     - **Keyboard:** a read-only list of every shortcut, taken from the command registry.
   - "Profiles" and "Distributions" show a short note naming the version in which they
     arrive.
8. **Themes**
   - The six built-in themes listed in the design README, each with the full 16-color ANSI
     palette, foreground, background, cursor, cursor text, and selection.
   - maw Default is the default theme, with the exact values in the design README.
   - The window chrome follows the theme, using the theme's chrome tokens when it defines
     them and the derivation in the design README otherwise. Changing the theme updates the
     chrome and every open terminal immediately.
   - Themes are `Codable`, so that the settings file can define custom ones.
9. **Font**
   - Bundle IBM Plex Mono as described in the design README, and use it for the chrome and
     the terminal.
10. **Settings persistence**
    - Settings are stored as JSON at `~/Library/Application Support/maw/settings.json`.
    - When the file is edited on disk, the app reloads it within one second, as Windows
      Terminal does. An invalid file shows a non-blocking banner with the decoding error and
      keeps the last valid settings.
    - Version the settings file format and add a migration hook.
11. **Behavior and quality**
    - Selection, copy (⌘C), and paste (⌘V), with a warning before pasting multiple lines
      into a running process.
    - ⌘+, ⌘-, and ⌘0 control the font size.
    - Running `yes | head -n 2000000` and `cat` on a 50 MB file must not freeze the UI.
    - VoiceOver labels on every control that is not plain text, and full keyboard
      navigation of the tabs, palette, distributions screen, and settings.
    - Quitting with running processes asks for confirmation, unless the user has turned that
      off.

## Tests

- **Unit tests** (`App/MawTerminalKit/Tests/MawTerminalKitTests/`, run in CI):
  - The split tree: split, close, focus movement, and equalize.
  - Tab model operations.
  - The command registry and the fuzzy matcher's ranking.
  - Theme decoding, the completeness of every built-in theme, the exact maw Default values,
    and the chrome derivation.
  - The settings round trip, migration, and the invalid-file behavior.
  - Parsing of OSC 7 working-directory URLs, and the working-directory selection logic.
- **CI builds the app** in a job in `.github/workflows/ci.yml`:
  - Install the Metal Toolchain in this job only, and print its version in the job log.
  - Build, test, and lint `App/MawTerminalKit`.
  - Install XcodeGen with Homebrew, then run `xcodegen` and `xcodebuild build` for the
    `maw` scheme with code signing disabled.

## Allowed changes outside `App/`

- **`.github/workflows/ci.yml`:** the app build job.
- **`.gitignore`:** the generated Xcode project and derived data.
- **`docs/decisions/`:** records 0007 and 0008.
- **`docs/ROADMAP.md`:** the phase 11a status.
- **`README.md`:** a short "Running the terminal app" section:
  1. `xcodebuild -downloadComponent MetalToolchain`
  2. `brew install xcodegen`
  3. `cd App && xcodegen`
  4. open `maw.xcodeproj` and run.

The root `Package.swift` and `Package.resolved` stay unchanged. Do not rename anything else
from MacWSL to maw in this phase. A separate pull request does the rename.

## Out of scope

- Connecting to Linux distributions, and distribution management actions.
- Port forwarding.
- Quake-style drop-down mode.
- Auto-update.
- Code signing beyond local development.
- Profiles beyond the local shell.

## Acceptance criteria

- In `App/MawTerminalKit`, `swift build -Xswiftc -warnings-as-errors`, `swift test`, and
  `swift format lint --strict` pass. The root package checks still pass, and CI is green,
  including the new app build job.
- On the owner's Mac, `cd App && xcodegen` followed by building and running the `maw`
  scheme in Xcode opens the app. The owner confirms each of the following:
  - The window matches `Main.dc.html`: black background, text tabs with reverse-video
    selection, boxed panes with titles on the border, and the key-hint bar.
  - The command palette matches `CommandPalette.dc.html`.
  - The distributions screen shows the empty state and real host values.
  - Tabs, split panes, the palette, and settings all work.
  - Changing the theme updates the chrome and open terminals immediately.
  - `vim`, `htop` (if installed), and `less` render correctly, and resizing the window
    reflows them.
  - Editing `settings.json` by hand changes the app within one second.
- The PR includes screenshots of the main window with a split, the command palette, the
  distributions screen, and the appearance settings page. Ask the owner to take them if you
  cannot.

## How to work

1. Present a short plan first. It must cover:
   - How the SwiftUI views host SwiftTerm's `NSView`.
   - How the tab strip is placed in the title bar.
   - The shape of `TerminalSession`.
   - How the command registry feeds menus, shortcuts, and the key-hint bar.

   Wait for approval.
2. Ask the owner to run the app and check the visual acceptance items. You cannot see the
   screen.
3. Finish with the PR, as described in the Workflow section of `CLAUDE.md`.
