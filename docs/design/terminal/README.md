# Terminal app design

These are the approved design references for the maw terminal app. Each `.dc.html` file is
the source of one artboard from the design canvas. Read them for exact colors, sizes, and
copy. They reference a canvas runtime (`support.js`) that is not in this repository, so they
do not render when opened directly. The values below are the ones an implementation must
match.

| File | Screen |
|------|--------|
| `Main.dc.html` | The main window: title-bar tabs, sidebar, split panes, status bar |
| `NewTab.dc.html` | The menu behind the chevron next to the new-tab button |
| `CommandPalette.dc.html` | The command palette (⌘⇧P) |
| `Themes.dc.html` | Settings, Appearance page with the theme gallery |

## Tokens

### Window chrome

| Token | Value | Use |
|-------|-------|-----|
| `window.background` | `#1B1C21` | Window and settings content background |
| `titlebar.background` | `#202127` | Title bar and status bar |
| `sidebar.background` | `#18191D` | Sidebar and settings navigation |
| `separator` | `rgba(255,255,255,0.07)` | Borders between regions |
| `control.border` | `rgba(255,255,255,0.08)` to `0.12` | Button and field outlines |
| `surface.raised` | `#24252C` / `#25262D` | Menus, palette, fields |
| `text.primary` | `#E6E8EC` | Main text |
| `text.strong` | `#F2F3F5` | Selected tab, selected items |
| `text.secondary` | `#9AA0AA` / `#B8BDC6` | Secondary labels, icons |
| `text.tertiary` | `#8B93A1` | Section headings, shortcut hints |
| `accent` | `#F59E5B` | Cursor, selection in menus and palette, focus ring on the active pane, memory bar |
| `selection.background` | `rgba(255,255,255,0.07)` to `0.09` | Selected tab, selected sidebar row |
| `status.running` | `#4ADE80` | Running distribution dot |

The accent is configurable in settings. The design offers `#F59E5B` (default), `#7AB0F5`,
`#8BD49C`, and `#C792EA`.

### Typography

- **UI text:** the system font (SF Pro). The design files use Inter as a stand-in.
  - Tab labels and sidebar names: 13 pt, medium.
  - Secondary lines: 11 pt.
  - Section headings: 11 pt, semibold, uppercase, tracking 0.06 em.
- **Terminal text:** JetBrains Mono 13 pt, with 20 px line height in the design. Bundle the
  font with the app under its OFL license. Fall back to SF Mono, then Menlo.

### Metrics

| Element | Value |
|---------|-------|
| Title bar height | 46 pt, with traffic lights inset 16 pt |
| Tab | 32 pt tall, 8 pt corner radius, colored 8 pt distribution dot, label, secondary path, close button |
| New-tab control | `+` and chevron in one outlined 28 pt group |
| Sidebar width | 236 pt, rows of 28 pt icon tile plus two text lines, 8 pt radius |
| Status bar height | 26 pt, 11 pt text |
| Terminal padding | 14 pt vertical, 16 pt horizontal |
| Split divider | 1 pt `rgba(255,255,255,0.08)`. The active pane has an inset 1 pt ring in the accent at 20% opacity. |
| Command palette | 600 pt wide, 84 pt from the top of the window, 54 pt search field, 38 pt rows, grouped |
| Menus and palette | 10 to 12 pt radius, shadow `0 18-24 48-64 rgba(0,0,0,0.55-0.6)` |

### Distribution colors

- Ubuntu: `#E95420`
- Debian: `#D70A53`
- Local shell: `#9AA0AA` on a `#3A3D45` tile

## Built-in themes

The six themes in `Themes.dc.html` are listed below. The implementation needs the full
16-color ANSI palette, plus foreground, background, cursor, and selection, for each theme.
Take those values from each theme's official published palette and cite the source in the
theme file.

- maw Night (default): background `#16171C`, foreground `#D7DAE0`, accent `#F59E5B`
- Catppuccin Mocha
- Dracula
- One Dark
- Gruvbox Dark
- Solarized Light

For maw Night, the design defines these ANSI colors:

| Color | Value |
|-------|-------|
| green | `#8BD49C` |
| blue | `#7AB0F5` |
| yellow | `#E6C07B` |
| magenta | `#C792EA` |
| red | `#F07178` |
| cyan | `#89DDFF` |

Derive the remaining colors (black, white, and the bright variants) from the same family and
document them.
