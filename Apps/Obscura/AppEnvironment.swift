// Builds the running app: the Journal in Application Support, the real capture sources, Vision, the engine, the model,
// the notifier and the floating screenshot thumbnail, and keeps them alive for the app's lifetime.
import AppKit
import Foundation
import ObscuraCapture
import ObscuraEngine
import ObscuraJournal
import ObscuraNotifyUI
import ObscuraOCR
import ObscuraPrefs
import ObscuraSearch
import ObscuraSupport
import ObscuraThumbnailUI
import ObscuraUIKit

@MainActor
final class AppEnvironment {
    let model: AppModel
    let router: AppRouter
    let engine: ShieldEngine
    let notifier: Notifier
    /// Obscura's own floating thumbnail after each new screenshot is checked (B-9, G-8).
    let thumbnails: ThumbnailController
    let updater: Updater
    /// Spotlight entries and Finder tags for covered files (G-24).
    let search: SearchCoordinator
    private var tasks: [Task<Void, Never>] = []

    /// `~/Library/Application Support/Obscura` (0700), as spec §5 lays out; the images are in its `Journal.noindex`
    /// (G-23, `JournalLocations`).
    static func supportRoot() throws -> URL {
        let root = JournalLocations.defaultRoot()
        try FileAtomics.makePrivateDirectory(root)
        return root
    }

    /// Set when this build names an earlier identity (G-38); its Spotlight step runs in `start()`.
    private let identityMigration: IdentityMigration?

    init() throws {
        // G-38: an earlier identity's settings, Keychain items and login item move to this one before any store opens
        // (the settings store writes its schema version, the Journal reads rule keys, the engine prepares the folder
        // confirmations). Only a build that names its earlier identity (Info.plist ObscuraPreviousIdentity) does this.
        let defaults = UserDefaults.standard
        identityMigration = AppIdentity.previous().map { IdentityMigration(previous: $0) }
        if let migration = identityMigration {
            _ = migration.carrySettings(into: defaults, domain: Bundle.main.bundleIdentifier ?? AppIdentity.current.defaultsDomain)
            _ = migration.moveKeychainItems(markers: defaults)
            migration.carryLoginItem(markers: defaults, status: { LoginItem.status() }, register: { try LoginItem.setEnabled(true) })
        }
        LoginItem.remember(LoginItem.status(), in: defaults)
        SettingsMigration.migrateIfNeeded(defaults: defaults)
        let settings = UserDefaultsSettingsStore()
        // G-30: custom rule values are sealed with a per-install key kept in the login keychain.
        let journal = try SQLiteJournalStore(root: Self.supportRoot(), ruleKeys: KeychainRuleKeyStore())
        // G-36: Downloads and added folders are watched only once the person confirmed them in Obscura; the confirmations
        // live in a Keychain item Obscura creates (the defaults domain is writable by any process running as the user).
        let folderApprovals = KeychainFolderApprovalStore()
        let watcher = FolderWatcher(roots: ShieldEngine.watchedRoots(from: settings.current(), approvals: (try? folderApprovals.load()) ?? []))
        let clipboard = ClipboardGuard()
        let imports = ImportSource()
        search = SearchCoordinator(journal: journal, index: CoreSpotlightIndex())
        engine = ShieldEngine(sources: [watcher, clipboard, imports], recognizer: VisionTextRecognizer(), journal: journal,
                              settings: settings, clock: SystemClock(), folderWatcher: watcher, clipboardGuard: clipboard,
                              redactedWord: String(localized: "REDACTED"), search: search, folderApprovals: folderApprovals)
        router = AppRouter()
        model = AppModel(engine: engine, journal: journal, settings: settings, router: router)
        notifier = Notifier(model: model)
        thumbnails = ThumbnailController(model: model)
        updater = Updater(model: model)
        router.updater = updater
        // After a verified install (G-33) the app quits for real; the relaunch helper opens the new copy.
        updater.quit = { [router] in router.quit() }
        // A scheduled check's update is passive: the panel's banner plus one quiet macOS banner (notifications.html).
        updater.coordinator.onOffer = { [notifier] offer in notifier.postUpdateAvailable(version: offer.version) }
        // One notice per catch: the thumbnail says whether it announces a report's catch (it saw the start with its switch
        // on, and a display can show it); otherwise the banner posts. Asked before the thumbnail handles the report.
        notifier.thumbnailClaims = { [thumbnails] report in thumbnails.claims(report) }
    }

    func start() {
        model.start()
        let engine = engine
        if let migration = identityMigration {
            // Before the engine's launch reconcile rebuilds the new domain; the two touch different domains either way.
            tasks.append(Task { await migration.retireSpotlightDomain(index: CoreSpotlightIndex(), markers: .standard) })
        }
        tasks.append(Task.detached(priority: .utility) { await engine.run() })
        // One task routes the engine's ordered scan events (G-9): a scan's start always arrives before its report, so the
        // thumbnail never sees a report ahead of its start. Starts go to the thumbnail only while
        // `settings.thumbnailEnabled` is on (read live, so the Settings switch takes effect at the next screenshot);
        // reports go to both. While the thumbnail is on, a screenshot catch's notice is the thumbnail, not a banner: the
        // notifier decides that from the report's own origin.
        tasks.append(Task { [weak self] in
            for await event in engine.events {
                guard let self else { return }
                switch event {
                case .started(let start):
                    if self.model.settings.thumbnailEnabled { self.thumbnails.handle(start: start) }
                case .finished(let report):
                    self.notifier.handle(report)
                    self.thumbnails.handle(report: report)
                }
            }
        })
        // Problems: the notifier posts new ones once and withdraws cleared ones, so a problem that returns alerts again.
        tasks.append(Task { [weak self] in
            for await status in engine.status { self?.notifier.reconcile(problems: status.problems) }
        })
        // "Check Again": the engine re-submits the file with the origin it first came from (or the watched folder's).
        notifier.rescan = { url in
            Task { await engine.retry(url) }
        }
        notifier.refreshDeliveryState()
        // The launch's scheduled update check (at most once a day, automatic checks on): a minute in, so it never
        // competes with Vision's warm-up or the first scans.
        tasks.append(Task { [router] in
            try? await Task.sleep(for: .seconds(60))
            router.scheduledUpdateCheck()
        })
    }

    /// A Spotlight result was opened (G-24): the viewer while its Journal entry exists, else the covered file in
    /// Finder (the entry expired; the file is what was found), else the Journal.
    func openSearchResult(_ identifier: String) {
        let engine = engine
        Task { @MainActor [router] in
            let target = await engine.searchTarget(for: identifier)
            router.whenReady {
                switch target {
                case .entry(let id): router.openViewer(entryID: id)
                case .file(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
                case .none: router.openJournal(selecting: nil)
                }
            }
        }
    }

    /// The setup demo: the real pipeline on the invented `.env` terminal.
    func runDemo() async -> (entryID: UUID, durationMS: Int)? {
        let data = SampleData.terminalPNG(covered: false)
        let outcome = await engine.scan(imageData: data, source: .demo, displayName: String(localized: "Test shot"), filePath: nil, origin: nil)
        await model.reloadEntries()
        if case .redacted(let id, _, let duration) = outcome {
            let ms = Int(duration.components.seconds * 1000) + Int(duration.components.attoseconds / 1_000_000_000_000_000)
            return (id, ms)
        }
        return nil
    }

    /// Shows or hides macOS's floating screenshot thumbnail. Off means every capture is written (and checked) at once.
    /// This is the documented user-level preference; SystemUIServer re-reads it when restarted.
    static func setFloatingThumbnail(_ show: Bool) async {
        await Task.detached {
            let write = Process()
            write.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            write.arguments = ["write", "com.apple.screencapture", "show-thumbnail", "-bool", show ? "true" : "false"]
            try? write.run(); write.waitUntilExit()
            let restart = Process()
            restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            restart.arguments = ["SystemUIServer"]
            try? restart.run(); restart.waitUntilExit()
        }.value
    }
}
