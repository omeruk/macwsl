import MawCore
import Testing

/// The default user of an imported distribution (prompts/06b-distro-removal-and-transfer.md,
/// "What --import configures").
@Suite struct DefaultUserChoiceTests {
    static let passwd = """
        root:x:0:0:root:/root:/bin/bash
        daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
        ayse:x:1000:1000:Ayse:/home/ayse:/bin/bash
        omer:x:1001:1001::/home/omer:/bin/bash
        Bad:x:1002:1002::/home/Bad:/bin/bash
        +nisuser::::::
        broken:x:1003
        """

    static func choose(
        option: String? = nil, mawConf: String? = nil, wslConf: String? = nil,
        passwd: String = passwd
    ) throws(MawError) -> DefaultUserChoice {
        try DefaultUserChoice.choose(
            option: option, mawConf: mawConf, wslConf: wslConf, passwd: passwd)
    }

    @Test func takesTheUserThatTheOptionNames() throws {
        #expect(
            try Self.choose(option: "omer", mawConf: "[user]\ndefault = ayse\n")
                == DefaultUserChoice(user: "omer", source: .option))
    }

    @Test func refusesAnOptionThatFailsTheRules() {
        let error = #expect(throws: MawError.self) { try Self.choose(option: "Bad") }
        guard case .invalidUserName("Bad", _)? = error else {
            Issue.record("\(String(describing: error))")
            return
        }
    }

    @Test func refusesAnOptionThatNamesNoUserOfTheArchive() {
        #expect(throws: MawError.userNotFound("zeynep", distribution: "the archive")) {
            try Self.choose(option: "zeynep", mawConf: "[user]\ndefault = ayse\n")
        }
        // A NIS line and a line without seven fields name no user.
        #expect(throws: MawError.userNotFound("broken", distribution: "the archive")) {
            try Self.choose(option: "broken")
        }
    }

    @Test func takesTheDefaultOfMawConf() throws {
        #expect(
            try Self.choose(
                mawConf: "[user]\ndefault = ayse\n", wslConf: "[user]\ndefault = omer\n")
                == DefaultUserChoice(user: "ayse", source: .mawConf))
    }

    @Test func fallsBackToWslConfWhenMawConfNamesNoUsableUser() throws {
        let wsl = "[boot]\nsystemd=true\n[user]\ndefault=omer\n"
        let expected = DefaultUserChoice(user: "omer", source: .wslConf)
        #expect(try Self.choose(mawConf: nil, wslConf: wsl) == expected)
        #expect(try Self.choose(mawConf: "[boot]\ncommand = true\n", wslConf: wsl) == expected)
        // A name that fails the rules, and one that is not in /etc/passwd.
        #expect(try Self.choose(mawConf: "[user]\ndefault = Bad\n", wslConf: wsl) == expected)
        #expect(try Self.choose(mawConf: "[user]\ndefault = zeynep\n", wslConf: wsl) == expected)
    }

    @Test func fallsBackToRootWhenNothingNamesAUsableUser() throws {
        let root = DefaultUserChoice(user: "root", source: .fallback)
        #expect(try Self.choose() == root)
        #expect(
            try Self.choose(
                mawConf: "[user]\ndefault = zeynep\n", wslConf: "[user]\ndefault = Bad\n")
                == root)
        #expect(try Self.choose(wslConf: "[boot]\nsystemd=true\n") == root)
        #expect(!root.lingers)
    }

    /// `root` is accepted from each source, although it already exists in every image and
    /// `--install` therefore refuses it as a new account's name.
    @Test func acceptsRootFromEverySource() throws {
        #expect(try Self.choose(option: "root") == DefaultUserChoice(user: "root", source: .option))
        #expect(
            try Self.choose(mawConf: "[user]\ndefault = root\n")
                == DefaultUserChoice(user: "root", source: .mawConf))
        #expect(
            try Self.choose(wslConf: "[user]\ndefault = root\n")
                == DefaultUserChoice(user: "root", source: .wslConf))
        #expect(try !Self.choose(option: "root").lingers)
        #expect(try Self.choose(option: "ayse").lingers)
    }

    @Test func readsTheUsersOfPasswd() {
        #expect(
            DefaultUserChoice.users(inPasswd: Self.passwd) == [
                "root", "daemon", "ayse", "omer", "Bad",
            ])
        #expect(DefaultUserChoice.users(inPasswd: "") == [])
    }
}
