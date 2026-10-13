import Foundation

/// Open Quickly matching over note names and aliases. A match is ranked in three tiers: the text
/// starts with the query, a word in it starts with the query, or the query's letters appear in
/// order. Within a tier shorter texts come first, then alphabetical order.
extension VaultTables {
    func search(_ query: String, limit: Int) -> [(entry: SearchEntry, tier: Int)] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).folded
        guard !needle.isEmpty, limit > 0 else { return [] }
        let compact = Array(needle.unicodeScalars.filter { !$0.properties.isWhitespace })
        var best: [Int: (entry: SearchEntry, tier: Int)] = [:]
        for entry in searchEntries {
            guard let tier = Self.tier(entry, needle: needle, compact: compact) else { continue }
            if let current = best[entry.note], !Self.ranksBefore((entry, tier), current) { continue }
            best[entry.note] = (entry, tier)
        }
        let ranked = best.values.sorted { lhs, rhs in
            if Self.ranksBefore(lhs, rhs) { return true }
            if Self.ranksBefore(rhs, lhs) { return false }
            return noteFiles[lhs.entry.note].key < noteFiles[rhs.entry.note].key
        }
        return Array(ranked.prefix(limit))
    }

    private static func ranksBefore(_ lhs: (entry: SearchEntry, tier: Int), _ rhs: (entry: SearchEntry, tier: Int)) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        if lhs.entry.length != rhs.entry.length { return lhs.entry.length < rhs.entry.length }
        if lhs.entry.key != rhs.entry.key { return lhs.entry.key < rhs.entry.key }
        return !lhs.entry.isAlias && rhs.entry.isAlias
    }

    static func tier(_ entry: SearchEntry, needle: String, compact: [Unicode.Scalar]) -> Int? {
        if entry.key.hasPrefix(needle) { return 0 }
        if startsAWord(entry.key, needle) { return 1 }
        if isSubsequence(compact, of: entry.scalars) { return 2 }
        return nil
    }

    /// True when some word of `text` (after a space or punctuation) starts with `needle`.
    static func startsAWord(_ text: String, _ needle: String) -> Bool {
        for range in text.ranges(of: needle) where range.lowerBound > text.startIndex {
            let previous = text[text.index(before: range.lowerBound)]
            if !(previous.isLetter || previous.isNumber) { return true }
        }
        return false
    }

    static func isSubsequence(_ needle: [Unicode.Scalar], of haystack: [Unicode.Scalar]) -> Bool {
        guard !needle.isEmpty else { return false }
        var position = 0
        for scalar in haystack where scalar == needle[position] {
            position += 1
            if position == needle.count { return true }
        }
        return false
    }
}
