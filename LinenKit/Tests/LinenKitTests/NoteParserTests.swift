import Foundation
import Testing
@testable import LinenKit

@Suite("Note parser")
struct NoteParserTests {
    @Test("Aliases from a block list, an inline list, one string and alias:")
    func aliases() {
        #expect(NoteParser.parse("---\naliases:\n  - One\n  - \"Two, quoted\"\n- Three\ntitle: x\n---\n").aliases
                == ["One", "Two, quoted", "Three"])
        #expect(NoteParser.parse("---\naliases: [a, \"b, c\", 'd''s']\n---\nbody").aliases == ["a", "b, c", "d's"])
        #expect(NoteParser.parse("---\naliases: Solo Name\n---\n").aliases == ["Solo Name"])
        #expect(NoteParser.parse("---\nalias: \"Quoted\"\n---\n").aliases == ["Quoted"])
        #expect(NoteParser.parse("---\ntitle: x\n---\naliases: [not, frontmatter]").aliases == [])
        #expect(NoteParser.parse("No frontmatter\naliases: [x]").aliases == [])
        #expect(NoteParser.parse("---\naliases: [unclosed]\n").aliases == [])
    }

    @Test("ATX headings outside fenced code, closing marks removed")
    func headings() {
        let text = """
        # One
        ## Two ##
        #tag is not a heading
        ####### seven is not a heading
           ### Indented three
        ```swift
        # inside code
        ```
        ~~~~
        ## inside tilde fence
        ```
        still inside
        ~~~~
        ## C#
        #
        """
        let headings = NoteParser.parse(text).headings
        #expect(headings.map(\.text) == ["One", "Two", "Indented three", "C#", ""])
        #expect(headings.map(\.level) == [1, 2, 3, 2, 1])
        #expect(headings.first?.line == 1)
    }

    @Test("Wiki links outside fenced and inline code, with embeds and labels")
    func links() {
        let text = """
        See [[Alpha]] and [[wiki/Beta|the beta]] and ![[image.png]].
        Code `[[NotALink]]` and ``a ` [[AlsoNot]]`` but [[Gamma#Heading]] counts.
        ```
        [[InFence]]
        ```
        Unclosed `tick [[Delta]] stays a link.
        Empty [[]] and [[ ]] are ignored; \\[[Escaped]] too.
        """
        let links = NoteParser.parse(text).links
        #expect(links.map(\.raw) == ["Alpha", "wiki/Beta|the beta", "image.png", "Gamma#Heading", "Delta"])
        #expect(links.map(\.isEmbed) == [false, false, true, false, false])
        #expect(links.map(\.line) == [1, 1, 1, 2, 6])
    }

    @Test("Frontmatter links count, with their property as context")
    func frontmatterLinks() {
        let text = "---\nrelated:\n  - \"[[wiki/projects/Ferry]]\"\nsource: \"[[Plan|the plan]]\"\n---\nBody [[Ferry]].\n"
        let links = NoteParser.parse(text).links
        #expect(links.map(\.raw) == ["wiki/projects/Ferry", "Plan|the plan", "Ferry"])
        #expect(links.map(\.inFrontmatter) == [true, true, false])
        #expect(links[0].sentence == "related: Ferry")
        #expect(links[1].sentence == "source: the plan")
    }

    @Test("The sentence holding a link, with markup reduced to labels")
    func sentences() {
        func sentence(_ line: String, _ index: Int = 0) -> String {
            let scan = LineScanner(Array(line.utf8), skipCode: true)
            return scan.sentence(for: index)
        }
        #expect(sentence("First one. Second has [[wiki/x|the link]] in it. Third.") == "Second has the link in it.")
        #expect(sentence("- [ ] Task about [[wiki/projects/Ferry]] today") == "Task about Ferry today")
        #expect(sentence("> [!note] Read [[Dr. Who]] first. Then rest.") == "Read Dr. Who first.")
        #expect(sentence("## See [[Note#Part]]") == "See Note > Part")
        #expect(sentence("هل قرأت [[خطة]]؟ نعم قرأتها.") == "هل قرأت خطة؟")
        #expect(sentence("A **bold** [link](https://x.y) then [[Z]].") == "A bold link then Z.")
        #expect(sentence("| a | see [[T]] here | c |") == "see T here")
        #expect(sentence("One [[A]]. Two [[B]].", 1) == "Two B.")
        let long = String(repeating: "word ", count: 120) + "[[Target]] " + String(repeating: "tail ", count: 60)
        let clipped = sentence(long)
        #expect(clipped.count <= 302)
        #expect(clipped.contains("Target"))
    }

    @Test("Link targets split into path, heading, block and label")
    func targets() {
        #expect(LinkTarget.parse("a/b#H|L") == LinkTarget(path: "a/b", heading: "H", label: "L"))
        #expect(LinkTarget.parse("a#^blk") == LinkTarget(path: "a", block: "blk"))
        #expect(LinkTarget.parse("a#One#Two") == LinkTarget(path: "a", heading: "Two"))
        #expect(LinkTarget.parse("a\\|L") == LinkTarget(path: "a", label: "L"))
        #expect(LinkTarget.parse("#H") == LinkTarget(path: "", heading: "H"))
        #expect(LinkTarget.displayLabel(for: "wiki/projects/Ferry.md") == "Ferry")
        #expect(LinkTarget.displayLabel(for: "Ferry#Goals") == "Ferry > Goals")
    }
}
