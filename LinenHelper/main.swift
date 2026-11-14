import AppKit

// LinenHelper: the login item inside Linen.app (PRD-2 SYNC-2, section 9.3). No Dock icon and no menu bar item; it
// keeps pinned folders ready for the iPhone while Linen is closed.

let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Linen/Helper", isDirectory: true)
try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

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
