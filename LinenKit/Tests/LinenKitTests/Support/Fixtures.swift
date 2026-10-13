import Foundation
@testable import LinenKit

/// Arabic names with hamza letters, in both normal forms.
enum ArabicNames {
    static let questions = "أسئلة"                 // أ and ئ
    static let management = "إدارة"                // إ
    static let conference = "مؤتمر"                // ؤ
    static let last = "آخر"                        // آ
    static let intro = "المقدمة"
    static let faq = "الأسئلة الشائعة"

    static func nfd(_ text: String) -> String { text.decomposedStringWithCanonicalMapping }
}

/// A generated vault exercising every resolution rule. Layout:
///
///     .obsidian/
///     Ferry.md                     root note, with "## Goals"
///     wiki/projects/Ferry.md       same name, deeper, with "## Goals" and "## Risks"
///     wiki/projects/Plan.md
///     wiki/people/Hatim.md         aliases: Abu Hatim, H. Alshehri, Plan
///     notes/Dup.md, other/Dup.md   same name, same depth
///     notes/Source.md, journal/Entry.md
///     a/Readme.md, b/README.md     names differing only by case; a/Note.md
///     shared1/One.md, shared2/Two.md   both alias "Shared"
///     assets/image.png, a/pic.png, b/c/pic.png
///     arabic/أسئلة.md               written NFD, alias "الأسئلة الشائعة", "## المقدمة"
///     arabic/إدارة.md               written NFC; arabic/مؤتمر.md and arabic/آخر.md written NFD
///     .trash/Ghost.md, node_modules/pkg/Hidden.md   never indexed
struct ResolutionFixture {
    let folder = TempFolder("LinenKitVault")
    var root: URL { folder.url }

    init() {
        folder.makeFolder(".obsidian")
        folder.write("Ferry.md", "# Ferry\n\n## Goals\n\nRoot ferry. Self link [[#Goals]].\n")
        folder.write("wiki/projects/Ferry.md", "# Ferry project\n\n## Goals\n\n## Risks\n")
        folder.write("wiki/projects/Plan.md", "Plan links [[Ferry]].\n")
        folder.write("wiki/people/Hatim.md", "---\naliases: [Abu Hatim, \"H. Alshehri\", Plan]\n---\n# Hatim\n")
        folder.write("notes/Dup.md", "dup one")
        folder.write("other/Dup.md", "dup two")
        folder.write("notes/Source.md", "Source [[Dup]].\n")
        folder.write("journal/Entry.md", "Entry.\n")
        folder.write("a/Readme.md", "lower")
        folder.write("b/README.md", "upper")
        folder.write("a/Note.md", "note in a")
        folder.write("shared1/One.md", "---\naliases: Shared\n---\n")
        folder.write("shared2/Two.md", "---\naliases:\n  - Shared\n---\n")
        folder.write("assets/image.png", "png")
        folder.write("a/pic.png", "png")
        folder.write("b/c/pic.png", "png")
        folder.writeRaw(folder: "arabic", name: ArabicNames.nfd(ArabicNames.questions) + ".md",
                        "---\naliases:\n  - \(ArabicNames.faq)\n---\n# \(ArabicNames.questions)\n\n## \(ArabicNames.intro)\n\nنص.\n")
        folder.writeRaw(folder: "arabic", name: ArabicNames.management + ".md", "# \(ArabicNames.management)\n")
        folder.writeRaw(folder: "arabic", name: ArabicNames.nfd(ArabicNames.conference) + ".md", "conference")
        folder.writeRaw(folder: "arabic", name: ArabicNames.nfd(ArabicNames.last) + ".md", "last")
        folder.write(".trash/Ghost.md", "ghost")
        folder.write("node_modules/pkg/Hidden.md", "hidden")
    }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    func index() async -> VaultIndex {
        let index = VaultIndex(vault: Vault(root: root, kind: .obsidian))
        await index.build()
        return index
    }
}

/// Describes a resolution by vault-relative NFC paths, so expectations read plainly.
func describe(_ resolution: LinkResolution, root: URL) -> String {
    func relative(_ url: URL) -> String {
        let path = Paths.canonical(url).path.nfc
        let prefix = Paths.canonical(root).path.nfc + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
    switch resolution {
    case .note(let url, let heading, let block):
        var text = "note \(relative(url))"
        if let heading { text += " #\(heading.nfc)" }
        if let block { text += " ^\(block)" }
        return text
    case .ambiguous(let urls):
        return "ambiguous " + urls.map(relative).joined(separator: ", ")
    case .missing(let path):
        return "missing \(path)"
    }
}
