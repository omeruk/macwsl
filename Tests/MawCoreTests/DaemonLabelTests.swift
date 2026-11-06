import MawCore
import Testing

/// A daemon's label names its staging directory, so it must name exactly one directory entry
/// inside `distros/.staging/`.
@Suite struct DaemonLabelTests {
    @Test(arguments: [
        "dev.maw.mawd", "dev.maw.mawd.integration-test", "dev.maw.mawd.test_2", "a",
        String(repeating: "a", count: 128),
    ])
    func acceptsALaunchdLabel(_ label: String) throws {
        #expect(try DaemonLabel(label).rawValue == label)
    }

    @Test(arguments: [
        ("", "the label is empty"),
        (".", "the label must start with a letter or digit"),
        ("..", "the label must start with a letter or digit"),
        ("../dev.maw.mawd", "the label must start with a letter or digit"),
        ("dev..maw", "the label must not contain '..'"),
        ("dev.maw/../x", "the character '/' is not allowed"),
        ("dev/maw", "the character '/' is not allowed"),
        ("/dev.maw.mawd", "the label must start with a letter or digit"),
        (".hidden", "the label must start with a letter or digit"),
        ("-option", "the label must start with a letter or digit"),
        ("dev maw", "the character ' ' is not allowed"),
        ("dev\u{0}maw", "the character '\\0' is not allowed"),
        ("dev\nmaw", "the character '\\n' is not allowed"),
        ("dev:maw", "the character ':' is not allowed"),
        ("dev\\maw", "the character '\\\\' is not allowed"),
        ("dev.maw.mawd\u{2215}x", "the character '\\u{2215}' is not allowed"),
        ("dév.maw", "the character '\\u{00E9}' is not allowed"),
        (
            String(repeating: "a", count: 129),
            "the label is 129 characters long, and the limit is 128"
        ),
    ])
    func refusesALabelThatIsNotOnePathComponent(_ label: String, reason: String) {
        #expect(throws: DaemonLabel.Invalid(label: label, reason: reason)) {
            try DaemonLabel(label)
        }
    }

    @Test func explainsARefusal() {
        let error = DaemonLabel.Invalid(label: "a\nb", reason: "the character '\\n' is not allowed")
        #expect(
            error.errorDescription
                == "The daemon label 'a\\nb' is not valid: the character '\\n' is not allowed.")
        #expect(error.recoverySuggestion != nil)
    }
}
