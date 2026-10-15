import Foundation

/// Renumbers a Quartz PDF's objects and rewrites its cross-reference table.
///
/// Why: drawing a `CGLayer` into a PDF context reserves object numbers that Quartz never writes (spike X(a): a
/// 500-node board used 810 objects and listed 137,276 cross-reference entries, 2.7 MB of a 5.4 MB file). The pass
/// reads Quartz's plain layout (`N 0 obj ... endobj`, direct stream lengths, a classic `xref` table), maps the
/// objects to 1...n in file order, rewrites `N 0 R` outside strings and never inside stream data, and writes a
/// fresh table. Anything it does not recognise (object streams, cross-reference streams, indirect lengths,
/// incremental updates) leaves the file as it was.
enum PDFCompact {
    /// Larger files are left as Quartz wrote them: the pass holds the file twice in memory.
    static let maxBytes = 64_000_000

    static func compact(_ data: Data) -> Data? {
        guard data.count <= maxBytes else { return nil }
        let b = [UInt8](data)
        guard b.count > 16, b.starts(with: Array("%PDF-".utf8)) else { return nil }
        if find(b, "/ObjStm", from: 0) != nil || find(b, "/XRef", from: 0) != nil { return nil }
        // Incremental updates have more than one table; Quartz writes one.
        guard let xref = findLast(b, "\nxref"), findLast(b, "\nxref", before: xref) == nil else { return nil }

        struct Obj { var num: Int; var dict: [UInt8]; var stream: ArraySlice<UInt8>? }
        var objects: [Obj] = []
        var header: [UInt8] = []
        var i = 0
        while i < xref {
            guard let (num, bodyStart) = objectHeader(b, at: i, limit: xref) else {
                if objects.isEmpty, let start = nextObject(b, from: i, limit: xref) { header = Array(b[0..<start]); i = start; continue }
                i += 1
                continue
            }
            if objects.isEmpty && header.isEmpty { header = Array(b[0..<i]) }
            guard let end = find(b, "endobj", from: bodyStart) else { return nil }
            if let s = find(b, "stream", from: bodyStart), s < end, b[s - 1] != UInt8(ascii: "d") {
                let dict = Array(b[bodyStart..<s])
                guard let len = directLength(dict) else { return nil }
                var dataStart = s + 6
                if dataStart < b.count, b[dataStart] == 13 { dataStart += 1 }
                if dataStart < b.count, b[dataStart] == 10 { dataStart += 1 }
                let dataEnd = dataStart + len
                guard dataEnd <= b.count, let es = find(b, "endstream", from: dataEnd), es - dataEnd < 4,
                      let objEnd = find(b, "endobj", from: es) else { return nil }
                objects.append(Obj(num: num, dict: dict, stream: b[dataStart..<dataEnd]))
                i = objEnd + 6
            } else {
                objects.append(Obj(num: num, dict: Array(b[bodyStart..<end]), stream: nil))
                i = end + 6
            }
        }
        guard !objects.isEmpty, let trailerAt = find(b, "trailer", from: xref), let startxref = find(b, "startxref", from: trailerAt) else { return nil }
        var map: [Int: Int] = [:]
        for (k, o) in objects.enumerated() {
            if map[o.num] != nil { return nil }
            map[o.num] = k + 1
        }
        var out: [UInt8] = header.isEmpty ? Array("%PDF-1.4\n".utf8) : header
        var offsets: [Int] = []
        offsets.reserveCapacity(objects.count)
        for (k, o) in objects.enumerated() {
            guard let dict = renumber(o.dict, map) else { return nil }
            offsets.append(out.count)
            out += Array("\(k + 1) 0 obj".utf8)
            out += dict
            if let s = o.stream {
                out += Array("stream\n".utf8)
                out += s
                out += Array("\nendstream\n".utf8)
            }
            out += Array("endobj\n".utf8)
        }
        let tableAt = out.count
        out += Array("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8)
        for off in offsets { out += Array(String(format: "%010d 00000 n \n", off).utf8) }
        guard var trailer = renumber(Array(b[(trailerAt + 7)..<startxref]), map) else { return nil }
        trailer = replaceSize(trailer, objects.count + 1)
        out += Array("trailer".utf8) + trailer
        out += Array("startxref\n\(tableAt)\n%%EOF\n".utf8)
        return Data(out)
    }

    // MARK: Reading

    private static func objectHeader(_ b: [UInt8], at i: Int, limit: Int) -> (Int, Int)? {
        // "N 0 obj" at the start of a line
        guard i == 0 || b[i - 1] == 10 || b[i - 1] == 13 else { return nil }
        var j = i, num = 0, digits = 0
        while j < limit, b[j] >= 48, b[j] <= 57 { num = num * 10 + Int(b[j] - 48); j += 1; digits += 1 }
        guard digits > 0, j + 6 <= limit, b[j] == 32, b[j + 1] == 48, b[j + 2] == 32,
              b[j + 3] == UInt8(ascii: "o"), b[j + 4] == UInt8(ascii: "b"), b[j + 5] == UInt8(ascii: "j") else { return nil }
        return (num, j + 6)
    }

    private static func nextObject(_ b: [UInt8], from: Int, limit: Int) -> Int? {
        var i = from
        while i < limit {
            if objectHeader(b, at: i, limit: limit) != nil { return i }
            i += 1
        }
        return nil
    }

    private static func directLength(_ dict: [UInt8]) -> Int? {
        // "/Length" itself, not "/Length1" or "/Length2" of an embedded font file.
        var from = 0
        var found: Int?
        while let at = find(dict, "/Length", from: from) {
            if at + 7 < dict.count, !isRegular(dict[at + 7]) { found = at; break }
            from = at + 7
        }
        guard let at = found else { return nil }
        var j = at + 7
        while j < dict.count, dict[j] == 32 || dict[j] == 10 || dict[j] == 13 { j += 1 }
        var n = 0, digits = 0
        while j < dict.count, dict[j] >= 48, dict[j] <= 57 { n = n * 10 + Int(dict[j] - 48); j += 1; digits += 1 }
        guard digits > 0 else { return nil }
        // "/Length 12 0 R" is an indirect length, which this pass does not follow.
        var k = j
        while k < dict.count, dict[k] == 32 { k += 1 }
        if k + 4 <= dict.count, dict[k] >= 48, dict[k] <= 57 {
            var m = k
            while m < dict.count, dict[m] >= 48, dict[m] <= 57 { m += 1 }
            if m + 2 <= dict.count, dict[m] == 32, dict[m + 1] == UInt8(ascii: "R") { return nil }
        }
        return n
    }

    /// Rewrites `N G R` references outside literal and hex strings.
    private static func renumber(_ s: [UInt8], _ map: [Int: Int]) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(s.count)
        var i = 0
        while i < s.count {
            let c = s[i]
            // Quartz writes no comments inside objects; one here means a layout this pass does not know.
            if c == UInt8(ascii: "%") { return nil }
            if c == UInt8(ascii: "(") {
                // a literal string, with nesting and escapes
                var depth = 0, j = i
                repeat {
                    if s[j] == UInt8(ascii: "\\") { j += 2; continue }
                    if s[j] == UInt8(ascii: "(") { depth += 1 } else if s[j] == UInt8(ascii: ")") { depth -= 1 }
                    j += 1
                } while j < s.count && depth > 0
                guard depth == 0 else { return nil }
                out += s[i..<j]
                i = j
                continue
            }
            if c == UInt8(ascii: "<"), i + 1 < s.count, s[i + 1] != UInt8(ascii: "<") {
                guard let close = s[i...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
                out += s[i...close]
                i = close + 1
                continue
            }
            if c == UInt8(ascii: "<"), i + 1 < s.count, s[i + 1] == UInt8(ascii: "<") {
                out += [c, c]
                i += 2
                continue
            }
            if c >= 48, c <= 57, i == 0 || !isRegular(s[i - 1]) || s[i - 1] == 32 || s[i - 1] == 91 {
                // number, space, generation, space, R
                var j = i, num = 0
                while j < s.count, s[j] >= 48, s[j] <= 57 { num = num * 10 + Int(s[j] - 48); j += 1 }
                var k = j
                if k < s.count, s[k] == 32 {
                    k += 1
                    let g0 = k
                    while k < s.count, s[k] >= 48, s[k] <= 57 { k += 1 }
                    if k > g0, k + 1 < s.count, s[k] == 32, s[k + 1] == UInt8(ascii: "R"), k + 2 == s.count || !isRegular(s[k + 2]) {
                        guard let new = map[num] else { return nil }
                        out += Array("\(new) 0 R".utf8)
                        i = k + 2
                        continue
                    }
                }
                out += s[i..<j]
                i = j
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    private static func isRegular(_ c: UInt8) -> Bool {
        !(c == 32 || c == 10 || c == 13 || c == 9 || c == 12 || c == 0 || "()<>[]{}/%".utf8.contains(c))
    }

    private static func replaceSize(_ t: [UInt8], _ n: Int) -> [UInt8] {
        guard let at = find(t, "/Size", from: 0) else { return t }
        var j = at + 5
        while j < t.count, t[j] == 32 { j += 1 }
        var k = j
        while k < t.count, t[k] >= 48, t[k] <= 57 { k += 1 }
        return Array(t[0..<at]) + Array("/Size \(n)".utf8) + Array(t[k...])
    }

    private static func find(_ b: [UInt8], _ needle: String, from: Int) -> Int? {
        let n = Array(needle.utf8)
        guard !n.isEmpty, b.count >= n.count else { return nil }
        var i = max(0, from)
        let last = b.count - n.count
        while i <= last {
            if b[i] == n[0] {
                var ok = true
                for k in 1..<n.count where b[i + k] != n[k] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }

    private static func findLast(_ b: [UInt8], _ needle: String, before: Int? = nil) -> Int? {
        let n = Array(needle.utf8)
        var i = min((before ?? b.count) - 1, b.count - n.count)
        while i >= 0 {
            if b[i] == n[0] {
                var ok = true
                for k in 1..<n.count where b[i + k] != n[k] { ok = false; break }
                if ok { return i }
            }
            i -= 1
        }
        return nil
    }
}
