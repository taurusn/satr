import AppKit

// LinenHelper: the login item inside Linen.app (PRD-2 SYNC-2, section 9.3). No Dock icon and no menu bar item; it
// keeps pinned folders ready for the iPhone while Linen is closed.

let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Linen/Helper", isDirectory: true)
try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

#if DEBUG
// Development only: `LINEN_HELPER_DEV=<folder> LinenHelper` runs a second helper beside the installed one, driven over
// stdin (see DevControl.swift). Never in a release build.
if let dev = ProcessInfo.processInfo.environment["LINEN_HELPER_DEV"] { DevControl.run(directory: URL(fileURLWithPath: dev)) }
#endif

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let service: HelperService
do {
    service = try HelperService(stateDirectory: support)
} catch {
    NSLog("LinenHelper could not start: \(error)")
    exit(1)
}
app.run()
