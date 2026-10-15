// EXP-6 check: board PNG drawn in bands. Reads a display list written by xa.swift, writes PNGs, and reports size,
// time and the process's peak memory, against the 16,384 px and 128 MP limits.
//
//   swiftc -O -swift-version 6 -parse-as-library -o build/png docs/spikes/export/png.swift Linen/Export/DisplayList.swift \
//     Linen/Export/OutlineText.swift Linen/Export/BoardPDF.swift Linen/Export/PDFCompact.swift Linen/Export/BoardPNG.swift -framework AppKit
//   ./build/png build/export-out/xa-displaylist-500.json build/export-out
import AppKit

func peakMB() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_maxrss) / 1_048_576
}

@main
struct PNGCheck {
    static func main() throws {
        let a = CommandLine.arguments
        let data = try Data(contentsOf: URL(fileURLWithPath: a[1]))
        let out = URL(fileURLWithPath: a[2])
        let list = try DisplayList.parse(try JSONSerialization.jsonObject(with: data))
        print("board \(Int(list.size.width)) x \(Int(list.size.height)) px; peak before drawing \(String(format: "%.0f", peakMB())) MB")
        let cases: [(String, BoardPNG.Region, Int)] = [("whole-1x", .whole, 1), ("whole-2x", .whole, 2), ("section0-4x", .section(list.sections.first?.id ?? ""), 4),
                                                      ("view-2x", .rect(CGRect(x: 0, y: 0, width: 1176, height: 800)), 2)]
        for (name, region, scale) in cases {
            let url = out.appendingPathComponent("png-\(name).png")
            do {
                let o = try BoardPNG.write(list, region: region, scale: scale, to: url)
                let w = o.width, h = o.height
                print("\(name): \(w) x \(h) px (\(String(format: "%.1f", Double(w * h) / 1e6)) MP), \(o.bytes / 1024) KB, \(String(format: "%.2f", o.seconds)) s; peak so far \(String(format: "%.0f", peakMB())) MB (a full RGBA image would be \(w * h * 4 / 1_048_576) MB)")
            } catch {
                print("\(name): \(error)")
            }
        }
    }
}
