import Foundation

// The small pieces the Mac's seal files (Linen/Pages: PageSeal, PageScheme, PageScripts; Linen/Document/SafeOpen)
// take from Mac-only files, given here for the phone.

/// A thread-safe "stop" for work already queued (Linen/Document/Schemes.swift on the Mac).
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// True once (Linen/Pages/PageSelfTest.swift on the Mac).
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// The phone has no reviewed WebKit inventory (PAGE-10) yet: scripts are off for every page until the link brings
/// the Mac's trust decisions, so EngineFlags leaves the private feature switches alone, as it does on any WebKit build
/// the Mac has not reviewed.
enum PageSelfTest {
    nonisolated(unsafe) static var generatingInventory = false
    nonisolated static func inventoryURL() -> URL? { nil }
}
