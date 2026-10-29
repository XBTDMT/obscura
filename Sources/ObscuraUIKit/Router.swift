// Cross-surface navigation (G-7): surfaces never import each other; they ask the router, and the app target implements it.
public import Foundation

/// The Settings panes, in sidebar order.
public enum SettingsPane: String, CaseIterable, Sendable, Hashable, Identifiable {
    case protection, detectors, redactionStyle, customRules, journalPrivacy, shortcuts, about
    public var id: String { rawValue }
}

/// Where the Journal window opens.
public enum JournalDestination: Hashable, Sendable {
    /// The catches, optionally with one entry selected.
    case catches(selecting: UUID?)
    /// The "Not checked" section: files Obscura could not check (G-13).
    case notChecked
    /// The "Not covered on disk" section: files that still show what was caught (fail-open #7).
    case notCovered
}

/// Where a surface can send the user. The app target opens the right window and brings the app forward.
@MainActor
public protocol Router: AnyObject {
    /// The Journal window, on the catches (optionally with one entry selected) or on the Not checked section.
    func openJournal(_ destination: JournalDestination)
    /// The viewer for one entry.
    func openViewer(entryID: UUID)
    /// G-40: the viewer for one picture's spots no reading could read (a Not checked row), outlined, with Not Text and
    /// Cover It.
    func openSpots(fileID: UUID)
    /// Settings, on a pane.
    func openSettings(_ pane: SettingsPane)
    /// The setup window, resuming at the first step not yet done.
    func openSetup()
    /// "Check for Updates…": checks the signed feed now and says what it found (G-33).
    func checkForUpdates()
    /// The update banner's Install: downloads, verifies and installs `AppModel.updateOffer`, then relaunches (G-33).
    func installUpdate()
    /// The update banner's Later: hides the banner until the next check reports the update again.
    func dismissUpdate()
    /// Quit for real (the panel's Quit; ⌘Q in a window only closes windows).
    func quit()
}

public extension Router {
    /// The Journal window on the catches, optionally with one entry selected.
    func openJournal(selecting entryID: UUID?) { openJournal(.catches(selecting: entryID)) }
}

/// A router that records calls, for previews and tests.
@MainActor
public final class RecordingRouter: Router {
    public private(set) var calls: [String] = []
    public init() {}
    public func openJournal(_ destination: JournalDestination) {
        switch destination {
        case .catches(let entryID): calls.append("journal:\(entryID?.uuidString ?? "-")")
        case .notChecked: calls.append("journal:notChecked")
        case .notCovered: calls.append("journal:notCovered")
        }
    }
    public func openViewer(entryID: UUID) { calls.append("viewer:\(entryID.uuidString)") }
    public func openSpots(fileID: UUID) { calls.append("spots:\(fileID.uuidString)") }
    public func openSettings(_ pane: SettingsPane) { calls.append("settings:\(pane.rawValue)") }
    public func openSetup() { calls.append("setup") }
    public func checkForUpdates() { calls.append("updates") }
    public func installUpdate() { calls.append("installUpdate") }
    public func dismissUpdate() { calls.append("dismissUpdate") }
    public func quit() { calls.append("quit") }
}
