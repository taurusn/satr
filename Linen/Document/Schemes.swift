import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// Serves the renderer from the app bundle as linen-app://renderer/ (PRD section 9).
final class AppScheme: NSObject, WKURLSchemeHandler {
    private let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
        super.init()
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "renderer" else { task.didFailWithError(URLError(.badURL)); return }
        let rel = url.path.split(separator: "/").map(String.init).filter { $0 != ".." && $0 != "." }
        let file = rel.reduce(root) { $0.appendingPathComponent($1) }
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-store"])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Opens files inside a vault without a race (SAFE-2): the path is walked from a descriptor of the vault root with
/// `openat`, one component at a time, never following a symlink unless it resolves inside the vault, in which case
/// the walk restarts from the root with the resolved path (at most 8 times).
enum SafeOpen {
    static let maxBytes = 50 * 1024 * 1024

    struct Opened {
        let fd: Int32
        let device: UInt64
        let inode: UInt64
        let size: Int
    }

    /// Normalises path components relative to the root; nil if `..` would leave it.
    static func normalise(_ parts: [String]) -> [String]? {
        var out: [String] = []
        for p in parts where !p.isEmpty && p != "." {
            if p == ".." { if out.isEmpty { return nil }; out.removeLast() } else { out.append(p) }
        }
        return out
    }

    static func open(root: URL, relative: String) -> Opened? {
        let rootPath = root.resolvingSymlinksInPath().path
        let rootFD = Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { return nil }
        defer { close(rootFD) }
        guard var comps = normalise(relative.split(separator: "/").map(String.init)), !comps.isEmpty else { return nil }
        var hops = 0
        walk: while hops <= 8 {
            var dir = dup(rootFD)
            for (i, name) in comps.enumerated() {
                let last = i == comps.count - 1
                let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (last ? 0 : O_DIRECTORY))
                if fd >= 0 { close(dir); dir = fd; continue }
                let err = errno
                // A symlink: read it, resolve it against its folder, and restart if it stays inside the vault.
                var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = readlinkat(dir, name, &buf, Int(PATH_MAX))
                close(dir)
                guard (err == ELOOP || err == ENOTDIR || err == EMLINK), n > 0, hops < 8 else { return nil }
                let target = String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                var base: [String]
                if target.hasPrefix("/") {
                    guard target == rootPath || target.hasPrefix(rootPath + "/") else { return nil }
                    base = target.dropFirst(rootPath.count).split(separator: "/").map(String.init)
                } else {
                    base = Array(comps[0..<i]) + target.split(separator: "/").map(String.init)
                }
                guard let next = normalise(base + comps[(i + 1)...]), !next.isEmpty else { return nil }
                comps = next
                hops += 1
                continue walk
            }
            var st = stat()
            guard fstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, Int(st.st_size) <= maxBytes else { close(dir); return nil }
            return Opened(fd: dir, device: UInt64(st.st_dev), inode: UInt64(st.st_ino), size: Int(st.st_size))
        }
        return nil
    }

    /// Opens an absolute path outside a vault, for a file the reader allowed; the final component is not followed.
    static func openOutside(path: String) -> Opened? {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, Int(st.st_size) <= maxBytes else { close(fd); return nil }
        return Opened(fd: fd, device: UInt64(st.st_dev), inode: UInt64(st.st_ino), size: Int(st.st_size))
    }

    /// Reads the whole file, or its first `limit` bytes, and closes the descriptor.
    static func read(_ o: Opened, limit: Int? = nil) -> Data? {
        defer { close(o.fd) }
        let want = min(o.size, limit ?? o.size)
        var data = Data(count: want)
        let got = data.withUnsafeMutableBytes { buf -> Int in
            var total = 0
            while total < want {
                let n = Darwin.read(o.fd, buf.baseAddress!.advanced(by: total), want - total)
                if n <= 0 { break }
                total += n
            }
            return total
        }
        return got == want ? data : nil
    }
}

/// Image checks shared by local and remote images (SAFE-1, SAFE-2): the type by name and by first bytes, which must
/// agree; the 40-megapixel cap, checked without overflow; downsampling past twice the column width; SVG drawn into
/// a bounded bitmap so its size and work stay fixed.
enum ImageCheck {
    static let maxPixels = 40_000_000
    static let maxEdge = 2880 // twice the 720 px column, at 2x
    static let maxSVGBytes = 2 * 1024 * 1024
    static let kinds: [String: String] = ["png": "png", "jpg": "jpeg", "jpeg": "jpeg", "gif": "gif", "bmp": "bmp", "tif": "tiff",
                                          "tiff": "tiff", "webp": "webp", "heic": "heif", "heif": "heif", "avif": "heif", "svg": "svg"]
    static let mimes: [String: String] = ["png": "image/png", "jpeg": "image/jpeg", "gif": "image/gif", "bmp": "image/bmp",
                                          "tiff": "image/tiff", "webp": "image/webp", "heif": "image/heif", "svg": "image/svg+xml"]

    /// The image kind by first bytes, or nil when the bytes are not an image Linen shows.
    static func kind(of data: Data) -> String? {
        let b = [UInt8](data.prefix(16))
        guard b.count >= 4 else { return nil }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpeg" }
        if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if b.starts(with: [0x42, 0x4D]) { return "bmp" }
        if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if b.count >= 12, Array(b[0...3]) == [0x52, 0x49, 0x46, 0x46], Array(b[8...11]) == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if b.count >= 12, Array(b[4...7]) == [0x66, 0x74, 0x79, 0x70] { return "heif" } // HEIC, HEIF, AVIF
        let head = String(decoding: data.prefix(1024), as: UTF8.self).lowercased()
        return head.contains("<svg") ? "svg" : nil
    }

    /// A local image: its name and its bytes name the same kind (SAFE-2).
    static func accepts(name: String, data: Data) -> Bool {
        guard let want = kinds[(name as NSString).pathExtension.lowercased()], let got = kind(of: data) else { return false }
        return want == got
    }

    /// A remote image: its declared type and its bytes name the same kind (SAFE-1).
    static func accepts(mime: String, data: Data) -> Bool {
        guard let got = kind(of: data), let want = mimes[got] else { return false }
        let m = mime.lowercased()
        return m == want || (got == "jpeg" && m == "image/jpg") || (got == "heif" && (m == "image/heic" || m == "image/avif"))
    }

    /// Positive and at most 40 megapixels, by division so huge sizes cannot overflow.
    static func pixelsOK(_ s: CGSize) -> Bool {
        guard s.width.isFinite, s.height.isFinite, s.width >= 1, s.height >= 1, s.width < 1e9, s.height < 1e9 else { return false }
        let w = Int(s.width), h = Int(s.height)
        return w <= maxPixels / h
    }

    /// Pixel size, or nil when unreadable. For SVG, the size the drawn bitmap will have.
    static func size(of data: Data) -> CGSize? {
        if kind(of: data) == "svg" { return svgBitmapSize(data) }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    /// The bytes to serve: refused past 40 megapixels, downsampled past the column's edge, SVG drawn to PNG.
    static func prepare(_ data: Data) -> (data: Data, mime: String)? {
        guard let kind = kind(of: data) else { return nil }
        if kind == "svg" { return drawSVG(data) }
        guard let s = size(of: data), pixelsOK(s) else { return nil }
        guard max(s.width, s.height) > CGFloat(maxEdge), let src = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                       kCGImageSourceThumbnailMaxPixelSize: maxEdge,
                                                                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            return (data, mimes[kind] ?? "application/octet-stream")
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, thumb, nil)
        CGImageDestinationFinalize(dest)
        return (out as Data, "image/png")
    }

    /// SVG at 2x its own size, never past the column's edge; 720 by 360 when it names no size.
    private static func svgBitmapSize(_ data: Data) -> CGSize? {
        guard data.count <= maxSVGBytes, let image = NSImage(data: data), image.isValid else { return nil }
        var size = image.size
        if !(size.width >= 1 && size.height >= 1 && size.width.isFinite && size.height.isFinite) { size = CGSize(width: 720, height: 360) }
        let scale = min(2, CGFloat(maxEdge) / max(size.width, size.height))
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    private static func drawSVG(_ data: Data) -> (data: Data, mime: String)? {
        guard let px = svgBitmapSize(data), let image = NSImage(data: data),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: px))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]).map { ($0, "image/png") }
    }
}

/// A file the page may load: inside the vault by its path from the root, or outside by an absolute path the reader
/// allowed. The page only ever sees the grant's random id (SAFE-2).
struct Grant {
    let root: URL?
    let relative: String
    let absolute: String
    let device: UInt64
    let inode: UInt64
}

/// One local image request, checked off the main thread (SAFE-2): opened by descriptor, its name and bytes agreeing,
/// at most 40 megapixels.
enum ImageProbe {
    enum Result {
        case ok(Grant, CGSize?)
        case outside(String)
        case missing
    }

    /// `allowed` maps canonical paths outside the vault that the reader allowed to their device and inode.
    static func check(_ file: URL?, root: URL, allowed: [String: FileID]) -> Result {
        guard let f = file?.standardizedFileURL.resolvingSymlinksInPath() else { return .missing }
        let inside = f.path.hasPrefix(root.path + "/")
        let relative = inside ? String(f.path.dropFirst(root.path.count + 1)) : ""
        let opened: SafeOpen.Opened?
        if inside {
            opened = SafeOpen.open(root: root, relative: relative)
        } else if let id = allowed[f.path] {
            opened = SafeOpen.openOutside(path: f.path).flatMap { o in
                if o.device == id.device && o.inode == id.inode { return o }
                close(o.fd)
                return nil
            }
        } else {
            return FileManager.default.fileExists(atPath: f.path) ? .outside(f.lastPathComponent) : .missing
        }
        guard let o = opened else { return .missing }
        let device = o.device, inode = o.inode, whole = o.size
        // The header is enough for the type and, for most images, the size; read the rest only when it is not.
        guard let head = SafeOpen.read(o, limit: 256 * 1024), ImageCheck.accepts(name: f.lastPathComponent, data: head) else { return .missing }
        var size = ImageCheck.size(of: head)
        if size == nil, whole > head.count {
            let again = inside ? SafeOpen.open(root: root, relative: relative) : SafeOpen.openOutside(path: f.path)
            if let a = again, a.device == device, a.inode == inode, let all = SafeOpen.read(a) { size = ImageCheck.size(of: all) } else if let a = again { close(a.fd) }
        }
        if let s = size, !ImageCheck.pixelsOK(s) { return .missing }
        return .ok(Grant(root: inside ? root : nil, relative: relative, absolute: f.path, device: device, inode: inode), size)
    }
}

/// A file's identity on disk.
struct FileID: Hashable {
    let device: UInt64
    let inode: UInt64
}

/// linen-local://grant/<id>: serves granted files from a re-validated descriptor, never reopened by a path the page
/// supplied. The file is opened and its size counted against the 200 MB budget before any read; reading and
/// decoding run two at a time off the main thread, and a stopped request is dropped before its read or decode and
/// never answered.
@MainActor
final class LocalScheme: NSObject, WKURLSchemeHandler {
    private var grants: [String: Grant] = [:]
    private var servedBytes = 0
    private var live: [ObjectIdentifier: CancelFlag] = [:]
    private let work: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()
    static let maxBytesPerDocument = 200 * 1024 * 1024

    func reset() {
        grants.removeAll()
        servedBytes = 0
        for flag in live.values { flag.cancel() }
        live.removeAll()
    }

    func grant(_ g: Grant) -> String {
        let id = UUID().uuidString.lowercased()
        grants[id] = g
        return id
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "grant", let g = grants[url.lastPathComponent],
              let o = g.root.map({ SafeOpen.open(root: $0, relative: g.relative) }) ?? SafeOpen.openOutside(path: g.absolute) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        guard o.device == g.device, o.inode == g.inode, servedBytes + o.size <= Self.maxBytesPerDocument else {
            close(o.fd); task.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        servedBytes += o.size
        let key = ObjectIdentifier(task), flag = CancelFlag(), box = TaskBox(task), name = g.absolute, size = o.size
        live[key] = flag
        work.addOperation {
            // The descriptor is closed exactly once: here when stopped before the read, else by the read itself.
            let ready: (data: Data, mime: String)?
            if flag.isCancelled { close(o.fd); ready = nil } else { ready = Self.load(o, name: name, flag: flag) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.live.removeValue(forKey: key) != nil else { return }
                    guard let ready else {
                        self.servedBytes -= size
                        box.task.didFailWithError(URLError(.cannotDecodeContentData)); return
                    }
                    box.task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                        headerFields: ["Content-Type": ready.mime, "Content-Length": "\(ready.data.count)"])!)
                    box.task.didReceive(ready.data)
                    box.task.didFinish()
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        live.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }

    /// Reads (closing the descriptor) and decodes, unless the request was stopped first.
    nonisolated private static func load(_ o: SafeOpen.Opened, name: String, flag: CancelFlag) -> (data: Data, mime: String)? {
        guard let raw = SafeOpen.read(o), !flag.isCancelled, ImageCheck.accepts(name: name, data: raw) else { return nil }
        return ImageCheck.prepare(raw)
    }
}

/// A thread-safe "stop" for work already queued.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// linen-remote://fetch?u=: fetches a remote image for a document the reader allowed (SAFE-1). Ephemeral session,
/// no cookies, http and https only, 3 redirects, 10 s, streamed and cut off past 10 MB, an image by its declared type
/// and its bytes, at most 40 megapixels. Stopping a request cancels its download.
@MainActor
final class RemoteScheme: NSObject, WKURLSchemeHandler {
    var allowed = false
    private var fetcher: RemoteFetcher?
    private var running: [ObjectIdentifier: Int] = [:]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard allowed, let url = task.request.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = comps.queryItems?.first(where: { $0.name == "u" })?.value, let remote = URL(string: raw),
              ["http", "https"].contains(remote.scheme?.lowercased() ?? "") else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let fetcher = self.fetcher ?? RemoteFetcher()
        self.fetcher = fetcher
        let key = ObjectIdentifier(task)
        let box = TaskBox(task)
        running[key] = fetcher.start(remote) { [weak self] ready in
            MainActor.assumeIsolated {
                guard let self, self.running.removeValue(forKey: key) != nil else { return }
                guard let ready else { box.task.didFailWithError(URLError(.cannotDecodeContentData)); return }
                box.task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                    headerFields: ["Content-Type": ready.mime, "Content-Length": "\(ready.data.count)"])!)
                box.task.didReceive(ready.data)
                box.task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        if let id = running.removeValue(forKey: ObjectIdentifier(task)) { fetcher?.cancel(id) }
    }

    /// Cancels every download and releases the session; called when the tab closes or unloads.
    func close() {
        running.removeAll()
        fetcher?.invalidate()
        fetcher = nil
    }
}

private final class TaskBox: @unchecked Sendable {
    let task: any WKURLSchemeTask
    init(_ t: any WKURLSchemeTask) { task = t }
}

/// The streaming download behind `RemoteScheme`; callbacks arrive on the main queue.
private final class RemoteFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maxBytes = 10 * 1024 * 1024
    typealias Done = @Sendable ((data: Data, mime: String)?) -> Void
    private let lock = NSLock()
    private var tasks: [Int: URLSessionTask] = [:]
    private var buffers: [Int: Data] = [:]
    private var mimes: [Int: String] = [:]
    private var redirects: [Int: Int] = [:]
    private var done: [Int: Done] = [:]
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 10
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: c, delegate: self, delegateQueue: queue)
    }()

    func start(_ url: URL, done callback: @escaping Done) -> Int {
        let task = session.dataTask(with: url)
        lock.withLock {
            tasks[task.taskIdentifier] = task
            buffers[task.taskIdentifier] = Data()
            done[task.taskIdentifier] = callback
        }
        task.resume()
        return task.taskIdentifier
    }

    func cancel(_ id: Int) {
        let task: URLSessionTask? = lock.withLock {
            done[id] = nil
            return tasks[id]
        }
        task?.cancel()
    }

    func invalidate() {
        lock.withLock { done.removeAll() }
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let mime = http.mimeType?.lowercased(), mime.hasPrefix("image/"),
              http.expectedContentLength <= Int64(Self.maxBytes) else { return .cancel }
        lock.withLock { mimes[dataTask.taskIdentifier] = mime }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over: Bool = lock.withLock {
            buffers[dataTask.taskIdentifier, default: Data()].append(data)
            return (buffers[dataTask.taskIdentifier]?.count ?? 0) > Self.maxBytes
        }
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        let count: Int = lock.withLock {
            redirects[task.taskIdentifier, default: 0] += 1
            return redirects[task.taskIdentifier]!
        }
        guard count <= 3, let scheme = request.url?.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        return request
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let id = task.taskIdentifier
        let (data, mime, callback): (Data?, String?, Done?) = lock.withLock {
            defer { tasks[id] = nil; buffers[id] = nil; mimes[id] = nil; redirects[id] = nil; done[id] = nil }
            return (buffers[id], mimes[id], done[id])
        }
        guard let callback else { return }
        var ready: (data: Data, mime: String)?
        if error == nil, let data, let mime, data.count <= Self.maxBytes, ImageCheck.accepts(mime: mime, data: data) {
            ready = ImageCheck.prepare(data)
        }
        DispatchQueue.main.async { callback(ready) }
    }
}
