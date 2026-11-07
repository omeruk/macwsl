import MawCore
import Testing

@Suite struct UserNameTests {
    static let reserved = DistroCatalog.builtIn.recommendedEntry.reservedNames

    @Test(arguments: [
        "ayse", "omer", "a", "dev-user", "build_bot", "x1", "machine$",
        String(repeating: "a", count: 32),
    ])
    func acceptsNamesThatUbuntuAccepts(_ name: String) throws {
        #expect(try UserName(name, reservedNames: Self.reserved).rawValue == name)
    }

    @Test(arguments: [
        ("", "the name is empty"),
        ("Ayse", "it must start with a lowercase letter"),
        ("1user", "it must start with a lowercase letter"),
        ("_user", "it must start with a lowercase letter"),
        ("omerFaruk", "it must not contain uppercase letters"),
        ("ayşe", "the character '\\u{015F}' is not allowed"),
        ("a b", "the character ' ' is not allowed"),
        ("a$b", "the character '$' is not allowed"),
        ("a.b", "the character '.' is not allowed"),
        (String(repeating: "a", count: 33), "it is 33 characters long, and the limit is 32"),
        ("root", "the distribution already has a user or group with that name"),
        ("sudo", "the distribution already has a user or group with that name"),
    ])
    func refusesOtherNames(_ name: String, _ reason: String) {
        #expect(throws: MawError.invalidUserName(name, reason: reason)) {
            try UserName(name, reservedNames: Self.reserved)
        }
    }
}
