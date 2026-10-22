import Foundation
import Testing

@testable import MawCore

@Suite struct DistroCatalogTests {
    let catalog = DistroCatalog.builtIn

    @Test func decodesTheBuiltInCatalogWithoutProblems() {
        #expect(!catalog.entries.isEmpty)
        #expect(catalog.problems() == [])
    }

    @Test func recommendsUbuntu2404() {
        #expect(catalog.recommendedEntry.name.rawValue == "Ubuntu-24.04")
        #expect(catalog.recommendedEntry.displayName == "Ubuntu 24.04 LTS")
    }

    @Test(arguments: ["Ubuntu-24.04", "ubuntu-24.04", "Ubuntu", "UBUNTU"])
    func findsAnEntryByNameOrAliasIgnoringCase(_ name: String) {
        #expect(catalog.entry(named: name)?.name.rawValue == "Ubuntu-24.04")
    }

    @Test func findsNothingForAnUnknownName() {
        #expect(catalog.entry(named: "Debian") == nil)
    }

    @Test func pinsEveryImageOverHTTPSWithASHA256() {
        for entry in catalog.entries {
            #expect(entry.image.url.scheme == "https", "\(entry.name)")
            #expect(CatalogImage.isSHA256(entry.image.sha256), "\(entry.name)")
            #expect(entry.image.size > 0 && entry.image.installedSize > 0, "\(entry.name)")
            #expect(entry.reservedNames.contains("root") && entry.reservedNames.contains("sudo"))
        }
    }

    @Test func namesCachedImagesByTheirSHA256() {
        let image = catalog.recommendedEntry.image
        #expect(image.cacheFileName == "\(image.sha256).tar.gz")
    }

    @Test func reportsAnUnsafeOrInconsistentCatalog() throws {
        var entry = catalog.recommendedEntry
        entry.image.url = try #require(URL(string: "http://example.com/image.tar.gz"))
        entry.image.sha256 = "ABC"
        let broken = DistroCatalog(
            recommended: try DistroName("Missing"), entries: [entry, entry])
        let problems = broken.problems()
        #expect(problems.contains("The recommended entry Missing does not exist."))
        #expect(problems.contains("The name Ubuntu-24.04 is used more than once."))
        #expect(problems.contains { $0.contains("does not use HTTPS") })
        #expect(problems.contains { $0.contains("is not a SHA-256") })
    }

    @Test(arguments: [
        ("74478b5024d9047397ba79d17c27f73caf85ada4988f88cffc2892d65e6a806b", true),
        ("74478B5024D9047397BA79D17C27F73CAF85ADA4988F88CFFC2892D65E6A806B", false),
        ("74478b5024d9047397ba79d17c27f73caf85ada4988f88cffc2892d65e6a806", false),
        ("74478b5024d9047397ba79d17c27f73caf85ada4988f88cffc2892d65e6a806g", false),
    ])
    func recognizesSHA256Digests(_ text: String, _ valid: Bool) {
        #expect(CatalogImage.isSHA256(text) == valid)
    }
}
