import Foundation

/// An ATX heading found in a note, outside fenced code.
public struct Heading: Sendable, Hashable {
    /// The heading level, 1 to 6.
    public let level: Int
    /// The heading text with the leading and closing `#` marks removed, in NFC.
    public let text: String
    /// The 1-based line number in the file.
    public let line: Int

    /// Makes a heading.
    public init(level: Int, text: String, line: Int) {
        self.level = level
        self.text = text
        self.line = line
    }
}

/// A note found by Open Quickly search, or a reference to a note in the index.
public struct NoteRef: Sendable, Hashable {
    /// The note's file.
    public let url: URL
    /// The note's name: its file name without the extension.
    public let name: String
    /// The note's path relative to the vault root, with its extension.
    public let path: String
    /// The alias that matched the query, when the match came from an alias rather than the name.
    public let matchedAlias: String?

    /// Makes a note reference.
    public init(url: URL, name: String, path: String, matchedAlias: String?) {
        self.url = url
        self.name = name
        self.path = path
        self.matchedAlias = matchedAlias
    }
}

/// One note that links to another, with the first sentence that holds the link.
public struct Backlink: Sendable, Hashable {
    /// The linking note.
    public let source: URL
    /// The linking note's name.
    public let name: String
    /// The linking note's path relative to the vault root.
    public let path: String
    /// The first sentence in the linking note that holds the link, with wiki link markup reduced
    /// to each link's label. A link found only in frontmatter gives its property line instead.
    public let sentence: String
    /// The 1-based line of that sentence.
    public let line: Int
    /// How many links the source note has to the target.
    public let count: Int

    /// Makes a backlink.
    public init(source: URL, name: String, path: String, sentence: String, line: Int, count: Int) {
        self.source = source
        self.name = name
        self.path = path
        self.sentence = sentence
        self.line = line
        self.count = count
    }
}

/// Where a wiki link points, as resolved by `VaultIndex.resolve(_:from:)`.
public enum LinkResolution: Sendable, Equatable {
    /// One file matched. For a note, `heading` is the heading text as written in the note when it
    /// was found (else as written in the link), and `block` is the block id after `#^`.
    /// Non-Markdown files always come back with both set to nil.
    case note(URL, heading: String?, block: String?)
    /// Several files matched equally well, sorted by vault-relative path.
    case ambiguous([URL])
    /// Nothing matched. The value is the link's path as written, without label or heading.
    case missing(String)
}

/// A file in the vault, with its comparison keys precomputed. It keeps no `URL`: an enumerator's URL carries the
/// resource values read during the walk (about 0.8 KB a file with its strings), and a vault can hold tens of
/// thousands of files. `VaultTables.url(of:)` makes the URL when a query hands one out.
struct FileEntry: Sendable {
    /// The vault-relative path as found on disk, in NFC.
    let path: String
    /// `path` case folded.
    let key: String
    /// The path as written on disk, only when it is not already NFC (a name written decomposed); nil otherwise.
    private let diskPath: String?

    /// - Parameter path: the vault-relative path as written on disk.
    init(path: String) {
        let nfc = path.nfc
        // Strings compare by canonical equivalence, so NFC and NFD forms of one name are `==`; compare the bytes.
        let isNFC = nfc.utf8.elementsEqual(path.utf8)
        self.path = isNFC ? path : nfc
        self.diskPath = isNFC ? nil : path
        let folded = path.folded
        self.key = folded.utf8.elementsEqual(self.path.utf8) ? self.path : folded
    }

    /// The last path component case folded, extension included.
    var nameKey: String {
        guard let slash = key.lastIndex(of: "/") else { return key }
        return String(key[key.index(after: slash)...])
    }

    /// The parent folder's key, empty at the vault root.
    var folderKey: String { VaultTables.folder(of: key) }

    /// The number of path components.
    var depth: Int { key.split(separator: "/", omittingEmptySubsequences: true).count }

    /// The file's URL under the vault root, spelled byte for byte as the walk found it. Made from the file system
    /// representation: every path-string initializer, and `appendingPathComponent`, decompose some names (an Arabic
    /// alef with hamza above, U+0623, becomes U+0627 U+0654), which the walk's own URLs never did.
    func url(in root: URL) -> URL {
        let rootPath = root.path
        let full = (rootPath == "/" ? "/" : rootPath + "/") + (diskPath ?? path)
        return full.withCString { URL(fileURLWithFileSystemRepresentation: $0, isDirectory: false, relativeTo: nil) }
    }
}

/// A wiki link found in a note.
struct WikiLink: Sendable {
    /// The text between `[[` and `]]`.
    let raw: String
    let isEmbed: Bool
    let inFrontmatter: Bool
    /// 1-based line number.
    let line: Int
    /// The first sentence holding the link, markup reduced to labels.
    let sentence: String
}

/// Everything the index keeps about one Markdown note.
struct NoteRecord: Sendable {
    let file: FileEntry
    let name: String
    let aliases: [String]
    let headings: [Heading]
    let links: [WikiLink]
}
