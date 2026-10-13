import Foundation

/// The result of decoding a file's bytes.
public struct DecodedText: Sendable, Equatable {
    /// The decoded text, without any byte order mark.
    public let text: String
    /// The encoding used.
    public let encoding: String.Encoding
    /// True when the encoding was guessed from the bytes rather than known from a byte order mark,
    /// strict UTF-8 validity or an override.
    public let detected: Bool
    /// True when some bytes could not be decoded and were replaced with U+FFFD.
    public let lossy: Bool

    /// Makes a decoded text.
    public init(text: String, encoding: String.Encoding, detected: Bool, lossy: Bool) {
        self.text = text
        self.encoding = encoding
        self.detected = detected
        self.lossy = lossy
    }
}

/// Turns file bytes into text and never fails.
///
/// Order: a byte order mark (UTF-8, UTF-16 LE or BE); else strict UTF-8; else UTF-8 with
/// replacement characters when the bytes are mostly valid UTF-8 (more valid multi-byte characters
/// than errors); else Windows-1256 when the bytes look like Arabic; else Windows-1252.
public enum TextDecoder {
    /// Windows-1256 (Arabic), which `String.Encoding` has no named constant for.
    public static let windowsArabic = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.windowsArabic.rawValue)))

    /// Decodes `data`. With `override`, that encoding is used as given (lossy if needed).
    public static func decode(_ data: Data, override: String.Encoding? = nil) -> DecodedText {
        let bytes = [UInt8](data)
        if let override { return decode(bytes, as: override) }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            let utf8 = UnicodeDecoding.utf8(bytes[3...])
            return DecodedText(text: utf8.text, encoding: .utf8, detected: false, lossy: utf8.errors > 0)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            let utf16 = UnicodeDecoding.utf16(bytes[2...], bigEndian: false)
            return DecodedText(text: utf16.text, encoding: .utf16LittleEndian, detected: false, lossy: utf16.lossy)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            let utf16 = UnicodeDecoding.utf16(bytes[2...], bigEndian: true)
            return DecodedText(text: utf16.text, encoding: .utf16BigEndian, detected: false, lossy: utf16.lossy)
        }
        if let text = String(validating: bytes, as: UTF8.self) {
            return DecodedText(text: text, encoding: .utf8, detected: false, lossy: false)
        }
        let utf8 = UnicodeDecoding.utf8(bytes[...])
        if utf8.multiByte > utf8.errors {
            return DecodedText(text: utf8.text, encoding: .utf8, detected: true, lossy: true)
        }
        if ArabicDetector.looksLikeWindows1256(bytes), SingleByteTable.windows1256.isValid(bytes) {
            let result = SingleByteTable.windows1256.decode(bytes)
            return DecodedText(text: result.text, encoding: windowsArabic, detected: true, lossy: result.lossy)
        }
        let result = SingleByteTable.windows1252.decode(bytes)
        return DecodedText(text: result.text, encoding: .windowsCP1252, detected: true, lossy: result.lossy)
    }

    private static func decode(_ bytes: [UInt8], as encoding: String.Encoding) -> DecodedText {
        func make(_ text: String, _ lossy: Bool) -> DecodedText {
            DecodedText(text: text, encoding: encoding, detected: false, lossy: lossy)
        }
        switch encoding {
        case .utf8:
            let body = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? bytes[3...] : bytes[...]
            let utf8 = UnicodeDecoding.utf8(body)
            return make(utf8.text, utf8.errors > 0)
        case .utf16LittleEndian, .utf16BigEndian, .utf16:
            var bigEndian = encoding == .utf16BigEndian
            var body = bytes[...]
            if bytes.starts(with: [0xFF, 0xFE]) { bigEndian = false; body = bytes[2...] }
            else if bytes.starts(with: [0xFE, 0xFF]) { bigEndian = true; body = bytes[2...] }
            let utf16 = UnicodeDecoding.utf16(body, bigEndian: bigEndian)
            return make(utf16.text, utf16.lossy)
        case .windowsCP1252:
            let result = SingleByteTable.windows1252.decode(bytes)
            return make(result.text, result.lossy)
        case windowsArabic:
            let result = SingleByteTable.windows1256.decode(bytes)
            return make(result.text, result.lossy)
        case .isoLatin1:
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: bytes.map { Unicode.Scalar($0) })
            return make(String(scalars), false)
        default:
            if let text = String(bytes: bytes, encoding: encoding) { return make(text, false) }
            let utf8 = UnicodeDecoding.utf8(bytes[...])
            return DecodedText(text: utf8.text, encoding: .utf8, detected: false, lossy: true)
        }
    }
}
