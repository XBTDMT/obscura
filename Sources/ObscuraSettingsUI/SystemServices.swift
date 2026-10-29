// What the Settings window reads from and does to macOS outside Obscura's own stores: folder access, the
// screenshot folder and floating thumbnail, notification permission, the login item, links, relaunch.
// Probes are injected so tests and previews never touch TCC, SMAppService or the notification center.
import AppKit
import Foundation
import ObscuraCapture
import UserNotifications

/// A snapshot of the system state the Protection and About panes show.
struct SystemSnapshot: Equatable, Sendable {
    var screenshotFolder: URL
    var screenshotAccess: FolderAccessState
    var downloads: URL
    var downloadsAccess: FolderAccessState
    /// Extra folder path → access state.
    var folderAccess: [String: FolderAccessState]
    var floatingThumbnail: Bool
    /// nil while unknown (outside an app bundle, or not yet asked).
    var notificationsDenied: Bool?
    var loginItem: LoginItemStatus

    static let placeholder = SystemSnapshot(
        screenshotFolder: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop"),
        screenshotAccess: .granted, downloads: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads"),
        downloadsAccess: .granted, folderAccess: [:], floatingThumbnail: false, notificationsDenied: nil, loginItem: .disabled)
}

/// The system calls the window makes, behind one seam.
struct SystemServices: Sendable {
    var snapshot: @Sendable (_ extraFolders: [String], _ probeDownloads: Bool) async -> SystemSnapshot
    var setFloatingThumbnail: @Sendable (_ enabled: Bool) async -> Void
    var setLoginItem: @Sendable (_ enabled: Bool) -> LoginItemStatus
    var openLoginItems: @MainActor @Sendable () -> Void
    var open: @MainActor @Sendable (_ url: URL) -> Void
    var reveal: @MainActor @Sendable (_ url: URL) -> Void
    var relaunch: @MainActor @Sendable () -> Bool

    /// True when this process is a real app bundle (not `swift test`), so TCC, SMAppService and notifications apply.
    static var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    static let live = SystemServices(
        snapshot: { extra, probeDownloads in
            let shots = ScreenshotFolder.current()
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
            var folders: [String: FolderAccessState] = [:]
            for path in extra { folders[path] = FolderAccess.probe(URL(filePath: path, directoryHint: .isDirectory)) }
            return SystemSnapshot(
                screenshotFolder: shots, screenshotAccess: FolderAccess.probe(shots),
                // Probing Downloads is what asks macOS for access, so it is only probed once the user turned it on.
                downloads: downloads, downloadsAccess: probeDownloads ? FolderAccess.probe(downloads) : .granted,
                folderAccess: folders, floatingThumbnail: ScreenshotFolder.floatingThumbnailEnabled(),
                notificationsDenied: await notificationsDenied(),
                loginItem: isAppBundle ? LoginItem.status() : .notFound)
        },
        setFloatingThumbnail: { enabled in await FloatingThumbnail.set(enabled) },
        setLoginItem: { enabled in
            guard isAppBundle else { return .notFound }
            try? LoginItem.setEnabled(enabled)
            return LoginItem.status()
        },
        openLoginItems: { LoginItem.openSystemSettings() },
        open: { NSWorkspace.shared.open($0) },
        reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        relaunch: { Relaunch.scheduleAfterExit() })

    /// A fixed snapshot and inert actions, for tests and previews.
    static func fixed(_ snapshot: SystemSnapshot) -> SystemServices {
        SystemServices(snapshot: { _, _ in snapshot }, setFloatingThumbnail: { _ in }, setLoginItem: { _ in snapshot.loginItem },
                       openLoginItems: {}, open: { _ in }, reveal: { _ in }, relaunch: { false })
    }

    private static func notificationsDenied() async -> Bool? {
        guard isAppBundle else { return nil }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .denied: return true
        case .authorized, .provisional, .ephemeral: return false
        default: return nil
        }
    }
}

/// System Settings deep links.
enum SystemLinks {
    static let filesAndFolders = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    static var notifications: URL {
        let id = Bundle.main.bundleIdentifier ?? ""
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
            ?? URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
    }
}

/// The screenshot floating thumbnail lives in the `com.apple.screencapture` domain; SystemUIServer only reads it
/// at launch, so it is restarted after the write (the same two steps the Screenshot app's own option takes).
enum FloatingThumbnail {
    static func set(_ enabled: Bool) async {
        await Task.detached {
            run("/usr/bin/defaults", ["write", ScreenshotFolder.suiteName, ScreenshotFolder.thumbnailKey, "-bool", enabled ? "true" : "false"])
            run("/usr/bin/killall", ["SystemUIServer"])
        }.value
    }

    private static func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Reported by the next snapshot: the row keeps showing the thumbnail as on.
        }
    }
}

/// Restarts Obscura for a language change: a detached shell waits for this process to exit, then reopens the bundle.
/// The caller then quits through the router (the panel's real Quit), so the app's ⌘Q interception does not hold it.
enum Relaunch {
    static func scheduleAfterExit() -> Bool {
        guard SystemServices.isAppBundle else { return false }
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                             "obscura-relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do { try process.run(); return true } catch { return false }
    }
}

/// The product's own addresses, read from the bundle so nothing is hard-coded here. The website and repository are
/// derived from the update feed (`ObscuraUpdateFeedURL`, a GitHub Pages address, G-33); a feedback mailbox is used only
/// when the bundle names one (`ObscuraFeedbackEmail`), otherwise feedback goes to the repository's issue form. A build
/// still holding the placeholder feed address has no links rather than wrong ones.
enum ProductLinks {
    static var feedURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "ObscuraUpdateFeedURL") as? String, !text.contains("REPLACE_WITH")
        else { return nil }
        return URL(string: text)
    }

    static var website: URL? {
        if let s = Bundle.main.object(forInfoDictionaryKey: "ObscuraWebsiteURL") as? String, let url = URL(string: s) { return url }
        return feedURL?.deletingLastPathComponent()
    }

    static var repository: URL? {
        if let s = Bundle.main.object(forInfoDictionaryKey: "ObscuraRepositoryURL") as? String, let url = URL(string: s) { return url }
        // https://<owner>.github.io/<repo>/obscura-update.json → https://github.com/<owner>/<repo>
        guard let feed = feedURL, let host = feed.host(), host.hasSuffix(".github.io") else { return nil }
        let owner = host.dropLast(".github.io".count)
        guard let repo = feed.pathComponents.dropFirst().first, !owner.isEmpty else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repo)")
    }

    static var feedbackEmail: String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "ObscuraFeedbackEmail") as? String, s.contains("@") else { return nil }
        return s
    }

    static var feedback: URL? {
        if let email = feedbackEmail {
            var c = URLComponents()
            c.scheme = "mailto"
            c.path = email
            c.queryItems = [URLQueryItem(name: "subject", value: "Obscura feedback")]
            return c.url
        }
        return repository?.appending(path: "issues/new")
    }

    /// "obscura.example" style display of a URL: host and path, no scheme.
    static func display(_ url: URL) -> String {
        let host = url.host() ?? ""
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? host : "\(host)/\(path)"
    }
}

/// The running build.
enum BuildInfo {
    static var version: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
    static var build: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String }
    static var isUniversal: Bool { (Bundle.main.executableArchitectures?.count ?? 0) > 1 }

    /// "Version 1.0 (112) · Universal · macOS 15 or later"
    static var line: String {
        var parts: [String] = []
        if let version {
            parts.append(build.map { String(localized: "Version \(version) (\($0))") } ?? String(localized: "Version \(version)"))
        }
        if isUniversal { parts.append(String(localized: "Universal")) }
        parts.append(String(localized: "macOS 15 or later"))
        return parts.joined(separator: " · ")
    }
}
