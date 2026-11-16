import MawCore
import Testing

@Suite struct MawConfTests {
    @Test func readsTheDefaultUser() {
        let conf = MawConf(parsing: "[user]\ndefault = ayse\n")
        #expect(conf.defaultUser == "ayse")
    }

    @Test func ignoresCommentsBlankLinesCaseAndQuotes() {
        let text = """
            # comment
            ; another comment

            [boot]
            command = echo hi
            [ User ]
              Default="omer"\r
            """
        let conf = MawConf(parsing: text)
        #expect(conf.defaultUser == "omer")
        #expect(conf.values["boot.command"] == "echo hi")
    }

    @Test func hasNoDefaultUserWhenItIsMissingOrEmpty() {
        #expect(MawConf(parsing: "").defaultUser == nil)
        #expect(MawConf(parsing: "[user]\ndefault =\n").defaultUser == nil)
        #expect(MawConf(parsing: "default = ayse\n").defaultUser == nil)
    }

    @Test func writesAFileItCanReadBack() throws {
        let text = MawConf.contents(defaultUser: try UserName("ayse"))
        #expect(MawConf(parsing: text).defaultUser == "ayse")
    }
}

/// `MawConf.settingDefaultUser(_:in:)`, which an import uses to write its choice into the
/// archive's `/etc/maw.conf`.
@Suite struct MawConfDefaultUserTests {
    @Test func changesNothingWhenTheFileAlreadyNamesTheUser() {
        #expect(MawConf.settingDefaultUser("ayse", in: "[user]\ndefault = ayse\n") == nil)
        #expect(MawConf.settingDefaultUser("ayse", in: "[User]\n  Default=\"ayse\"\n") == nil)
    }

    @Test func replacesTheDefaultAndKeepsEveryOtherLine() throws {
        let text = """
            # Settings of my distribution
            [boot]
            command = service ssh start

            [user]
            ; the account I work in
            default = omer
            [automount]
            enabled = false
            """
        let changed = try #require(MawConf.settingDefaultUser("ayse", in: text))
        #expect(
            changed == """
                # Settings of my distribution
                [boot]
                command = service ssh start

                [user]
                ; the account I work in
                default = ayse
                [automount]
                enabled = false

                """)
        let conf = MawConf(parsing: changed)
        #expect(conf.defaultUser == "ayse")
        #expect(conf.values["boot.command"] == "service ssh start")
        #expect(conf.values["automount.enabled"] == "false")
    }

    /// The parser keeps the last `default` of the `[user]` sections, so that is the line
    /// replaced; an earlier one stays as it is.
    @Test func replacesTheDefaultThatTheParserReads() throws {
        let text = "[user]\ndefault = omer\n[boot]\n[user]\ndefault = zeynep\n"
        let changed = try #require(MawConf.settingDefaultUser("ayse", in: text))
        #expect(changed == "[user]\ndefault = omer\n[boot]\n[user]\ndefault = ayse\n")
        #expect(MawConf(parsing: changed).defaultUser == "ayse")
    }

    @Test func replacesAnEmptyDefault() throws {
        let changed = try #require(MawConf.settingDefaultUser("ayse", in: "[user]\ndefault =\n"))
        #expect(changed == "[user]\ndefault = ayse\n")
    }

    @Test func addsTheDefaultUnderAnExistingUserSection() throws {
        let text = "[user]\n# no default yet\n[boot]\ncommand = true\n"
        let changed = try #require(MawConf.settingDefaultUser("ayse", in: text))
        #expect(changed == "[user]\ndefault = ayse\n# no default yet\n[boot]\ncommand = true\n")
        #expect(MawConf(parsing: changed).defaultUser == "ayse")
    }

    /// A `default` outside a `[user]` section is not the default user, and stays.
    @Test func appendsAUserSectionWhenThereIsNone() throws {
        let text = "[boot]\ndefault = something\ncommand = true"
        let changed = try #require(MawConf.settingDefaultUser("ayse", in: text))
        #expect(
            changed == "[boot]\ndefault = something\ncommand = true\n\n[user]\ndefault = ayse\n")
        #expect(MawConf(parsing: changed).defaultUser == "ayse")
        #expect(MawConf(parsing: changed).values["boot.default"] == "something")
    }

    @Test func writesAWholeFileWhenThereWasNone() throws {
        let changed = try #require(MawConf.settingDefaultUser("root", in: ""))
        #expect(changed == "[user]\ndefault = root\n")
    }
}
