import AppKit
import Foundation

/// Watches one open document and delivers its content whenever any writer saves it: in-place
/// writes, atomic replaces, `mv` over, Vim-style saves, delete and recreate, and coordinated writes.
///
/// Signals: a vnode source on the parent folder (catches replaces) and one on the file (catches
/// in-place writes), rearmed whenever the file's inode changes and followed by a fresh stat so a
/// save between stat and rearm is not lost. An `NSFilePresenter` catches coordinated writers and
/// moves, and a wake notification triggers a stat after sleep. Neither is ever waited on.
///
/// Timing: every observed change bumps a generation counter. A read starts 40 ms after the last
/// change and repeats (up to 5 times) while size or modification time move under it. While changes
/// keep arriving less than 40 ms apart, an intermediate read is delivered at most every 250 ms with
/// `inBurst: true`; the read after the changes stop arrives with `inBurst: false`, and `.quiet`
/// follows 300 ms after the last change. A missing file is treated as being replaced for 500 ms
/// before `.missing`, or `.moved` when the same file turns up elsewhere. A file that is there but cannot
/// be opened (a privacy refusal, missing permissions) reports `.unreadable` with the error number.
/// Files on volumes that are not local are also polled every 2 s, since network volumes send no
/// events for writes made on other machines (OPEN-8).
///
/// `start()` delivers the current content once as generation 0. All methods are thread safe; the
/// handler runs on the queue given to `init`, and never after `stop()` returns on that queue.
public final class FileWatcher: @unchecked Sendable {
    /// Something that happened to the watched file.
    public enum Event: Sendable, Equatable {
        /// The file's bytes, read after the change numbered `generation`. `inBurst` is true for an
        /// intermediate read taken while writes were still arriving.
        case content(Data, generation: Int, inBurst: Bool)
        /// No change for 300 ms; `generation` is the last change seen.
        case quiet(generation: Int)
        /// The file has been gone for 500 ms and was not found elsewhere.
        case missing
        /// The file was renamed or moved to this URL, which `url` now returns.
        case moved(URL)
        /// The file is there but could not be opened; the value is the error number (EPERM for a
        /// privacy refusal, EACCES for permissions).
        case unreadable(Int32)
    }

    static let settleDelay = 0.040
    static let burstInterval = 0.250
    static let quietDelay = 0.300
    static let missingGrace = 0.500
    static let maxReadAttempts = 5
    static let pollInterval = 2.0

    /// The watched file's URL, updated when the file moves.
    public var url: URL { lock.withLock { currentURL } }

    private let lock = NSLock()
    private var currentURL: URL      // guarded by lock
    private var running = false      // guarded by lock
    private var session = 0          // guarded by lock

    private let target: DispatchQueue
    private let handler: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "linen.file-watcher", qos: .userInitiated)

    // Everything below is owned by `queue`.
    private var active = false
    private var activeSession = 0
    private var path: String
    private var folderSource: (any DispatchSourceFileSystemObject)?
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var fileDescriptor: Int32 = -1
    private var armedID: FileSignature.ID?
    private var lastSignature: FileSignature?
    private var lastPresent: FileSignature?
    private var generation = 0
    private var runActive = false
    private var runMark = DispatchTime.now()
    private var settleItem: DispatchWorkItem?
    private var quietItem: DispatchWorkItem?
    private var missingItem: DispatchWorkItem?
    private var missingReported = false
    private var presenter: WatcherPresenter?
    private var wakeObserver: (any NSObjectProtocol)?
    private var pollTimer: (any DispatchSourceTimer)?
    private let forcePolling: Bool

    /// Makes a watcher for `url`. Events are delivered on `queue`. Call `start()` to begin.
    /// `poll` forces the 2 s polling used for network volumes, for tests.
    public init(url: URL, queue: DispatchQueue = .main, poll: Bool = false, handler: @escaping @Sendable (FileWatcher.Event) -> Void) {
        let standard = url.standardizedFileURL
        currentURL = standard
        path = standard.path
        target = queue
        forcePolling = poll
        self.handler = handler
    }

    deinit {
        pollTimer?.cancel()
        folderSource?.cancel()
        fileSource?.cancel()
        settleItem?.cancel()
        quietItem?.cancel()
        missingItem?.cancel()
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    /// Starts watching and delivers the current content as generation 0 (or `.missing` after 500 ms
    /// when the file is not there). Calling it while running does nothing.
    public func start() {
        let started: Int? = lock.withLock {
            guard !running else { return nil }
            running = true
            session += 1
            return session
        }
        guard let started else { return }
        queue.async { self.begin(session: started) }
    }

    /// Stops watching. No event is delivered after this returns, when called on the handler's queue.
    public func stop() {
        let wasRunning: Bool = lock.withLock {
            let was = running
            running = false
            session += 1
            return was
        }
        guard wasRunning else { return }
        queue.async { self.teardown() }
    }

    // MARK: Lifecycle

    private func begin(session started: Int) {
        active = true
        activeSession = started
        path = url.path
        generation = 0
        runActive = false
        missingReported = false
        armFolder()
        registerPresenter()
        observeWake()
        armPolling()
        if FileSignature(path: path) != nil { armFile() }
        lastSignature = FileSignature(path: path)
        lastPresent = lastSignature
        if lastSignature != nil {
            deliverRead(inBurst: false)
        } else {
            scheduleMissing()
        }
    }

    private func teardown() {
        active = false
        for item in [settleItem, quietItem, missingItem] { item?.cancel() }
        settleItem = nil
        quietItem = nil
        missingItem = nil
        folderSource?.cancel()
        folderSource = nil
        pollTimer?.cancel()
        pollTimer = nil
        disarmFile()
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        presenter = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        lastSignature = nil
        lastPresent = nil
    }

    // MARK: Sources

    private func armFolder() {
        folderSource?.cancel()
        folderSource = nil
        let folder = (path as NSString).deletingLastPathComponent
        let descriptor = open(folder, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in self?.observe() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        folderSource = source
    }

    private func armFile() {
        disarmFile()
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        armedID = FileSignature(descriptor: descriptor)?.id
        fileDescriptor = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .attrib, .revoke], queue: queue)
        source.setEventHandler { [weak self] in self?.observe() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        fileSource = source
    }

    private func disarmFile() {
        fileSource?.cancel()
        fileSource = nil
        fileDescriptor = -1
        armedID = nil
    }

    /// Polls the file every 2 s when its volume is not local (or when forced), so remote writes are seen.
    private func armPolling() {
        pollTimer?.cancel()
        pollTimer = nil
        let folder = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
        let local = (try? folder.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? true
        guard forcePolling || !local else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.observe() }
        timer.resume()
        pollTimer = timer
    }

    private func registerPresenter() {
        let presenter = WatcherPresenter(
            url: URL(fileURLWithPath: path),
            onChange: { [weak self] in
                guard let self else { return }
                self.queue.async { self.observe() }
            },
            onMove: { [weak self] newURL in
                guard let self else { return }
                self.queue.async { self.presenterMoved(to: newURL) }
            })
        NSFileCoordinator.addFilePresenter(presenter)
        self.presenter = presenter
    }

    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.wake() }
        }
    }

    private func wake() {
        guard active else { return }
        if folderSource == nil { armFolder() }
        observe()
    }

    // MARK: Changes

    /// Stats the path, rearms the file source when the inode changed (then stats again), and records
    /// a change when the signature differs from the last one seen.
    private func observe() {
        guard active else { return }
        var signature = FileSignature(path: path)
        var rearms = 0
        while let current = signature, current.id != armedID, rearms < 4 {
            armFile()
            signature = FileSignature(path: path)
            rearms += 1
        }
        guard signature != lastSignature else { return }
        lastSignature = signature
        changed(signature)
    }

    private func changed(_ signature: FileSignature?) {
        generation += 1
        let now = DispatchTime.now()
        reschedule(&quietItem, after: Self.quietDelay) { $0.quietFired() }
        if let signature {
            lastPresent = signature
            missingItem?.cancel()
            missingItem = nil
            missingReported = false
        } else if missingItem == nil, !missingReported {
            scheduleMissing()
        }
        if runActive {
            let elapsed = Double(now.uptimeNanoseconds - runMark.uptimeNanoseconds) / 1e9
            if signature != nil, elapsed >= Self.burstInterval {
                runMark = now
                deliverRead(inBurst: true)
            }
        } else {
            runActive = true
            runMark = now
        }
        reschedule(&settleItem, after: Self.settleDelay) { $0.settleFired() }
    }

    private func settleFired() {
        settleItem = nil
        runActive = false
        guard lastSignature != nil else { return }
        deliverRead(inBurst: false)
    }

    private func quietFired() {
        quietItem = nil
        guard lastSignature != nil else { return }
        emit(.quiet(generation: generation))
    }

    private func deliverRead(inBurst: Bool) {
        let readGeneration = generation
        guard let data = StableReader.read(path: path, presenter: presenter, attempts: Self.maxReadAttempts) else {
            // There but not readable: say why, so the reader sees a state instead of an empty page.
            let descriptor = open(path, O_RDONLY | O_CLOEXEC)
            let error = errno
            if descriptor >= 0 { close(descriptor) } else if FileSignature(path: path) != nil { emit(.unreadable(error)) }
            return
        }
        emit(.content(data, generation: readGeneration, inBurst: inBurst))
    }

    // MARK: Missing and moves

    private func scheduleMissing() {
        reschedule(&missingItem, after: Self.missingGrace) { $0.missingFired() }
    }

    private func missingFired() {
        missingItem = nil
        observe()
        guard lastSignature == nil else { return }
        if fileDescriptor >= 0, let moved = OpenFile.currentPath(of: fileDescriptor, expected: armedID),
           !samePlace(moved, path) {
            adopt(moved)
            return
        }
        missingReported = true
        emit(.missing)
    }

    private func presenterMoved(to newURL: URL) {
        guard active else { return }
        let newPath = newURL.standardizedFileURL.path
        guard !samePlace(newPath, path), FileSignature(path: newPath) != nil else { return }
        adopt(newPath)
    }

    /// Follows the file to its new path: rearms the sources and the presenter, reports the move, and
    /// treats it as a change only when size or modification time moved too.
    private func adopt(_ newPath: String) {
        let newURL = URL(fileURLWithPath: newPath)
        lock.withLock { currentURL = newURL }
        path = newPath
        missingItem?.cancel()
        missingItem = nil
        missingReported = false
        armFolder()
        armPolling()
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        registerPresenter()
        if FileSignature(path: path)?.id != armedID { armFile() }
        emit(.moved(newURL))
        let signature = FileSignature(path: path)
        if let signature, let previous = lastPresent, signature.sameContentStamp(as: previous) {
            lastSignature = signature
            lastPresent = signature
        } else {
            lastSignature = signature
            changed(signature)
        }
    }

    private func samePlace(_ first: String, _ second: String) -> Bool {
        Paths.canonical(URL(fileURLWithPath: first)).path == Paths.canonical(URL(fileURLWithPath: second)).path
    }

    // MARK: Delivery

    private func emit(_ event: Event) {
        let expected = activeSession
        target.async { [self] in
            guard lock.withLock({ running && session == expected }) else { return }
            handler(event)
        }
    }

    private func reschedule(_ item: inout DispatchWorkItem?, after delay: Double,
                            _ action: @escaping @Sendable (FileWatcher) -> Void) {
        item?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active else { return }
            action(self)
        }
        item = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
