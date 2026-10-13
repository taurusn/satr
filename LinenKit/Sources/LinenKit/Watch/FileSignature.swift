import Foundation

/// What `FileWatcher` compares to decide that a file changed: its identity, size and modification
/// time. Access time and status-change time are left out, so reading or tagging a file is not a change.
struct FileSignature: Equatable, Sendable {
    /// The file's device and inode, which change when a writer replaces the file.
    struct ID: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
    }

    let id: ID
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    /// Stats `path`, following symlinks; nil when nothing is there.
    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        self.init(info)
    }

    /// Stats an open descriptor.
    init?(descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        self.init(info)
    }

    private init(_ info: stat) {
        id = ID(device: info.st_dev, inode: info.st_ino)
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }

    /// True when size and modification time match, whatever the identity.
    func sameContentStamp(as other: FileSignature) -> Bool {
        size == other.size && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
    }
}
