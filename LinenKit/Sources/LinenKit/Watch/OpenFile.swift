import Foundation

/// Asks the system where an open file lives now.
enum OpenFile {
    /// The current path of the file open on `descriptor`, when it still has a name (it was renamed
    /// or moved rather than deleted) and is the file with identity `expected`.
    static func currentPath(of descriptor: Int32, expected: FileSignature.ID?) -> String? {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_nlink > 0,
              FileSignature(descriptor: descriptor)?.id == expected else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard FileSignature(path: path)?.id == expected else { return nil }
        return path
    }
}
