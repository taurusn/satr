import Foundation
import Testing
@testable import LinenKit

/// Every save style from spike S(b), in a temp folder. Timing bounds leave slack for loaded CI
/// machines; the measured latencies are printed.
@Suite("File watcher", .serialized)
struct FileWatcherTests {
    /// A started watcher on `note.md` holding "v0", after its initial content arrived.
    final class Harness: @unchecked Sendable {
        let folder = TempFolder("LinenKitWatch")
        let file: URL
        let recorder = EventRecorder()
        let watcher: FileWatcher

        init(_ initial: String = "v0") async throws {
            file = folder.write("note.md", initial)
            let recorder = recorder
            watcher = FileWatcher(url: file, queue: recorder.queue) { recorder.record($0) }
            watcher.start()
            let ready = await waitUntil(timeout: 2) { recorder.firstContent(initial) != nil }
            try #require(ready, "initial content arrives")
            #expect(recorder.contents.first?.generation == 0)
        }

        /// Waits for `text` to arrive after `since`, returning the latency from `since`.
        func latency(of text: String, since: Date, timeout: Double = 2) async -> Double? {
            let arrived = await waitUntil(timeout: timeout) { recorder.firstContent(text, after: since) != nil }
            guard arrived, let found = recorder.firstContent(text, after: since) else { return nil }
            return found.time.timeIntervalSince(since)
        }

        deinit { watcher.stop() }
    }

    private func report(_ label: String, _ latency: Double?) {
        print("FileWatcher \(label): \(latency.map { String(format: "%.0f ms", $0 * 1000) } ?? "none")")
    }

    @Test("In-place write (same inode)")
    func inPlace() async throws {
        let harness = try await Harness()
        let before = inode(harness.file)
        let start = Date()
        try writeInPlace(harness.file, "v1 in place")
        let latency = await harness.latency(of: "v1 in place", since: start)
        report("in-place write", latency)
        #expect(inode(harness.file) == before)
        #expect((latency ?? 99) < 0.5)
        #expect(harness.recorder.firstContent("v1 in place")?.inBurst == false)
    }

    @Test("Foundation atomic write (new inode)")
    func atomic() async throws {
        let harness = try await Harness()
        let before = inode(harness.file)
        let start = Date()
        try Data("v1 atomic".utf8).write(to: harness.file, options: .atomic)
        let latency = await harness.latency(of: "v1 atomic", since: start)
        report("atomic write", latency)
        #expect(inode(harness.file) != before)
        #expect((latency ?? 99) < 0.5)
        try writeInPlace(harness.file, "v2 after rearm")
        #expect(await harness.latency(of: "v2 after rearm", since: start) != nil, "the file source was rearmed on the new inode")
    }

    @Test("Temp file, then rename over")
    func renameOver() async throws {
        let harness = try await Harness()
        let temp = harness.folder.write(".note.md.tmp", "v1 renamed over")
        let start = Date()
        #expect(rename(temp.path, harness.file.path) == 0)
        let latency = await harness.latency(of: "v1 renamed over", since: start)
        report("rename over", latency)
        #expect((latency ?? 99) < 0.5)
    }

    @Test("Vim style: rename away, write new, delete backup")
    func vimStyle() async throws {
        let harness = try await Harness()
        let backup = harness.folder.url.appendingPathComponent("note.md~")
        let start = Date()
        #expect(rename(harness.file.path, backup.path) == 0)
        try Data("v1 vim".utf8).write(to: harness.file)
        #expect(unlink(backup.path) == 0)
        let latency = await harness.latency(of: "v1 vim", since: start)
        report("vim-style save", latency)
        #expect((latency ?? 99) < 0.5)
        try? await Task.sleep(for: .milliseconds(800))
        #expect(harness.recorder.missingCount == 0)
        #expect(harness.recorder.moves.isEmpty)
        #expect(samePath(harness.watcher.url, harness.file))
    }

    @Test("Delete, then recreate after 300 ms")
    func deleteRecreate() async throws {
        let harness = try await Harness()
        #expect(unlink(harness.file.path) == 0)
        try? await Task.sleep(for: .milliseconds(300))
        let start = Date()
        try Data("v1 recreated".utf8).write(to: harness.file)
        let latency = await harness.latency(of: "v1 recreated", since: start)
        report("delete and recreate", latency)
        #expect((latency ?? 99) < 0.5)
        try? await Task.sleep(for: .milliseconds(700))
        #expect(harness.recorder.missingCount == 0)
    }

    @Test("Coordinated write")
    func coordinated() async throws {
        let harness = try await Harness()
        let start = Date()
        var coordinationError: NSError?
        var writeError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: harness.file, options: [], error: &coordinationError) { url in
            do { try Data("v1 coordinated".utf8).write(to: url) } catch { writeError = error }
        }
        #expect(coordinationError == nil)
        #expect(writeError == nil)
        let latency = await harness.latency(of: "v1 coordinated", since: start)
        report("coordinated write", latency)
        #expect((latency ?? 99) < 0.5)
    }

    @Test("20 rapid writes 20 ms apart", arguments: [false, true])
    func rapidWrites(atomic: Bool) async throws {
        let harness = try await Harness()
        let start = Date()
        var lastWrite = Date()
        var finalText = ""
        for number in 1...20 {
            finalText = "burst write \(number) " + String(repeating: "x", count: number * 50)
            if atomic { try Data(finalText.utf8).write(to: harness.file, options: .atomic) }
            else { try writeInPlace(harness.file, finalText) }
            lastWrite = Date()
            try? await Task.sleep(for: .milliseconds(20))
        }
        let expected = finalText
        let settled = await waitUntil(timeout: 2) { harness.recorder.quiets.contains { $0.time > lastWrite } }
        #expect(settled, "quiet follows the burst")
        let burst = harness.recorder.contents.filter { $0.time > start }
        let intermediate = burst.filter(\.inBurst)
        let last = try #require(burst.last)
        let lag = last.time.timeIntervalSince(lastWrite)
        print("FileWatcher rapid \(atomic ? "atomic" : "in-place") writes: \(burst.count) reads, \(intermediate.count) intermediate, final \(String(format: "%.0f ms", lag * 1000)) after the last write")
        #expect(intermediate.count <= 6)
        #expect(String(decoding: last.data, as: UTF8.self) == expected)
        #expect(last.inBurst == false)
        #expect(lag < 0.4)
        let quiet = try #require(harness.recorder.quiets.last)
        #expect(quiet.generation >= last.generation)
        #expect(quiet.time.timeIntervalSince(lastWrite) >= 0.29)
    }

    @Test("Quiet arrives 300 ms after the last change, with its generation")
    func quiet() async throws {
        let harness = try await Harness()
        let start = Date()
        try writeInPlace(harness.file, "v1 quiet")
        let arrived = await waitUntil(timeout: 2) { harness.recorder.quiets.contains { $0.time > start } }
        #expect(arrived)
        let quiet = try #require(harness.recorder.quiets.last)
        let content = try #require(harness.recorder.contents.last)
        #expect(quiet.generation == content.generation)
        #expect(content.generation >= 1)
        let delay = quiet.time.timeIntervalSince(start)
        print("FileWatcher quiet: \(String(format: "%.0f ms", delay * 1000)) after the write")
        #expect(delay >= 0.29 && delay < 0.8)
    }

    @Test("Renaming the file reports .moved and follows it")
    func renamed() async throws {
        let harness = try await Harness()
        let destination = harness.folder.url.appendingPathComponent("renamed.md")
        let start = Date()
        #expect(rename(harness.file.path, destination.path) == 0)
        let moved = await waitUntil(timeout: 2) { !harness.recorder.moves.isEmpty }
        #expect(moved)
        let move = try #require(harness.recorder.moves.first)
        print("FileWatcher rename: .moved after \(String(format: "%.0f ms", move.time.timeIntervalSince(start) * 1000))")
        #expect(samePath(move.url, destination))
        #expect(samePath(harness.watcher.url, destination))
        #expect(harness.recorder.missingCount == 0)
        let after = Date()
        try writeInPlace(destination, "v2 at new name")
        #expect(await harness.latency(of: "v2 at new name", since: after) != nil)
    }

    @Test("A coordinated move reports one .moved")
    func coordinatedMove() async throws {
        let harness = try await Harness()
        let destination = harness.folder.url.appendingPathComponent("moved by Finder.md")
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        let start = Date()
        coordinator.coordinate(writingItemAt: harness.file, options: .forMoving, writingItemAt: destination,
                               options: .forReplacing, error: &coordinationError) { source, target in
            try? FileManager.default.moveItem(at: source, to: target)
            coordinator.item(at: source, didMoveTo: target)
        }
        #expect(coordinationError == nil)
        #expect(await waitUntil(timeout: 2) { !harness.recorder.moves.isEmpty })
        try? await Task.sleep(for: .milliseconds(900))
        let moves = harness.recorder.moves
        print("FileWatcher coordinated move: .moved after \(String(format: "%.0f ms", (moves.first?.time.timeIntervalSince(start) ?? 0) * 1000))")
        #expect(moves.count == 1)
        #expect(samePath(harness.watcher.url, destination))
        #expect(harness.recorder.missingCount == 0)
    }

    @Test("Moving the file to another folder reports .moved")
    func movedFolder() async throws {
        let harness = try await Harness()
        harness.folder.makeFolder("elsewhere")
        let destination = harness.folder.url.appendingPathComponent("elsewhere/note.md")
        #expect(rename(harness.file.path, destination.path) == 0)
        #expect(await waitUntil(timeout: 2) { !harness.recorder.moves.isEmpty })
        #expect(samePath(harness.watcher.url, destination))
        let after = Date()
        try Data("v2 moved folder".utf8).write(to: destination, options: .atomic)
        #expect(await harness.latency(of: "v2 moved folder", since: after) != nil, "the folder source follows the move")
    }

    @Test("Deleting the file for over a second reports .missing once, after the grace period")
    func deleted() async throws {
        let harness = try await Harness()
        let start = Date()
        #expect(unlink(harness.file.path) == 0)
        let missing = await waitUntil(timeout: 2) { harness.recorder.missingCount > 0 }
        #expect(missing)
        let entry = try #require(harness.recorder.entries.first { $0.event == .missing })
        let delay = entry.time.timeIntervalSince(start)
        print("FileWatcher delete: .missing after \(String(format: "%.0f ms", delay * 1000))")
        #expect(delay >= 0.45 && delay < 1.2)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(harness.recorder.missingCount == 1)
        #expect(harness.recorder.quiets.allSatisfy { $0.time < start })
        let back = Date()
        try Data("v1 back".utf8).write(to: harness.file)
        #expect(await harness.latency(of: "v1 back", since: back) != nil, "a file that returns is read again")
    }

    @Test("A file missing at start reports .missing, then content when it appears")
    func missingAtStart() async throws {
        let folder = TempFolder("LinenKitWatch")
        let file = folder.url.appendingPathComponent("later.md")
        let recorder = EventRecorder()
        let watcher = FileWatcher(url: file, queue: recorder.queue) { recorder.record($0) }
        watcher.start()
        defer { watcher.stop() }
        #expect(await waitUntil(timeout: 2) { recorder.missingCount == 1 })
        let start = Date()
        try Data("arrived".utf8).write(to: file, options: .atomic)
        #expect(await waitUntil(timeout: 2) { recorder.firstContent("arrived", after: start) != nil })
    }

    @Test("No events after stop")
    func stops() async throws {
        let harness = try await Harness()
        harness.watcher.stop()
        let count = harness.recorder.entries.count
        try writeInPlace(harness.file, "after stop")
        try? await Task.sleep(for: .milliseconds(600))
        #expect(harness.recorder.entries.count == count)
        harness.watcher.start()
        #expect(await waitUntil(timeout: 2) { harness.recorder.firstContent("after stop") != nil }, "restart reads again")
    }

    @Test("A file that is there but cannot be opened reports .unreadable")
    func unreadable() async throws {
        let folder = TempFolder("LinenKitWatch")
        let file = folder.write("locked.md", "secret")
        chmod(file.path, 0)
        defer { chmod(file.path, 0o644) }
        let recorder = EventRecorder()
        let watcher = FileWatcher(url: file, queue: recorder.queue) { recorder.record($0) }
        watcher.start()
        defer { watcher.stop() }
        #expect(await waitUntil(timeout: 2) { recorder.entries.contains { $0.event == .unreadable(EACCES) } })
        #expect(recorder.contents.isEmpty)
        chmod(file.path, 0o644)
        let start = Date()
        try writeInPlace(file, "opened")
        #expect(await waitUntil(timeout: 2) { recorder.firstContent("opened", after: start) != nil }, "reads once allowed")
    }

    @Test("Polling (network volumes) sees changes and adds no events of its own")
    func polling() async throws {
        let folder = TempFolder("LinenKitWatch")
        let file = folder.write("remote.md", "v0")
        let recorder = EventRecorder()
        let watcher = FileWatcher(url: file, queue: recorder.queue, poll: true) { recorder.record($0) }
        watcher.start()
        defer { watcher.stop() }
        #expect(await waitUntil(timeout: 2) { recorder.firstContent("v0") != nil })
        try? await Task.sleep(for: .milliseconds(4500))
        #expect(recorder.contents.count == 1, "two quiet polls deliver nothing")
        let start = Date()
        try writeInPlace(file, "v1 polled")
        #expect(await waitUntil(timeout: 3) { recorder.firstContent("v1 polled", after: start) != nil })
    }
}
