// How Obscura's windows decide the app's Dock presence, where focus goes when the last one closes, and what opening
// Obscura again shows (recon 01: M-6, M-7, M-8). Pure values, so the app delegate's AppKit shell stays thin and tested.
public import Foundation
public import ObscuraPrefs

public enum WindowFlow {
    /// What the delegate knows about one of the app's windows.
    public struct WindowInfo: Equatable, Sendable {
        public var isVisible: Bool
        public var isMiniaturized: Bool
        public var isTitled: Bool
        /// Panels (the menu bar panel, the floating thumbnail) never count as windows the user opened.
        public var isPanel: Bool

        public init(isVisible: Bool, isMiniaturized: Bool, isTitled: Bool, isPanel: Bool) {
            self.isVisible = isVisible
            self.isMiniaturized = isMiniaturized
            self.isTitled = isTitled
            self.isPanel = isPanel
        }

        /// A window the user opened and can get back to: on screen, or minimized in the Dock (M-8).
        public var isOpenWindow: Bool { isTitled && !isPanel && (isVisible || isMiniaturized) }
    }

    /// `.regular` (Dock icon, menus) while any window is open, minimized ones included; `.accessory` otherwise.
    public static func wantsDockIcon(_ windows: [WindowInfo]) -> Bool {
        windows.contains(where: \.isOpenWindow)
    }

    /// After a window closed and none is left open: hand activation back to the app the user came from, so the keyboard
    /// does not stay on a windowless Obscura (M-7). Nil when a window is still open, Obscura is not the active app,
    /// the menu bar panel is showing (it handles its own focus), or there is no other app to return to.
    public static func focusReturnAfterLastWindowClosed(windows: [WindowInfo], appIsActive: Bool, panelIsOpen: Bool,
                                                        previousApp: pid_t?, ownPID: pid_t) -> pid_t? {
        guard !wantsDockIcon(windows), appIsActive, !panelIsOpen, let previousApp, previousApp != ownPID else { return nil }
        return previousApp
    }

    /// What opening Obscura again (Finder, Spotlight, Launchpad, the Dock) does while it is already running.
    public enum Reopen: Equatable, Sendable {
        /// A window is on screen: AppKit brings the app's windows forward as usual.
        case bringWindowsForward
        /// An unfinished setup resumes where it stopped (onboarding.html: "resumable from the menu bar").
        case openSetup
        /// Nothing is on screen: the menu bar panel opens under the item, so the relaunch visibly lands somewhere and
        /// no window appears that the user did not ask for (onboarding.html "Open at login": no window opens).
        case openPanel
        /// Nothing is on screen and the user chose Settings (`Settings.reopenShows`, G-19 M-6).
        case openSettings
        /// Nothing is on screen and the user chose the Journal.
        case openJournal
    }

    /// An open window always comes forward; an unfinished setup always resumes Setup (whatever the setting says, the
    /// unfinished setup is what needs the user); otherwise `target` decides, the panel by default (G-19 M-6).
    public static func reopen(hasVisibleWindows: Bool, hasFinishedSetup: Bool, target: ReopenTarget = .panel) -> Reopen {
        if hasVisibleWindows { return .bringWindowsForward }
        guard hasFinishedSetup else { return .openSetup }
        switch target {
        case .panel: return .openPanel
        case .settings: return .openSettings
        case .journal: return .openJournal
        }
    }
}
