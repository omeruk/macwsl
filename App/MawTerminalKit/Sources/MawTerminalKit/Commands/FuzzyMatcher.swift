import Foundation

/// The result of matching a palette query against a command title.
public struct FuzzyMatch: Hashable, Sendable, Comparable {
    /// How the query matched, best first.
    public enum Kind: Int, Hashable, Sendable, Comparable {
        /// Every query character, in order, but not contiguous.
        case subsequence = 0
        /// A contiguous run inside a word.
        case substring = 1
        /// The first letters of consecutive words: `spr` in `split pane right`.
        case wordInitials = 2
        /// A contiguous run that starts at the beginning of a word.
        case wordStart = 3
        /// A contiguous run at the beginning of the title.
        case prefix = 4

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var kind: Kind
    /// The offsets of the matched characters in the title, for highlighting.
    public var matchedOffsets: [Int]
    /// Within the same kind, a lower penalty ranks higher: matches that start earlier and,
    /// for subsequences, have smaller gaps.
    public var penalty: Int

    /// Orders matches from worst to best, so that `max()` and a descending sort pick the best.
    public static func < (lhs: FuzzyMatch, rhs: FuzzyMatch) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        return lhs.penalty > rhs.penalty
    }
}

/// Matches palette queries against command titles.
///
/// Prefix and word-start matches rank above word-initial matches, which rank above substrings,
/// which rank above scattered subsequences. Matching ignores case, and spaces in the query
/// match any run of separators in the title, so `new tab zsh` finds `new tab: zsh on this mac`.
public enum FuzzyMatcher {
    /// Characters that separate words in a title.
    static let separators: Set<Character> = [" ", ":", "-", "_", "/", ".", "(", ")", "…"]

    public static func match(_ query: String, in title: String) -> FuzzyMatch? {
        let needle = Array(query.lowercased()).filter { !separators.contains($0) || $0 == " " }
        let words = needle.split(separator: " ", omittingEmptySubsequences: true)
        guard !words.isEmpty else { return nil }
        let haystack = Array(title.lowercased())
        let wordStarts = Set(
            haystack.indices.filter { index in
                !separators.contains(haystack[index])
                    && (index == 0 || separators.contains(haystack[index - 1]))
            })

        // A single word: try the contiguous kinds first.
        if words.count == 1 {
            let word = Array(words[0])
            if let start = firstOccurrence(of: word, in: haystack, where: { $0 == 0 }) {
                return FuzzyMatch(
                    kind: .prefix, matchedOffsets: Array(start..<start + word.count), penalty: 0)
            }
            if let start = firstOccurrence(
                of: word, in: haystack, where: { wordStarts.contains($0) })
            {
                return FuzzyMatch(
                    kind: .wordStart, matchedOffsets: Array(start..<start + word.count),
                    penalty: start)
            }
            if let offsets = wordInitials(word, in: haystack, wordStarts: wordStarts) {
                return FuzzyMatch(kind: .wordInitials, matchedOffsets: offsets, penalty: offsets[0])
            }
            if let start = firstOccurrence(of: word, in: haystack, where: { _ in true }) {
                return FuzzyMatch(
                    kind: .substring, matchedOffsets: Array(start..<start + word.count),
                    penalty: start)
            }
        } else if let offsets = wordSequence(
            words.map(Array.init), in: haystack, wordStarts: wordStarts)
        {
            // Several words, each at the start of a word in the title, in order.
            return FuzzyMatch(kind: .wordStart, matchedOffsets: offsets, penalty: offsets[0])
        }
        return subsequence(Array(needle.filter { $0 != " " }), in: haystack)
    }

    /// Matches `query` against every title and returns the matches ranked best first. Ties keep
    /// the order of `titles`, which is the registry's order.
    public static func rank(_ query: String, titles: [String]) -> [(index: Int, match: FuzzyMatch)]
    {
        titles.enumerated()
            .compactMap { index, title in match(query, in: title).map { (index, $0) } }
            .sorted { lhs, rhs in
                lhs.match == rhs.match ? lhs.index < rhs.index : lhs.match > rhs.match
            }
    }

    private static func firstOccurrence(
        of word: [Character], in haystack: [Character], where accept: (Int) -> Bool
    ) -> Int? {
        guard word.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - word.count) where accept(start) {
            if haystack[start..<start + word.count].elementsEqual(word) {
                return start
            }
        }
        return nil
    }

    /// Each character of `word` as the first letter of consecutive words of the title.
    private static func wordInitials(
        _ word: [Character], in haystack: [Character], wordStarts: Set<Int>
    ) -> [Int]? {
        guard word.count > 1 else { return nil }
        let starts = wordStarts.sorted()
        guard word.count <= starts.count else { return nil }
        for first in 0...(starts.count - word.count) {
            let candidate = Array(starts[first..<first + word.count])
            if zip(candidate, word).allSatisfy({ haystack[$0] == $1 }) {
                return candidate
            }
        }
        return nil
    }

    /// Each query word as the beginning of a title word, in order.
    private static func wordSequence(
        _ words: [[Character]], in haystack: [Character], wordStarts: Set<Int>
    ) -> [Int]? {
        var offsets: [Int] = []
        var position = 0
        for word in words {
            guard
                let start = wordStarts.sorted().first(where: { start in
                    start >= position && start + word.count <= haystack.count
                        && haystack[start..<start + word.count].elementsEqual(word)
                })
            else { return nil }
            offsets += start..<start + word.count
            position = start + word.count
        }
        return offsets
    }

    /// The query's characters in order, each at its earliest possible position.
    private static func subsequence(_ needle: [Character], in haystack: [Character]) -> FuzzyMatch?
    {
        guard !needle.isEmpty else { return nil }
        var offsets: [Int] = []
        var position = 0
        for character in needle {
            guard let found = haystack[position...].firstIndex(of: character) else { return nil }
            offsets.append(found)
            position = found + 1
        }
        let gaps = zip(offsets, offsets.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0 - 1) }
        return FuzzyMatch(
            kind: .subsequence, matchedOffsets: offsets, penalty: gaps * 4 + offsets[0])
    }
}
