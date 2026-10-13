import Foundation

/// Reads a file through `NSFileCoordinator`, repeating while its size or modification time change
/// under the read, so a half-written save is not delivered as final.
enum StableReader {
    /// The file's bytes once a read sees the same size and modification time before and after it.
    /// After `attempts` unstable reads the latest bytes are returned anyway; nil when the file is gone.
    static func read(path: String, presenter: (any NSFilePresenter)?, attempts: Int) -> Data? {
        var latest: Data?
        for _ in 0..<max(1, attempts) {
            guard let before = FileSignature(path: path) else { return latest }
            let data = coordinatedRead(URL(fileURLWithPath: path), presenter: presenter)
            let after = FileSignature(path: path)
            if let data { latest = data }
            if let data, let after, before == after, Int64(data.count) == after.size { return data }
            if after == nil { return latest }
        }
        return latest
    }

    /// One coordinated read. The watcher's own presenter is passed so coordination never waits on it.
    private static func coordinatedRead(_ url: URL, presenter: (any NSFilePresenter)?) -> Data? {
        var result: Data?
        var error: NSError?
        NSFileCoordinator(filePresenter: presenter).coordinate(readingItemAt: url, options: [.withoutChanges], error: &error) {
            result = try? Data(contentsOf: $0)
        }
        if result == nil, error != nil { result = try? Data(contentsOf: url) }
        return result
    }
}
