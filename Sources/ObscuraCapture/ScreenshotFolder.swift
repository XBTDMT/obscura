public import Foundation

/// Reads where macOS saves screenshots. Mirrors the system's own lookup (spec §4 row 1): the
/// `com.apple.screencapture` defaults suite, key `location`, tilde-expanded, which must be an existing
/// directory; otherwise `~/Desktop`. This type only *reads* state. Changing the thumbnail setting means
/// `defaults write` + `killall SystemUIServer`, and the app layer decides whether to do that.
public enum ScreenshotFolder {
    public static let suiteName = "com.apple.screencapture"
    public static let locationKey = "location"
    public static let thumbnailKey = "show-thumbnail"

    /// The folder screenshots land in right now. There is no system notification when it changes, so the
    /// caller re-reads this on a slow timer and on window appear.
    public static func current(defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) -> URL {
        if let raw = defaults?.string(forKey: locationKey), !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(filePath: expanded, directoryHint: .isDirectory).standardizedFileURL
            }
        }
        return desktop
    }

    /// Whether the floating thumbnail is shown after a capture (default true). While it floats, the file
    /// has not been renamed to its final name yet, and a drag from the thumbnail bypasses the watcher.
    public static func floatingThumbnailEnabled(defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) -> Bool {
        guard let object = defaults?.object(forKey: thumbnailKey) else { return true }
        if let number = object as? NSNumber { return number.boolValue }
        if let string = object as? String { return (string as NSString).boolValue }
        return true
    }

    static var desktop: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop", directoryHint: .isDirectory)
    }
}
