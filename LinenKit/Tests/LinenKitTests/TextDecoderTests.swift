import Foundation
import Testing
@testable import LinenKit

@Suite("Text decoder")
struct TextDecoderTests {
    private func bytes(_ text: String, _ encoding: String.Encoding) throws -> Data {
        try #require(text.data(using: encoding), "\(text) encodes")
    }

    @Test("Strict UTF-8, with and without BOM")
    func utf8() {
        let text = "Linen سطر — naïve"
        let plain = TextDecoder.decode(Data(text.utf8))
        #expect(plain == DecodedText(text: text, encoding: .utf8, detected: false, lossy: false))
        let bom = TextDecoder.decode(Data([0xEF, 0xBB, 0xBF] + Array(text.utf8)))
        #expect(bom == DecodedText(text: text, encoding: .utf8, detected: false, lossy: false))
        #expect(TextDecoder.decode(Data()) == DecodedText(text: "", encoding: .utf8, detected: false, lossy: false))
    }

    @Test("UTF-16 with a byte order mark, both byte orders")
    func utf16() throws {
        let text = "Read سطر 📄"
        let little = Data([0xFF, 0xFE]) + (try bytes(text, .utf16LittleEndian))
        #expect(TextDecoder.decode(little) == DecodedText(text: text, encoding: .utf16LittleEndian, detected: false, lossy: false))
        let big = Data([0xFE, 0xFF]) + (try bytes(text, .utf16BigEndian))
        #expect(TextDecoder.decode(big) == DecodedText(text: text, encoding: .utf16BigEndian, detected: false, lossy: false))
        let odd = TextDecoder.decode(little + Data([0x41]))
        #expect(odd.lossy)
        #expect(odd.text == text + "\u{FFFD}")
    }

    @Test("Windows-1252 for Latin text: French, Spanish, German, smart quotes")
    func windows1252() throws {
        for text in ["Le café est très bon, à côté de l’hôtel.", "¿Qué día está aquí? Más señor, canción.",
                     "Größe über Straße “zitat” — Ende", "naïve résumé"] {
            let decoded = TextDecoder.decode(try bytes(text, .windowsCP1252))
            #expect(decoded == DecodedText(text: text, encoding: .windowsCP1252, detected: true, lossy: false), "\(text)")
        }
    }

    @Test("Windows-1256 for Arabic text, alone and mixed with English")
    func windows1256() throws {
        for text in ["مرحبا بالعالم، هذا نص عربي.", "ملف README هنا مع أسئلة وإجابات", "قارئ سطر يحافظ على الموضع"] {
            let decoded = TextDecoder.decode(try bytes(text, TextDecoder.windowsArabic))
            #expect(decoded == DecodedText(text: text, encoding: TextDecoder.windowsArabic, detected: true, lossy: false), "\(text)")
        }
    }

    @Test("Too few Arabic-range bytes fall back to Windows-1252")
    func shortArabic() throws {
        let decoded = TextDecoder.decode(Data("ab ".utf8) + Data([0xC7, 0xE1]) + Data(" cd".utf8))
        #expect(decoded.encoding == .windowsCP1252)
        #expect(decoded.detected)
    }

    @Test("Malformed UTF-8 decodes as UTF-8 with replacement characters")
    func malformed() {
        var data = Data("سطر يقرأ Markdown ".utf8)
        data.append(0xD9)                     // a truncated two-byte sequence
        data.append(contentsOf: Array(" and keeps going — ✓".utf8))
        data.append(contentsOf: [0xFF, 0xFE, 0x41])
        let decoded = TextDecoder.decode(data)
        #expect(decoded.encoding == .utf8)
        #expect(decoded.detected)
        #expect(decoded.lossy)
        #expect(decoded.text == "سطر يقرأ Markdown \u{FFFD} and keeps going — ✓\u{FFFD}\u{FFFD}A")
    }

    @Test("Undefined Windows-1252 bytes become replacement characters")
    func undefined1252() {
        let decoded = TextDecoder.decode(Data([0x41, 0x81, 0x42]))
        #expect(decoded.encoding == .windowsCP1252)
        #expect(decoded.text == "A\u{FFFD}B")
        #expect(decoded.lossy)
    }

    @Test("An override is used as given")
    func override() throws {
        let arabic = try bytes("مرحبا بالعالم", TextDecoder.windowsArabic)
        let forced = TextDecoder.decode(arabic, override: .windowsCP1252)
        #expect(forced.encoding == .windowsCP1252)
        #expect(!forced.detected)
        #expect(forced.text != "مرحبا بالعالم")
        let back = TextDecoder.decode(arabic, override: TextDecoder.windowsArabic)
        #expect(back == DecodedText(text: "مرحبا بالعالم", encoding: TextDecoder.windowsArabic, detected: false, lossy: false))
        let latin = TextDecoder.decode(Data([0x63, 0x61, 0x66, 0xE9]), override: .isoLatin1)
        #expect(latin.text == "café")
        let badUTF8 = TextDecoder.decode(Data([0x61, 0xFF]), override: .utf8)
        #expect(badUTF8 == DecodedText(text: "a\u{FFFD}", encoding: .utf8, detected: false, lossy: true))
    }
}
