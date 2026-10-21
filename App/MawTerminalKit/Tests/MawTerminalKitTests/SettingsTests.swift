import Foundation
import MawTerminalKit
import Testing

@Suite struct SettingsCodingTests {
    @Test func roundTripsEveryField() throws {
        var settings = Settings()
        settings.theme = "Dracula"
        settings.themes = [
            Theme(
                name: "Mine", ansi: Theme.dracula.ansi, foreground: "#FFFFFF",
                background: "#101010",
                cursor: "#FFFFFF", cursorText: "#101010", selectionBackground: "#303030",
                chrome: ChromeOverrides(accent: "#FF0000"))
        ]
        settings.fontFamily = "Menlo"
        settings.fontSize = 15
        settings.cursorShape = .underline
        settings.backgroundOpacity = 0.8
        settings.defaultProfile = "local"
        settings.localShell = "/bin/bash"
        settings.showKeyHints = false
        settings.confirmCloseWithRunningProcess = false
        settings.confirmQuitWithRunningProcess = false
        let data = try SettingsCoding.encode(settings)
        #expect(try SettingsCoding.decode(data) == settings)
    }

    @Test func writesTheCurrentVersion() throws {
        let data = try SettingsCoding.encode(Settings())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == Settings.currentVersion)
    }

    @Test func missingKeysTakeTheirDefaults() throws {
        let settings = try SettingsCoding.decode(Data(#"{"theme": "One Dark"}"#.utf8))
        var expected = Settings()
        expected.theme = "One Dark"
        #expect(settings == expected)
    }

    @Test func unknownKeysAreIgnored() throws {
        let settings = try SettingsCoding.decode(Data(#"{"futureOption": [1, 2]}"#.utf8))
        #expect(settings == Settings())
    }

    @Test func outOfRangeValuesAreClamped() throws {
        let settings = try SettingsCoding.decode(
            Data(#"{"fontSize": 400, "backgroundOpacity": 0}"#.utf8))
        #expect(settings.fontSize == Settings.fontSizeRange.upperBound)
        #expect(settings.backgroundOpacity == Settings.backgroundOpacityRange.lowerBound)
    }

    @Test func typeErrorsNameTheKey() {
        #expect(throws: SettingsError.invalid(detail: "fontSize: expected a number")) {
            try SettingsCoding.decode(Data(#"{"fontSize": "big"}"#.utf8))
        }
    }

    @Test func nestedErrorsNameTheFullPath() throws {
        let error = try #require(throws: SettingsError.self) {
            try SettingsCoding.decode(
                Data(##"{"themes": [{"name": "x", "ansi": {}, "foreground": "#000000"}]}"##.utf8))
        }
        guard case .invalid(let detail) = error else {
            Issue.record("Unexpected error \(error)")
            return
        }
        #expect(detail.hasPrefix("themes[0]"))
    }

    @Test func syntaxErrorsAreReported() throws {
        let error = try #require(throws: SettingsError.self) {
            try SettingsCoding.decode(Data("{\n  \"theme\": \"Dracula\",,\n}".utf8))
        }
        #expect(error.errorDescription?.hasPrefix("settings.json is invalid: ") == true)
    }

    @Test func aNonObjectIsRejected() {
        #expect(throws: SettingsError.invalid(detail: "the file must contain a JSON object")) {
            try SettingsCoding.decode(Data("[]".utf8))
        }
    }

    @Test func unknownThemesFallBackToMawDefault() throws {
        let settings = try SettingsCoding.decode(Data(#"{"theme": "Nope"}"#.utf8))
        #expect(settings.selectedTheme == .mawDefault)
    }

    @Test func customThemesReplaceBuiltInThemesOfTheSameName() {
        var settings = Settings()
        var custom = Theme.dracula
        custom.background = "#000000"
        settings.themes = [custom]
        settings.theme = "Dracula"
        #expect(settings.selectedTheme.background.hex == "#000000")
        #expect(settings.availableThemes.count == Theme.builtIn.count)
    }
}

@Suite struct SettingsMigrationTests {
    @Test func aFileWithoutAVersionIsVersionOne() throws {
        var json = JSONValue.object(["theme": .string("Dracula")])
        try SettingsMigration.standard.migrate(&json)
        #expect(json["version"] == .number(1))
    }

    @Test func newerVersionsAreRejected() {
        var json = JSONValue.object(["version": .number(99)])
        #expect(throws: SettingsError.newerVersion(found: 99, supported: Settings.currentVersion)) {
            try SettingsMigration.standard.migrate(&json)
        }
    }

    @Test func invalidVersionsAreRejected() {
        var json = JSONValue.object(["version": .string("one")])
        #expect(throws: SettingsError.invalid(detail: "version: expected a number")) {
            try SettingsMigration.standard.migrate(&json)
        }
    }

    @Test func stepsRunInOrderUpToTheCurrentVersion() throws {
        // A hypothetical format 3 that renamed "theme" twice.
        let migration = SettingsMigration(
            steps: [
                2: { json in
                    json["colorScheme"] = json["theme"]
                    json["theme"] = nil
                },
                3: { json in
                    json["theme"] = json["colorScheme"]
                    json["colorScheme"] = nil
                },
            ], currentVersion: 3)
        var json = JSONValue.object(["version": .number(1), "theme": .string("Dracula")])
        try migration.migrate(&json)
        #expect(json == .object(["version": .number(3), "theme": .string("Dracula")]))
    }

    @Test func decodingAppliesTheMigration() throws {
        let migration = SettingsMigration(
            steps: [2: { json in json["fontSize"] = .number(20) }], currentVersion: 2)
        let settings = try SettingsCoding.decode(
            Data(#"{"version": 1}"#.utf8), migration: migration)
        #expect(settings.fontSize == 20)
    }
}

@MainActor
@Suite struct SettingsStoreTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "maw-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var fileURL: URL { directory.appending(path: "settings.json") }

    @Test func loadingWithoutAFileWritesTheDefaults() throws {
        let store = SettingsStore(fileURL: fileURL)
        store.load()
        #expect(store.settings == Settings())
        #expect(try SettingsCoding.decode(Data(contentsOf: fileURL)) == Settings())
        #expect(store.problem == nil)
    }

    @Test func updatesAreSaved() throws {
        let store = SettingsStore(fileURL: fileURL)
        store.load()
        store.update { $0.theme = "Gruvbox Dark" }
        #expect(try SettingsCoding.decode(Data(contentsOf: fileURL)).theme == "Gruvbox Dark")
    }

    @Test func anInvalidFileKeepsTheLastValidSettings() throws {
        let store = SettingsStore(fileURL: fileURL)
        store.load()
        store.update { $0.theme = "Dracula" }
        try Data(#"{"theme": 3}"#.utf8).write(to: fileURL)
        store.reload()
        #expect(store.settings.theme == "Dracula")
        #expect(store.problem == .invalid(detail: "theme: expected a string"))

        try Data(#"{"theme": "One Dark"}"#.utf8).write(to: fileURL)
        store.reload()
        #expect(store.settings.theme == "One Dark")
        #expect(store.problem == nil)
    }

    @Test func changesInTheAppDoNotOverwriteAnInvalidFile() throws {
        let store = SettingsStore(fileURL: fileURL)
        store.load()
        let invalid = Data(#"{"theme": "#.utf8)
        try invalid.write(to: fileURL)
        store.reload()
        store.update { $0.fontSize = 18 }
        #expect(store.settings.fontSize == 18)
        #expect(try Data(contentsOf: fileURL) == invalid)
    }

    @Test func editsOnDiskAreReloadedWithinOneSecond() async throws {
        let store = SettingsStore(fileURL: fileURL)
        store.load()
        store.startWatching()
        defer { store.stopWatching() }

        // An in-place write, as `echo > settings.json` does.
        try Data(#"{"theme": "Dracula"}"#.utf8).write(to: fileURL)
        #expect(await waitUntil(seconds: 1) { store.settings.theme == "Dracula" })

        // An atomic replace, as most editors save.
        try Data(#"{"theme": "One Dark"}"#.utf8).write(to: fileURL, options: .atomic)
        #expect(await waitUntil(seconds: 1) { store.settings.theme == "One Dark" })

        // And again after the replace, which the watcher must have followed.
        try Data(#"{"theme": "Gruvbox Dark"}"#.utf8).write(to: fileURL)
        #expect(await waitUntil(seconds: 1) { store.settings.theme == "Gruvbox Dark" })
    }
}

/// Polls `condition` on the main actor until it holds or `seconds` pass.
@MainActor
func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
