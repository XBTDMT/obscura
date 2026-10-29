// App-level behaviour SwiftUI does not express: one instance only, the menu bar item and its panel (G-14), the Dock icon
// only while a window is open, focus back to the app the user came from when the last window closes, what opening
// Obscura again shows, and ⌘Q closing windows instead of stopping protection (spec §8).
// The decisions are `WindowFlow` (ObscuraUIKit) and `PanelPresentation` (ObscuraMenuBarUI); this file carries them out.
import AppKit
import SwiftUI
import ObscuraMenuBarUI
import ObscuraSearch
import ObscuraSetupUI
import ObscuraUIKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// What `ObscuraApp.init` built: the running environment, or why it could not start.
    enum Boot {
        case ready(AppEnvironment)
        case failed(String)
    }

    static var boot: Boot?

    weak var router: AppRouter?
    private var environment: AppEnvironment?
    private(set) var menuBar: MenuBarController?
    private var observers: [any NSObjectProtocol] = []
    /// The last app other than Obscura that was active: where focus goes back when Obscura's last window closes.
    private var previousApp: pid_t?
    /// Set when this process found another Obscura running and is only handing over to it.
    private var isHandingOver = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // One instance: a second launch hands over to the first and leaves. Opening the running copy's bundle sends it
        // the reopen event, so it shows something (`applicationShouldHandleReopen`), not just an invisible activation.
        let mine = NSRunningApplication.current
        guard let id = Bundle.main.bundleIdentifier,
              let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0 != mine })
        else { return }
        isHandingOver = true
        guard let url = other.bundleURL else {
            other.activate()
            exit(0)
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in exit(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isHandingOver else { return }
        NSApp.setActivationPolicy(.accessory)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateActivationPolicy() }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            let counts = MainActor.assumeIsolated { window.map(Self.info)?.isTitledWindow ?? false }
            // After the close has finished, not during it (recon M-7): the window is gone from the list by then.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.windowClosed(counts: counts) }
            }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let pid, pid != ProcessInfo.processInfo.processIdentifier { self?.previousApp = pid }
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.router?.reallyQuit = true }
        })
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }

        switch Self.boot {
        case .ready(let env):
            environment = env
            router = env.router
            let settings: @MainActor () -> ColorScheme? = { env.model.settings.appearance.colorScheme }
            let menuBar = MenuBarController(model: env.model, labelAccessory: AnyView(RouterBinder(router: env.router)),
                                            colorScheme: settings)
            self.menuBar = menuBar
            env.router.panel = menuBar
            // Confirm before Undo, when the user turned it on (G-19 #11): the system alert, from any surface.
            env.model.confirmUndo = { request in await UndoAlert.confirm(request) }
            // The setup card's "N of 8 done · Next: …" is read fresh each time the panel opens (G-19 M-19).
            menuBar.willOpen = { Self.refreshSetupSummary(env.model) }
            Self.refreshSetupSummary(env.model)
            env.start()
            env.router.whenReady { [weak self] in self?.openLaunchWindows(env) }
        case .failed(let message):
            menuBar = MenuBarController(label: AnyView(Image(systemName: "exclamationmark.triangle")),
                                        accessibilityLabel: String(localized: "Obscura couldn't start"),
                                        content: { AnyView(StartupFailureView(message: message)) })
        case nil:
            break
        }
    }

    /// Reads setup's progress for the panel's setup card while setup is unfinished; clears it once setup is done.
    private static func refreshSetupSummary(_ model: AppModel) {
        guard !model.settings.hasFinishedSetup else {
            model.setupSummary = nil
            return
        }
        Task { @MainActor in model.setupSummary = await SetupSummaryReader.current(settings: model.settings) }
    }

    /// The launch's own windows: setup on a first run (a finished setup opens nothing, onboarding.html "Open at login").
    private func openLaunchWindows(_ env: AppEnvironment) {
        #if DEBUG
        // Debug builds only: `-ObscuraOpen journal|settings|setup|viewer` opens a window at launch, for UI tests and
        // for checking windows without driving the menu bar.
        if let target = UserDefaults.standard.string(forKey: "ObscuraOpen") {
            Task { @MainActor in
                await env.model.reloadEntries()
                switch target {
                case "journal": env.router.openJournal(selecting: env.model.entries.first?.id)
                case "settings": env.router.openSettings(.protection)
                case "detectors": env.router.openSettings(.detectors)
                case "rules": env.router.openSettings(.customRules)
                case "style": env.router.openSettings(.redactionStyle)
                case "viewer": if let id = env.model.entries.first?.id { env.router.openViewer(entryID: id) }
                default: env.router.openSetup()
                }
            }
            return
        }
        #endif
        if !env.model.settings.hasFinishedSetup { env.router.openSetup() }
    }

    // MARK: Windows

    private static func info(_ w: NSWindow) -> WindowFlow.WindowInfo {
        WindowFlow.WindowInfo(isVisible: w.isVisible, isMiniaturized: w.isMiniaturized,
                              isTitled: w.styleMask.contains(.titled), isPanel: w is NSPanel)
    }

    private var windowInfos: [WindowFlow.WindowInfo] { NSApp.windows.map(Self.info) }

    /// `.regular` (Dock icon, menus) while a window is open, minimized ones included (M-8); `.accessory` otherwise.
    private func updateActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy = WindowFlow.wantsDockIcon(windowInfos) ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }

    private func windowClosed(counts: Bool) {
        updateActivationPolicy()
        // Only a window the user opened hands focus back; a panel (an alert, the thumbnail) closing does not, and nor
        // does any close while a window is on its way (the thumbnail's Open in Viewer closes the card as the Viewer opens).
        guard counts, router?.isWindowOnItsWay != true,
              let pid = WindowFlow.focusReturnAfterLastWindowClosed(
                windows: windowInfos, appIsActive: NSApp.isActive, panelIsOpen: menuBar?.isOpen ?? false,
                previousApp: previousApp, ownPID: ProcessInfo.processInfo.processIdentifier),
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated
        else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    /// Opening Obscura again while it runs (Finder, Spotlight, Launchpad, the Dock) shows something (recon M-6).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let settings = environment?.model.settings
        switch WindowFlow.reopen(hasVisibleWindows: WindowFlow.wantsDockIcon(windowInfos), hasFinishedSetup: settings?.hasFinishedSetup ?? true,
                                 target: settings?.reopenShows ?? .panel) {
        case .bringWindowsForward:
            return true
        case .openSetup:
            router?.openSetup()
            return false
        case .openPanel:
            menuBar?.open()
            return false
        case .openSettings:
            router?.openSettings(.protection)
            return false
        case .openJournal:
            router?.openJournal(selecting: nil)
            return false
        }
    }

    /// Opening one of Obscura's Spotlight results (G-24).
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard let id = SearchResultActivity.identifier(activityType: userActivity.activityType, userInfo: userActivity.userInfo),
              let environment else { return false }
        environment.openSearchResult(id)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if router?.reallyQuit == true || isSystemQuit() || isHandingOver { return .terminateNow }
        // With no engine running (startup failed) there is nothing to keep running: its panel's Quit really quits.
        if case .failed = Self.boot { return .terminateNow }
        for w in NSApp.windows where Self.info(w).isTitledWindow && w.isVisible { w.performClose(nil) }
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Windows are never brought back at launch (onboarding.html "Open at login": no window opens; recon M-10). The
    /// scenes also say so (`.restorationBehavior(.disabled)`); this covers AppKit's own window restoration.
    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }

    /// Logout, restart and shutdown send a quit Apple event carrying a reason; those always quit.
    private func isSystemQuit() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEQuitApplication else { return false }
        return event.attributeDescriptor(forKeyword: kAEQuitReason) != nil
    }
}

private extension WindowFlow.WindowInfo {
    /// A titled window that is not a panel: the kind ⌘Q closes and whose closing can hand focus back.
    var isTitledWindow: Bool { isTitled && !isPanel }
}
