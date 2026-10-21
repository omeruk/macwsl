import SwiftUI

/// Everything inside a terminal window: the tab strip in the title bar area, the selected
/// tab's content, the key-hint bar, and the command palette above them.
struct WindowRootView: View {
    let model: WindowModel

    var body: some View {
        let chrome = model.chrome
        let opacity = model.effectiveSettings.backgroundOpacity
        VStack(spacing: 0) {
            TitleBarView(model: model)
            if let problem = model.settingsStore.problem {
                SettingsProblemBanner(problem: problem)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            KeyHintBar(model: model)
        }
        .background(chrome.background.color.opacity(opacity))
        .overlay {
            if model.palette != nil {
                CommandPaletteView(model: model)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.chrome, chrome)
        .environment(\.ansi, model.effectiveSettings.selectedTheme.ansi)
        .preferredColorScheme(
            chrome.background.relativeLuminance > 0.5 ? .light : .dark)
    }

    @ViewBuilder private var content: some View {
        switch model.selectedTab?.content {
        case .terminal(let tree)?:
            PaneGridView(model: model, tree: tree)
        case .screen(.distributions)?:
            DistributionsScreen(model: model)
        case .screen(.settings)?:
            SettingsScreen(model: model)
        case nil:
            Color.clear
        }
    }
}

/// The non-blocking notice shown while `settings.json` cannot be used.
struct SettingsProblemBanner: View {
    let problem: SettingsError
    @Environment(\.chrome) private var chrome

    var body: some View {
        HStack(spacing: 0) {
            Text("● ").chromeStyle(chrome.problem)
            Text(message).chromeStyle(chrome.problem)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
        .help(problem.recoverySuggestion ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }

    private var message: String {
        let description = problem.errorDescription ?? "settings.json cannot be used"
        switch problem {
        case .invalid, .newerVersion, .readFailed:
            return description + ". Using the last valid settings."
        case .writeFailed:
            return description + "."
        }
    }
}
