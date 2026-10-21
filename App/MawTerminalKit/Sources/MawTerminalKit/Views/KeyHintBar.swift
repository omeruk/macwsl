import SwiftUI

/// The bar at the bottom of the window: key hints from the command registry on the left, then
/// a spacer, the focused session's status, and screen-wide hints such as `esc back` at the
/// right end.
struct KeyHintBar: View {
    let model: WindowModel
    @Environment(\.chrome) private var chrome

    var body: some View {
        let hints = model.settings.showKeyHints ? model.registry.hints(in: model.context) : []
        HStack(spacing: 18) {
            ForEach(hints.filter { $0.placement == .leading }, id: \.command) { hint in
                HintView(hint: hint) { model.perform(hint.command) }
            }
            Spacer(minLength: 0)
            StatusView(model: model)
            ForEach(hints.filter { $0.placement == .trailing }, id: \.command) { hint in
                HintView(hint: hint) { model.perform(hint.command) }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }
}

private struct HintView: View {
    let hint: CommandRegistry.Hint
    let action: () -> Void
    @Environment(\.chrome) private var chrome

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(hint.keys).chromeStyle(hint.isEnabled ? chrome.accent : chrome.lineStrong)
                Text(hint.label).chromeStyle(hint.isEnabled ? chrome.textMuted : chrome.lineStrong)
                if let note = hint.note {
                    Text(note).chromeStyle(chrome.lineStrong)
                }
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(!hint.isEnabled)
        .accessibilityLabel("\(hint.label), \(hint.keys)\(hint.note.map { ", \($0)" } ?? "")")
    }
}

/// `● name · directory · cols×rows` for a terminal tab, the settings file's state on the
/// settings tab.
private struct StatusView: View {
    let model: WindowModel
    @Environment(\.chrome) private var chrome

    var body: some View {
        if let status {
            HStack(spacing: 0) {
                Text("● ").chromeStyle(status.isProblem ? chrome.problem : chrome.statusOK)
                Text(status.text).chromeStyle(chrome.textSecondary)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var status: (text: String, isProblem: Bool)? {
        switch model.selectedTab?.content {
        case .terminal?:
            guard let pane = model.focusedPane else { return nil }
            var parts = [pane.displayName]
            if let directory = pane.workingDirectory {
                parts.append(abbreviatingHome(directory))
            }
            parts.append(pane.size.description)
            if let termination = pane.termination {
                return (parts.joined(separator: " · ") + " · " + termination.description, true)
            }
            return (parts.joined(separator: " · "), false)
        case .screen(.settings)?:
            let problem = model.settingsStore.problem
            return ("settings.json · \(problem == nil ? "saved" : "not in use")", problem != nil)
        case .screen(.distributions)?, nil:
            return nil
        }
    }
}
