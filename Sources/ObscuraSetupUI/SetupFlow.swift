// The setup window's controller: which row is showing, what the system said, the demo's result, and every action.
import AppKit
import Foundation
import Observation
import ObscuraCapture
import ObscuraJournal
import ObscuraPrefs
import ObscuraSupport
import ObscuraUIKit

/// The test shot on the first screen.
enum DemoState {
    case idle
    case running
    case succeeded(DemoResult)
    case failed(DemoFailure)

    var isFailed: Bool { if case .failed = self { return true } else { return false } }
    var result: DemoResult? { if case .succeeded(let r) = self { return r } else { return nil } }
}

enum DemoFailure: Equatable {
    /// The pipeline returned nothing.
    case didNotRun
    /// It ran and caught nothing.
    case nothingCaught
}

struct DemoResult {
    var entryID: UUID
    var durationMS: Int
    var secrets: Int
    var displayName: String
    var original: NSImage?
    var clean: NSImage?
}

@MainActor
@Observable
final class SetupFlow {
    let model: AppModel
    let system: SetupSystem
    private let runDemo: @Sendable () async -> (entryID: UUID, durationMS: Int)?

    /// The row on screen; nil until `start()` has read the system.
    private(set) var current: SetupStep?
    private(set) var snapshot: SetupSnapshot
    /// Steps passed, persisted in `Settings.setupStepsSeen` so a closed setup resumes at the first step not yet passed.
    private(set) var seen: Set<SetupStep> = [] {
        didSet {
            guard seen != oldValue else { return }
            let raw = SetupStep.allCases.filter { seen.contains($0) }.map(\.rawValue)
            model.updateSettings { $0.setupStepsSeen = raw }
        }
    }
    private(set) var demo: DemoState = .idle
    var showsOriginal = false
    private(set) var loginError: String?
    private(set) var thumbnailChanging = false
    /// macOS asks with a banner in the top-right corner, not in this window; true until the user answers it.
    private(set) var notificationsAsking = false
    /// macOS refused to ask (the request threw); the pane offers System Settings instead of a dead button.
    private(set) var notificationsRequestFailed = false
    /// macOS's error as "domain code" (no message text), shown with the refusal so a report can name the cause.
    private(set) var notificationsRequestError: String?

    init(model: AppModel, system: SetupSystem, runDemo: @escaping @Sendable () async -> (entryID: UUID, durationMS: Int)?) {
        self.model = model
        self.system = system
        self.runDemo = runDemo
        seen = Set(model.settings.setupStepsSeen.compactMap(SetupStep.init(rawValue:)))
        snapshot = system.baseSnapshot()
    }

    var progress: SetupProgress {
        SetupProgress(snapshot: snapshot, settings: model.settings, seen: seen, demoFailed: demo.isFailed)
    }

    func state(_ step: SetupStep) -> SetupStepState { progress.state(step) }

    // MARK: Navigation

    /// Reads the system and opens at the resume point. A folder whose step was already passed (a re-run, or a setup
    /// closed early and reopened) is probed again, since its prompt was answered then; one not reached yet is asked
    /// only from its own step.
    func start() async {
        // The same reading the menu bar's setup card makes (`SetupSummaryReader`), so the two never disagree.
        snapshot = await system.refreshed(snapshot, settings: model.settings, seen: seen)
        go(to: progress.resumeStep)
    }

    func go(to step: SetupStep) {
        if let current, current != step { seen.insert(current) }
        current = step
        showsOriginal = false
        loginError = nil
        if step == .theCatch, case .idle = demo { Task { await runTestShot() } }
    }

    func advance() {
        guard let current else { return }
        if let next = current.next { go(to: next) } else { seen.insert(current) }
    }

    // MARK: The catch

    func runTestShot() async {
        demo = .running
        guard let outcome = await runDemo() else { demo = .failed(.didNotRun); return }
        let entry = try? await model.journal.entry(outcome.entryID)
        let secrets = entry?.findings.count ?? 0
        guard secrets > 0 else { demo = .failed(.nothingCaught); return }
        let original = (try? await model.journal.originalData(outcome.entryID)).flatMap(NSImage.init(data:))
        let clean = (try? await model.journal.cleanImage(outcome.entryID).data).flatMap(NSImage.init(data:))
        demo = .succeeded(DemoResult(entryID: outcome.entryID, durationMS: outcome.durationMS, secrets: secrets,
                                     displayName: entry?.displayName ?? String(localized: "Test shot"), original: original, clean: clean))
        await model.reloadEntries()
    }

    // MARK: Folders

    func allowScreenshotFolder() {
        snapshot.screenshotFolder = system.screenshotFolder()
        let access = system.probeFolder(snapshot.screenshotFolder)
        snapshot.screenshotAccess = access
        if access == .granted { model.updateSettings { $0.guardsScreenshotFolder = true } }
    }

    func allowDownloads() async {
        let access = system.probeFolder(snapshot.downloadsFolder)
        snapshot.downloadsAccess = access
        // G-36: the person's click in setup is the confirmation, kept before the setting changes.
        if access == .granted, await model.confirmFolder(snapshot.downloadsFolder) { model.updateSettings { $0.guardsDownloads = true } }
    }

    func openFilesAndFolders() { system.openURL(system.filesAndFoldersURL) }

    // MARK: Floating thumbnail

    /// Asks the app to change the Screenshot app's setting, then reads it back.
    func setFloatingThumbnail(shown: Bool, using action: (@MainActor (Bool) async -> Void)?) async {
        guard let action else { return }
        thumbnailChanging = true
        await action(shown)
        snapshot.floatingThumbnailEnabled = system.floatingThumbnailEnabled()
        thumbnailChanging = false
    }

    // MARK: Notifications

    func requestNotifications() async {
        notificationsAsking = true
        notificationsRequestFailed = false
        notificationsRequestError = nil
        defer { notificationsAsking = false }
        do {
            snapshot.notifications = try await system.requestNotifications()
        } catch {
            let ns = error as NSError
            notificationsRequestError = "\(ns.domain) \(ns.code)"
            Log.app.error("notification request refused: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            snapshot.notifications = await system.notificationPermission()
            notificationsRequestFailed = snapshot.notifications == .notDetermined
        }
        if snapshot.notifications == .granted { model.updateSettings { $0.showsNotifications = true } }
    }

    func keepNotificationsOff() {
        model.updateSettings { $0.showsNotifications = false }
        advance()
    }

    func openNotificationSettings() { system.openURL(system.notificationSettingsURL) }

    // MARK: Open at login

    var opensAtLogin: Bool { snapshot.loginItem == .enabled || snapshot.loginItem == .requiresApproval }

    func setOpenAtLogin(_ on: Bool) {
        loginError = nil
        do { try system.setLoginItem(on) } catch {
            loginError = on ? String(localized: "macOS didn't add Obscura to Login Items.")
                            : String(localized: "macOS didn't remove Obscura from Login Items.")
        }
        snapshot.loginItem = system.loginItemStatus()
    }

    func openLoginItems() { system.openLoginItems() }

    // MARK: Refresh and finish

    /// Re-reads what can change behind the window's back (System Settings, the Screenshot app). Folders are re-probed
    /// only once they have been asked, so this never raises a prompt.
    func refresh() async {
        snapshot.floatingThumbnailEnabled = system.floatingThumbnailEnabled()
        snapshot.loginItem = system.loginItemStatus()
        if snapshot.screenshotAccess != nil { snapshot.screenshotAccess = system.probeFolder(snapshot.screenshotFolder) }
        if snapshot.downloadsAccess != nil { snapshot.downloadsAccess = system.probeFolder(snapshot.downloadsFolder) }
        snapshot.notifications = await system.notificationPermission()
    }

    /// Close setup: records that it has run, then hands the window back to its owner.
    func finish(then onFinish: () -> Void) {
        if let current { seen.insert(current) }
        model.updateSettings { $0.hasFinishedSetup = true }
        onFinish()
    }

    // MARK: Test and preview hooks

    func preset(step: SetupStep, seen: Set<SetupStep> = [], demo: DemoState = .idle, snapshot: SetupSnapshot? = nil) {
        current = step
        self.seen = seen
        self.demo = demo
        if let snapshot { self.snapshot = snapshot }
    }
}
