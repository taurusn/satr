import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Board PNG (PRD-2 EXP-6): the whole board, a section or the view at 1x, 2x or 4x, up to 16,384 px a side and 128
/// megapixels. Drawn in bands of rows and handed to ImageIO as a stream, so memory holds one band, never the image.
enum BoardPNG {
    enum Region: Sendable, Equatable {
        case whole
        case section(String)
        /// A rectangle in board pixels (the view).
        case rect(CGRect)
    }

    struct Output: Sendable {
        var width: Int
        var height: Int
        var bytes: Int
        var seconds: Double
    }

    enum Failure: Error, CustomStringConvertible, Equatable {
        /// Past the limits; `fits` is the largest of 1x, 2x and 4x that would fit (nil when even 1x does not).
        case tooLarge(width: Int, height: Int, fits: Int?)
        case noSuchSection, emptyArea, cannotWrite(String)
        var description: String {
            switch self {
            case let .tooLarge(w, h, fits):
                w == Int.max ? String(localized: "That area is too large for a PNG")
                    : fits.map { String(localized: "\(w) × \(h) px is past the PNG limit; \($0)x fits") }
                    ?? String(localized: "\(w) × \(h) px is past the PNG limit even at 1x; export one section per file")
            case .noSuchSection: String(localized: "That section is no longer on this board")
            case .emptyArea: String(localized: "There is nothing to draw in that area")
            case let .cannotWrite(name): String(localized: "Linen could not write \(name)")
            }
        }
    }

    static let maxSide = 16_384
    static let maxPixels = 128_000_000
    /// Rows per band: 16,384 x 512 x 4 bytes is 32 MB at the widest.
    static let bandRows = 512

    /// Pixel size at a scale; 0 for geometry that is not a finite, positive rectangle (never traps).
    static func size(of r: CGRect, scale: Int) -> (Int, Int) {
        let w = Double(r.width) * Double(scale), h = Double(r.height) * Double(scale)
        guard w.isFinite, h.isFinite, w > 0, h > 0, w < 1e9, h < 1e9 else { return (0, 0) }
        return (Int(w.rounded(.up)), Int(h.rounded(.up)))
    }

    static func fits(_ r: CGRect, scale: Int) -> Bool {
        guard [1, 2, 4].contains(scale) else { return false }
        let (w, h) = size(of: r, scale: scale)
        return w > 0 && h > 0 && w <= maxSide && h <= maxSide && Double(w) * Double(h) <= Double(maxPixels)
    }

    static func area(_ list: DisplayList, _ region: Region) throws -> CGRect {
        switch region {
        case .whole: return CGRect(origin: .zero, size: list.size).insetBy(dx: -24, dy: -24)
        case let .section(id):
            guard let s = list.sections.first(where: { $0.id == id }) else { throw Failure.noSuchSection }
            return s.rect.insetBy(dx: -16, dy: 0).union(CGRect(x: s.rect.minX, y: s.rect.minY - 44, width: 1, height: 1))
        case let .rect(r): return r
        }
    }

    static func write(_ list: DisplayList, region: Region = .whole, scale: Int = 2, to url: URL) throws -> Output {
        let started = Date()
        let r = try area(list, region)
        let (w, h) = size(of: r, scale: scale)
        // Geometry past any size (infinite, absurd) is too large; an empty or unsupported one has nothing to draw.
        if !r.width.isFinite || !r.height.isFinite || r.width * CGFloat(max(1, scale)) >= 1e9 || r.height * CGFloat(max(1, scale)) >= 1e9 {
            throw Failure.tooLarge(width: Int.max, height: Int.max, fits: nil)
        }
        guard w > 0, h > 0, [1, 2, 4].contains(scale) else { throw Failure.emptyArea }
        guard fits(r, scale: scale) else {
            throw Failure.tooLarge(width: w, height: h, fits: [4, 2, 1].first { $0 < scale && fits(r, scale: $0) })
        }
        let source = Bands(list: list, area: r, scale: CGFloat(scale), width: w, height: h)
        var callbacks = CGDataProviderSequentialCallbacks(
            version: 0,
            getBytes: { info, buffer, count in Unmanaged<Bands>.fromOpaque(info!).takeUnretainedValue().read(into: buffer, count: count) },
            skipForward: { info, count in Unmanaged<Bands>.fromOpaque(info!).takeUnretainedValue().skip(count) },
            rewind: { info in Unmanaged<Bands>.fromOpaque(info!).takeUnretainedValue().rewind() },
            releaseInfo: { info in Unmanaged<Bands>.fromOpaque(info!).release() })
        guard let provider = CGDataProvider(sequentialInfo: Unmanaged.passRetained(source).toOpaque(), callbacks: &callbacks),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.cannotWrite(url.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.cannotWrite(url.lastPathComponent) }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return Output(width: w, height: h, bytes: bytes, seconds: Date().timeIntervalSince(started))
    }
}

/// Renders the image band by band as ImageIO reads it.
private final class Bands {
    let list: DisplayList
    let area: CGRect
    let scale: CGFloat
    let width: Int, height: Int
    private var band = [UInt8]()
    private var bandStart = 0      // first row of the current band
    private var bandRows = 0
    private var offset = 0         // bytes read so far from the image
    private(set) var peakBand = 0

    init(list: DisplayList, area: CGRect, scale: CGFloat, width: Int, height: Int) {
        self.list = list
        self.area = area
        self.scale = scale
        self.width = width
        self.height = height
        bandStart = -1
    }

    private var rowBytes: Int { width * 4 }

    private func render(row: Int) {
        bandStart = row
        bandRows = min(BoardPNG.bandRows, height - row)
        let count = bandRows * rowBytes
        if band.count != count { band = [UInt8](repeating: 0, count: count) }
        peakBand = max(peakBand, count)
        band.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: bandRows, bitsPerComponent: 8, bytesPerRow: rowBytes,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.setFillColor(RGBA.paper.cg)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: bandRows))
            ctx.interpolationQuality = .high
            ctx.setShouldSmoothFonts(false)
            // y down, board pixels, this band's rows only
            ctx.translateBy(x: 0, y: CGFloat(bandRows))
            ctx.scaleBy(x: scale, y: -scale)
            let top = area.minY + CGFloat(row) / scale
            ctx.translateBy(x: -area.minX, y: -top)
            let visible = CGRect(x: area.minX, y: top, width: area.width, height: CGFloat(bandRows) / scale)
            ctx.clip(to: visible)
            let text = OutlineText(context: ctx, raster: true)
            let painter = BoardPainter(list: list, text: text, ctx: ctx)
            painter.imageScale = scale
            painter.paint(visible: visible)
        }
    }

    func read(into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        var written = 0
        let total = height * rowBytes
        while written < count, offset < total {
            let row = offset / rowBytes
            if bandStart < 0 || row < bandStart || row >= bandStart + bandRows { render(row: row) }
            let inBand = offset - bandStart * rowBytes
            let n = min(count - written, bandRows * rowBytes - inBand)
            band.withUnsafeBytes { src in
                (buffer + written).copyMemory(from: src.baseAddress! + inBand, byteCount: n)
            }
            written += n
            offset += n
        }
        return written
    }

    func skip(_ count: off_t) -> off_t {
        let total = height * rowBytes
        let n = min(Int(count), total - offset)
        offset += n
        return off_t(n)
    }

    func rewind() {
        offset = 0
    }
}
