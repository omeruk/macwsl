import MawCore
import Testing

@Suite struct GuestLocaleTests {
    @Test func buildsTheLocaleFromTheMacsLanguageAndRegion() {
        #expect(GuestLocale.preferred(languageCode: "tr", regionCode: "TR") == "tr_TR.UTF-8")
        #expect(GuestLocale.preferred(languageCode: "en", regionCode: "tr") == "en_TR.UTF-8")
        #expect(GuestLocale.preferred(languageCode: "en", regionCode: nil) == nil)
        #expect(GuestLocale.preferred(languageCode: "yue", regionCode: "HK") == nil)
        #expect(GuestLocale.preferred(languageCode: "en", regionCode: "419") == nil)
    }

    @Test func usesThePreferredLocaleWhenTheDistributionHasIt() {
        let available = ["C", "C.utf8", "POSIX", "tr_TR.utf8"]
        #expect(GuestLocale.choose(preferred: "tr_TR.UTF-8", available: available) == "tr_TR.UTF-8")
    }

    @Test func fallsBackToCUTF8() {
        let available = ["C", "C.utf8", "POSIX"]
        #expect(GuestLocale.choose(preferred: "en_TR.UTF-8", available: available) == "C.UTF-8")
        #expect(GuestLocale.choose(preferred: nil, available: available) == "C.UTF-8")
    }

    @Test func comparesCodeSetsAsGlibcDoes() {
        #expect(GuestLocale.normalized("tr_TR.UTF-8") == "tr_TR.utf8")
        #expect(GuestLocale.normalized("de_DE.UTF-8@euro") == "de_DE.utf8@euro")
        #expect(GuestLocale.normalized("C") == "C")
    }
}
