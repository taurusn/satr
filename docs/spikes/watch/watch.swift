// Spike S(b): which signals see each kind of save. Watches one file three ways and prints every event:
// a vnode source on the open file, a vnode source on its folder, and an NSFilePresenter.
import Foundation

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)
let t0 = Date()
func log(_ s: String) { print(String(format: "%7.3f  %@", Date().timeIntervalSince(t0), s)); fflush(stdout) }
func inode(_ p: String) -> String { (try? FileManager.default.attributesOfItem(atPath: p)[.systemFileNumber]).map { "\($0)" } ?? "gone" }

var fileSource: DispatchSourceFileSystemObject?
func watchFile() {
    fileSource?.cancel()
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { log("file: cannot open (gone)"); return }
    let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib, .revoke], queue: .main)
    s.setEventHandler { log("file vnode: \(s.data) inode now \(inode(path))") }
    s.setCancelHandler { close(fd) }
    s.resume()
    fileSource = s
}
let dfd = open(url.deletingLastPathComponent().path, O_EVTONLY)
let dirSource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dfd, eventMask: [.write], queue: .main)
dirSource.setEventHandler { log("dir vnode: write, file inode \(inode(path))"); watchFile() }
dirSource.resume()

final class Presenter: NSObject, NSFilePresenter {
    var presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    init(_ u: URL) { presentedItemURL = u }
    func presentedItemDidChange() { log("presenter: didChange") }
    func presentedItemDidMove(to newURL: URL) { log("presenter: didMove to \(newURL.lastPathComponent)") }
    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) { log("presenter: deletion"); completionHandler(nil) }
}
let presenter = Presenter(url)
NSFileCoordinator.addFilePresenter(presenter)
watchFile()
log("watching \(url.lastPathComponent) inode \(inode(path))")
DispatchQueue.main.asyncAfter(deadline: .now() + Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "60")!) { exit(0) }
dispatchMain()
