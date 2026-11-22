import MawCore
import Testing

@Suite struct MacPathTests {
    let paths = MacPath(home: "/Users/alice")!

    @Test func translatesTheHomeDirectoryItself() {
        #expect(paths.linuxPath(forMac: "/Users/alice") == "/mnt/mac")
        #expect(paths.linuxPath(forMac: "/Users/alice/") == "/mnt/mac")
        #expect(paths.macPath(forLinux: "/mnt/mac") == "/Users/alice")
        #expect(paths.macPath(forLinux: "/mnt/mac/") == "/Users/alice")
    }

    @Test func translatesAPathUnderTheHomeDirectory() {
        #expect(paths.linuxPath(forMac: "/Users/alice/Projects/app") == "/mnt/mac/Projects/app")
        #expect(paths.macPath(forLinux: "/mnt/mac/Projects/app") == "/Users/alice/Projects/app")
        #expect(paths.linuxPath(forMac: "/Users/alice/Projects/app/") == "/mnt/mac/Projects/app")
    }

    @Test func resolvesDotAndDotDotFirst() {
        #expect(paths.linuxPath(forMac: "/Users/alice/./a/../b") == "/mnt/mac/b")
        #expect(paths.linuxPath(forMac: "/Users/bob/../alice/x") == "/mnt/mac/x")
        #expect(paths.linuxPath(forMac: "/Users/alice/..") == nil)
        #expect(paths.macPath(forLinux: "/mnt/mac/a/../../etc") == nil)
        #expect(paths.macPath(forLinux: "/mnt//mac//a") == "/Users/alice/a")
    }

    @Test func refusesAPathThatOnlySharesAPrefixOfTheName() {
        #expect(paths.linuxPath(forMac: "/Users/alice2") == nil)
        #expect(paths.linuxPath(forMac: "/Users/alice2/x") == nil)
        #expect(paths.macPath(forLinux: "/mnt/macintosh") == nil)
    }

    @Test func refusesPathsOutsideEitherSide() {
        #expect(paths.linuxPath(forMac: "/tmp") == nil)
        #expect(paths.linuxPath(forMac: "/Volumes/USB") == nil)
        #expect(paths.macPath(forLinux: "/home/alice") == nil)
        #expect(paths.macPath(forLinux: "/mnt") == nil)
        #expect(paths.linuxPath(forMac: "relative") == nil)
        #expect(paths.macPath(forLinux: "relative") == nil)
    }

    @Test func passesSpacesAndNonASCIILettersThrough() {
        let nfd = "c\u{0327}"
        #expect(paths.linuxPath(forMac: "/Users/alice/My Projects/ç") == "/mnt/mac/My Projects/ç")
        let translated = paths.linuxPath(forMac: "/Users/alice/\(nfd)")
        #expect(translated.map { Array($0.utf8) } == Array("/mnt/mac/\(nfd)".utf8))
        let home = MacPath(home: "/Users/Ayşe Öz")!
        #expect(home.macPath(forLinux: "/mnt/mac/a b") == "/Users/Ayşe Öz/a b")
    }

    @Test func needsAnAbsoluteHomeDirectoryOtherThanTheRoot() {
        #expect(MacPath(home: "Users/alice") == nil)
        #expect(MacPath(home: "/") == nil)
        #expect(MacPath(home: "/Users/../") == nil)
        #expect(MacPath(home: "/Users/alice/")?.home == "/Users/alice")
    }

    @Test func normalizesRelativeAndAbsolutePaths() {
        #expect(MacPath.normalized("") == ".")
        #expect(MacPath.normalized(".") == ".")
        #expect(MacPath.normalized("./a/") == "a")
        #expect(MacPath.normalized("a/../..") == "..")
        #expect(MacPath.normalized("../a/./b") == "../a/b")
        #expect(MacPath.normalized("/..") == "/")
        #expect(MacPath.normalized("//a//b/") == "/a/b")
        #expect(MacPath.absolute("b/../c", in: "/x/y") == "/x/y/c")
        #expect(MacPath.absolute("/z", in: "/x/y") == "/z")
    }
}

@Suite struct MacShareHomeArgumentTests {
    @Test func encodesSpacesAndNonASCIILetters() throws {
        let argument = try #require(MacShare.homeCommandLineArgument("/Users/Ayşe Öz/a%b"))
        #expect(argument == "maw.home=/Users/Ay%C5%9Fe%20%C3%96z/a%25b")
        #expect(
            MacShare.home(fromCommandLine: "quiet \(argument) maw.share=maw-mac\n")
                == "/Users/Ayşe Öz/a%b")
    }

    @Test func leavesOutAHomeDirectoryTooLongToEncode() {
        let long = "/" + String(repeating: "ü", count: 200)
        #expect(MacShare.homeCommandLineArgument(long) == nil)
        #expect(MacShare.homeCommandLineArgument("/" + String(repeating: "a", count: 1_022)) != nil)
    }

    @Test func treatsAnInvalidOrMissingValueAsUnknown() {
        #expect(MacShare.home(fromCommandLine: "console=hvc0 maw.share=maw-mac") == nil)
        for value in ["%", "%2", "%zz", "/a%2", "/a\"b", "/a\u{1}b", "%FF%FE", "relative", ""] {
            #expect(MacShare.home(fromCommandLine: "maw.home=\(value)") == nil, "\(value)")
        }
        #expect(MacShare.home(fromCommandLine: "maw.home=%2FUsers%2Fa") == "/Users/a")
    }
}
