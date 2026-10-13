import Foundation

/// The `NSFilePresenter` a `FileWatcher` registers, so coordinated writers and moves are seen. It
/// never blocks: every callback is forwarded to the watcher's queue and answered at once.
final class WatcherPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemOperationQueue: OperationQueue
    private let lock = NSLock()
    private var itemURL: URL
    private let onChange: @Sendable () -> Void
    private let onMove: @Sendable (URL) -> Void

    init(url: URL, onChange: @escaping @Sendable () -> Void, onMove: @escaping @Sendable (URL) -> Void) {
        itemURL = url
        self.onChange = onChange
        self.onMove = onMove
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "linen.file-watcher.presenter"
        presentedItemOperationQueue = queue
        super.init()
    }

    var presentedItemURL: URL? { lock.withLock { itemURL } }

    func presentedItemDidChange() { onChange() }

    func presentedItemDidMove(to newURL: URL) {
        lock.withLock { itemURL = newURL }
        onMove(newURL)
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        completionHandler(nil)
        onChange()
    }
}
