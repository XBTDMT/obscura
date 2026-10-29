// Everything setup asks of macOS, behind closures so tests and previews never raise a real prompt.
import AppKit
import Foundation
import ObscuraCapture
import UserNotifications

@MainActor
struct SetupSystem {
    var screenshotFolder: () -> URL
    var downloadsFolder: () -> URL
    /// Lists the folder once. The first call for Desktop or Downloads is what raises the TCC prompt.
    var probeFolder: (URL) -> FolderAccessState
    var floatingThumbnailEnabled: () -> Bool
    var notificationPermission: () async -> NotificationPermission
    /// Returns once the user has answered macOS's banner; throws when macOS refuses to ask at all.
    var requestNotifications: () async throws -> NotificationPermission
    var loginItemStatus: () -> LoginItemStatus
    var setLoginItem: (Bool) throws -> Void
    var openLoginItems: () -> Void
    var openURL: (URL) -> Void
    var bundleIdentifier: String

    /// The real Mac.
    static var live: SetupSystem {
        SetupSystem(
            screenshotFolder: { ScreenshotFolder.current() },
            downloadsFolder: {
                FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads", directoryHint: .isDirectory)
            },
            probeFolder: { FolderAccess.probe($0) },
            floatingThumbnailEnabled: { ScreenshotFolder.floatingThumbnailEnabled() },
            notificationPermission: { await LiveNotifications.permission() },
            requestNotifications: { try await LiveNotifications.request() },
            loginItemStatus: { LoginItem.status() },
            setLoginItem: { try LoginItem.setEnabled($0) },
            openLoginItems: { LoginItem.openSystemSettings() },
            openURL: { NSWorkspace.shared.open($0) },
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "app.obscura"
        )
    }

    /// System Settings → Privacy & Security → Files and Folders.
    var filesAndFoldersURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
    }

    /// System Settings → Notifications → Obscura.
    var notificationSettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleIdentifier)")!
    }
}

/// UNUserNotificationCenter needs an app bundle; these run only from `SetupSystem.live`.
enum LiveNotifications {
    nonisolated static func permission() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return map(settings.authorizationStatus)
    }

    nonisolated static func request() async throws -> NotificationPermission {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        return await permission()
    }

    nonisolated static func map(_ status: UNAuthorizationStatus) -> NotificationPermission {
        switch status {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}
