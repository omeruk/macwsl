# Terminal app design

These are the approved design references for the maw terminal app. Each `.dc.html` file is
the source of one artboard from the design canvas. Read them for exact colors, sizes, and
copy. They reference a canvas runtime (`support.js`) that is not in this repository, so they
do not render when opened directly. The values below are the ones an implementation must
match.

| File | Screen |
|------|--------|
| `Main.dc.html` | The main window: title-bar tabs, split panes, key-hint bar, status |
| `CommandPalette.dc.html` | The command palette (⌘⇧P) |
| `Distributions.dc.html` | The distributions screen (⌘⇧L), shown with sample data |

The sample distributions, paths, and numbers in the boards illustrate layout and color only.
The running app shows real data or an empty state, never sample data.

## Principles

The window uses the visual language of a terminal user interface. It has no sidebar, no
rounded controls, and no icons. Every element is monospaced text, a box drawn with a 1 px
line, or a block of reverse video.

- **One typeface.** IBM Plex Mono is used for the chrome and the terminal alike.
- **Black and grey chrome.** The window chrome uses only the background, the foreground, the
  greys listed below, and one accent (gold) for keys.
- **Color belongs to content.** The other palette colors appear only in terminal output and
  in data, such as the state and numbers in the distributions table.
- **Pink means a problem.** In the maw Default theme the red slot is pink (`#E8557C`). It
  marks errors, failures, and modified files, and nothing decorative.
- **Selection is reverse video.** The selected tab, palette row, and table row use the
  foreground as the background, with black text.

## Tokens

### Chrome

| Token | Value | Use |
|-------|-------|-----|
| `background` | `#000000` | Window, panes, palette, boxes |
| `titlebar.background` | `#0A0A0A` | Title bar strip |
| `line` | `#262626` | Title bar border, inactive pane border, separators inside the palette |
| `line.strong` | `#4A4A4A` | Active pane border, palette border, distributions table box |
| `text` | `#CFD5E3` | Primary text, active pane title, cursor, selection background |
| `text.selected` | `#000000` | Text on a selected (reverse video) row or tab |
| `text.selectedSecondary` | `#4A4A4A` | Secondary text on a selected row or tab (tab number, palette group, shortcut) |
| `text.secondary` | `#8C8C8C` | Inactive pane title, column headers, counts, the "maw" label, `+` |
| `text.tab` | `#A6A6A6` | Unselected tab label |
| `text.tabNumber` | `#777777` | Unselected tab number, input placeholder |
| `text.muted` | `#8B91A1` | Key-hint descriptions, palette groups and shortcuts, stopped state |
| `accent` | `#F7CE46` | Keys in key hints, the palette `>` prompt, matched letters in the palette, default marker `*` |
| `status.ok` | `#CAE797` | Status dot, running state |
| `overlay` | `rgba(0,0,0,0.6)` | Dimming behind the command palette |

### Typography

- **IBM Plex Mono**, 13 pt, with a 20 pt line height, for every element. Bundle the font
  with the app under its SIL Open Font License 1.1, taken from the official IBM Plex
  release, and verify each file's SHA-256 at build time.
  - Weights in the chrome: Regular (400). Matched letters in the palette use SemiBold (600).
  - Terminal faces: Regular, Italic, Bold, and Bold Italic.
  - Fall back to SF Mono, then Menlo, if the bundled font cannot be loaded.
- No uppercase section headings, except the column headers of the distributions table,
  which are data labels.

### Metrics

| Element | Value |
|---------|-------|
| Title bar | 38 pt in the board. The implementation follows the height AppKit gives an empty unified compact toolbar, and records any difference. |
| Tab | 24 pt tall, 10 pt horizontal padding, 2 pt gap, square corners. Label `<n> <name>  <directory>`, with two spaces before the directory. |
| New-tab control | A plain `+` after the last tab, in `text.secondary` |
| Right end of title bar | `maw` in `text.secondary` |
| Pane area | 10 pt inset from the window edges and between panes |
| Pane box | 1 pt border; 12 pt top, 14 pt horizontal, 10 pt bottom padding |
| Box title | Text placed on the top border, 10 pt from the left edge, 6 pt padding on each side, over the background color. Right-aligned box titles mirror this. |
| Pane title | `<n> <name> <directory>`, where `<n>` is the pane's position in the tab |
| Key-hint bar | 30 pt tall at the bottom of the window, 14 pt padding, 18 pt between hints |
| Command palette | 620 pt wide, centered, 70 pt from the top of the window, 44 pt input row, 26 pt result rows, hint row at the bottom |
| Distributions table | 26 pt rows, columns 28, 200, 110, 120, 90, 110, 90 pt, and the remainder for KERNEL |

### Key-hint bar and status

- The left side lists the main shortcuts: `⌘T tab`, `⌘D split`, `⌘⇧L distros`,
  `⌘⇧P commands`, `⌘, settings`. Keys use `accent` and descriptions use `text.muted`.
- The right side shows the focused session: a `status.ok` dot, then the session name and
  details separated by ` · `, in `text.secondary`.
- The distributions screen replaces the hints with its own actions and `esc back`.
- A setting hides the key hints. The status stays visible.

### Distributions screen

- It opens as a tab named `distributions`, like a settings page in Windows Terminal.
- The table box title is `distributions (<count>)`. The right side of the border shows the
  host summary: memory, CPU cores, and the macOS version.
- Columns: marker, NAME, STATE, MEMORY, CPU, DISK, UPTIME, KERNEL. The default distribution
  has a `*` marker in `accent`. Running is `status.ok`, stopped is `text.muted`, numbers use
  the theme's magenta slot, and KERNEL uses `text.muted`.
- Below the table, a details box for the selected distribution and a memory box with a bar
  chart of the last 60 seconds in the theme's blue slot.
- **Empty state.** With no distributions, the table shows its header and a single line in
  `text.muted`: `no distributions installed`. The details and memory boxes are not shown.
  The hint bar shows `i install…` in `line.strong` with the note `arrives in a later
  version`, and `esc back`.

### Settings

There is no board for settings. Settings open as a tab named `settings` (⌘,) and follow the
chrome rules above.

- A box titled `settings` on the left lists the pages: appearance, general, keyboard,
  profiles, and distributions. The selected page is reverse video.
- A box on the right, titled with the page name, holds the fields as `label  value` rows,
  with the label in `text.secondary`. Choices cycle with ←→, or open a reverse-video list.
- The appearance page has a `preview` box that renders a short sample session in the
  selected theme.

## Built-in themes

A theme defines the 16 ANSI colors, foreground, background, cursor, cursor text, and
selection background. It may also define the chrome tokens above. When a theme does not
define them, the chrome is derived from the theme: `background` and `text` from the theme's
background and foreground, the greys by mixing the foreground into the background, and
`accent` from the yellow slot. Document the mixing ratios in the code.

The built-in themes are:

- maw Default (the default), defined below.
- Catppuccin Mocha
- Dracula
- One Dark
- Gruvbox Dark
- Solarized Light

Take the values of the other five themes from each project's official published palette and
cite the source in the theme file.

### maw Default

The six chromatic colors were sampled from the owner's reference theme. The bright variants
are derived from them by moving each color 35% of the way to white in HLS space, keeping hue
and saturation. Contrast ratios are against `#000000`.

| Slot | Normal | Contrast | Bright | Contrast |
|------|--------|----------|--------|----------|
| black | `#262626` | 1.4 | `#5D636F` | 3.5 |
| red | `#E8557C` | 6.0 | `#F091AA` | 9.3 |
| green | `#CAE797` | 15.4 | `#DDEFBB` | 17.1 |
| yellow | `#F7CE46` | 13.9 | `#FADF87` | 16.0 |
| blue | `#A783F7` | 7.2 | `#C6AEFA` | 10.8 |
| magenta | `#E99173` | 8.8 | `#F1B8A4` | 12.1 |
| cyan | `#7AD3D5` | 12.1 | `#A9E2E4` | 14.7 |
| white | `#CFD5E3` | 14.3 | `#E0E4ED` | 16.5 |

| Role | Value |
|------|-------|
| background | `#000000` |
| foreground | `#CFD5E3` |
| cursor | `#CFD5E3` |
| cursor text | `#000000` |
| selection background | `#343A46` (foreground contrast 7.8) |

Notes:

- Bright black is the reference theme's comment color, so that dimmed text such as shell
  autosuggestions reads as a comment.
- Magenta holds the reference theme's peach. Programs that print numbers and constants in
  magenta, such as `vim` with its default syntax colors, show them in peach, as in the board.
- The prompt colors in `Main.dc.html` illustrate one possible shell configuration. The app
  does not change the user's prompt.
