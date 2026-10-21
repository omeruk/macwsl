import MawTerminalKit
import Testing

@Suite struct FuzzyMatcherTests {
    @Test func classifiesMatches() {
        #expect(FuzzyMatcher.match("split", in: "split pane right")?.kind == .prefix)
        #expect(FuzzyMatcher.match("pane", in: "split pane right")?.kind == .wordStart)
        #expect(FuzzyMatcher.match("spr", in: "split pane right")?.kind == .wordInitials)
        #expect(FuzzyMatcher.match("lit", in: "split pane right")?.kind == .substring)
        #expect(FuzzyMatcher.match("sxt", in: "split pane right") == nil)
        #expect(FuzzyMatcher.match("spnrt", in: "split pane right")?.kind == .subsequence)
    }

    @Test func ignoresCase() {
        #expect(FuzzyMatcher.match("SPLIT", in: "split pane right")?.kind == .prefix)
    }

    @Test func emptyQueriesMatchNothing() {
        #expect(FuzzyMatcher.match("", in: "split pane right") == nil)
        #expect(FuzzyMatcher.match("   ", in: "split pane right") == nil)
    }

    @Test func reportsMatchedOffsets() {
        #expect(FuzzyMatcher.match("pane", in: "split pane right")?.matchedOffsets == [6, 7, 8, 9])
        #expect(FuzzyMatcher.match("spr", in: "split pane right")?.matchedOffsets == [0, 6, 11])
    }

    @Test func wordsAfterSeparatorsCountAsWordStarts() {
        // "zsh" follows ": " in the palette title.
        let match = FuzzyMatcher.match("zsh", in: "new tab: zsh on this mac")
        #expect(match?.kind == .wordStart)
        #expect(match?.matchedOffsets == [9, 10, 11])
    }

    @Test func multiWordQueriesMatchWordStartsInOrder() {
        let match = FuzzyMatcher.match("new tab zsh", in: "new tab: zsh on this mac")
        #expect(match?.kind == .wordStart)
        #expect(FuzzyMatcher.match("zsh new", in: "new tab: zsh on this mac")?.kind != .wordStart)
    }

    @Test func ranksPrefixAndWordStartAboveSubstring() {
        let titles = ["equalize panes", "split pane right", "open distributions", "pane: zoom"]
        let ranked = FuzzyMatcher.rank("pane", titles: titles).map { titles[$0.index] }
        // "pane: zoom" is a prefix match, then the word-start matches, earliest first.
        #expect(ranked == ["pane: zoom", "split pane right", "equalize panes"])
    }

    @Test func ranksSubstringAboveSubsequence() {
        let titles = ["font size: decrease", "theme: switch"]
        // "it" is a substring of "switch" and only a subsequence of "font size: decrease".
        let ranked = FuzzyMatcher.rank("it", titles: titles).map { titles[$0.index] }
        #expect(ranked.first == "theme: switch")
    }

    @Test func earlierMatchesRankHigherWithinAKind() {
        let titles = ["focus pane right", "split pane right"]
        let ranked = FuzzyMatcher.rank("right", titles: titles).map { titles[$0.index] }
        #expect(ranked == ["focus pane right", "split pane right"])
    }

    @Test func designQueryFindsTheSplitCommandsFirst() {
        // The palette board shows the query "sp".
        let titles = [
            "new tab: zsh on this mac", "split pane right", "split pane down", "equalize panes",
            "open distributions", "theme: switch",
        ]
        let ranked = FuzzyMatcher.rank("sp", titles: titles).map { titles[$0.index] }
        #expect(Array(ranked.prefix(2)) == ["split pane right", "split pane down"])
    }
}
