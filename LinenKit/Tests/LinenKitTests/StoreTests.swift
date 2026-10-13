import Foundation
import Testing
@testable import LinenKit

@Suite("Stores")
struct StoreTests {
    private func place(_ index: Int, quote: String = "a quote") -> Place {
        Place(blockHash: "hash\(index)", blockIndex: index, offset: 0.25, quote: quote, zoom: 1.2, atEnd: false,
              date: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index)))
    }

    @Test("File keys come from volume and file ID, survive renames, and fall back to the path")
    func fileKeys() throws {
        let folder = TempFolder()
        let file = folder.write("a.md", "x")
        let key = FileKey.make(for: file)
        #expect(key.hasPrefix("id:"))
        let renamed = folder.url.appendingPathComponent("b.md")
        try FileManager.default.moveItem(at: file, to: renamed)
        #expect(FileKey.make(for: renamed) == key)
        #expect(FileKey.make(for: folder.write("c.md", "y")) != key)
        let missing = folder.url.appendingPathComponent("missing.md")
        #expect(FileKey.make(for: missing) == "path:" + missing.standardizedFileURL.path)
    }

    @Test("Bookmarks find a renamed and a moved file")
    func bookmarks() throws {
        let folder = TempFolder()
        let file = folder.write("Original.md", "x")
        let bookmark = try #require(FileIdentity.bookmark(for: file))
        let renamed = folder.url.appendingPathComponent("Renamed by Obsidian.md")
        try FileManager.default.moveItem(at: file, to: renamed)
        let resolved = try #require(FileIdentity.resolve(bookmark))
        #expect(samePath(resolved.url, renamed))

        folder.makeFolder("archive")
        let moved = folder.url.appendingPathComponent("archive/Renamed by Obsidian.md")
        try FileManager.default.moveItem(at: renamed, to: moved)
        #expect(samePath(try #require(FileIdentity.resolve(bookmark)).url, moved))

        try FileManager.default.removeItem(at: moved)
        #expect(FileIdentity.resolve(bookmark) == nil)
        #expect(FileIdentity.resolve(Data("not a bookmark".utf8)) == nil)
    }

    @Test("Places persist through flush and a new store")
    func placesPersist() {
        let folder = TempFolder()
        let store = PlaceStore(directory: folder.url)
        store.set(place(1), forKey: "k1")
        store.set(place(2, quote: "سطر"), forKey: "k2")
        store.flush()
        let reopened = PlaceStore(directory: folder.url)
        #expect(reopened.place(forKey: "k1") == place(1))
        #expect(reopened.place(forKey: "k2") == place(2, quote: "سطر"))
        #expect(reopened.count == 2)
        reopened.remove(forKey: "k1")
        #expect(reopened.place(forKey: "k1") == nil)
    }

    @Test("Writes are debounced: nothing at once, written within a second")
    func debounced() async {
        let folder = TempFolder()
        let store = PlaceStore(directory: folder.url)
        let file = folder.url.appendingPathComponent("places.json")
        store.set(place(1), forKey: "k1")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await waitUntil(timeout: 1.5) { FileManager.default.fileExists(atPath: file.path) })
        #expect(PlaceStore(directory: folder.url).place(forKey: "k1") == place(1))
    }

    @Test("The least recently used file is evicted, and reads count as use")
    func eviction() {
        let folder = TempFolder()
        let store = PlaceStore(directory: folder.url, capacity: 3)
        store.set(place(1), forKey: "a")
        store.set(place(2), forKey: "b")
        store.set(place(3), forKey: "c")
        _ = store.place(forKey: "a")
        store.set(place(4), forKey: "d")
        #expect(store.count == 3)
        #expect(store.place(forKey: "b") == nil)
        #expect(store.place(forKey: "a") != nil)
        store.flush()
        let reopened = PlaceStore(directory: folder.url, capacity: 3)
        #expect(reopened.count == 3)
        #expect(reopened.place(forKey: "b") == nil)
    }

    @Test("At most 500 files by default")
    func defaultCapacity() {
        let folder = TempFolder()
        let store = PlaceStore(directory: folder.url)
        for index in 0...500 { store.set(place(index), forKey: "key\(index)") }
        #expect(store.count == 500)
        #expect(store.place(forKey: "key0") == nil)
        #expect(store.place(forKey: "key500") == place(500))
    }

    @Test("A place is found after an atomic save changes the file ID, and after a rename")
    func placeByURL() throws {
        let folder = TempFolder()
        let file = folder.write("PRD.md", "v1")
        let store = PlaceStore(directory: folder.url.appendingPathComponent("support"))
        store.set(place(7), for: file)
        let oldKey = FileKey.make(for: file)
        try Data("v2".utf8).write(to: file, options: .atomic)
        #expect(FileKey.make(for: file) != oldKey)
        #expect(store.place(for: file) == place(7))
        #expect(store.place(forKey: FileKey.make(for: file)) == place(7), "the entry moved to the new key")
        #expect(store.count == 1)

        let renamed = folder.url.appendingPathComponent("PRD renamed.md")
        try FileManager.default.moveItem(at: file, to: renamed)
        #expect(store.place(for: renamed) == place(7))
        store.set(place(8), for: renamed)
        #expect(store.count == 1)
    }

    @Test("Baselines keep at most 20,000 hashes and 500 files, and persist")
    func baselines() {
        let folder = TempFolder()
        let store = BaselineStore(directory: folder.url)
        let many = (0..<20_050).map { "h\($0)" }
        store.set(many, forKey: "big")
        #expect(store.hashes(forKey: "big")?.count == 20_000)
        #expect(store.hashes(forKey: "big")?.last == "h19999")
        for index in 0..<500 { store.set(["x\(index)"], forKey: "f\(index)") }
        #expect(store.count == 500)
        #expect(store.hashes(forKey: "big") == nil)
        store.flush()
        let reopened = BaselineStore(directory: folder.url)
        #expect(reopened.hashes(forKey: "f499") == ["x499"])
        #expect(reopened.count == 500)

        let small = BaselineStore(directory: folder.url.appendingPathComponent("small"), capacity: 2, maxHashes: 3)
        small.set(["a", "b", "c", "d"], forKey: "one")
        #expect(small.hashes(forKey: "one") == ["a", "b", "c"])
    }

    @Test("Baselines by URL follow an atomic save")
    func baselineByURL() throws {
        let folder = TempFolder()
        let file = folder.write("note.md", "v1")
        let store = BaselineStore(directory: folder.url.appendingPathComponent("support"))
        store.set(["h1", "h2"], for: file)
        try Data("v2".utf8).write(to: file, options: .atomic)
        #expect(store.hashes(for: file) == ["h1", "h2"])
    }

    @Test("Sessions save, debounce and restore, and a renamed tab's bookmark still resolves")
    func sessions() async throws {
        let folder = TempFolder()
        let first = folder.write("one.md", "1")
        let second = folder.write("two.md", "2")
        let tabs = try [first, second].map { TabState(bookmark: try #require(FileIdentity.bookmark(for: $0)), path: $0.path) }
        let session = Session(windows: [tabs, [tabs[0]]])
        let directory = folder.url.appendingPathComponent("support")
        let store = SessionStore(directory: directory)
        #expect(store.session == Session())
        store.save(session)
        #expect(store.session == session)
        #expect(await waitUntil(timeout: 1.5) { SessionStore(directory: directory).session == session })

        let renamed = folder.url.appendingPathComponent("one renamed.md")
        try FileManager.default.moveItem(at: first, to: renamed)
        let restored = SessionStore(directory: directory).session
        let resolved = try #require(FileIdentity.resolve(restored.windows[0][0].bookmark))
        #expect(samePath(resolved.url, renamed))

        store.save(Session(windows: []))
        store.flush()
        #expect(SessionStore(directory: directory).session == Session(windows: []))
    }

    @Test("A corrupt store file starts empty instead of failing")
    func corrupt() throws {
        let folder = TempFolder()
        try Data("{ not json".utf8).write(to: folder.url.appendingPathComponent("places.json"))
        let store = PlaceStore(directory: folder.url)
        #expect(store.count == 0)
        store.set(place(1), forKey: "k")
        store.flush()
        #expect(PlaceStore(directory: folder.url).place(forKey: "k") == place(1))
    }
}
