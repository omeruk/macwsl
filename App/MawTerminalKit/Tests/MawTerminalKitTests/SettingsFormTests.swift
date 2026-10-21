import MawTerminalKit
import Testing

@Suite struct SettingsFormTests {
    let profiles = [Profile.localShell("/bin/zsh")]

    func form(_ change: (inout Settings) -> Void = { _ in }) -> SettingsForm {
        var settings = Settings()
        change(&settings)
        return SettingsForm(settings: settings, profiles: profiles)
    }

    @Test func pagesListTheirFields() {
        #expect(
            form().fields(on: .appearance).map(\.label) == [
                "theme", "font family", "font size", "cursor", "background opacity",
            ])
        #expect(
            form().fields(on: .general).map(\.label) == [
                "default profile", "local shell", "show key hints", "confirm close",
                "confirm quit",
            ])
        #expect(form().fields(on: .keyboard).isEmpty)
        #expect(SettingsPage.profiles.placeholder != nil)
        #expect(SettingsPage.distributions.placeholder != nil)
        #expect(SettingsPage.appearance.placeholder == nil)
    }

    @Test func valuesAreFormattedForDisplay() {
        let fields = form { $0.backgroundOpacity = 0.85 }.fields(on: .appearance)
        #expect(fields.map(\.value) == ["maw Default", "IBM Plex Mono", "13", "block", "85%"])
    }

    @Test func themesCycleAndWrap() {
        let last = Theme.builtIn.last!.name
        #expect(form().stepping(.theme, forward: true).theme == "Catppuccin Mocha")
        #expect(form().stepping(.theme, forward: false).theme == last)
        #expect(form { $0.theme = last }.stepping(.theme, forward: true).theme == "maw Default")
    }

    @Test func numbersStepWithinTheirRanges() {
        #expect(form().stepping(.fontSize, forward: true).fontSize == 14)
        #expect(
            form { $0.fontSize = Settings.fontSizeRange.upperBound }
                .stepping(.fontSize, forward: true).fontSize == Settings.fontSizeRange.upperBound)
        #expect(form().stepping(.backgroundOpacity, forward: false).backgroundOpacity == 0.95)
        #expect(form().stepping(.backgroundOpacity, forward: true).backgroundOpacity == 1)
    }

    @Test func togglesAndConfirmationChoicesFlip() {
        #expect(form().stepping(.showKeyHints, forward: true).showKeyHints == false)
        #expect(
            form().stepping(.confirmClose, forward: true).confirmCloseWithRunningProcess == false)
        #expect(
            form().choosing(.confirmQuit, index: 1).confirmQuitWithRunningProcess == false)
    }

    @Test func choosingFromAListSetsTheValue() {
        #expect(form().choosing(.cursorShape, index: 2).cursorShape == .underline)
        #expect(form().choosing(.fontFamily, index: 2).fontFamily == "Menlo")
        // An index outside the list changes nothing.
        #expect(form().choosing(.cursorShape, index: 9) == Settings())
    }

    @Test func aCustomFontFamilyIsOffered() {
        let fields = form { $0.fontFamily = "Fira Code" }.fields(on: .appearance)
        guard case .choice(let options, let selected) = fields[1].kind else {
            Issue.record("font family is not a choice")
            return
        }
        #expect(options.last == "Fira Code")
        #expect(selected == options.count - 1)
    }

    @Test func anEmptyLocalShellMeansTheLoginShell() {
        #expect(form().settingText(.localShell, to: "  /bin/bash ").localShell == "/bin/bash")
        #expect(
            form { $0.localShell = "/bin/bash" }.settingText(.localShell, to: "  ").localShell
                == nil)
        let shellField = form().fields(on: .general)[1]
        #expect(shellField.value.hasPrefix("login shell ("))
    }
}
