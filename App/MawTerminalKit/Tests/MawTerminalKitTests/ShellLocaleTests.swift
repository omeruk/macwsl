import Foundation
import MawTerminalKit
import Testing

@Suite struct ShellLocaleTests {
    /// The locales of a system without `en_TR.UTF-8`, like macOS.
    let available: Set<String> = [
        "C", "POSIX", "en_US.UTF-8", "tr_TR.UTF-8", "de_DE.UTF-8", "en_US.ISO8859-1",
    ]

    func resolve(_ environment: [String: String], _ locale: String) -> [String: String] {
        ShellLocale.environment(
            environment, locale: Locale(identifier: locale), isValid: available.contains)
    }

    @Test func candidatesGoFromTheRegionToTheLanguageToEnglish() {
        #expect(
            ShellLocale.candidates(for: Locale(identifier: "en_TR"))
                == ["en_TR.UTF-8", "en_EN.UTF-8", "en_US.UTF-8"])
        #expect(
            ShellLocale.candidates(for: Locale(identifier: "tr_DE"))
                == ["tr_DE.UTF-8", "tr_TR.UTF-8", "en_US.UTF-8"])
        #expect(
            ShellLocale.candidates(for: Locale(identifier: "en_US")) == [
                "en_US.UTF-8", "en_EN.UTF-8",
            ])
    }

    @Test func englishInTurkeyFallsBackToUSEnglish() {
        // The reported case: system language English, region Turkey, no inherited LANG.
        #expect(resolve([:], "en_TR")["LANG"] == "en_US.UTF-8")
    }

    @Test func aLanguageWithoutItsRegionUsesItsOwnCountry() {
        #expect(resolve([:], "tr_DE")["LANG"] == "tr_TR.UTF-8")
    }

    @Test func theUsersRegionWinsWhenItExists() {
        #expect(resolve([:], "de_DE")["LANG"] == "de_DE.UTF-8")
    }

    @Test func aValidInheritedLocaleIsKeptUnchanged() {
        #expect(resolve(["LANG": "de_DE.UTF-8"], "en_TR") == ["LANG": "de_DE.UTF-8"])
        // Valid but not UTF-8: still the user's choice.
        #expect(resolve(["LANG": "en_US.ISO8859-1"], "en_TR") == ["LANG": "en_US.ISO8859-1"])
        #expect(resolve(["LC_ALL": "C"], "en_TR") == ["LC_ALL": "C"])
        #expect(
            resolve(["LC_CTYPE": "tr_TR.UTF-8", "LANG": "nonsense"], "en_TR")
                == ["LC_CTYPE": "tr_TR.UTF-8", "LANG": "nonsense"])
    }

    @Test func anInvalidInheritedLangIsReplaced() {
        #expect(resolve(["LANG": "en_TR.UTF-8"], "en_TR")["LANG"] == "en_US.UTF-8")
    }

    @Test func invalidOverridesAreRemovedSoThatLangApplies() {
        let resolved = resolve(
            ["LC_ALL": "en_TR.UTF-8", "LC_CTYPE": "xx", "LANG": "de_DE.UTF-8"], "en_TR")
        #expect(resolved == ["LANG": "de_DE.UTF-8"])
    }

    @Test func otherVariablesAreUntouched() {
        let resolved = resolve(["LC_MESSAGES": "whatever", "HOME": "/Users/x"], "en_TR")
        #expect(resolved["LC_MESSAGES"] == "whatever")
        #expect(resolved["HOME"] == "/Users/x")
    }

    @Test func withNoValidCandidateTheShellGetsNoLang() {
        let resolved = ShellLocale.environment(
            ["LANG": "bad"], locale: Locale(identifier: "en_TR"), isValid: { _ in false })
        #expect(resolved["LANG"] == nil)
    }

    @Test func theSystemCheckRecognizesMacOSLocales() {
        #expect(ShellLocale.isValidCharacterType("en_US.UTF-8"))
        #expect(ShellLocale.isValidCharacterType("C"))
        #expect(!ShellLocale.isValidCharacterType("en_TR.UTF-8"))
        #expect(!ShellLocale.isValidCharacterType("nonsense"))
    }
}
