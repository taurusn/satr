import Foundation
import Testing
@testable import LinenKit

/// Lane linen-lighter (2026-11-24): the index keeps no URLs, parses plain UTF-8 notes in place, and indexes live only
/// while a document uses them. Every result must stay exactly what it was.
@Suite("Vault index weight")
struct VaultIndexWeightTests {
    /// The walk's own URL for every file in the fixture, keyed by NFC vault-relative path.
    private func walkedURLs(_ root: URL) -> [String: URL] {
        let canonical = Paths.canonical(root)
        var out: [String: URL] = [:]
        let enumerator = FileManager.default.enumerator(at: canonical, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])!
        for case let url as URL in enumerator where !url.hasDirectoryPath {
            out[String(url.path.dropFirst(canonical.path.count + 1)).nfc] = url
        }
        return out
    }

    @Test("URLs handed out are the walk's own, byte for byte, for NFC and NFD Arabic names")
    func urlsAsWalked() async {
        let fixture = ResolutionFixture()
        let index = await fixture.index()
        let walked = walkedURLs(fixture.root)
        let source = fixture.url("notes/Source.md")
        let cases = [
            ("arabic/" + ArabicNames.management, "arabic/" + ArabicNames.management + ".md"),   // NFC on disk, إ decomposable
            ("arabic/" + ArabicNames.questions, "arabic/" + ArabicNames.questions + ".md"),     // NFD on disk
            ("arabic/" + ArabicNames.conference, "arabic/" + ArabicNames.conference + ".md"),   // NFD on disk
            ("wiki/projects/Plan", "wiki/projects/Plan.md"),
            ("assets/image.png", "assets/image.png"),
        ]
        for (link, path) in cases {
            guard case let .note(url, _, _) = index.resolve(link, from: source) else {
                Issue.record("\(link) did not resolve")
                continue
            }
            let expected = walked[path.nfc]
            #expect(expected != nil, "\(path) not walked")
            #expect(url == expected, "\(link)")
            #expect(url.absoluteString == expected?.absoluteString, "\(link)")
        }
        // Search and backlinks hand out the same URLs.
        let found = index.search(ArabicNames.management, limit: 1).first?.url
        #expect(found?.absoluteString == walked[("arabic/" + ArabicNames.management + ".md").nfc]?.absoluteString)
        let backlink = index.backlinks(to: fixture.url("notes/Dup.md"), limit: 5).first?.source
        #expect(backlink?.absoluteString == walked["notes/Source.md"]?.absoluteString)
    }

    @Test("A file name with a letter every path initializer decomposes keeps its spelling")
    func precomposedHamza() async {
        let folder = TempFolder()
        folder.makeFolder(".obsidian")
        let name = "كلمات الأغاني"   // الأ: U+0623, precomposed on disk
        folder.writeRaw(folder: "songs", name: name + ".json", "{}")
        folder.write("Index.md", "See [[\(name).json]].\n")
        let index = VaultIndex(vault: Vault(root: folder.url, kind: .obsidian))
        await index.build()
        let walked = walkedURLs(folder.url)["songs/\(name).json".nfc]
        guard case let .note(url, _, _) = index.resolve("\(name).json", from: folder.url.appendingPathComponent("Index.md")) else {
            Issue.record("did not resolve")
            return
        }
        #expect(url.absoluteString == walked?.absoluteString)
        #expect(url.absoluteString.contains("%D8%A3"))   // U+0623, not U+0627 U+0654
    }

    private func summary(_ note: ParsedNote) -> String {
        var lines = note.aliases.map { "alias \($0)" }
        lines += note.headings.map { "heading \($0.level) \($0.line) \($0.text)" }
        lines += note.links.map { "link \($0.raw) \($0.isEmbed) \($0.inFrontmatter) \($0.line) \($0.sentence)" }
        return lines.joined(separator: "\n")
    }

    @Test("Parsing a note's bytes in place gives what decoding it first gives, in every encoding")
    func parseInPlace() {
        let text = "---\naliases: [One, \"اثنان\"]\nrelated: \"[[Plan]]\"\n---\n# العنوان\n\nSee [[Ferry#Goals|the goals]] and ![[pic.png]].\r\n\n```\n[[not a link]]\n```\n## Two\nأسئلة [[أسئلة]] `[[code]]`\n"
        var samples: [(String, Data)] = [
            ("utf8", Data(text.utf8)),
            ("utf8 bom", Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)),
            ("utf16 le", Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!),
            ("utf16 be", Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!),
            ("empty", Data()),
            ("broken utf8", Data(text.utf8) + Data([0xC3]) + Data("\n# Tail [[Last]]\n".utf8)),
            ("ascii", Data("# Plain\n[[A]] [[B|b]]\n".utf8)),
        ]
        if let arabic = "# عنوان\n[[ملاحظة]]\n".data(using: TextDecoder.windowsArabic) { samples.append(("windows-1256", arabic)) }
        for (label, data) in samples {
            let decoded = NoteParser.parse(TextDecoder.decode(data).text)
            let inPlace = NoteParser.parse(data: data)
            #expect(summary(inPlace) == summary(decoded), "\(label)")
        }
        #expect(!summary(NoteParser.parse(data: Data(text.utf8))).isEmpty)
    }

    @Test("UTF-8 validity matches String(validating:) on edge cases")
    func utf8Validity() {
        let cases: [[UInt8]] = [
            [], Array("plain".utf8), Array("عربي".utf8), Array("😀".utf8),
            [0xC0, 0x80], [0xE0, 0x80, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80],
            [0xE2, 0x82], [0x80], [0xFF], [0x61, 0xC3], [0xEF, 0xBB, 0xBF, 0x61], [0x00],
        ]
        for bytes in cases {
            let valid = bytes.withUnsafeBufferPointer { NoteParser.isValidUTF8($0) }
            #expect(valid == (String(validating: bytes, as: UTF8.self) != nil), "\(bytes)")
        }
    }

    @Test("An index lives while a document uses it; the last one let go is kept until another is")
    func cacheKeepsOne() {
        var made = 0
        let cache = VaultIndexCache { vault in made += 1; return VaultIndex(vault: vault) }
        let a = Vault(root: URL(fileURLWithPath: "/tmp/linen-a", isDirectory: true), kind: .folder)
        let b = Vault(root: URL(fileURLWithPath: "/tmp/linen-b", isDirectory: true), kind: .folder)

        var first: VaultIndex? = cache.acquire(a)
        var second: VaultIndex? = cache.acquire(a)
        #expect(first === second)
        #expect(made == 1)
        weak var weakA = first
        #expect(!cache.release(second!))          // one document still uses it
        second = nil
        #expect(cache.kept == nil)
        #expect(cache.release(first!))            // the last one: kept
        first = nil
        #expect(weakA != nil)
        #expect(cache.kept === weakA)
        #expect(cache.acquire(a) === weakA)       // reopened at once, not rebuilt
        #expect(made == 1)
        cache.release(weakA!)

        var other: VaultIndex? = cache.acquire(b)
        cache.release(other!)                    // b is kept now, a is let go
        other = nil
        #expect(weakA == nil)
        #expect(cache.kept?.vault == b)
        #expect(cache.liveCount == 1)
        #expect(!cache.release(cache.kept!))      // a release without an acquire changes nothing
    }

    @Test("Lookups never keep an index; the kept one goes after its time unused")
    func cacheLookupsAndExpiry() {
        let cache = VaultIndexCache { VaultIndex(vault: $0) }
        let a = Vault(root: URL(fileURLWithPath: "/tmp/linen-a", isDirectory: true), kind: .folder)
        let b = Vault(root: URL(fileURLWithPath: "/tmp/linen-b", isDirectory: true), kind: .folder)

        var lookup: VaultIndex? = cache.index(for: a)
        weak var weakLookup = lookup
        #expect(cache.existing(for: a) === lookup)
        lookup = nil
        #expect(weakLookup == nil)
        #expect(cache.existing(for: a) == nil)
        #expect(cache.existing(for: b) == nil)    // existing(for:) never makes one
        #expect(cache.liveCount == 0)

        let start = Date()
        var used: VaultIndex? = cache.acquire(b)
        weak var weakUsed = used
        cache.release(used!, now: start)
        used = nil
        cache.dropKept(olderThan: 600, now: start.addingTimeInterval(599))
        #expect(weakUsed != nil)
        cache.dropKept(olderThan: 600, now: start.addingTimeInterval(600))
        #expect(weakUsed == nil)
        #expect(cache.kept == nil)
    }
}
