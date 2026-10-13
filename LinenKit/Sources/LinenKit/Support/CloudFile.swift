import Foundation

/// iCloud Drive files that are not downloaded (OPEN-8): never read in the background, since a read downloads them.
public enum CloudFile {
    /// True for a file whose contents live only in the cloud.
    public static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_flags & UInt32(SF_DATALESS)) != 0
    }
}
