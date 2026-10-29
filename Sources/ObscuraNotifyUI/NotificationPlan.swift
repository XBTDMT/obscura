// ObscuraNotifyUI — the value types the notifier decides with. Everything here is pure so tests drive it; the
// UserNotifications calls live in Notifier.swift and only translate these values (design/mockups/unified/notifications.html).
import Foundation

/// What a delivered notification is, carried in `userInfo[NotifyKey.kind]` so the delegate can route it.
enum NoticeKind: String, Sendable, Hashable {
    /// One caught image: a silent banner with Undo and Review.
    case catchOne = "catch"
    /// Three or more catches from one source within a minute, folded into one banner.
    case summary
    /// The banner that replaces a catch after Undo: "Undone · original showing".
    case restored
    /// A sounded, time-sensitive alert with its fix in view.
    case problem
    /// A check found an update (passive).
    case update
}

/// How loudly macOS may deliver a plan.
enum NoticeLevel: Sendable, Hashable {
    case passive, active, timeSensitive
}

/// One notification to post, fully decided. The thin layer turns it into a `UNNotificationRequest`.
struct NotificationPlan: Sendable, Hashable {
    /// Request identifier. A later plan with the same identifier replaces the delivered one.
    var identifier: String
    var title: String
    /// The body sentence(s), without the verdict line.
    var body: String
    /// The verdict line drawn under the body ("Safe to share", "Original showing", …); nil for problems and updates.
    var verdict: String?
    var threadIdentifier: String
    var categoryIdentifier: String?
    var level: NoticeLevel
    var sound: Bool
    var kind: NoticeKind
    /// Routing data only: entry id, file path, problem kind. Never recognized text.
    var userInfo: [String: String]
    /// The banner's picture: a temporary PNG of the clean crop (`CatchPicture`, G-19 #10), attached when posted and
    /// deleted after. Nil for every plan but a single catch.
    var pictureFile: URL? = nil

    /// The body macOS shows: the sentences, then the verdict on its own line (the mockup's pill position).
    var deliveredBody: String {
        guard let verdict else { return body }
        return body + "\n" + verdict
    }
}

/// `userInfo` keys.
enum NotifyKey {
    static let kind = "obscura.kind"
    static let entry = "entry"
    static let path = "path"
    static let problem = "problem"
    /// The `Settings.extraFolders` string of an added folder, so Stop Watching removes exactly that entry.
    static let extraFolder = "extraFolder"
    /// The Settings pane a problem's Open Settings goes to (`SettingsPane` raw value).
    static let pane = "pane"
}

/// Category, action and thread identifiers. Action identifiers are stable API: the app's notification history keeps them.
enum NotifyID {
    // Categories
    static let catchCategory = "obscura.catch"
    static let restoredCategory = "obscura.restored"
    static let updateCategory = "obscura.update"
    static func problemCategory(_ kind: ProblemNotice.Kind) -> String { "obscura.problem.\(kind.rawValue)" }

    // Actions
    static let undo = "undo"
    static let review = "review"
    static let blackOutAgain = "blackOutAgain"
    static let allowAccess = "allowAccess"
    static let later = "later"
    static let checkAgain = "checkAgain"
    static let showInFinder = "showInFinder"
    static let copyClean = "copyClean"
    static let openSystemSettings = "openSystemSettings"
    static let stopWatching = "stopWatching"
    static let openSettings = "openSettings"
    static let installUpdate = "installUpdate"
    static let openNotChecked = "openNotChecked"
    static let openJournal = "openJournal"
    static let whatsNew = "whatsNew"

    // Threads: one per catch source so Notification Centre groups repeats; problems and the update have their own.
    static func catchThread(_ source: String) -> String { "obscura.catch.\(source)" }
    static let problemThread = "obscura.problem"
    static let updateThread = "obscura.update"

    // Request identifiers that are not an entry id.
    static let updateRequest = "obscura.update"
    static func problemRequest(_ key: String) -> String { "obscura.problem.\(key)" }
}

/// One banner action.
struct ActionSpec: Sendable, Hashable {
    var identifier: String
    var title: String
    /// Brings Obscura forward (Review, Show in Finder, Settings). Background actions run without opening a window.
    var foreground: Bool
}

/// One notification category: the actions a banner of that kind offers.
struct CategorySpec: Sendable, Hashable {
    var identifier: String
    var actions: [ActionSpec]
}
