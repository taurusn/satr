import Foundation

/// A plain diagnostic log: ~/Library/Logs/Linen.log.
enum Log {
    private static let queue = DispatchQueue(label: "linen.log")
    nonisolated(unsafe) private static var handle: FileHandle? = {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Linen.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        return try? FileHandle(forWritingTo: url)
    }()

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        queue.async {
            handle?.seekToEndOfFile()
            handle?.write(Data("\(stamp) \(line)\n".utf8))
        }
    }
}
