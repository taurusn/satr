import Foundation
import Testing
@testable import LinenKit

@Suite("Pin library")
struct PinLibraryTests {
    /// Linen's own fixtures, from this file's place in the repository.
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures")

    @Test("The fixtures serve as two pins, notes and boards, each listing only documents")
    func twoPins() async throws {
        let support = TempFolder()
        let library = FixturePinLibrary(fixtures: Self.fixtures, support: support.url)
        let pins = await library.pins()
        #expect(Set(pins.map(\.id)) == ["fixtures-notes", "fixtures-boards"])
        let notes = await library.files(in: "fixtures-notes")
        #expect(notes.contains { $0.ref.path == "Complete.md" && $0.kind == .note })
        #expect(notes.contains { $0.ref.path == "blocks/arabic.md" })
        #expect(!notes.contains { $0.ref.path.hasPrefix("boards/") })
        #expect(!notes.contains { $0.ref.path.hasSuffix(".png") || $0.ref.path.hasSuffix(".notes.json") })
        let boards = await library.files(in: "fixtures-boards")
        #expect(boards.contains { $0.ref.path == "big-500.canvas" && $0.kind == .board })
        #expect(!boards.contains { $0.ref.path == "gen.js" })
        #expect(pins.allSatisfy { $0.size > 0 && $0.generation == PinGeneration(1) })
    }

    @Test("An open document keeps the generation it opened in after the pin moves on")
    func generations() async throws {
        let support = TempFolder()
        let library = FixturePinLibrary(fixtures: Self.fixtures, support: support.url)
        var changes = library.changes().makeAsyncIterator()
        let doc = try await library.open(PinFileRef(pin: "fixtures-boards", path: "kinds.canvas"))
        #expect(doc.generation == PinGeneration(1))
        library.advance("fixtures-boards")
        #expect(await changes.next() == .generation("fixtures-boards", PinGeneration(2)))
        #expect(doc.generation == PinGeneration(1))
        #expect(library.openGenerations == [PinGeneration(1)])
        let again = try await library.open(PinFileRef(pin: "fixtures-boards", path: "kinds.canvas"))
        #expect(again.generation == PinGeneration(2))
        doc.close()
        doc.close()
        #expect(library.openGenerations == [PinGeneration(2)])
        await #expect(throws: PinLibraryError.self) { try await library.open(PinFileRef(pin: "fixtures-boards", path: "../Complete.md")) }
    }

    @Test("Threads show only for files that changed after they were read")
    func threads() async throws {
        let support = TempFolder()
        let library = FixturePinLibrary(fixtures: Self.fixtures, support: support.url)
        let ref = PinFileRef(pin: "fixtures-notes", path: "Complete.md")
        #expect(await library.files(in: "fixtures-notes").first { $0.ref == ref }?.changedSinceRead == false)
        library.markChanged(ref)
        #expect(await library.files(in: "fixtures-notes").first { $0.ref == ref }?.changedSinceRead == true)
        await library.markRead(ref)
        #expect(await library.files(in: "fixtures-notes").first { $0.ref == ref }?.changedSinceRead == false)
    }

    @Test("References resolve beside the file, then by name in its pin, then in other pins")
    func references() async {
        let support = TempFolder()
        let library = FixturePinLibrary(fixtures: Self.fixtures, support: support.url)
        let from = PinFileRef(pin: "fixtures-notes", path: "Complete.md")
        #expect(await library.resolve("Linked Note", from: from) == .file(PinFileRef(pin: "fixtures-notes", path: "Linked Note.md")))
        #expect(await library.resolve("Linked Note#Heading|label", from: from) == .file(PinFileRef(pin: "fixtures-notes", path: "Linked Note.md")))
        #expect(await library.resolve("satr-test-image.png", from: from) == .file(PinFileRef(pin: "fixtures-notes", path: "satr-test-image.png")))
        #expect(await library.resolve("kinds.canvas", from: from) == .file(PinFileRef(pin: "fixtures-boards", path: "kinds.canvas")))
        #expect(await library.resolve("No Such Note", from: from) == .missing)
    }

    @Test("Titles come from a note's heading, a board's title and a page's title tag")
    func titles() {
        let folder = TempFolder()
        #expect(DocumentTitle.title(of: folder.write("a.md", "---\ntitle: x\n---\n```\n# not this\n```\n# Where it stands\n"), kind: .note) == "Where it stands")
        #expect(DocumentTitle.title(of: folder.write("b.md", "no heading"), kind: .note) == "b")
        #expect(DocumentTitle.title(of: folder.write("c.canvas", #"{"nodes":[],"linen":{"title":"Requests readiness"}}"#), kind: .board) == "Requests readiness")
        #expect(DocumentTitle.title(of: folder.write("d.html", "<html><head><TITLE>Lab &amp; report</TITLE>"), kind: .page) == "Lab & report")
        #expect(DocumentKind(fileName: "x.canvas.notes.json") == nil)
        #expect(DocumentKind(fileName: "x.TXT") == .note)
    }

    @Test("Opened files are copied, listed newest first, replaced by name and removed with their copy")
    func opened() throws {
        let support = TempFolder(), outside = TempFolder()
        let store = OpenedFiles(directory: support.url.appendingPathComponent("Opened"))
        let a = try store.add(copying: outside.write("Plan.md", "# Quarter plan\n"))
        let b = try store.add(copying: outside.write("map.canvas", "{}"))
        #expect(store.all().map(\.id) == [b.id, a.id])
        #expect(a.title == "Quarter plan" && b.kind == .board)
        let a2 = try store.add(copying: outside.write("Plan.md", "# Quarter plan, again\n"))
        #expect(store.all().map(\.id) == [a2.id, b.id])
        #expect(!FileManager.default.fileExists(atPath: store.url(for: a).path))
        store.remove(b.id)
        #expect(store.all().map(\.id) == [a2.id])
        #expect(throws: (any Error).self) { try store.add(copying: outside.write("photo.png", "x")) }
    }
}
