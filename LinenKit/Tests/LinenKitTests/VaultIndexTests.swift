import Foundation
import Testing
@testable import LinenKit

@Suite("Vault locator")
struct VaultLocatorTests {
    @Test("The nearest .obsidian wins over a nearer .git; then .git; then the file's folder")
    func detection() {
        let folder = TempFolder()
        folder.makeFolder("vault/.obsidian")
        folder.makeFolder("vault/repo/.git")
        let inRepo = folder.write("vault/repo/docs/PRD.md", "x")
        let vault = VaultLocator.vault(for: inRepo)
        #expect(vault.kind == .obsidian)
        #expect(samePath(vault.root, folder.url.appendingPathComponent("vault")))

        folder.makeFolder("code/.git")
        let inCode = folder.write("code/src/README.md", "x")
        #expect(VaultLocator.vault(for: inCode) == Vault(root: folder.url.appendingPathComponent("code"), kind: .git))

        folder.write("loose/sub/.git", "gitdir: elsewhere")   // a worktree's .git file counts
        let inWorktree = folder.write("loose/sub/a.md", "x")
        #expect(VaultLocator.vault(for: inWorktree).kind == .git)

        let plain = folder.write("plain/note.md", "x")
        let found = VaultLocator.vault(for: plain)
        #expect(found.kind == .folder || found.kind == .git)
        if found.kind == .folder { #expect(samePath(found.root, folder.url.appendingPathComponent("plain"))) }
    }

    @Test("Symlinks are resolved before searching")
    func symlinks() throws {
        let folder = TempFolder()
        folder.makeFolder("real/.obsidian")
        folder.write("real/notes/a.md", "x")
        try FileManager.default.createSymbolicLink(at: folder.url.appendingPathComponent("link.md"),
                                                   withDestinationURL: folder.url.appendingPathComponent("real/notes/a.md"))
        let vault = VaultLocator.vault(for: folder.url.appendingPathComponent("link.md"))
        #expect(vault.kind == .obsidian)
        #expect(samePath(vault.root, folder.url.appendingPathComponent("real")))
    }
}

@Suite("Vault index")
struct VaultIndexTests {
    @Test("Counts notes, skips hidden folders and node_modules, names notes")
    func counts() async {
        let fixture = ResolutionFixture()
        let index = await fixture.index()
        #expect(index.noteCount == 17)
        #expect(index.noteName(for: fixture.url("wiki/projects/Ferry.md")) == "Ferry")
        #expect(index.noteName(for: fixture.url("arabic/" + ArabicNames.questions + ".md")) == ArabicNames.questions)
        #expect(index.noteName(for: fixture.url("elsewhere/Unknown Note.md")) == "Unknown Note")
        #expect(index.aliases(for: fixture.url("wiki/people/Hatim.md")) == ["Abu Hatim", "H. Alshehri", "Plan"])
    }

    @Test("Search ranks prefix, then word start, then subsequence; shorter first")
    func searchRanking() async {
        let folder = TempFolder()
        for name in ["Ferry", "Ferry PRD", "Linen Ferry notes", "Free Fair", "Offer", "Unrelated"] {
            folder.write("\(name).md", "x")
        }
        folder.write("people/Wolf.md", "---\naliases: [Dheeb the wolf]\n---\n")
        let index = VaultIndex(vault: Vault(root: folder.url, kind: .folder))
        await index.build()
        #expect(index.search("fer", limit: 10).map(\.name) == ["Ferry", "Ferry PRD", "Linen Ferry notes", "Offer", "Free Fair"])
        #expect(index.search("FER", limit: 2).map(\.name) == ["Ferry", "Ferry PRD"])
        #expect(index.search("lfn", limit: 10).map(\.name) == ["Linen Ferry notes"])
        let alias = index.search("dheeb", limit: 5)
        #expect(alias.map(\.name) == ["Wolf"])
        #expect(alias.first?.matchedAlias == "Dheeb the wolf")
        #expect(alias.first?.path == "people/Wolf.md")
        #expect(index.search("wolf", limit: 5).first?.matchedAlias == nil)
        #expect(index.search("   ", limit: 5).isEmpty)
        #expect(index.search("zzz", limit: 5).isEmpty)
    }

    @Test("Search folds case and Unicode normal forms, including NFD Arabic names")
    func searchArabic() async {
        let fixture = ResolutionFixture()
        let index = await fixture.index()
        let prefix = String(ArabicNames.questions.prefix(2))
        #expect(index.search(prefix, limit: 5).first?.name.nfc == ArabicNames.questions)
        #expect(index.search(ArabicNames.nfd(prefix), limit: 5).first?.name.nfc == ArabicNames.questions)
        #expect(index.search("الشائعة", limit: 5).first?.matchedAlias == ArabicNames.faq)
        #expect(index.search("readme", limit: 5).map(\.path).sorted() == ["a/Readme.md", "b/README.md"])
    }

    @Test("Backlinks: one per source note, first sentence, labels, frontmatter fallback, no self links")
    func backlinks() async {
        let folder = TempFolder()
        folder.makeFolder(".obsidian")
        let target = folder.write("wiki/Target.md", "# Target\nSelf [[Target]].\n")
        folder.write("Beta.md", "Intro line. Then [[wiki/Target|the target]] matters. Later [[Target#H]] again.\n")
        folder.write("alpha.md", "---\nrelated: \"[[Target]]\"\n---\nNo body link.\n")
        folder.write("Gamma.md", "---\nup: \"[[Target]]\"\n---\nBody mentions ![[Target]] as an embed.\n")
        folder.write("Delta.md", "Code `[[Target]]` only.\n")
        let index = VaultIndex(vault: Vault(root: folder.url, kind: .obsidian))
        await index.build()

        let links = index.backlinks(to: target, limit: 10)
        #expect(links.map(\.name) == ["alpha", "Beta", "Gamma"])
        #expect(links.map(\.count) == [1, 2, 2])
        #expect(links[0].sentence == "related: Target")
        #expect(links[1].sentence == "Then the target matters.")
        #expect(links[1].line == 1)
        #expect(links[2].sentence == "Body mentions Target as an embed.")
        #expect(index.backlinkCount(to: target) == 3)
        #expect(index.backlinks(to: target, limit: 2).count == 2)
        #expect(index.backlinks(to: folder.url.appendingPathComponent("Beta.md"), limit: 10).isEmpty)
    }

    @Test("Updates add, change and remove notes and refresh resolution and backlinks")
    func updates() async throws {
        let folder = TempFolder()
        folder.makeFolder(".obsidian")
        let source = folder.write("Source.md", "Links to [[Fresh]].\n")
        let index = VaultIndex(vault: Vault(root: folder.url, kind: .obsidian))
        await index.build()
        #expect(index.noteCount == 1)
        #expect(describe(index.resolve("Fresh", from: source), root: folder.url) == "missing Fresh")

        let fresh = folder.write("notes/Fresh.md", "# Fresh\n")
        await index.update(changed: [fresh])
        #expect(index.noteCount == 2)
        #expect(describe(index.resolve("Fresh", from: source), root: folder.url) == "note notes/Fresh.md")
        #expect(index.backlinks(to: fresh, limit: 5).map(\.name) == ["Source"])

        let twin = folder.write("other/Fresh.md", "twin")
        await index.update(changed: [twin])
        #expect(describe(index.resolve("Fresh", from: source), root: folder.url) == "ambiguous notes/Fresh.md, other/Fresh.md")

        try writeInPlace(source, "No links now.\n")
        await index.update(changed: [source])
        #expect(index.backlinks(to: fresh, limit: 5).isEmpty)

        try FileManager.default.removeItem(at: folder.url.appendingPathComponent("other"))
        await index.update(changed: [folder.url.appendingPathComponent("other")])
        #expect(index.noteCount == 2)
        #expect(describe(index.resolve("Fresh", from: source), root: folder.url) == "note notes/Fresh.md")

        folder.write("added/Deep/One.md", "x")
        folder.write("added/Two.md", "x")
        await index.update(changed: [folder.url.appendingPathComponent("added")])
        #expect(index.noteCount == 4)

        folder.write(".hidden/Secret.md", "x")
        await index.update(changed: [folder.url.appendingPathComponent(".hidden/Secret.md"), URL(fileURLWithPath: "/tmp/outside.md")])
        #expect(index.noteCount == 4)
    }

    @Test("Queries stay fast on the calling thread")
    func queryCost() async {
        let folder = TempFolder()
        GeneratedVault.write(into: folder, notes: 500)
        let index = VaultIndex(vault: Vault(root: folder.url, kind: .obsidian))
        await index.build()
        let source = folder.url.appendingPathComponent("area-0/Note 0.md")
        let start = Date()
        for round in 0..<100 {
            _ = index.resolve("Note \(round * 3)", from: source)
            _ = index.search("note \(round)", limit: 20)
            _ = index.backlinks(to: folder.url.appendingPathComponent("area-\(round % 10)/Note \(round).md"), limit: 10)
        }
        let perRound = Date().timeIntervalSince(start) / 100 * 1000
        print("VaultIndex query round (resolve + search + backlinks) on 500 notes: \(String(format: "%.2f", perRound)) ms")
        #expect(perRound < 20)
    }
}
