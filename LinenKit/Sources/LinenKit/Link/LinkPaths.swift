import Foundation

/// The link's limits (PRD-2 SYNC-8 and section 9.3): every frame is bounded and anything larger ends the session.
public enum LinkBounds {
    /// The largest frame payload either side accepts: a manifest page, a `want`, a chunk.
    public static let maxFrame = 1 << 20
    /// The bytes one `chunk` carries at most.
    public static let chunkBytes = 512 * 1024
    /// Entries one pin's manifest may hold.
    public static let maxEntriesPerPin = 50_000
    /// The largest file the link carries (SYNC-8).
    public static let maxFileSize: Int64 = 200 * 1024 * 1024
    /// Everything kept on the phone, by default (SYNC-8; Settings on the Mac changes it).
    public static let defaultTotalLimit: Int64 = 2 * 1024 * 1024 * 1024
    /// The link's protocol version, sent in `hello`.
    public static let protocolVersion = 1
}

/// Relative paths as the manifest carries them (section 9.3): NFC, `/`-separated, checked component by component on
/// both sides. No empty, `.` or `..` component, no absolute path, nothing a file system would read differently.
public enum LinkPath {
    /// Why a path is refused, or nil when it is fine.
    public static func problem(_ path: String) -> String? {
        if path.isEmpty { return "empty path" }
        if path.hasPrefix("/") { return "absolute path" }
        if path.utf8.count > 1024 { return "path longer than 1024 bytes" }
        // Swift's == treats canonically equivalent strings as equal, so compare the bytes.
        if !path.utf8.elementsEqual(path.precomposedStringWithCanonicalMapping.utf8) { return "path not in NFC" }
        if path.contains("\0") { return "path holds a NUL" }
        for c in path.split(separator: "/", omittingEmptySubsequences: false) {
            if c.isEmpty { return "empty component" }
            if c == "." || c == ".." { return "\(c) component" }
            if c.utf8.count > 255 { return "component longer than 255 bytes" }
        }
        return nil
    }

    public static func isValid(_ path: String) -> Bool { problem(path) == nil }

    /// The key two paths share when a case-insensitive or normalising file system would treat them as one.
    public static func foldKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    /// The paths that collide with another in the list by case or Unicode form; all members of a collision are
    /// returned, so neither file is sent and the pin says why. (Strings that differ only by Unicode form are one value
    /// in a Swift set; the NFC check refuses the non-NFC one anyway.)
    public static func collisions(_ paths: [String]) -> Set<String> {
        var groups: [String: [String]] = [:]
        for p in paths { groups[foldKey(p), default: []].append(p) }
        return Set(groups.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    /// Pin IDs name folders on the phone, so they are checked as strictly as paths.
    public static func isValidPinID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
    }

    /// A SHA-256 in lowercase hex.
    public static func isValidHash(_ hash: String) -> Bool {
        hash.count == 64 && hash.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}
