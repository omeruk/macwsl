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
