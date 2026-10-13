import Foundation

/// One tab of a restored session.
public struct TabState: Codable, Sendable, Equatable {
    /// Bookmark data for the tab's file, from `FileIdentity.bookmark(for:)`.
    public var bookmark: Data
    /// The file's path when the session was saved, shown when the bookmark no longer resolves.
    public var path: String

    /// Makes a tab state.
    public init(bookmark: Data, path: String) {
        self.bookmark = bookmark
        self.path = path
    }
}

/// The windows and tabs open when the app last saved its session.
public struct Session: Codable, Sendable, Equatable {
    /// Each window's tabs, in order.
    public var windows: [[TabState]]
    /// Each window's selected tab, by position; nil in sessions saved before it was recorded.
    public var front: [Int]?

    /// Makes a session.
    public init(windows: [[TabState]] = [], front: [Int]? = nil) {
        self.windows = windows
        self.front = front
    }
}

/// Saves and restores the session, in `session.json`.
public final class SessionStore: Sendable {
    private let file: JSONFileStore<Session>

    /// Opens (or creates) the store in `directory`.
    public init(directory: URL) {
        file = JSONFileStore(fileURL: directory.appendingPathComponent("session.json"), empty: Session())
    }

    /// The last saved session, empty when there is none.
    public var session: Session { file.read { $0 } }

    /// Replaces the session; it is written within 500 ms.
    public func save(_ session: Session) {
        file.mutate { $0 = session }
    }

    /// Writes pending changes now, for example at quit.
    public func flush() { file.flush() }
}
