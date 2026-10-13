import Foundation

/// The internal result of resolving a link, by table index.
enum LinkMatch: Sendable {
    case note(Int, heading: String?, block: String?)
    case attachment(Int)
    case selfLink(heading: String?, block: String?)
    case ambiguous([FileEntry])
    case missing(String)
}

/// Link resolution over one snapshot's tables. The rules, in order:
/// 1. The label after `|` and the subpath after `#` are split off (`LinkTarget`).
/// 2. Paths compare in NFC, case folded; `.md` is optional.
/// 3. A path starting with `./` or `../` is relative to the source note's folder and must match exactly.
/// 4. A path holding `/` that equals a vault-relative path matches it (a leading `/` allows only this).
/// 5. Otherwise any file whose vault-relative path equals the target or ends with `/target` matches.
///    Among several, the one at `<source folder>/<target>` wins, else the single shallowest one
///    (fewest path components), else the link is ambiguous.
/// 6. Aliases are tried only when no file matched, with the same tie-breaks.
/// 7. A target with an extension other than `.md` looks for that file first, then for a note.
extension VaultTables {
    private enum Found {
        case none
        case one(Int)
        case many([Int])
    }

    func resolveMatch(_ raw: String, sourceKey: String?) -> LinkMatch {
        let target = LinkTarget.parse(raw)
        guard !target.path.isEmpty else { return .selfLink(heading: target.heading, block: target.block) }
        var key = target.path.folded
        let rootAnchored = key.hasPrefix("/")
        while key.hasPrefix("/") { key.removeFirst() }
        let relative = key == "." || key == ".." || key.hasPrefix("./") || key.hasPrefix("../")
        let sourceFolder = sourceKey.map(Self.folder(of:))
        let explicitMarkdown = key.hasSuffix(".md")
        let base = explicitMarkdown ? String(key.dropLast(3)) : key
        let lastName = base.split(separator: "/").last.map(String.init) ?? base
        let otherExtension = !explicitMarkdown && Self.hasExtension(lastName)

        let order: [Bool] = otherExtension ? [false, true] : [true]
        for wantsNote in order {
            let fullKey = wantsNote ? base + ".md" : base
            let entries = wantsNote ? noteFiles : attachments
            let found = find(fullKey, byKey: wantsNote ? noteByKey : attachmentByKey,
                             byName: wantsNote ? notesByName : attachmentsByName, entries: entries,
                             relative: relative, rootAnchored: rootAnchored, sourceFolder: sourceFolder)
            switch found {
            case .none: continue
            case .one(let index):
                return wantsNote ? .note(index, heading: heading(target.heading, in: index), block: target.block)
                                 : .attachment(index)
            case .many(let indices):
                return .ambiguous(indices.map { entries[$0] }.sorted(by: Self.byPath))
            }
        }

        if !relative, !rootAnchored, let candidates = notesByAlias[key] ?? notesByAlias[base] {
            let found = pick(candidates, entries: noteFiles) { notes[$0].file.folderKey == sourceFolder }
            switch found {
            case .none: break
            case .one(let index): return .note(index, heading: heading(target.heading, in: index), block: target.block)
            case .many(let indices): return .ambiguous(indices.map { notes[$0].file }.sorted(by: Self.byPath))
            }
        }
        return .missing(target.path)
    }

    private func find(_ fullKey: String, byKey: [String: Int], byName: [String: [Int]], entries: [FileEntry],
                      relative: Bool, rootAnchored: Bool, sourceFolder: String?) -> Found {
        if relative {
            guard let sourceFolder, let joined = Self.join(sourceFolder, fullKey), let index = byKey[joined] else { return .none }
            return .one(index)
        }
        if rootAnchored || fullKey.contains("/") {
            if let index = byKey[fullKey] { return .one(index) }
            if rootAnchored { return .none }
        }
        let name = fullKey.split(separator: "/").last.map(String.init) ?? fullKey
        let suffix = "/" + fullKey
        let candidates = (byName[name] ?? []).filter { entries[$0].key == fullKey || entries[$0].key.hasSuffix(suffix) }
        let preferred = sourceFolder.map { $0.isEmpty ? fullKey : $0 + "/" + fullKey }
        return pick(candidates, entries: entries) { entries[$0].key == preferred }
    }

    /// The tie-break: one candidate wins outright; else the one in the source's folder; else the single
    /// shallowest; else all candidates are returned as ambiguous.
    private func pick(_ candidates: [Int], entries: [FileEntry], isPreferred: (Int) -> Bool) -> Found {
        guard !candidates.isEmpty else { return .none }
        if candidates.count == 1 { return .one(candidates[0]) }
        let preferred = candidates.filter(isPreferred)
        if preferred.count == 1 { return .one(preferred[0]) }
        let pool = preferred.isEmpty ? candidates : preferred
        let depth = pool.map { entries[$0].depth }.min() ?? 0
        let shallowest = pool.filter { entries[$0].depth == depth }
        if shallowest.count == 1 { return .one(shallowest[0]) }
        return .many(candidates)
    }

    /// The heading as written in the note when the link's heading matches one (case folded, spaces
    /// collapsed), else the link's own text.
    func heading(_ wanted: String?, in note: Int) -> String? {
        guard let wanted else { return nil }
        let key = Self.headingKey(wanted)
        return notes[note].headings.first { Self.headingKey($0.text) == key }?.text ?? wanted
    }

    private static func headingKey(_ text: String) -> String {
        text.folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func folder(of key: String) -> String {
        guard let slash = key.lastIndex(of: "/") else { return "" }
        return String(key[..<slash])
    }

    /// Joins a folder key and a relative path, resolving `.` and `..`; nil when it leaves the vault.
    static func join(_ folder: String, _ relative: String) -> String? {
        var parts = folder.split(separator: "/").map(String.init)
        for part in relative.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else {
                parts.append(String(part))
            }
        }
        return parts.joined(separator: "/")
    }

    /// True when a file name ends in a short alphanumeric extension such as `png` or `pdf`.
    static func hasExtension(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        return (1...10).contains(ext.count) && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func byPath(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        lhs.key != rhs.key ? lhs.key < rhs.key : lhs.path < rhs.path
    }
}
