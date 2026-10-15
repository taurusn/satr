import Foundation
import UniformTypeIdentifiers
import WebKit

/// The page's folder, held open by descriptor for the tab's life (Codex m9 review, item 1): renaming the folder
/// and putting a symlink in its place cannot move the page's reach somewhere else, because every file is opened by
/// walking from this descriptor, never from the folder's path again.
final class PinnedFolder: @unchecked Sendable {
    let fd: Int32
    let path: String
    let device: UInt64
    let inode: UInt64

    init?(_ url: URL) {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        let d = Darwin.open(p, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard d >= 0 else { return nil }
        var st = stat()
        guard fstat(d, &st) == 0 else { close(d); return nil }
        fd = d
        path = p
        device = UInt64(st.st_dev)
        inode = UInt64(st.st_ino)
    }

    deinit { close(fd) }

    /// SafeOpen's walk (Linen/Document/Schemes.swift), started from the pinned descriptor: one component at a time
    /// with O_NOFOLLOW; a symlink is followed only when it resolves inside the folder, and then the walk restarts
    /// from the descriptor (at most 8 times). Regular files only, at most SafeOpen.maxBytes.
    func open(_ relative: String) -> SafeOpen.Opened? {
        guard var comps = SafeOpen.normalise(relative.split(separator: "/").map(String.init)), !comps.isEmpty else { return nil }
        var hops = 0
        walk: while hops <= 8 {
            var dir = dup(fd)
            guard dir >= 0 else { return nil }
            for (i, name) in comps.enumerated() {
                let last = i == comps.count - 1
                let next = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (last ? 0 : O_DIRECTORY))
                if next >= 0 { close(dir); dir = next; continue }
                let err = errno
                var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = readlinkat(dir, name, &buf, Int(PATH_MAX))
                close(dir)
                guard err == ELOOP || err == ENOTDIR || err == EMLINK, n > 0, hops < 8 else { return nil }
                let target = String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                var base: [String]
                if target.hasPrefix("/") {
                    guard target == path || target.hasPrefix(path + "/") else { return nil }
                    base = target.dropFirst(path.count).split(separator: "/").map(String.init)
                } else {
                    base = Array(comps[0..<i]) + target.split(separator: "/").map(String.init)
                }
                guard let resolved = SafeOpen.normalise(base + comps[(i + 1)...]), !resolved.isEmpty else { return nil }
                comps = resolved
                hops += 1
                continue walk
            }
            var st = stat()
            guard fstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, Int(st.st_size) <= SafeOpen.maxBytes else { close(dir); return nil }
            return SafeOpen.Opened(fd: dir, device: UInt64(st.st_dev), inode: UInt64(st.st_ino), size: Int(st.st_size))
        }
        return nil
    }

    /// Where an opened file really is (symlinks resolved by the kernel), for handing a link to the rest of Linen.
    static func realPath(of fd: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) != -1 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// linen-page://<random>/: serves one sealed page and the files in its folder (PAGE-2). It answers only its own
/// exact authority (no port, no user) and refuses every other (WebKit registers a handler per scheme, not per
/// host); files are opened by a descriptor walk from the pinned folder, dot-files and anything outside are refused,
/// and when the folder is the home folder, a volume's root or the top of Desktop, Documents or Downloads only the
/// page itself is served. Every response carries the CSP (so every document, frame, worker and worklet script gets
/// it) and `nosniff`. Work is bounded: 64 requests in flight, 1 GB served per load, 3 reads at a time, each held
/// until delivered. A test or the self-test can serve an in-memory folder instead of the disk.
@MainActor
final class PageScheme: NSObject, WKURLSchemeHandler {
    let host: String
    let folder: URL
    let pinned: PinnedFolder?
    let pagePath: String
    let onlyPage: Bool
    let virtualFiles: [String: Data]?
    var scripts: Bool
    var options: SealOptions
    /// Every request and what was done with it, for the spike and the self-test (never page content).
    var onRequest: ((_ url: String, _ served: Bool, _ reason: String) -> Void)?
    static let maxInFlight = 64
    static let maxBytesPerLoad = 1024 * 1024 * 1024
    private var live: [ObjectIdentifier: CancelFlag] = [:]
    private var servedBytes = 0
    private let work: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .userInitiated
        return q
    }()

    /// A page on disk: `page` is the HTML file, already canonical (the controller resolves it once); its folder is
    /// what the page may reach.
    init(page: URL, scripts: Bool, options: SealOptions = .full, pinned held: PinnedFolder? = nil) {
        let f = page.standardizedFileURL
        host = PageSeal.randomHost()
        folder = f.deletingLastPathComponent()
        // The tab passes the folder it pinned when it opened, so a rebuild never re-resolves the path (review 2).
        pinned = held ?? PinnedFolder(folder)
        pagePath = f.lastPathComponent
        onlyPage = Self.isBroadRoot(folder)
        virtualFiles = nil
        self.scripts = scripts
        self.options = options
    }

    /// An in-memory folder (the self-test's probe pages), keyed by relative path.
    init(files: [String: Data], page: String, scripts: Bool, options: SealOptions) {
        host = PageSeal.randomHost()
        folder = URL(fileURLWithPath: "/var/empty")
        pinned = nil
        pagePath = page
        onlyPage = false
        virtualFiles = files
        self.scripts = scripts
        self.options = options
    }

    var pageURL: URL { URL(string: "\(PageSeal.pageScheme)://\(host)/\(Self.encode(pagePath))")! }
    var origin: String { "\(PageSeal.pageScheme)://\(host)" }

    static func encode(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? "" }
            .joined(separator: "/")
    }

    /// The home folder, any volume's root (by the file system, wherever it is mounted), or the top of Desktop,
    /// Documents or Downloads (PAGE-2).
    static func isBroadRoot(_ folder: URL) -> Bool {
        let u = folder.resolvingSymlinksInPath().standardizedFileURL
        let p = u.path
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
        let tops = [home, "/"] + ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 }
        if tops.contains(p) { return true }
        if (try? u.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true { return true }
        let parts = p.split(separator: "/")
        return parts.count == 2 && parts[0] == "Volumes"
    }

    /// True for this page's exact origin (scheme, random host, no port, no user).
    func isOwn(_ u: URL) -> Bool {
        u.scheme == PageSeal.pageScheme && u.host?.lowercased() == host && u.port == nil && u.user == nil && u.password == nil
    }

    /// Starts a new load's byte budget (the controller calls it before each main-frame load).
    func resetBudget() { servedBytes = 0 }

    /// Drops every request still in flight (teardown).
    func cancelAll() {
        for f in live.values { f.cancel() }
        live.removeAll()
        work.cancelAllOperations()
    }

    /// The page-relative path of a request, or nil with the reason it is refused. The path is split while still
    /// percent-encoded, so an encoded separator cannot make a new component.
    func relativePath(of url: URL) -> (path: String?, reason: String) {
        guard url.scheme == PageSeal.pageScheme else { return (nil, "scheme") }
        guard isOwn(url) else { return (nil, "another host") }
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        var parts: [String] = []
        for piece in raw.split(separator: "/", omittingEmptySubsequences: true) {
            guard let d = String(piece).removingPercentEncoding, !d.isEmpty else { return (nil, "bad encoding") }
            if d.contains("/") || d.contains("\\") || d.contains("\0") { return (nil, "encoded separator") }
            if d == ".." { return (nil, "leaves the folder") }
            if d == "." { continue }
            parts.append(d)
        }
        guard !parts.isEmpty else { return (nil, "folder") }
        let rel = parts.joined(separator: "/")
        // Hidden files and folders (.git, .env) are never served; the page itself is, whatever its name.
        if rel != pagePath, parts.contains(where: { $0.hasPrefix(".") }) { return (nil, "hidden file") }
        if onlyPage && rel != pagePath { return (nil, "only the page is served from this folder") }
        return (rel, "")
    }

    /// The preflight page: Linen's own, run with scripts in this tab's exact configuration before the author's page.
    /// It checks the removal script pinned WebRTC, the rule list blocks its canary path, and the CSP reports a
    /// violation, each only when that wall is meant to be on, and writes the result for the isolated world to read.
    func preflightHTML() -> String {
        """
        <!doctype html><meta charset="utf-8"><title>Linen</title><pre></pre><script>
        (async () => {
          const r = {};
          if (\(options.removal)) { const d = Object.getOwnPropertyDescriptor(window, 'RTCPeerConnection'); r.removal = !!d && d.configurable === false && d.value === undefined; }
          if (\(options.rules)) { try { await fetch('\(PageSeal.ruleCanaryPath)'); r.rules = false; } catch (e) { r.rules = true; } }
          if (\(options.csp)) {
            r.csp = await new Promise((ok) => {
              document.addEventListener('securitypolicyviolation', () => ok(true), {once: true});
              fetch('http://127.0.0.1:9/').catch(() => {});
              setTimeout(() => ok(false), 1500);
            });
          }
          document.querySelector('pre').textContent = JSON.stringify(r);
        })();
        </script>
        """
    }

    var preflightURL: URL { URL(string: "\(origin)/\(PageSeal.preflightPath)")! }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        if isOwn(url), url.path == "/" + PageSeal.preflightPath || url.path == "/" + PageSeal.ruleCanaryPath {
            // The canary answers when the rule list failed to block it, which the preflight reads as a missing wall.
            var h = responseHeaders(for: PageSeal.preflightPath)
            if options.csp { h["Content-Security-Policy"] = PageSeal.csp(scripts: true, sandbox: options.sandbox) }
            let body = url.path == "/" + PageSeal.preflightPath ? preflightHTML() : "canary"
            onRequest?(url.absoluteString, true, url.path == "/" + PageSeal.ruleCanaryPath ? "rule canary reached" : "preflight")
            respond(task, url: url, data: Data(body.utf8), headers: h, range: nil)
            return
        }
        let (rel, reason) = relativePath(of: url)
        guard let rel else {
            onRequest?(url.absoluteString, false, reason)
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let headers = responseHeaders(for: rel)
        let range = task.request.value(forHTTPHeaderField: "Range")
        if let files = virtualFiles {
            guard let data = files[rel] else {
                onRequest?(url.absoluteString, false, "missing")
                task.didFailWithError(URLError(.fileDoesNotExist)); return
            }
            onRequest?(url.absoluteString, true, "")
            respond(task, url: url, data: data, headers: headers, range: range)
            return
        }
        guard live.count < Self.maxInFlight else {
            onRequest?(url.absoluteString, false, "too many requests at once")
            task.didFailWithError(URLError(.resourceUnavailable)); return
        }
        guard let pinned else {
            onRequest?(url.absoluteString, false, "folder not available")
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let key = ObjectIdentifier(task), flag = CancelFlag(), box = SchemeTaskBox(task)
        live[key] = flag
        work.addOperation {
            guard !flag.isCancelled, let opened = pinned.open(rel) else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(key, box, url, nil, headers, range) } }
                return
            }
            let data = SafeOpen.read(opened)
            // Hold this read until the main thread has handed it to WebKit, so at most three are ever in memory.
            let delivered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(key, box, url, data, headers, range) }
                delivered.signal()
            }
            delivered.wait()
        }
    }

    private func finish(_ key: ObjectIdentifier, _ box: SchemeTaskBox, _ url: URL, _ data: Data?, _ headers: [String: String], _ range: String?) {
        guard live.removeValue(forKey: key) != nil else { return }
        guard let data else {
            onRequest?(url.absoluteString, false, "missing or outside the folder")
            box.task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        guard servedBytes + data.count <= Self.maxBytesPerLoad else {
            onRequest?(url.absoluteString, false, "over this page's budget")
            box.task.didFailWithError(URLError(.dataLengthExceedsMaximum)); return
        }
        servedBytes += data.count
        onRequest?(url.absoluteString, true, "")
        respond(box.task, url: url, data: data, headers: headers, range: range)
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        live.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }

    func responseHeaders(for rel: String) -> [String: String] {
        var h = [
            "Content-Type": Self.mime(for: rel),
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "no-store",
            "Referrer-Policy": "no-referrer",
            "Accept-Ranges": "bytes",
        ]
        if options.csp { h["Content-Security-Policy"] = PageSeal.csp(scripts: scripts, sandbox: options.sandbox) }
        return h
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, headers: [String: String], range: String?) {
        var h = headers
        var body = data
        var status = 200
        if let range {
            switch Self.byteRange(range, count: data.count) {
            case let .some(r):
                body = data.subdata(in: r)
                status = 206
                h["Content-Range"] = "bytes \(r.lowerBound)-\(r.upperBound - 1)/\(data.count)"
            case .none:
                body = Data()
                status = 416
                h["Content-Range"] = "bytes */\(data.count)"
            }
        }
        h["Content-Length"] = "\(body.count)"
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: h)!)
        task.didReceive(body)
        task.didFinish()
    }

    /// `bytes=a-b`, `bytes=a-` or `bytes=-n`, for media elements; nil when unsatisfiable. No arithmetic can overflow:
    /// an end past the file is clamped before adding one.
    nonisolated static func byteRange(_ header: String, count: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), count > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let ends = spec.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard ends.count == 2 else { return nil }
        switch (ends[0], ends[1]) {
        case let (a?, b?) where a >= 0 && b >= a && a < count: return a..<(b >= count - 1 ? count : b + 1)
        case let (a?, nil) where a >= 0 && a < count: return a..<count
        case let (nil, n?) where n > 0: return (n >= count ? 0 : count - n)..<count
        default: return nil
        }
    }

    nonisolated static func mime(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json", "map": return "application/json"
        case "svg": return "image/svg+xml"
        case "wasm": return "application/wasm"
        case "txt", "md", "markdown", "csv": return "text/plain; charset=utf-8"
        case "otf": return "font/otf"
        case "ttf": return "font/ttf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}

/// linen-kit://kit/: the Loom kit (PAGE-3), a separate read-only origin serving exactly `loom.css` and the six
/// Thmanyah faces, with the CORS header fonts need. Any other host or path is refused.
@MainActor
final class KitScheme: NSObject, WKURLSchemeHandler {
    static let faces = ["thmanyahsans-Regular", "thmanyahsans-Medium", "thmanyahsans-Bold", "thmanyahserifdisplay-Light",
                        "thmanyahseriftext-Regular", "thmanyahseriftext-Medium"]
    let css: URL?
    let fonts: URL?
    var onRequest: ((_ url: String, _ served: Bool) -> Void)?

    init(css: URL?, fonts: URL?) {
        self.css = css
        self.fonts = fonts
    }

    /// The kit as the app ships it: loom.css from the bundle, the faces from the renderer's fonts folder.
    static func bundled() -> KitScheme {
        let res = Bundle.main.resourceURL
        let css = Bundle.main.url(forResource: "loom", withExtension: "css") ?? res?.appendingPathComponent("kit/loom.css")
        return KitScheme(css: css, fonts: res?.appendingPathComponent("renderer/fonts"))
    }

    func file(for url: URL) -> (URL, String)? {
        guard url.scheme == PageSeal.kitScheme, url.host == PageSeal.kitHost, url.port == nil, url.user == nil, url.password == nil else { return nil }
        let path = url.path
        if path == "/loom.css", let css { return (css, "text/css") }
        for f in Self.faces where path == "/fonts/\(f).otf" {
            if let fonts { return (fonts.appendingPathComponent("\(f).otf"), "font/otf") }
        }
        return nil
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let (file, mime) = file(for: url), let data = try? Data(contentsOf: file) else {
            onRequest?(task.request.url?.absoluteString ?? "?", false)
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        onRequest?(url.absoluteString, true)
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime, "Content-Length": "\(data.count)", "X-Content-Type-Options": "nosniff",
            "Access-Control-Allow-Origin": "*", "Cross-Origin-Resource-Policy": "cross-origin", "Cache-Control": "max-age=3600",
        ])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Carries a scheme task across the hop to the main queue.
final class SchemeTaskBox: @unchecked Sendable {
    let task: any WKURLSchemeTask
    init(_ task: any WKURLSchemeTask) { self.task = task }
}
