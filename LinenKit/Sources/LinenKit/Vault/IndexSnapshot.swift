import Foundation

/// One immutable state of the vault index. Queries take the current snapshot under a short lock
/// and then read it freely; builds and updates make a new one and swap it in.
final class IndexSnapshot: Sendable {
    let tables: VaultTables
    /// Backlinks keyed by the target's file key, one group per source note.
    let incoming: [String: [VaultTables.BacklinkGroup]]

    init(root: URL, notes: [NoteRecord], attachments: [FileEntry]) {
        let tables = VaultTables(root: root, notes: notes, attachments: attachments)
        self.tables = tables
        self.incoming = tables.computeIncoming()
    }

    static func empty(root: URL) -> IndexSnapshot {
        IndexSnapshot(root: root, notes: [], attachments: [])
    }
}

/// The lookup tables of one snapshot: notes and other files sorted by path, with maps by path,
/// by file name and by alias.
struct VaultTables: Sendable {
    struct SearchEntry: Sendable {
        let note: Int
        let text: String
        let key: String
        let scalars: [Unicode.Scalar]
        let length: Int
        let isAlias: Bool
    }

    struct BacklinkGroup: Sendable {
        let source: Int
        let sentence: String
        let line: Int
        let count: Int
    }

    let root: URL
    let rootKey: String
    let notes: [NoteRecord]
    /// `notes[i].file`, kept as its own array so resolution never rebuilds it.
    let noteFiles: [FileEntry]
    let attachments: [FileEntry]
    let noteByKey: [String: Int]
    let notesByName: [String: [Int]]
    let attachmentByKey: [String: Int]
    let attachmentsByName: [String: [Int]]
    let notesByAlias: [String: [Int]]
    let searchEntries: [SearchEntry]

    init(root: URL, notes: [NoteRecord], attachments: [FileEntry]) {
        self.root = root
        self.rootKey = root.path.folded
        self.notes = notes.sorted { $0.file.key < $1.file.key }
        self.noteFiles = self.notes.map(\.file)
        self.attachments = attachments.sorted { $0.key < $1.key }

        var noteByKey: [String: Int] = [:]
        var notesByName: [String: [Int]] = [:]
        var notesByAlias: [String: [Int]] = [:]
        var search: [SearchEntry] = []
        for (index, note) in self.notes.enumerated() {
            noteByKey[note.file.key] = index
            notesByName[note.file.nameKey, default: []].append(index)
            search.append(Self.entry(index, note.name, isAlias: false))
            for alias in note.aliases {
                let key = alias.folded
                if notesByAlias[key]?.contains(index) != true { notesByAlias[key, default: []].append(index) }
                search.append(Self.entry(index, alias, isAlias: true))
            }
        }
        var attachmentByKey: [String: Int] = [:]
        var attachmentsByName: [String: [Int]] = [:]
        for (index, file) in self.attachments.enumerated() {
            attachmentByKey[file.key] = index
            attachmentsByName[file.nameKey, default: []].append(index)
        }
        self.noteByKey = noteByKey
        self.notesByName = notesByName
        self.notesByAlias = notesByAlias
        self.attachmentByKey = attachmentByKey
        self.attachmentsByName = attachmentsByName
        self.searchEntries = search
    }

    private static func entry(_ note: Int, _ text: String, isAlias: Bool) -> SearchEntry {
        let key = text.folded
        return SearchEntry(note: note, text: text, key: key, scalars: Array(key.unicodeScalars),
                           length: text.count, isAlias: isAlias)
    }

    /// Resolves every link once and groups the results by target, one group per source note. The
    /// group's sentence is the first body sentence, else the first frontmatter line.
    func computeIncoming() -> [String: [BacklinkGroup]] {
        var groups: [String: [BacklinkGroup]] = [:]
        for (sourceIndex, note) in notes.enumerated() {
            var perTarget: [String: (sentence: String, line: Int, inFrontmatter: Bool, count: Int)] = [:]
            var order: [String] = []
            for link in note.links {
                guard let target = resolvedKey(link.raw, sourceKey: note.file.key), target != note.file.key else { continue }
                if var existing = perTarget[target] {
                    existing.count += 1
                    if existing.inFrontmatter, !link.inFrontmatter {
                        existing.sentence = link.sentence
                        existing.line = link.line
                        existing.inFrontmatter = false
                    }
                    perTarget[target] = existing
                } else {
                    perTarget[target] = (link.sentence, link.line, link.inFrontmatter, 1)
                    order.append(target)
                }
            }
            for target in order {
                guard let found = perTarget[target] else { continue }
                groups[target, default: []].append(
                    BacklinkGroup(source: sourceIndex, sentence: found.sentence, line: found.line, count: found.count))
            }
        }
        for key in groups.keys {
            groups[key]?.sort { lhs, rhs in
                let left = notes[lhs.source], right = notes[rhs.source]
                let leftName = left.name.folded, rightName = right.name.folded
                return leftName != rightName ? leftName < rightName : left.file.key < right.file.key
            }
        }
        return groups
    }

    /// The file key a link resolves to, when it resolves to exactly one file.
    private func resolvedKey(_ raw: String, sourceKey: String) -> String? {
        switch resolveMatch(raw, sourceKey: sourceKey) {
        case .note(let index, _, _): return notes[index].file.key
        case .attachment(let index): return attachments[index].key
        case .selfLink, .ambiguous, .missing: return nil
        }
    }

    /// The vault-relative key for a URL, or nil when it lies outside the vault.
    func relativeKey(for url: URL) -> String? {
        let prefix = rootKey == "/" ? "/" : rootKey + "/"
        let direct = url.standardizedFileURL.path.folded
        if direct.hasPrefix(prefix) { return String(direct.dropFirst(prefix.count)) }
        let canonical = Paths.canonical(url).path.folded
        if canonical.hasPrefix(prefix) { return String(canonical.dropFirst(prefix.count)) }
        return nil
    }
}
