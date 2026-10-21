import SwiftUI

/// The command palette (⌘⇧P), as in `CommandPalette.dc.html`: a box titled `commands` with the
/// match count on its border, a `>` prompt, and grouped results whose matched letters are
/// underlined. "theme: switch" turns it into a theme list that previews each theme.
struct CommandPaletteView: View {
    let model: WindowModel
    @Environment(\.chrome) private var chrome
    @FocusState private var queryFocused: Bool

    /// One result row.
    struct Row: Identifiable {
        var id: String
        var group: String
        var title: String
        var matched: Set<Int>
        var keys: String
        var perform: @MainActor () -> Void
    }

    static let width: CGFloat = 620
    static let rowHeight: CGFloat = 26
    static let visibleRows = 12

    var body: some View {
        let state = model.palette ?? PaletteState()
        let (rows, total) = rows(for: state)
        let selection = min(state.selection, max(rows.count - 1, 0))
        ZStack(alignment: .top) {
            chrome.overlay.color
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityHidden(true)
            Box(
                title: state.mode == .commands ? "commands" : "themes",
                trailingTitle: "\(rows.count)/\(total)", titleColor: chrome.text,
                trailingTitleColor: chrome.textSecondary, borderColor: chrome.lineStrong,
                padding: EdgeInsets()
            ) {
                VStack(spacing: 0) {
                    queryField(state)
                    Rectangle().fill(chrome.line.color).frame(height: 1)
                    results(rows, selection: selection)
                    Rectangle().fill(chrome.line.color).frame(height: 1)
                    footer
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: Self.width)
            .background(chrome.background.color, ignoresSafeAreaEdges: [])
            .shadow(color: .black.opacity(0.5), radius: 24, y: 18)
            .padding(.top, 70)
        }
        .onAppear { queryFocused = true }
        .onKeyPress(.upArrow) {
            move(by: -1, count: rows.count)
            return .handled
        }
        .onKeyPress(.downArrow) {
            move(by: 1, count: rows.count)
            return .handled
        }
        .onKeyPress(.return) {
            if rows.indices.contains(selection) {
                rows[selection].perform()
            }
            return .handled
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.mode == .commands ? "Command palette" : "Themes")
        .accessibilityAddTraits(.isModal)
    }

    private func queryField(_ state: PaletteState) -> some View {
        HStack(spacing: 10) {
            Text(">").chromeStyle(chrome.accent)
            TextField(
                "",
                text: Binding(
                    get: { model.palette?.query ?? "" },
                    set: { query in
                        model.palette?.query = query
                        model.palette?.selection = 0
                        previewSelectedTheme()
                    }),
                prompt: Text(state.mode == .commands ? "Search commands" : "Search themes")
                    .foregroundStyle(chrome.textTabNumber.color)
            )
            .textFieldStyle(.plain)
            .font(MawFonts.chromeFont())
            .foregroundStyle(chrome.text.color)
            .focused($queryFocused)
            .accessibilityLabel(state.mode == .commands ? "Search commands" : "Search themes")
            Text("esc").chromeStyle(chrome.textMuted)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private func results(_ rows: [Row], selection: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if rows.isEmpty {
                        Text("no match").chromeStyle(chrome.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .frame(height: Self.rowHeight)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, selected: index == selection)
                            .onTapGesture { row.perform() }
                            .onHover { inside in
                                if inside { model.palette?.selection = index }
                            }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: CGFloat(min(max(rows.count, 1), Self.visibleRows)) * Self.rowHeight)
            .onChange(of: selection) { _, new in
                if rows.indices.contains(new) {
                    proxy.scrollTo(rows[new].id)
                }
            }
        }
    }

    private func rowView(_ row: Row, selected: Bool) -> some View {
        HStack(spacing: 0) {
            Text(row.group)
                .chromeStyle(selected ? chrome.textSelectedSecondary : chrome.textMuted)
                .frame(width: MawFonts.chromeCharacterWidth * 8, alignment: .leading)
            highlighted(row, selected: selected)
            Spacer(minLength: 12)
            Text(row.keys)
                .chromeStyle(selected ? chrome.textSelectedSecondary : chrome.textMuted)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.rowHeight)
        .background(selected ? chrome.text.color : .clear, ignoresSafeAreaEdges: [])
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.keys.isEmpty ? row.title : "\(row.title), \(row.keys)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { row.perform() }
    }

    /// The title with matched letters underlined, SemiBold, and in the accent color, or black
    /// on the selected row.
    private func highlighted(_ row: Row, selected: Bool) -> Text {
        let plain = selected ? chrome.textSelected : chrome.text
        let match = selected ? chrome.textSelected : chrome.accent
        var text = Text("")
        var run = ""
        var runMatched = false
        func flush() {
            guard !run.isEmpty else { return }
            let piece = Text(run)
                .font(MawFonts.chromeFont(semibold: runMatched))
                .foregroundColor((runMatched ? match : plain).color)
            text = text + (runMatched ? piece.underline() : piece)
            run = ""
        }
        for (offset, character) in row.title.enumerated() {
            let isMatched = row.matched.contains(offset)
            if isMatched != runMatched {
                flush()
                runMatched = isMatched
            }
            run.append(character)
        }
        flush()
        return text
    }

    private var footer: some View {
        HStack(spacing: 18) {
            footerHint("↑↓", "move")
            footerHint("↩", state == .themes ? "apply" : "run")
            footerHint("esc", state == .themes ? "restore" : "close")
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: Self.rowHeight)
    }

    private var state: PaletteState.Mode { model.palette?.mode ?? .commands }

    private func footerHint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(keys).chromeStyle(chrome.accent)
            Text(label).chromeStyle(chrome.textMuted)
        }
    }

    // MARK: Rows

    private func rows(for state: PaletteState) -> ([Row], Int) {
        switch state.mode {
        case .commands:
            let commands = model.registry.paletteCommands(in: model.context)
            let rows = commands.map { definition in
                Row(
                    id: "\(definition.id)", group: definition.group.rawValue,
                    title: definition.title, matched: [], keys: definition.keys,
                    perform: { [model] in model.perform(definition.id) })
            }
            return (filter(rows, query: state.query), rows.count)
        case .themes:
            let current = model.settings.theme
            let rows = model.settings.availableThemes.map { theme in
                Row(
                    id: theme.name, group: "theme", title: theme.name, matched: [],
                    keys: theme.name == current ? "*" : "",
                    perform: { [model] in
                        model.previewThemeName = theme.name
                        model.choosePreviewedTheme()
                    })
            }
            return (filter(rows, query: state.query), rows.count)
        }
    }

    private func filter(_ rows: [Row], query: String) -> [Row] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return rows }
        return FuzzyMatcher.rank(query, titles: rows.map(\.title)).map { index, match in
            var row = rows[index]
            row.matched = Set(match.matchedOffsets)
            return row
        }
    }

    private func move(by step: Int, count: Int) {
        guard count > 0, let selection = model.palette?.selection else { return }
        model.palette?.selection = min(max(selection + step, 0), count - 1)
        previewSelectedTheme()
    }

    /// In the theme list, shows the selected theme in the whole window.
    private func previewSelectedTheme() {
        guard let state = model.palette, state.mode == .themes else { return }
        let (rows, _) = rows(for: state)
        let index = min(state.selection, max(rows.count - 1, 0))
        if rows.indices.contains(index) {
            model.previewThemeName = rows[index].title
        }
    }

    private func close() {
        model.closePalette(restoringTheme: state == .themes)
    }
}
