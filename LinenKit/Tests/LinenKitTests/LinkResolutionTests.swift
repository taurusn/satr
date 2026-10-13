import Foundation
import Testing
@testable import LinenKit

@Suite("Link resolution")
struct LinkResolutionTests {
    let fixture = ResolutionFixture()

    private func resolve(_ target: String, from source: String) async -> String {
        let index = await fixture.index()
        return describe(index.resolve(target, from: fixture.url(source)), root: fixture.root)
    }

    @Test("(a) a path from the vault root matches exactly, any case, .md optional")
    func rootPath() async {
        let index = await fixture.index()
        let source = fixture.url("journal/Entry.md")
        for target in ["wiki/projects/Ferry", "wiki/projects/Ferry.md", "WIKI/Projects/FERRY"] {
            #expect(describe(index.resolve(target, from: source), root: fixture.root) == "note wiki/projects/Ferry.md")
        }
        // A leading slash allows only the vault-root path, even where the source folder has its own Ferry.
        #expect(describe(index.resolve("/Ferry", from: fixture.url("wiki/projects/Plan.md")), root: fixture.root) == "note Ferry.md")
    }

    @Test("(b) ./ and ../ are relative to the source note's folder")
    func relativePaths() async {
        let index = await fixture.index()
        let source = fixture.url("notes/Source.md")
        #expect(describe(index.resolve("../wiki/projects/Plan", from: source), root: fixture.root) == "note wiki/projects/Plan.md")
        #expect(describe(index.resolve("./Dup", from: source), root: fixture.root) == "note notes/Dup.md")
        #expect(describe(index.resolve("./Missing", from: source), root: fixture.root) == "missing ./Missing")
        #expect(describe(index.resolve("../../Ferry", from: source), root: fixture.root) == "missing ../../Ferry")
    }

    @Test("(c) a bare name prefers the source's folder, then the single shallowest path")
    func bareNames() async {
        #expect(await resolve("Ferry", from: "journal/Entry.md") == "note Ferry.md")
        #expect(await resolve("Ferry", from: "wiki/projects/Plan.md") == "note wiki/projects/Ferry.md")
        #expect(await resolve("ferry.md", from: "journal/Entry.md") == "note Ferry.md")
    }

    @Test("(c) a partial path matches the end of a vault path")
    func partialPath() async {
        #expect(await resolve("projects/Ferry", from: "journal/Entry.md") == "note wiki/projects/Ferry.md")
        #expect(await resolve("projects/Plan.md", from: "Ferry.md") == "note wiki/projects/Plan.md")
    }

    @Test("(c) duplicate names at the same depth are ambiguous unless one is in the source's folder")
    func duplicates() async {
        #expect(await resolve("Dup", from: "journal/Entry.md") == "ambiguous notes/Dup.md, other/Dup.md")
        #expect(await resolve("Dup", from: "notes/Source.md") == "note notes/Dup.md")
        #expect(await resolve("Dup", from: "other/Dup.md") == "note other/Dup.md")
    }

    @Test("Names differing only by case compare equal")
    func caseOnly() async {
        #expect(await resolve("readme", from: "Ferry.md") == "ambiguous a/Readme.md, b/README.md")
        #expect(await resolve("README", from: "a/Note.md") == "note a/Readme.md")
        #expect(await resolve("ReadMe", from: "b/README.md") == "note b/README.md")
    }

    @Test("Labels, headings and block ids are split off")
    func subpaths() async {
        let index = await fixture.index()
        let source = fixture.url("journal/Entry.md")
        func check(_ target: String, _ expected: String) {
            #expect(describe(index.resolve(target, from: source), root: fixture.root) == expected, "\(target)")
        }
        check("Ferry#Goals|the plan", "note Ferry.md #Goals")
        check("Ferry#goals", "note Ferry.md #Goals")
        check("Ferry#^abc123", "note Ferry.md ^abc123")
        check("Ferry#Unknown heading", "note Ferry.md #Unknown heading")
        check("wiki/projects/Ferry#Risks|risks", "note wiki/projects/Ferry.md #Risks")
        check("Ferry\\|in a table", "note Ferry.md")
        check(" Ferry ", "note Ferry.md")
    }

    @Test("A link to a heading in the same note resolves to the source")
    func selfLink() async {
        #expect(await resolve("#Goals", from: "Ferry.md") == "note Ferry.md #Goals")
        #expect(await resolve("#^block1", from: "Ferry.md") == "note Ferry.md ^block1")
    }

    @Test("(d) aliases match only when no file name matches")
    func aliases() async {
        #expect(await resolve("Abu Hatim", from: "journal/Entry.md") == "note wiki/people/Hatim.md")
        #expect(await resolve("abu hatim", from: "journal/Entry.md") == "note wiki/people/Hatim.md")
        #expect(await resolve("H. Alshehri", from: "journal/Entry.md") == "note wiki/people/Hatim.md")
        #expect(await resolve("Plan", from: "journal/Entry.md") == "note wiki/projects/Plan.md")
        #expect(await resolve("Shared", from: "journal/Entry.md") == "ambiguous shared1/One.md, shared2/Two.md")
        #expect(await resolve("Shared", from: "shared2/Two.md") == "note shared2/Two.md")
    }

    @Test("(e) files with another extension resolve by the same rules, without heading")
    func attachments() async {
        #expect(await resolve("image.png", from: "journal/Entry.md") == "note assets/image.png")
        #expect(await resolve("IMAGE.PNG#x", from: "journal/Entry.md") == "note assets/image.png")
        #expect(await resolve("assets/image.png", from: "journal/Entry.md") == "note assets/image.png")
        #expect(await resolve("pic.png", from: "journal/Entry.md") == "note a/pic.png")
        #expect(await resolve("pic.png", from: "b/c/x.md") == "note b/c/pic.png")
        #expect(await resolve("c/pic.png", from: "journal/Entry.md") == "note b/c/pic.png")
    }

    @Test("NFD-encoded Arabic file names with hamza letters resolve from NFC links and back")
    func arabicNormalization() async throws {
        let rawNames = fixture.folder.rawNames(in: "arabic")
        let nfdBytes = Array((ArabicNames.nfd(ArabicNames.questions) + ".md").utf8)
        let nfcBytes = Array((ArabicNames.questions + ".md").utf8)
        try #require(nfdBytes != nfcBytes)
        #expect(rawNames.contains(nfdBytes), "the fixture name is NFD on disk")
        #expect(!rawNames.contains(nfcBytes))

        let source = "journal/Entry.md"
        let questions = "note arabic/\(ArabicNames.questions).md"
        #expect(await resolve(ArabicNames.questions, from: source) == questions)
        #expect(await resolve(ArabicNames.nfd(ArabicNames.questions), from: source) == questions)
        #expect(await resolve("arabic/" + ArabicNames.questions, from: source) == questions)
        #expect(await resolve(ArabicNames.faq, from: source) == questions)
        #expect(await resolve(ArabicNames.management, from: source) == "note arabic/\(ArabicNames.management).md")
        #expect(await resolve(ArabicNames.nfd(ArabicNames.management), from: source) == "note arabic/\(ArabicNames.management).md")
        #expect(await resolve(ArabicNames.conference, from: source) == "note arabic/\(ArabicNames.conference).md")
        #expect(await resolve(ArabicNames.last, from: source) == "note arabic/\(ArabicNames.last).md")
    }

    @Test("Arabic headings match in either normal form and come back as written in the note")
    func arabicHeadings() async {
        let index = await fixture.index()
        let source = fixture.url("journal/Entry.md")
        let expected = "note arabic/\(ArabicNames.questions).md #\(ArabicNames.intro)"
        #expect(describe(index.resolve("\(ArabicNames.questions)#\(ArabicNames.intro)", from: source), root: fixture.root) == expected)
        let nfdLink = ArabicNames.nfd("\(ArabicNames.questions)#\(ArabicNames.intro)")
        #expect(describe(index.resolve(nfdLink, from: source), root: fixture.root) == expected)
        let headings = index.headings(for: fixture.url("arabic/" + ArabicNames.questions + ".md")).map(\.text)
        #expect(headings == [ArabicNames.questions, ArabicNames.intro])
    }

    @Test("Unresolved links, including notes in skipped folders, are missing")
    func missing() async {
        #expect(await resolve("Nowhere", from: "journal/Entry.md") == "missing Nowhere")
        #expect(await resolve("Nowhere#Heading|label", from: "journal/Entry.md") == "missing Nowhere")
        #expect(await resolve("Ghost", from: "journal/Entry.md") == "missing Ghost")
        #expect(await resolve("Hidden", from: "journal/Entry.md") == "missing Hidden")
        #expect(await resolve("wiki/Ferry", from: "journal/Entry.md") == "missing wiki/Ferry")
    }
}
