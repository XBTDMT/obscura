public import Foundation
import ServiceManagement

public enum LoginItemStatus: Sendable, Hashable {
    case enabled
    case disabled
    /// Registered, but the user has to approve it in System Settings > General > Login Items.
    case requiresApproval
    /// The app is outside an Applications folder (for example a debug build), where a login item would point at a copy
    /// that moves or disappears.
    case notFound
}

/// Launch-at-login over `SMAppService.mainApp`. `.requiresApproval` is surfaced as its own state (not read as "off"), so
/// the UI can offer the System Settings shortcut.
public enum LoginItem {
    public static func status() -> LoginItemStatus {
        classify(SMAppService.mainApp.status, inApplications: isInApplicationsFolder(Bundle.main.bundleURL))
    }

    /// `SMAppService` answers `.notFound` for an app it has simply never registered, wherever the app is, so that
    /// answer alone never means "move the app": inside an Applications folder it is plain "off" and the switch can try.
    static func classify(_ status: SMAppService.Status, inApplications: Bool) -> LoginItemStatus {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return inApplications ? .disabled : .notFound
        case .notFound: return inApplications ? .disabled : .notFound
        @unknown default: return inApplications ? .disabled : .notFound
        }
    }

    /// True for a bundle inside /Applications or the user's ~/Applications (at any depth), symlinks resolved.
    static func isInApplicationsFolder(_ bundleURL: URL,
                                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let roots = ["/Applications", home.resolvingSymlinksInPath().standardizedFileURL.appending(path: "Applications").path]
        return roots.contains { path.hasPrefix($0 + "/") }
    }

    /// Registers or unregisters the main app. Re-read `status()` afterwards: registering can land in
    /// `.requiresApproval`.
    public static func setEnabled(_ enabled: Bool) throws {
        defer { remember(status()) }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// The defaults key holding whether the login item was on when Obscura last looked (G-38). The switch itself is
    /// always read live from `SMAppService`; this memory exists only so a launch under a new bundle identifier (whose
    /// registration was made for the old one) can tell that the person had it on (`LoginItemCarryOver`).
    public static let lastKnownKey = "loginItem.lastKnownOn"

    /// Records `status` as the last one seen. `.notFound` (a copy outside Applications) says nothing about the person's
    /// choice and leaves the memory as it is.
    public static func remember(_ status: LoginItemStatus, in defaults: UserDefaults = .standard) {
        switch status {
        case .enabled, .requiresApproval: defaults.set(true, forKey: lastKnownKey)
        case .disabled: defaults.set(false, forKey: lastKnownKey)
        case .notFound: break
        }
    }

    /// The last status recorded by `remember`: true (on), false (off) or nil (never recorded).
    public static func lastKnownOn(in defaults: UserDefaults = .standard) -> Bool? {
        defaults.object(forKey: lastKnownKey) as? Bool
    }

    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// G-38: the login item after the bundle identifier changed. The earlier registration was made for the earlier bundle
/// identifier, so the renamed app can start unregistered even when the person had it on. On the first launch under the new
/// identity the app registers it again, but only when the earlier identity recorded it as on: an unknown or "off" choice
/// is never turned on for the person.
public enum LoginItemCarryOver {
    public enum Action: Sendable, Equatable {
        case register
        case leave
    }

    /// `previouslyOn`: the earlier identity's `LoginItem.lastKnownOn` (carried with its settings); `status`: this
    /// identity's registration now.
    public static func action(previouslyOn: Bool?, status: LoginItemStatus) -> Action {
        guard previouslyOn == true else { return .leave }
        switch status {
        case .disabled: return .register
        // Already on (macOS kept it) or waiting for approval: nothing to do. Outside Applications: registering would
        // point at a copy that moves.
        case .enabled, .requiresApproval, .notFound: return .leave
        }
    }
}
