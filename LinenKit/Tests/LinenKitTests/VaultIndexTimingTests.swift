import Foundation
import Testing
@testable import LinenKit

/// Writes a synthetic vault shaped like a real one: ten folders, frontmatter with aliases and a
/// related link, headings, English and Arabic paragraphs, ten wiki links per note, code with links
/// that must be ignored. About 10 KB per note.
enum GeneratedVault {
    static func write(into folder: TempFolder, notes count: Int) {
        folder.makeFolder(".obsidian")
        var seed: UInt64 = 42
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let paragraph = "Linen keeps the place while the file is rewritten underneath it, and shows what changed. "
        let arabic = "يحافظ سطر على موضع القراءة أثناء إعادة كتابة الملف ويعرض ما تغير. "
        for number in 0..<count {
            var text = "---\naliases: [Alias \(number), \"N\(number)\"]\nrelated: \"[[Note \(next(count))]]\"\ntags: [generated]\n---\n"
            text += "# Note \(number)\n\n"
            for section in 0..<6 {
                text += "## Section \(section)\n\n"
                text += String(repeating: paragraph, count: 6) + " See [[Note \(next(count))]] and [[area-\(next(10))/Note \(next(count))|a label]].\n\n"
                text += String(repeating: arabic, count: 4) + "\n\n"
                if section == 2 { text += "```swift\nlet link = \"[[Not a link]]\"\n```\n\nInline `[[code]]` here.\n\n" }
            }
            folder.write("area-\(number % 10)/Note \(number).md", text)
        }
    }
}

@Suite("Vault index timing", .serialized)
struct VaultIndexTimingTests {
    @Test("Build of a generated 500-note vault takes under 2 s")
    func generated() async {
        let folder = TempFolder()
        GeneratedVault.write(into: folder, notes: 500)
        let index = VaultIndex(vault: Vault(root: folder.url, kind: .obsidian))
        let start = Date()
        await index.build()
        let elapsed = Date().timeIntervalSince(start)
        let summary = index.resolutionSummary()
        print("VaultIndex build, generated vault: \(index.noteCount) notes, \(summary.links) links, \(Int(elapsed * 1000)) ms")
        #expect(index.noteCount == 500)
        #expect(summary.ambiguous == 0)
        #expect(summary.links == 500 * 13)
        #expect(elapsed < 2)
    }

    @Test("Build of ~/vault (read only) takes under 2 s",
          .enabled(if: FileManager.default.fileExists(atPath: NSHomeDirectory() + "/vault")))
    func realVault() async {
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/vault")
        var times: [Int] = []
        var last: VaultIndex?
        for _ in 0..<3 {
            let index = VaultIndex(vault: Vault(root: root, kind: .obsidian))
            let start = Date()
            await index.build()
            times.append(Int(Date().timeIntervalSince(start) * 1000))
            last = index
        }
        guard let index = last else { return }
        let summary = index.resolutionSummary()
        print("VaultIndex build, ~/vault: \(index.noteCount) notes, runs \(times.map { "\($0) ms" }.joined(separator: ", "))")
        print("~/vault links: \(summary.links) total, \(summary.resolved) resolved, \(summary.ambiguous) ambiguous, \(summary.missing) missing")
        #expect(index.noteCount > 0)
        #expect(Double(times[0]) < 2000)
    }
}
