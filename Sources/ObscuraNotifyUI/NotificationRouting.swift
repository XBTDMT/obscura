// ObscuraNotifyUI — what a click on a banner or one of its buttons does, decided from the delivered notification's
// kind, action identifier and userInfo. Pure; the Notifier carries the result out through the model and the router.
import Foundation
import ObscuraCapture
import ObscuraUIKit

enum NotificationResponse: Sendable, Hashable {
    case undo(UUID)
    case review(UUID)
    case blackOutAgain(UUID)
    case openJournal
    /// The Journal's "Not checked" section (G-13).
    case openNotChecked
    case openSettings(SettingsPane)
    /// System Settings › Privacy & Security › Files and Folders.
    case openFilesAndFoldersPrivacy
    case stopWatchingDownloads
    case stopWatchingFolder(String)
    case checkAgain(path: String)
    case showInFinder(path: String)
    case copyClean(UUID)
    case installUpdate
    /// Dismissed, Later, or a click with nothing to open.
    case nothing
}

enum NotificationRouting {
    /// The default action (a click on the banner body) and UNNotificationDismissActionIdentifier are passed through
    /// as their system identifiers; `defaultAction` is `UNNotificationDefaultActionIdentifier`.
    static func route(kind: NoticeKind?, action: String, userInfo: [String: String], defaultAction: String) -> NotificationResponse {
        let entry = userInfo[NotifyKey.entry].flatMap(UUID.init(uuidString:))
        let path = userInfo[NotifyKey.path]
        switch kind {
        case .catchOne?:
            guard let entry else { return .openJournal }
            switch action {
            case NotifyID.undo: return .undo(entry)
            case NotifyID.review, defaultAction: return .review(entry)
            default: return .nothing
            }
        case .restored?:
            guard let entry else { return .openJournal }
            switch action {
            case NotifyID.blackOutAgain: return .blackOutAgain(entry)
            case NotifyID.review, defaultAction: return .review(entry)
            default: return .nothing
            }
        case .summary?:
            return action == defaultAction ? .openJournal : .nothing
        case .update?:
            switch action {
            case NotifyID.installUpdate, NotifyID.whatsNew, defaultAction: return .installUpdate
            default: return .nothing
            }
        case .problem?:
            return problemRoute(action: action, userInfo: userInfo, entry: entry, path: path, defaultAction: defaultAction)
        case nil:
            return .nothing
        }
    }

    private static func problemRoute(action: String, userInfo: [String: String], entry: UUID?, path: String?,
                                     defaultAction: String) -> NotificationResponse {
        let kind = userInfo[NotifyKey.problem].flatMap(ProblemNotice.Kind.init(rawValue:))
        let pane = userInfo[NotifyKey.pane].flatMap(SettingsPane.init(rawValue:)) ?? .protection
        switch action {
        case NotifyID.allowAccess, NotifyID.openSystemSettings: return .openFilesAndFoldersPrivacy
        case NotifyID.openSettings: return .openSettings(pane)
        case NotifyID.stopWatching:
            if let folder = userInfo[NotifyKey.extraFolder] { return .stopWatchingFolder(folder) }
            return .stopWatchingDownloads
        case NotifyID.checkAgain: return path.map { .checkAgain(path: $0) } ?? .nothing
        case NotifyID.showInFinder: return path.map { .showInFinder(path: $0) } ?? .nothing
        case NotifyID.copyClean: return entry.map { .copyClean($0) } ?? .nothing
        case NotifyID.openNotChecked: return .openNotChecked
        case NotifyID.openJournal: return .openJournal
        case defaultAction:
            // A click on the alert itself goes where its first fix would.
            switch kind {
            case .screenshotFolderDenied?, .watchedFolderDenied?: return .openFilesAndFoldersPrivacy
            case .screenshotFolderMissing?, .watchedFolderMissing?, .ruleSkipped?, .sourceDown?, .fileTooLarge?, .filesTooLarge?:
                return .openSettings(pane)
            case .filesUnchecked?: return .openNotChecked
            case .cleanCopiesFailed?: return .openJournal
            case .writeFailed?: return entry.map { .review($0) } ?? (path.map { .showInFinder(path: $0) } ?? .nothing)
            case .fileUnchecked?: return path.map { .showInFinder(path: $0) } ?? .nothing
            case .clipboardUnchecked?: return entry.map { .review($0) } ?? .nothing
            case nil: return .nothing
            }
        default: return .nothing
        }
    }
}

/// Whether a finished scan still gets its banner. With Obscura's floating thumbnail on, a catch from the screenshot
/// folder is announced by the thumbnail in the corner the habit already looks at, so it posts no banner (r3-a, G-8:
/// one notice per catch). Clipboard catches, Downloads, extra folders, imports, problems and updates keep their
/// banners. The origin is the scan report's own (G-9), the same one the thumbnail accepts a scan by, so the two agree
/// on which catches are the thumbnail's without either keeping state about starts.
enum CatchBannerRule {
    static func posts(_ triage: ReportTriage, origin: FileOrigin?, thumbnailOn: Bool) -> Bool {
        posts(triage, thumbnailClaims: origin == .screenshotFolder && thumbnailOn)
    }

    /// The rule as the app runs it: the thumbnail itself says whether it announces this catch (it saw the scan start
    /// with the switch on, and a display can show it), so a catch is never left with no notice, and the switch being
    /// flipped mid-scan never gives it two or none.
    static func posts(_ triage: ReportTriage, thumbnailClaims: Bool) -> Bool {
        guard case .caught = triage else { return true }
        return !thumbnailClaims
    }
}
