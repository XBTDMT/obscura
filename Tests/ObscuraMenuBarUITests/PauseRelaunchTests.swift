// A pause survives a relaunch (redman 2026-10-27, "Pause duration is held only in memory"): the end is persisted in
// UserDefaults (`protection.pausedUntil`), and a fresh store, engine and model over the same defaults domain — what a
// relaunch is — keep skipping every image until it ends, re-arm the auto-resume, or resume a pause that ran out while
// the app was not running. Each test builds its "relaunch" from scratch on a throwaway defaults suite.
import Foundation
import CoreGraphics
import Testing
import ObscuraUIKit
import ObscuraEngine
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSupport
import ObscuraTestSupport
@testable import ObscuraMenuBarUI

@MainActor
@Suite(.serialized) struct PauseRelaunchTests {
    /// One app launch: a persisted settings store, a real engine (stub recognizer that always finds a made-up key) and
    /// the model, started the way AppEnvironment.start does: model first, so the pause is settled before any scan.
    @MainActor
    final class Launch {
        let root: URL
        let store: UserDefaultsSettingsStore
        let engine: ShieldEngine
        let router = RecordingRouter()
        let model: AppModel
        let memory: PanelMemory

        init(defaults: UserDefaults, root: URL) throws {
            self.root = root
            // Each launch opens its own Journal: only the settings domain carries over, which is what this tests.
            let journal = try SQLiteJournalStore(root: root.appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true), ruleKeys: InMemoryRuleKeyStore(),
                                                 clock: SystemClock())
            store = UserDefaultsSettingsStore(defaults: defaults)
            engine = ShieldEngine(sources: [], recognizer: StubTextRecognizer(lines: [PanelModelTests.keyLine]), journal: journal,
                                  settings: store, clock: SystemClock(), folderWatcher: nil, clipboardGuard: nil)
            model = AppModel(engine: engine, journal: journal, settings: store, router: router)
            memory = TestData.memory()
            PanelMemory.register(memory, for: model)
            model.start()
        }

        func scan() async -> ScanOutcome {
            await engine.scan(imageData: SampleData.terminalPNG(covered: false), source: .imported, displayName: "Test shot",
                              filePath: nil, origin: nil)
        }

        func snapshot() -> PanelSnapshot {
            PanelSnapshot.make(MenuBarPanel.inputs(model: model, memory: memory, now: Date()))
        }
    }

    /// A defaults domain and a Journal folder shared by the launches of one test.
    final class Machine {
        let defaults = TestDefaults("pause-relaunch").defaults
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("obscura-pause-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        @MainActor func launch() throws -> Launch { try Launch(defaults: defaults, root: root) }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func relaunchDuringATimedPauseStaysPausedAndReArmsTheResume() async throws {
        let machine = try Machine()
        let first = try machine.launch()
        await first.engine.catalogueChanged()
        await PanelActionPerformer(model: first.model, memory: first.memory).perform(.pause(.oneHour))
        let until = try #require(first.store.current().pausedUntil)
        first.model.stop()

        let second = try machine.launch()
        await second.engine.catalogueChanged()
        #expect(second.model.settings.pausedUntil == until)
        #expect(second.model.resumeScheduledAt == until)
        #expect(second.model.pause == PauseState(since: nil, resumesAt: until))
        // The engine's own pause flag is gone with the old process; the persisted end alone keeps it skipping.
        #expect(await second.engine.isPaused == false)
        #expect(await second.scan().skipReason == .protectionPaused)
        #expect(await second.engine.currentStatus().protection == .paused)
        #expect(await eventually { second.model.status.protection == .paused })
        let card = try #require(second.snapshot().paused)
        #expect(card.title == "Paused")
        #expect(card.detail.hasPrefix("Resumes automatically"))
        second.model.stop()
    }

    @Test func relaunchAfterThePauseRanOutResumesProtection() async throws {
        let machine = try Machine()
        let first = try machine.launch()
        first.model.pause(until: Date().addingTimeInterval(3600))
        first.model.stop()
        // The app was closed past the end: write an end that has already passed, as a later launch would find it.
        machine.defaults.set(Date().addingTimeInterval(-60), forKey: SettingsKey.pausedUntil.rawValue)

        let second = try machine.launch()
        await second.engine.catalogueChanged()
        #expect(second.store.current().pausedUntil == nil)
        #expect(second.model.pause == nil && second.model.resumeScheduledAt == nil)
        #expect(await second.scan().isRedacted)
        #expect(await eventually { second.model.status.protection == .protected })
        #expect(second.snapshot().paused == nil)
        second.model.stop()
    }

    @Test func relaunchWhilePausedUntilResumedStaysPausedWithNoTimer() async throws {
        let machine = try Machine()
        let first = try machine.launch()
        await PanelActionPerformer(model: first.model, memory: first.memory).perform(.pause(.untilResumed))
        #expect(first.store.current().pausedUntil == .distantFuture)
        first.model.stop()

        let second = try machine.launch()
        await second.engine.catalogueChanged()
        #expect(second.store.current().isPausedUntilResumed)
        #expect(second.model.resumeScheduledAt == nil)
        #expect(second.model.pause == PauseState(since: nil, resumesAt: nil))
        #expect(await second.scan().skipReason == .protectionPaused)
        #expect(await eventually { second.model.status.protection == .paused })
        #expect(second.snapshot().paused?.detail == "Stays paused until you resume.")

        // Resume ends it for good: the next launch protects.
        await PanelActionPerformer(model: second.model, memory: second.memory).perform(.resume)
        second.model.stop()
        let third = try machine.launch()
        await third.engine.catalogueChanged()
        #expect(third.store.current().pausedUntil == nil)
        #expect(await third.scan().isRedacted)
        third.model.stop()
    }

    @Test func aRearmedPauseResumesByItselfWhenItEnds() async throws {
        let machine = try Machine()
        machine.defaults.set(Date().addingTimeInterval(0.4), forKey: SettingsKey.pausedUntil.rawValue)
        let launch = try machine.launch()
        await launch.engine.catalogueChanged()
        #expect(launch.model.resumeScheduledAt != nil)
        #expect(await launch.scan().skipReason == .protectionPaused)
        #expect(await eventually { launch.store.current().pausedUntil == nil })
        #expect(await eventually { launch.model.status.protection == .protected })
        #expect(await launch.scan().isRedacted)
        launch.model.stop()
    }

    @Test func aNewPauseReplacesTheOldTimer() async throws {
        let machine = try Machine()
        let launch = try machine.launch()
        launch.model.pause(for: .milliseconds(300))
        launch.model.pause(for: nil)
        try await Task.sleep(for: .milliseconds(600))
        #expect(launch.store.current().isPausedUntilResumed, "the short pause's timer must not end the indefinite one")
        launch.model.stop()
    }
}
