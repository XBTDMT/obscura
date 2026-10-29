// Every rail row's state and the resume point, derived from settings, what the system reports and which rows the user
// has passed in this window. Pure, so the menu bar's "N of 9 done · Next: …" can be computed from the same rules.
public import Foundation
public import ObscuraCapture
public import ObscuraPrefs

/// Notification permission as setup needs it.
public enum NotificationPermission: Sendable, Hashable {
    case notDetermined
    case granted
    case denied
}

/// What the system says right now. Folder access is `nil` until it has been asked (asking is the TCC prompt).
public struct SetupSnapshot: Sendable, Hashable {
    public var screenshotFolder: URL
    public var downloadsFolder: URL
    public var screenshotAccess: FolderAccessState?
    public var downloadsAccess: FolderAccessState?
    public var floatingThumbnailEnabled: Bool
    public var notifications: NotificationPermission
    public var loginItem: LoginItemStatus

    public init(screenshotFolder: URL, downloadsFolder: URL, screenshotAccess: FolderAccessState? = nil,
                downloadsAccess: FolderAccessState? = nil, floatingThumbnailEnabled: Bool = true,
                notifications: NotificationPermission = .notDetermined, loginItem: LoginItemStatus = .disabled) {
        self.screenshotFolder = screenshotFolder
        self.downloadsFolder = downloadsFolder
        self.screenshotAccess = screenshotAccess
        self.downloadsAccess = downloadsAccess
        self.floatingThumbnailEnabled = floatingThumbnailEnabled
        self.notifications = notifications
        self.loginItem = loginItem
    }
}

/// The rail, computed.
public struct SetupProgress: Sendable, Hashable {
    public var snapshot: SetupSnapshot
    public var settings: Settings
    /// Rows the user has moved past in this window.
    public var seen: Set<SetupStep>
    /// The demo ran and did not produce a catch.
    public var demoFailed: Bool

    public init(snapshot: SetupSnapshot, settings: Settings, seen: Set<SetupStep> = [], demoFailed: Bool = false) {
        self.snapshot = snapshot
        self.settings = settings
        self.seen = seen
        self.demoFailed = demoFailed
    }

    /// A finished setup counts every row as passed, so a re-run shows refusals rather than "not done yet".
    private func passed(_ step: SetupStep) -> Bool { settings.hasFinishedSetup || seen.contains(step) }

    public func state(_ step: SetupStep) -> SetupStepState {
        switch step {
        case .theCatch:
            if demoFailed { return .declined }
            return passed(step) ? .done : .pending
        case .welcome:
            return passed(step) ? .done : .pending
        case .screenshotFolder:
            if !settings.guardsScreenshotFolder { return passed(step) ? .skipped : .pending }
            switch snapshot.screenshotAccess {
            case .granted: return .done
            case .denied, .missing: return .unprotected
            case nil: return passed(step) ? .declined : .pending
            }
        case .downloads:
            switch snapshot.downloadsAccess {
            case .granted: return settings.guardsDownloads ? .done : (passed(step) ? .skipped : .pending)
            case .denied: return .declined
            case .missing: return .skipped
            case nil:
                if settings.guardsDownloads { return passed(step) ? .declined : .pending }
                return passed(step) ? .skipped : .pending
            }
        case .floatingThumbnail:
            if !snapshot.floatingThumbnailEnabled { return .done }
            return passed(step) ? .declined : .pending
        case .notifications:
            switch snapshot.notifications {
            case .granted: return settings.showsNotifications ? .done : .skipped
            case .denied: return settings.showsNotifications ? .declined : .skipped
            case .notDetermined:
                if !settings.showsNotifications { return passed(step) ? .skipped : .pending }
                return passed(step) ? .declined : .pending
            }
        case .openAtLogin:
            switch snapshot.loginItem {
            case .enabled: return .done
            case .requiresApproval: return .declined
            case .disabled, .notFound: return passed(step) ? .declined : .pending
            }
        case .menuBarIcon:
            // Passing the step is the choice: the Classic ring kept is as much a pick as any other mark.
            return passed(step) ? .done : .pending
        case .done:
            return settings.hasFinishedSetup ? .done : .pending
        }
    }

    public var states: [SetupStep: SetupStepState] {
        Dictionary(uniqueKeysWithValues: SetupStep.allCases.map { ($0, state($0)) })
    }

    /// "N of 9 done": every finished row, the Done row included.
    public var finishedCount: Int { SetupStep.allCases.filter { state($0).isFinished }.count }

    /// Where the window opens: the first row not reached yet; on a finished setup, the first red row, then the first
    /// orange row, then the summary.
    public var resumeStep: SetupStep {
        let all = SetupStep.allCases
        if let first = all.first(where: { state($0) == .pending }) { return first }
        if let red = all.first(where: { state($0) == .unprotected }) { return red }
        if let orange = all.first(where: { state($0) == .declined }) { return orange }
        return .done
    }
}
