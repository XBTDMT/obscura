// The app's Router: closes the menu bar panel, opens the scene for each destination and brings its window forward.
import AppKit
import SwiftUI
import ObscuraMenuBarUI
import ObscuraUIKit

/// Window identifiers, shared by the scenes and the router.
enum WindowID {
    static let journal = "journal"
    static let viewer = "viewer"
    static let settings = "settings"
    static let setup = "setup"
    /// G-40: the spot viewer, one window per Not checked row.
    static let spots = "spots"

    /// The router's key for one Viewer window (the Viewer scene opens one window per entry).
    static func viewer(_ entryID: UUID) -> String { "\(viewer):\(entryID.uuidString)" }
    /// The router's key for one spot viewer window.
    static func spots(_ fileID: UUID) -> String { "\(spots):\(fileID.uuidString)" }
}

@MainActor
@Observable
final class AppRouter: Router {
    /// Set by `RouterBinder` from a view that is always mounted (the menu bar label). Window requests made before it is
    /// set (the launch's own, see `whenReady`) wait for it.
    @ObservationIgnored var openWindow: OpenWindowAction? {
        didSet {
            guard openWindow != nil else { return }
            let waiting = whenBound
            whenBound.removeAll()
            waiting.forEach { $0() }
        }
    }
    @ObservationIgnored weak var updater: Updater?
    /// The menu bar panel (G-14): every window-opening route closes it first, whichever surface asked.
    @ObservationIgnored weak var panel: MenuBarController?
    /// The pane Settings shows; the Settings window binds to it.
    var settingsPane: SettingsPane = .protection
    /// The Journal's selection; the Journal window binds to it.
    var journalSelection: Set<UUID> = []
    /// Where the Journal should go next (its section); the Journal window binds to it, applies it and clears it, whether
    /// it was already open or opens now.
    var journalDestination: JournalDestination?
    /// Set by the panel's Quit, an update's relaunch or a system shutdown; otherwise ⌘Q only closes windows.
    @ObservationIgnored var reallyQuit = false

    /// Each scene's window, reported by the scene itself (`WindowReporter`), so the router never guesses which
    /// NSWindow belongs to which scene.
    @ObservationIgnored private var windows: [String: WeakWindow] = [:]
    /// Windows asked for that have not come forward yet.
    @ObservationIgnored private var pendingRaise: Set<String> = []
    @ObservationIgnored private var whenBound: [@MainActor () -> Void] = []
    /// When the last window request was made; a window may still be on its way for a moment after.
    @ObservationIgnored private var lastOpenRequest: Date = .distantPast

    /// Runs `body` once the router can open windows (at once if it already can).
    func whenReady(_ body: @escaping @MainActor () -> Void) {
        if openWindow != nil { body() } else { whenBound.append(body) }
    }

    func openJournal(_ destination: JournalDestination) {
        if case .catches(let entryID?) = destination { journalSelection = [entryID] }
        journalDestination = destination
        show(WindowID.journal) { $0(id: WindowID.journal) }
    }

    func openViewer(entryID: UUID) {
        show(WindowID.viewer(entryID)) { $0(id: WindowID.viewer, value: entryID) }
    }

    func openSpots(fileID: UUID) {
        show(WindowID.spots(fileID)) { $0(id: WindowID.spots, value: fileID) }
    }

    func openSettings(_ pane: SettingsPane) {
        settingsPane = pane
        show(WindowID.settings) { $0(id: WindowID.settings) }
    }

    func openSetup() { show(WindowID.setup) { $0(id: WindowID.setup) } }

    /// "Check for Updates…" (G-33): checks the signed feed now and answers in an alert — up to date, the reason a check
    /// failed, or the update found with Install / Later. In a build with no release key, the alert says updates are not
    /// set up (recon M-3: the row used to do nothing at all).
    func checkForUpdates() {
        panel?.closeForWindowOpening()
        lastOpenRequest = Date()
        guard let coordinator = updater?.coordinator, coordinator.isAvailable else {
            alert(title: UpdateCopy.notSetUpTitle, body: UpdateCopy.notSetUpBody)
            return
        }
        Task { @MainActor [weak self] in
            guard let result = await coordinator.checkForUpdates(), let self else { return }
            switch result {
            case .upToDate(let version):
                self.alert(title: UpdateCopy.upToDateTitle(version), body: nil)
            case .failed(let reason):
                self.alert(title: UpdateCopy.checkFailedTitle, body: reason)
            case .available(let offer):
                let install = self.alert(title: UpdateCopy.availableTitle(offer.version), body: UpdateCopy.availableBody,
                                         buttons: [String(localized: "Install and Relaunch"), String(localized: "Later")])
                if install == .alertFirstButtonReturn { self.installUpdate() } else { coordinator.dismiss() }
            }
        }
    }

    /// Install (the banner, the menu row, the notification): Obscura downloads and verifies the update itself and
    /// relaunches; the banner shows "Installing…" meanwhile, and the reason if it stops (the installed app unchanged).
    func installUpdate() {
        panel?.closeForWindowOpening()
        guard let coordinator = updater?.coordinator else { return }
        Task { @MainActor in await coordinator.install() }
    }

    /// Later: the banner goes until the next check reports the update again.
    func dismissUpdate() { updater?.coordinator.dismiss() }

    /// A scheduled update check (at most once a day, only with automatic checks on): at launch and when a window opens,
    /// as Settings → About promises.
    func scheduledUpdateCheck() {
        guard let coordinator = updater?.coordinator else { return }
        Task { @MainActor in await coordinator.scheduledCheck() }
    }

    @discardableResult
    private func alert(title: String, body: String?, buttons: [String] = [String(localized: "OK")]) -> NSApplication.ModalResponse {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        if let body { alert.informativeText = body }
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
    }

    func quit() {
        reallyQuit = true
        NSApp.terminate(nil)
    }

    // MARK: Windows

    /// Called by each scene's `WindowReporter` when its view lands in a window.
    func register(_ window: NSWindow, for key: String) {
        windows[key] = WeakWindow(window: window)
        if pendingRaise.contains(key) { raise(key) }
    }

    /// Closes one scene's window by its key (Setup's "Close setup", recon M-11), never whichever window happens to be key.
    func closeWindow(_ key: String) {
        windows[key]?.window?.performClose(nil)
    }

    /// A window was asked for within the last second and may not be on screen yet.
    var isWindowOnItsWay: Bool { Date().timeIntervalSince(lastOpenRequest) < 1 }

    private func show(_ key: String, open: @escaping @MainActor (OpenWindowAction) -> Void) {
        // The panel goes first, so it never floats over the window that comes forward (G-14, recon M-1).
        panel?.closeForWindowOpening()
        guard let openWindow else {
            whenBound.append { [weak self] in self?.show(key, open: open) }
            return
        }
        lastOpenRequest = Date()
        pendingRaise.insert(key)
        scheduledUpdateCheck()
        bringForward()
        open(openWindow)
        // An already-open window comes forward now; a new one when its scene reports it (register), or on the next
        // turn if SwiftUI reused a window that had already reported.
        if let window = windows[key]?.window, window.isVisible || window.isMiniaturized { raise(key) }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingRaise.contains(key), let window = self.windows[key]?.window, window.isVisible else { return }
                self.raise(key)
            }
        }
    }

    /// Brings a scene's window to the front and into focus once it exists (recon M-9: activating before the window
    /// existed could leave it behind the app the user clicked from, the thumbnail and notifications included).
    private func raise(_ key: String) {
        pendingRaise.remove(key)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let window = self?.windows[key]?.window else { return }
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
        }
    }

    private func bringForward() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}

/// A window held without keeping it alive.
private struct WeakWindow {
    weak var window: NSWindow?
}

/// Captures the scene's `openWindow` action for the router. Mounted beside the menu bar label, which always exists.
struct RouterBinder: View {
    let router: AppRouter
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { router.openWindow = openWindow }
    }
}

/// Reports the NSWindow a scene's content lands in to the router, under the scene's key.
struct WindowReporter: NSViewRepresentable {
    let key: String
    let router: AppRouter

    func makeNSView(context: Context) -> ReporterView {
        let view = ReporterView()
        view.onWindow = { [router, key] window in router.register(window, for: key) }
        return view
    }

    func updateNSView(_ nsView: ReporterView, context: Context) {}

    final class ReporterView: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
