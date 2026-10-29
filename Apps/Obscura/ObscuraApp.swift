// The app: four windows, each a surface module (G-7). The menu bar item and its panel are Obscura's own
// (`MenuBarController`, G-14), made by the app delegate; everything else lives in the packages.
//
// Every scene is suppressed at launch and never restored: Obscura starts in the menu bar and no window opens unless
// setup is unfinished (onboarding.html "Open at login"; recon M-10). Each scene reports its window to the router
// (`WindowReporter`), which brings it forward once it exists (recon M-9).
import SwiftUI
import ObscuraJournalUI
import ObscuraPrefs
import ObscuraSettingsUI
import ObscuraSetupUI
import ObscuraUIKit
import ObscuraViewerUI

@main
struct ObscuraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var env: AppEnvironment?

    init() {
        #if DEBUG
        // Debug builds only: `-ObscuraSearchReport YES` prints what Obscura holds in Spotlight and which covered files
        // carry its tags (counts and ids only), then quits. Read-only; it runs before anything opens the Journal.
        if UserDefaults.standard.bool(forKey: "ObscuraSearchReport") { SearchReportLaunch.runAndExit() }
        #endif
        do {
            let env = try AppEnvironment()
            _env = State(initialValue: env)
            AppDelegate.boot = .ready(env)
        } catch {
            AppDelegate.boot = .failed(String(describing: error))
        }
    }

    var body: some Scene {
        Window(String(localized: "Journal"), id: WindowID.journal) {
            if let env {
                JournalWindow(model: env.model, selection: Bindable(env.router).journalSelection,
                              destination: Bindable(env.router).journalDestination)
                    .background(WindowReporter(key: WindowID.journal, router: env.router))
                    .preferredColorScheme(env.model.settings.appearance.colorScheme)
            }
        }
        .defaultSize(width: OMetric.journalSize.width, height: OMetric.journalSize.height)
        // G-19 #14: the Journal resizes freely above its minimum, and the grid adds a column for every 164 pt.
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        // Its Window-menu item is `BoundCommandButton` below, so its shortcut follows the person's bindings live (G-20); a
        // scene's own `.keyboardShortcut` is fixed when the scene is built.
        .commandsRemoved()

        WindowGroup(String(localized: "Viewer"), id: WindowID.viewer, for: UUID.self) { $entryID in
            if let env, let entryID {
                ViewerWindow(model: env.model, entryID: entryID)
                    .onRulesChanged { await env.model.rulesChanged() }
                    .background(WindowReporter(key: WindowID.viewer(entryID), router: env.router))
                    .preferredColorScheme(env.model.settings.appearance.colorScheme)
            }
        }
        .defaultSize(width: OMetric.viewerWidth, height: 560)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        // A Viewer only ever opens for an entry: no File ▸ New Viewer Window, no blank Viewer (recon M-5).
        .commandsRemoved()

        // G-40: a picture's spots no reading could read, outlined, with Not Text and Cover It.
        WindowGroup(String(localized: "Viewer"), id: WindowID.spots, for: UUID.self) { $fileID in
            if let env, let fileID {
                SpotReviewWindow(model: env.model, fileID: fileID)
                    .background(WindowReporter(key: WindowID.spots(fileID), router: env.router))
                    .preferredColorScheme(env.model.settings.appearance.colorScheme)
            }
        }
        .defaultSize(width: OMetric.viewerWidth, height: 520)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window(String(localized: "Obscura Settings"), id: WindowID.settings) {
            if let env {
                SettingsWindow(model: env.model, pane: Bindable(env.router).settingsPane)
                    .onCatalogueChange { Task { await env.model.rulesChanged() } }
                    .background(WindowReporter(key: WindowID.settings, router: env.router))
                    .preferredColorScheme(env.model.settings.appearance.colorScheme)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appSettings) {
                BoundCommandButton(model: env?.model, id: .appSettings, title: String(localized: "Settings…")) {
                    env?.router.openSettings(.protection)
                }
            }
            CommandGroup(before: .singleWindowList) {
                BoundCommandButton(model: env?.model, id: .appOpenJournal, title: String(localized: "Journal")) {
                    env?.router.openJournal(selecting: nil)
                }
            }
            CommandGroup(after: .appInfo) {
                Button(String(localized: "Check for Updates…")) { env?.router.checkForUpdates() }
            }
        }

        // One name for the Setup window everywhere: the Window menu, the title bar and Mission Control (recon M-18).
        Window(String(localized: "Obscura Setup"), id: WindowID.setup) {
            if let env {
                SetupWindow(model: env.model,
                            runDemo: { await env.runDemo() },
                            onFinish: { env.router.closeWindow(WindowID.setup) })
                    .onSetFloatingThumbnail { show in await AppEnvironment.setFloatingThumbnail(show) }
                    .background(WindowReporter(key: WindowID.setup, router: env.router))
                    .preferredColorScheme(env.model.settings.appearance.colorScheme)
            }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

/// A main-menu command whose shortcut is the person's current binding. A view of its own, so reading the settings
/// here re-renders the menu item when they change in Settings ▸ Keyboard Shortcuts (no relaunch).
struct BoundCommandButton: View {
    let model: AppModel?
    let id: ShortcutID
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action).shortcut(id, model?.settings.keyBindings ?? .defaults)
    }
}

/// Shown in the panel if the Journal folder or database cannot be opened, so the failure is never silent.
struct StartupFailureView: View {
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Obscura couldn't start").font(OFont.title)
            Text("Its Journal in Application Support could not be opened. Screenshots are not being checked.")
                .font(OFont.callout).foregroundStyle(OColor.text2)
            Text(message).font(OFont.mono).foregroundStyle(OColor.text3).textSelection(.enabled)
            Button(String(localized: "Quit Obscura")) { NSApp.terminate(nil) }.buttonStyle(OButtonStyle(.quiet))
        }
        .padding(16)
        .frame(width: OMetric.menuBarPanelWidth)
    }
}
