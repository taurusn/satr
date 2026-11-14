import Foundation

/// What each pinned file looked like when it was last opened on this phone, for the Library's thread (IOS-1). A file
/// is changed since read when it was opened before and its stamp differs now; a file never opened has no thread, so a
/// first sync does not mark everything. Kept in `reads.json`, keyed by `PinFileRef.storeKey`.
public final class ReadMarks: Sendable {
    private let file: JSONFileStore<[String: String]>

    public init(directory: URL) {
        file = JSONFileStore(fileURL: directory.appendingPathComponent("reads.json"), empty: [:])
    }

    /// A file's stamp: its content hash when the mirror knows it, else size and modification time.
    public static func stamp(size: Int64, modified: Date) -> String {
        "\(size):\(Int64((modified.timeIntervalSince1970 * 1000).rounded()))"
    }

    public func changed(_ ref: PinFileRef, stamp: String) -> Bool {
        let key = ref.storeKey
        return file.read { $0[key] }.map { $0 != stamp } ?? false
    }

    public func markRead(_ ref: PinFileRef, stamp: String) {
        let key = ref.storeKey
        file.mutate { $0[key] = stamp }
    }

    /// Records a stamp the file will never have, so it shows as changed (fixtures and tests).
    public func markStale(_ ref: PinFileRef) {
        let key = ref.storeKey
        file.mutate { $0[key] = "stale" }
    }

    public func forget(pin: Pin.ID) {
        let prefix = PinFileRef(pin: pin, path: "").storeKey
        file.mutate { marks in marks = marks.filter { !$0.key.hasPrefix(prefix) } }
    }

    public func flush() { file.flush() }
}
