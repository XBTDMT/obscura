// When the menu bar panel opens and closes, and where focus goes after (G-14, G-15; recon M-1, M-2). Pure values, so
// every rule is a unit test; `MenuBarController` is the thin AppKit shell that carries the decisions out.
import CoreGraphics
import Foundation

/// The panel's open/close state and the rules behind it.
struct PanelPresentation: Equatable {
    /// Why the panel is closing.
    enum CloseReason: Equatable, Sendable {
        /// A panel action that closes it (see `closeTiming(for:)`).
        case action(PanelAction)
        /// The router is about to open a window or the update alert, from any surface (panel, thumbnail, notification,
        /// app menu). The window comes forward; Obscura takes focus.
        case windowOpening
        /// A second click on the menu bar item.
        case statusItemClicked
        case escape
        /// A click anywhere outside the panel and the menu bar item.
        case clickedOutside
        /// Obscura stopped being the active app (⌘-Tab, a click in another app's window).
        case appResignedActive
        /// The panel stopped being the key window (another window, Obscura's or another app's, took the keyboard).
        case panelResignedKey
    }

    /// When an action closes the panel, relative to carrying it out.
    enum Timing: Equatable, Sendable {
        /// The action works in place; the panel stays and shows the result.
        case never
        /// The action opens a window: the panel goes first, so it never floats over the window that comes forward.
        case beforePerforming
        /// Copy Clean (G-15): the copy finishes, then the panel goes and focus returns, so ⌘V lands in that app.
        case afterPerforming
    }

    /// Where the keyboard goes once the panel is gone.
    enum FocusReturn: Equatable, Sendable {
        /// Leave it: Obscura is bringing a window forward, or the user already went somewhere else.
        case none
        /// Hand activation back to the app that was frontmost when the panel opened.
        case activate(pid_t)
    }

    private(set) var isOpen = false
    /// The app that was frontmost when the panel opened, unless that was Obscura itself.
    private(set) var previousApp: pid_t?

    /// Opens the panel. Returns false when it is already open (nothing to do).
    mutating func open(frontmostApp: pid_t?, ownPID: pid_t) -> Bool {
        guard !isOpen else { return false }
        isOpen = true
        previousApp = frontmostApp == ownPID ? nil : frontmostApp
        return true
    }

    /// Closes the panel. Returns nil when it was already closed (a second close is a no-op), else where focus goes.
    mutating func close(_ reason: CloseReason) -> FocusReturn? {
        guard isOpen else { return nil }
        isOpen = false
        defer { previousApp = nil }
        guard Self.returnsFocus(reason), let previousApp else { return FocusReturn.none }
        return .activate(previousApp)
    }

    // MARK: Rules

    /// Which panel actions close the panel, and when (recon 01, "What each panel action does today, and what it should do").
    static func closeTiming(for action: PanelAction) -> Timing {
        switch action {
        case .review, .reviewSpots, .openJournal, .openJournalNotChecked, .openJournalNotCovered, .openSettings, .openSetup, .checkForUpdates, .installUpdate:
            return .beforePerforming
        case .copyClean:
            return .afterPerforming
        case .undo, .blackOutAgain, .pause, .resume, .dismissUpdate, .stopWatching, .checkAgain, .retryNotCovered, .retryMaintenance:
            return .never
        case .quit:
            // The app exits; there is nothing to close first.
            return .never
        }
    }

    /// Whether the panel closes at this point of carrying `action` out.
    static func closes(_ action: PanelAction, at phase: PanelActionPhase) -> Bool {
        switch (closeTiming(for: action), phase) {
        case (.beforePerforming, .willPerform), (.afterPerforming, .didPerform): return true
        default: return false
        }
    }

    /// Whether closing for `reason` hands focus back to the app the user came from.
    static func returnsFocus(_ reason: CloseReason) -> Bool {
        switch reason {
        case .action(let action):
            // Copy Clean returns focus (G-15); a window-opening action leaves it to the window coming forward.
            return closeTiming(for: action) == .afterPerforming
        case .statusItemClicked, .escape:
            // The user dismissed the panel without going anywhere: back to where they were.
            return true
        case .windowOpening, .clickedOutside, .appResignedActive, .panelResignedKey:
            return false
        }
    }

    /// Whether a mouse-down at `point` (screen coordinates) is on the menu bar item, so the item's own action toggles the
    /// panel and the click-outside rule leaves it alone. Decided by where the click is, not by which window took it: on
    /// macOS 27 the menu bar draws status items itself, so a click on Obscura's item reaches the app as a click in
    /// another process (the global monitor) and only its position says it was the item. The item spans the bar's full
    /// height, like any menu bar item; `item` is nil when the item is not on screen.
    static func isOnItem(_ point: CGPoint, item: CGRect?, menuBar: CGRect) -> Bool {
        guard let item else { return false }
        return point.x >= item.minX && point.x < item.maxX && point.y >= menuBar.minY && point.y < menuBar.maxY
    }

    // MARK: Placement and look

    /// The gap between the bottom of the menu bar and the panel's top edge (design/mockups/unified/menubar.html `.mwrap`).
    static let gapBelowMenuBar: CGFloat = 5
    /// The panel keeps this far from the screen's left and right edges.
    static let screenMargin: CGFloat = 8
    /// The panel's corner radius (menubar.html `.panel`).
    static let cornerRadius: CGFloat = 12

    /// The panel's frame (AppKit screen coordinates, origin bottom-left): its leading edge under the menu bar item's,
    /// like a menu, its top just below the bar, clamped so it stays on the item's screen.
    static func frame(contentSize: CGSize, item: CGRect, visible: CGRect) -> CGRect {
        let width = contentSize.width
        let height = min(contentSize.height, max(0, item.minY - gapBelowMenuBar - visible.minY))
        let maxX = visible.maxX - screenMargin - width
        let x = max(visible.minX + screenMargin, min(item.minX, maxX))
        let y = item.minY - gapBelowMenuBar - height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
