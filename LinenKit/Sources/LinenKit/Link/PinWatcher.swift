#if os(macOS)
import CoreServices
import Foundation

/// Watches the pinned folders and files with FSEvents and reports which pins changed, a quarter second after the last
/// event, so a burst of saves becomes one rescan (SYNC-5's changes within 2 s).
public final class PinWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "linen.link.watch")
    private var stream: FSEventStreamRef?
    private var roots: [(id: String, path: String)] = []
    private var pending = Set<String>()
    private var flush: DispatchWorkItem?
    private let onChange: @Sendable ([String]) -> Void

    public init(onChange: @escaping @Sendable ([String]) -> Void) { self.onChange = onChange }

    deinit { stop() }

    /// Watches these pins from now on.
    public func watch(_ pins: [(id: String, url: URL)]) {
        queue.sync {
            // realpath, as FSEvents reports it (`resolvingSymlinksInPath` drops `/private` from `/private/var`).
            let next = pins.map { ($0.id, Paths.canonical($0.url).path) }
            guard next.map(\.1) != roots.map(\.path) || next.map(\.0) != roots.map(\.id) else { return }
            roots = next.map { (id: $0.0, path: $0.1) }
            startStream()
        }
    }

    public func stop() {
        queue.sync {
            if let s = stream {
                FSEventStreamStop(s)
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
            }
            stream = nil
        }
    }

    private func startStream() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        guard !roots.isEmpty else { return }
        // A single-file pin is watched through its folder.
        let paths = Array(Set(roots.map { p in Paths.isDirectory(p.path) ? p.path : (p.path as NSString).deletingLastPathComponent }))
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<PinWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.events(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    /// On `queue`.
    private func events(_ paths: [String]) {
        for p in paths {
            for r in roots where p == r.path || p.hasPrefix(r.path + "/") || (!Paths.isDirectory(r.path) && (r.path as NSString).deletingLastPathComponent == p) {
                pending.insert(r.id)
            }
        }
        guard !pending.isEmpty else { return }
        flush?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let ids = Array(self.pending)
            self.pending = []
            self.onChange(ids)
        }
        flush = item
        queue.asyncAfter(deadline: .now() + 0.25, execute: item)
    }
}
#endif
