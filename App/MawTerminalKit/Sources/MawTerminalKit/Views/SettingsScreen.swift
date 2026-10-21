import AppKit
import SwiftTerm
import SwiftUI

/// The settings tab (⌘,): a `settings` box listing the pages, and a box with the selected
/// page's fields as `label  value` rows. Laid out as in the sketch approved for phase 11a.
///
/// Keys: ↑↓ move, ←→ change the value, ↩ opens a list of choices (or edits text), ⇥ switches
/// between the boxes, and esc closes a list, cancels an edit, or returns to the previous tab.
/// In the theme list, each theme is previewed as the selection moves, and esc restores the
/// theme that was selected before.
struct SettingsScreen: View {
    let model: WindowModel

    enum Area { case pages, fields }

    /// An open list of choices for a field.
    struct OpenList: Equatable {
        var field: SettingsForm.FieldID
        var options: [String]
        var selection: Int
        var original: Int
    }

    @State private var page = SettingsPage.appearance
    @State private var area = Area.pages
    @State private var fieldIndex = 0
    @State private var list: OpenList?
    @State private var editingText: String?
    @FocusState private var keyboardFocused: Bool
    @FocusState private var textFocused: Bool
    @Environment(\.chrome) private var chrome

    static let labelWidth: CGFloat = MawFonts.chromeCharacterWidth * 20
    static let valueWidth: CGFloat = MawFonts.chromeCharacterWidth * 30
    static let rowHeight: CGFloat = 26

    private var form: SettingsForm {
        SettingsForm(settings: model.settings, profiles: model.profiles)
    }

    var body: some View {
        let fields = form.fields(on: page)
        HStack(alignment: .top, spacing: 10) {
            pagesBox
                .frame(width: 200)
            fieldsBox(fields)
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 0, trailing: 10))
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .onAppear { keyboardFocused = true }
        .onKeyPress(.upArrow) { handle(.up, fields: fields) }
        .onKeyPress(.downArrow) { handle(.down, fields: fields) }
        .onKeyPress(.leftArrow) { handle(.left, fields: fields) }
        .onKeyPress(.rightArrow) { handle(.right, fields: fields) }
        .onKeyPress(.return) { handle(.enter, fields: fields) }
        .onKeyPress(.tab) { handle(.tab, fields: fields) }
        .onKeyPress(.escape) { handle(.escape, fields: fields) }
    }

    // MARK: Pages

    private var pagesBox: some View {
        Box(title: "settings", titleColor: chrome.text, borderColor: boxBorder(.pages)) {
            VStack(spacing: 0) {
                ForEach(SettingsPage.allCases, id: \.self) { candidate in
                    let selected = candidate == page
                    Text(candidate.rawValue)
                        .chromeStyle(selected ? chrome.textSelected : chrome.text)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: Self.rowHeight)
                        .background(selected ? chrome.text.color : .clear, ignoresSafeAreaEdges: [])
                        .contentShape(Rectangle())
                        .onTapGesture {
                            select(page: candidate)
                            area = .pages
                        }
                        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { select(page: candidate) }
                }
            }
            .padding(.horizontal, -6)
        }
    }

    // MARK: Fields

    @ViewBuilder
    private func fieldsBox(_ fields: [SettingsForm.Field]) -> some View {
        switch page {
        case .keyboard:
            KeyboardPage(
                shortcuts: model.registry.keyboardShortcuts,
                selection: area == .fields ? fieldIndex : nil, borderColor: boxBorder(.fields))
        case .profiles, .distributions:
            Box(title: page.rawValue, titleColor: chrome.text, borderColor: boxBorder(.fields)) {
                Text(page.placeholder ?? "").chromeStyle(chrome.textSecondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .appearance, .general:
            Box(title: page.rawValue, titleColor: chrome.text, borderColor: boxBorder(.fields)) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                        fieldRow(field, index: index)
                            .zIndex(list?.field == field.id ? 1 : 0)
                    }
                    if page == .appearance {
                        Box(
                            title: "preview", titleColor: chrome.textSecondary,
                            borderColor: chrome.line
                        ) {
                            ThemePreview(appearance: previewAppearance)
                        }
                        .frame(height: 190)
                        .padding(.top, 20)
                        .zIndex(-1)
                    }
                }
            }
        }
    }

    private func fieldRow(_ field: SettingsForm.Field, index: Int) -> some View {
        let focused = area == .fields && index == fieldIndex
        return HStack(spacing: 0) {
            Text(field.label)
                .chromeStyle(focused ? chrome.textSelectedSecondary : chrome.textSecondary)
                .frame(width: Self.labelWidth, alignment: .leading)
            if editingText != nil, focused, case .text = field.kind {
                TextField("", text: Binding(get: { editingText ?? "" }, set: { editingText = $0 }))
                    .textFieldStyle(.plain)
                    .font(MawFonts.chromeFont())
                    .foregroundStyle(chrome.textSelected.color)
                    .focused($textFocused)
                    .onSubmit { finishEditing(field, commit: true) }
                    .onKeyPress(.escape) {
                        finishEditing(field, commit: false)
                        return .handled
                    }
                    .frame(width: Self.valueWidth)
                    .accessibilityLabel(field.label)
            } else {
                Text(field.value)
                    .chromeStyle(focused ? chrome.textSelected : chrome.text)
                    .truncationMode(.middle)
                    .frame(width: Self.valueWidth, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        area = .fields
                        fieldIndex = index
                        activate(field)
                    }
            }
            Spacer(minLength: 0)
            if focused {
                Text(hints(for: field)).chromeStyle(chrome.textSelectedSecondary)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: Self.rowHeight)
        .background(focused ? chrome.text.color : .clear, ignoresSafeAreaEdges: [])
        .contentShape(Rectangle())
        .onTapGesture {
            area = .fields
            fieldIndex = index
        }
        .padding(.horizontal, -6)
        .overlay(alignment: .topLeading) {
            if let list, list.field == field.id {
                ChoiceList(list: list) { index in
                    self.list?.selection = index
                    choose(index, in: list.field)
                }
                .offset(x: Self.labelWidth + Self.valueWidth * 0.6, y: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(field.label), \(field.value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(field, forward: true)
            case .decrement: step(field, forward: false)
            @unknown default: break
            }
        }
    }

    private func hints(for field: SettingsForm.Field) -> String {
        switch field.kind {
        case .choice: "←→   ↩ list"
        case .number: "←→"
        case .toggle: "←→   ↩ switch"
        case .text: "↩ edit"
        }
    }

    private func boxBorder(_ box: Area) -> ThemeColor {
        area == box ? chrome.lineStrong : chrome.line
    }

    /// The preview box follows the settings, including a theme being browsed in a list.
    private var previewAppearance: TerminalAppearance {
        TerminalAppearance(settings: model.effectiveSettings, fontSizeAdjustment: 0)
    }

    // MARK: Keys

    enum Key { case up, down, left, right, enter, tab, escape }

    private func handle(_ key: Key, fields: [SettingsForm.Field]) -> KeyPress.Result {
        if editingText != nil {
            return .ignored
        }
        if let open = list {
            switch key {
            case .up, .down:
                let next = min(
                    max(open.selection + (key == .up ? -1 : 1), 0), open.options.count - 1)
                list?.selection = next
                if open.field == .theme {
                    model.previewThemeName = open.options[next]
                }
            case .enter:
                choose(open.selection, in: open.field)
            case .escape:
                closeList(restore: true)
            case .left, .right, .tab:
                break
            }
            return .handled
        }
        switch (key, area) {
        case (.escape, _):
            model.perform(.back)
        case (.tab, _):
            area = area == .pages ? .fields : .pages
            fieldIndex = 0
        case (.up, .pages), (.down, .pages):
            let pages = SettingsPage.allCases
            let index = pages.firstIndex(of: page) ?? 0
            select(page: pages[min(max(index + (key == .up ? -1 : 1), 0), pages.count - 1)])
        case (.right, .pages), (.enter, .pages):
            area = .fields
            fieldIndex = 0
        case (.left, .pages):
            break
        case (.up, .fields), (.down, .fields):
            let count = page == .keyboard ? model.registry.keyboardShortcuts.count : fields.count
            guard count > 0 else { break }
            fieldIndex = min(max(fieldIndex + (key == .up ? -1 : 1), 0), count - 1)
        case (.left, .fields), (.right, .fields):
            if fields.indices.contains(fieldIndex) {
                step(fields[fieldIndex], forward: key == .right)
            }
        case (.enter, .fields):
            if fields.indices.contains(fieldIndex) {
                activate(fields[fieldIndex])
            }
        }
        return .handled
    }

    private func select(page newPage: SettingsPage) {
        page = newPage
        fieldIndex = 0
        closeList(restore: true)
    }

    private func step(_ field: SettingsForm.Field, forward: Bool) {
        let updated = form.stepping(field.id, forward: forward)
        model.settingsStore.update { $0 = updated }
    }

    /// ↩ or a click on a value: opens a choice list, flips a toggle, or edits text.
    private func activate(_ field: SettingsForm.Field) {
        switch field.kind {
        case .choice(let options, let selected):
            list = OpenList(
                field: field.id, options: options, selection: selected, original: selected)
        case .toggle:
            step(field, forward: true)
        case .text(let text):
            editingText = text
            textFocused = true
        case .number:
            break
        }
    }

    private func choose(_ index: Int, in field: SettingsForm.FieldID) {
        let updated = form.choosing(field, index: index)
        model.previewThemeName = nil
        model.settingsStore.update { $0 = updated }
        list = nil
    }

    private func closeList(restore: Bool) {
        if restore, list?.field == .theme {
            model.previewThemeName = nil
        }
        list = nil
    }

    private func finishEditing(_ field: SettingsForm.Field, commit: Bool) {
        if commit, let text = editingText {
            let updated = form.settingText(field.id, to: text)
            model.settingsStore.update { $0 = updated }
        }
        editingText = nil
        keyboardFocused = true
    }
}

/// The reverse-video list that ↩ opens on a choice field.
private struct ChoiceList: View {
    let list: SettingsScreen.OpenList
    let choose: (Int) -> Void
    @Environment(\.chrome) private var chrome

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(list.options.enumerated()), id: \.offset) { index, option in
                let selected = index == list.selection
                HStack(spacing: 0) {
                    Text(option).chromeStyle(selected ? chrome.textSelected : chrome.text)
                    Spacer(minLength: 16)
                    Text(index == list.original ? "*" : " ")
                        .chromeStyle(selected ? chrome.textSelected : chrome.accent)
                }
                .padding(.horizontal, 8)
                .frame(height: SettingsScreen.rowHeight)
                .background(selected ? chrome.text.color : .clear, ignoresSafeAreaEdges: [])
                .contentShape(Rectangle())
                .onTapGesture { choose(index) }
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .frame(width: 240)
        .background(chrome.background.color, ignoresSafeAreaEdges: [])
        .overlay { Rectangle().strokeBorder(chrome.lineStrong.color, lineWidth: 1) }
        .shadow(color: .black.opacity(0.5), radius: 16, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choices")
    }
}

/// A read-only list of every shortcut, from the command registry.
private struct KeyboardPage: View {
    let shortcuts: [CommandDefinition]
    let selection: Int?
    let borderColor: ThemeColor
    @Environment(\.chrome) private var chrome

    var body: some View {
        Box(
            title: "keyboard (\(shortcuts.count))", titleColor: chrome.text,
            borderColor: borderColor
        ) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shortcuts.enumerated()), id: \.element.id) { index, command in
                            let selected = index == selection
                            HStack(spacing: 0) {
                                Text(command.group.rawValue)
                                    .chromeStyle(
                                        selected ? chrome.textSelectedSecondary : chrome.textMuted
                                    )
                                    .frame(
                                        width: MawFonts.chromeCharacterWidth * 10,
                                        alignment: .leading)
                                Text(command.title).chromeStyle(
                                    selected ? chrome.textSelected : chrome.text)
                                Spacer(minLength: 12)
                                Text(command.keys)
                                    .chromeStyle(selected ? chrome.textSelected : chrome.accent)
                            }
                            .padding(.horizontal, 6)
                            .frame(height: SettingsScreen.rowHeight)
                            .background(
                                selected ? chrome.text.color : .clear, ignoresSafeAreaEdges: []
                            )
                            .id(index)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .onChange(of: selection) { _, new in
                    if let new { proxy.scrollTo(new) }
                }
            }
            .padding(.horizontal, -6)
        }
    }
}

/// A short sample session rendered by a real terminal view in the selected theme, font, and
/// cursor. It takes no input.
struct ThemePreview: NSViewRepresentable {
    let appearance: TerminalAppearance

    func makeNSView(context: Context) -> PreviewTerminalView {
        let view = PreviewTerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 170))
        view.apply(appearance, previous: nil)
        view.lastAppearance = appearance
        view.feed(text: Self.sample)
        return view
    }

    func updateNSView(_ view: PreviewTerminalView, context: Context) {
        guard view.lastAppearance != appearance else { return }
        view.apply(appearance, previous: view.lastAppearance)
        view.lastAppearance = appearance
    }

    /// The sample uses most ANSI slots: the prompt, a branch, modified and untracked files,
    /// and a directory listing.
    static let sample: String = {
        let esc = "\u{1B}["
        let prompt = "\(esc)36muser@mac\(esc)0m \(esc)34m~/project\(esc)0m \(esc)90m%\(esc)0m "
        return [
            prompt + "git status -sb",
            "\(esc)90m## \(esc)0m\(esc)33mmain\(esc)90m...\(esc)0m\(esc)31morigin/main\(esc)0m",
            " \(esc)31mM\(esc)0m Sources/App.swift",
            "\(esc)32m??\(esc)0m Tests/AppTests.swift",
            prompt + "ls",
            "\(esc)34mSources  Tests\(esc)0m  Package.swift  README.md",
            prompt,
        ].joined(separator: "\r\n")
    }()
}

final class PreviewTerminalView: TerminalView {
    var lastAppearance: TerminalAppearance?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
