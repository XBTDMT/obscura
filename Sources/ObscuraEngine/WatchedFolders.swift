// Where the folders Obscura guards are. The engine asks this each time it needs them (a folder change, a write-back
// check, an origin), so the answer is always the one in force now. Tests hand in their own folders; the app uses the
// system's.
public import Foundation
import ObscuraCapture

public struct FolderLocations: Sendable {
    /// Where macOS saves screenshots right now.
    public var screenshotFolder: @Sendable () -> URL
    /// The user's Downloads folder.
    public var downloads: @Sendable () -> URL

    public init(screenshotFolder: @escaping @Sendable () -> URL, downloads: @escaping @Sendable () -> URL) {
        self.screenshotFolder = screenshotFolder
        self.downloads = downloads
    }

    public static let system = FolderLocations(
        screenshotFolder: { ScreenshotFolder.current() },
        downloads: { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true) })
}
