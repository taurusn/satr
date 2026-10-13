import Foundation

/// Lossy UTF-8 and UTF-16 decoding that replaces each invalid sequence with U+FFFD and counts them.
enum UnicodeDecoding {
    static let replacement = Unicode.Scalar(0xFFFD)!

    /// Decodes UTF-8, counting errors and valid characters of two or more bytes.
    static func utf8(_ bytes: ArraySlice<UInt8>) -> (text: String, errors: Int, multiByte: Int) {
        var scalars = String.UnicodeScalarView()
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        var errors = 0
        var multiByte = 0
        loop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                if scalar.value >= 0x80 { multiByte += 1 }
                scalars.append(scalar)
            case .error:
                errors += 1
                scalars.append(replacement)
            case .emptyInput:
                break loop
            }
        }
        return (String(scalars), errors, multiByte)
    }

    /// Decodes UTF-16 in the given byte order. A trailing odd byte becomes U+FFFD.
    static func utf16(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) -> (text: String, lossy: Bool) {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = bytes.startIndex
        while index + 1 < bytes.endIndex {
            let first = UInt16(bytes[index]), second = UInt16(bytes[index + 1])
            units.append(bigEndian ? first << 8 | second : second << 8 | first)
            index += 2
        }
        var scalars = String.UnicodeScalarView()
        var iterator = units.makeIterator()
        var decoder = UTF16()
        var lossy = false
        loop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .error: lossy = true; scalars.append(replacement)
            case .emptyInput: break loop
            }
        }
        if bytes.count % 2 == 1 {
            lossy = true
            scalars.append(replacement)
        }
        return (String(scalars), lossy)
    }
}

/// A single-byte code page as a 256-entry table built from the system's converter, so decoding can
/// replace undefined bytes instead of failing.
struct SingleByteTable: Sendable {
    static let windows1252 = SingleByteTable(.windowsCP1252)
    static let windows1256 = SingleByteTable(TextDecoder.windowsArabic)

    private let scalars: [Unicode.Scalar?]

    init(_ encoding: String.Encoding) {
        scalars = (0...255).map { value -> Unicode.Scalar? in
            if value < 0x80 { return Unicode.Scalar(UInt8(value)) }
            guard let text = String(bytes: [UInt8(value)], encoding: encoding),
                  text.unicodeScalars.count == 1 else { return nil }
            return text.unicodeScalars.first
        }
    }

    /// True when every byte is defined in this code page.
    func isValid(_ bytes: [UInt8]) -> Bool {
        bytes.allSatisfy { scalars[Int($0)] != nil }
    }

    func decode(_ bytes: [UInt8]) -> (text: String, lossy: Bool) {
        var view = String.UnicodeScalarView()
        var lossy = false
        for byte in bytes {
            if let scalar = scalars[Int(byte)] {
                view.append(scalar)
            } else {
                lossy = true
                view.append(UnicodeDecoding.replacement)
            }
        }
        return (String(view), lossy)
    }
}

/// Decides whether undecodable bytes are Windows-1256 Arabic rather than Windows-1252.
///
/// The rule: at least three bytes in 0xC1 to 0xDA or 0xDC to 0xED, and more such Arabic-range bytes
/// than Latin-1 accented ones. Because the two ranges overlap (0xE9 is both "é" and an Arabic-range
/// byte), each high byte is classed by its context: a byte next to an ASCII letter, or one of the
/// Latin letters Windows-1256 keeps (à â ç è é ê ë î ï ô ù û ü), counts as Latin; an Arabic-range
/// byte between spaces, punctuation or other high bytes counts as Arabic.
enum ArabicDetector {
    private static let latinIn1256: Set<UInt8> = [0xE0, 0xE2, 0xE7, 0xE8, 0xE9, 0xEA, 0xEB, 0xEE, 0xEF, 0xF4, 0xF9, 0xFB, 0xFC]

    static func looksLikeWindows1256(_ bytes: [UInt8]) -> Bool {
        var arabic = 0
        var latin = 0
        for (index, byte) in bytes.enumerated() where byte >= 0xC0 && byte != 0xD7 && byte != 0xF7 {
            let previous = index > 0 ? bytes[index - 1] : 0x20
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0x20
            let besideLatin = isASCIILetter(previous) || isASCIILetter(next)
            if latinIn1256.contains(byte) || besideLatin {
                latin += 1
            } else if (0xC1...0xDA).contains(byte) || (0xDC...0xED).contains(byte) {
                arabic += 1
            }
        }
        return arabic >= 3 && arabic > latin
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }
}
