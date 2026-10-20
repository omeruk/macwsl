import Foundation
import MacWSLCore
import Testing

@Suite struct DistroNameTests {
    @Test(arguments: ["Ubuntu", "Ubuntu-24.04", "debian_12", "a", "9", "Alpine.3.20", "x-"])
    func acceptsValidNames(_ name: String) throws {
        let distro = try DistroName(name)
        #expect(distro.rawValue == name)
        #expect(distro.description == name)
    }

    @Test(arguments: [
        "", "-v", ".", "..", ".hidden", "_private", "Ubuntu 24.04", "a/b", "../etc",
        "Übuntu", "name!", "tab\there",
    ])
    func rejectsInvalidNames(_ name: String) {
        #expect(throws: MacWSLError.self) { try DistroName(name) }
    }

    @Test func acceptsMaximumLength() throws {
        let name = String(repeating: "a", count: DistroName.maximumLength)
        #expect(try DistroName(name).rawValue == name)
    }

    @Test func rejectsOneOverMaximumLength() {
        let name = String(repeating: "a", count: DistroName.maximumLength + 1)
        #expect {
            try DistroName(name)
        } throws: { error in
            guard case MacWSLError.invalidDistroName(name, let reason) = error else { return false }
            return reason.contains("65 characters")
        }
    }

    @Test func errorExplainsTheRuleAndTheFix() throws {
        let error = try #require(throws: MacWSLError.self) { try DistroName("Ubuntu 24.04") }
        #expect(
            error.errorDescription
                == "'Ubuntu 24.04' is not a valid distribution name: "
                + "the character ' ' is not allowed.")
        #expect(error.recoverySuggestion?.contains("Ubuntu-24.04") == true)
    }

    @Test func roundTripsThroughJSON() throws {
        let original = try DistroName("Ubuntu-24.04")
        let data = try JSONEncoder().encode([original])
        #expect(String(decoding: data, as: UTF8.self) == #"["Ubuntu-24.04"]"#)
        #expect(try JSONDecoder().decode([DistroName].self, from: data) == [original])
    }

    @Test func decodingRejectsInvalidNames() {
        let data = Data(#"["../etc"]"#.utf8)
        #expect(throws: MacWSLError.self) {
            try JSONDecoder().decode([DistroName].self, from: data)
        }
    }
}
