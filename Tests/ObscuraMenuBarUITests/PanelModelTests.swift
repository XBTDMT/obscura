// The panel on a real AppModel over a real ShieldEngine (stub recognizer, temp Journal, temp files): the states the
// model can reach without a seam, and Undo reaching restoreOriginal. AppModel.status is private(set), so states the
// engine cannot be driven into here (checking, a scan failure) are covered by PanelSnapshotTests on built values.
import Foundation
import CoreGraphics
import Testing
import ObscuraUIKit
import ObscuraEngine
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSupport
@testable import ObscuraMenuBarUI

@MainActor
@Suite(.serialized) struct PanelModelTests {
    /// Made up: Stripe-shaped, never issued.
    static let fakeKey = "sk_live_Tq4Wm8ZxR2vLp7NcY5bHd3Ks"
    static let keyLine = OCRLine(index: 0, text: "STRIPE_SECRET_KEY=\(fakeKey)", rect: CGRect(x: 40, y: 60, width: 900, height: 40))

    @MainActor
    final class Harness {
        let root: URL
        let store: InMemorySettingsStore
        let engine: ShieldEngine
        let router = RecordingRouter()
        let model: AppModel
        let memory: PanelMemory

        @MainActor
        init(settings: ObscuraPrefs.Settings = .default, lines: [OCRLine] = [PanelModelTests.keyLine]) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("obscura-menubar-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let journal = try SQLiteJournalStore(root: root.appendingPathComponent("journal", isDirectory: true), ruleKeys: InMemoryRuleKeyStore(), clock: SystemClock())
            store = InMemorySettingsStore(settings)
            engine = ShieldEngine(sources: [], recognizer: StubTextRecognizer(lines: lines), journal: journal, settings: store,
                                  clock: SystemClock(), folderWatcher: nil, clipboardGuard: nil)
            model = AppModel(engine: engine, journal: journal, settings: store, router: router)
            memory = TestData.memory(now: Date().addingTimeInterval(-3600))
            PanelMemory.register(memory, for: model)
            model.start()
        }

        @MainActor
        func snapshot(now: Date = Date()) -> PanelSnapshot {
            PanelSnapshot.make(MenuBarPanel.inputs(model: model, memory: memory, now: now))
        }

        func performer() -> PanelActionPerformer { PanelActionPerformer(model: model, memory: memory) }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test func protectedThenPausedThenResumed() async throws {
        let h = try Harness()
        await h.engine.catalogueChanged()
        #expect(await eventually { h.model.status.weekStats.count == 7 })
        #expect(h.snapshot().header.title == "Protected")
        #expect(h.model.markState == .protected)

        await h.performer().perform(.pause(.fifteenMinutes))
        #expect(await eventually { if case .paused = h.model.status.protection { return true }; return false })
        let paused = h.snapshot()
        #expect(paused.header.title == "Paused")
        #expect(paused.paused?.title.hasPrefix("Paused since") == true)
        #expect(paused.paused?.detail.hasPrefix("Resumes automatically at") == true)
        #expect(paused.menuTitles.first == "Resume Protection")
        #expect(h.model.markState == .paused)

        await h.performer().perform(.resume)
        #expect(await eventually { h.model.status.protection == .protected })
        #expect(h.snapshot().paused == nil)
        h.model.stop()
    }

    @Test func clipboardOffIsPartlyProtected() async throws {
        var settings = ObscuraPrefs.Settings.default
        settings.guardsClipboard = false
        let h = try Harness(settings: settings)
        await h.engine.catalogueChanged()
        #expect(await eventually { if case .partlyProtected = h.model.status.protection { return true }; return false })
        #expect(await eventually { !h.model.settings.guardsClipboard })
        let s = h.snapshot()
        #expect(s.header.title == "Partly protected")
        #expect(s.header.sentence.hasPrefix("Clipboard guard is off."))
        #expect(h.model.markState == .partlyProtected)
        h.model.stop()
    }

    /// F17 (G-36): a folder named in the settings outside Obscura (`defaults write`) is not watched; the panel says so and
    /// sends the person to review it; confirming it in Obscura clears it.
    @Test func aFolderAddedOutsideObscuraAsksToBeReviewed() async throws {
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("obscura-unconfirmed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let folder = folderURL.path
        var settings = ObscuraPrefs.Settings.default
        settings.guardsScreenshotFolder = false
        settings.extraFolders = [folder]
        let h = try Harness(settings: settings)
        await h.engine.maintenanceTick()
        #expect(await eventually { !h.model.unconfirmedFolders.isEmpty })
        #expect(h.model.unconfirmedFolders == [folderURL.standardizedFileURL.path])
        let banner = try #require(h.snapshot().banners.first { $0.title.hasSuffix("isn't watched yet") })
        #expect(banner.buttons.map(\.title) == ["Review…", "Stop Watching"])
        #expect(banner.buttons.map(\.action) == [.openSettings(.protection), .stopWatching(.extra(folder))])

        #expect(await h.model.confirmFolder(folderURL))
        #expect(await eventually { h.model.unconfirmedFolders.isEmpty })
        h.model.stop()
    }

    @Test func aMissingFolderNeedsAttentionAndStopWatchingClearsIt() async throws {
        let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent("obscura-missing-\(UUID().uuidString)")
        let missing = missingURL.path
        var settings = ObscuraPrefs.Settings.default
        settings.guardsScreenshotFolder = false
        settings.extraFolders = [missing]
        let h = try Harness(settings: settings)
        // The person added it in Obscura (G-36), and it was deleted afterwards.
        try FileManager.default.createDirectory(at: missingURL, withIntermediateDirectories: true)
        #expect(await h.engine.confirmFolder(missingURL))
        try FileManager.default.removeItem(at: missingURL)
        await h.engine.maintenanceTick()
        #expect(await eventually { if case .needsAttention = h.model.status.protection { return true }; return false })
        #expect(await eventually { h.model.settings.extraFolders == [missing] })
        let s = h.snapshot()
        #expect(s.header.title == "Needs attention")
        let banner = try #require(s.banners.first { $0.title.hasSuffix("is missing") })
        #expect(banner.buttons.map(\.action) == [.openSettings(.protection), .stopWatching(.extra(missing))])
        #expect(h.model.markState == .needsAttention)

        await h.performer().perform(.stopWatching(.extra(missing)))
        #expect(h.store.current().extraFolders.isEmpty)
        await h.engine.maintenanceTick()
        #expect(await eventually { if case .needsAttention = h.model.status.protection { return false }; return true })
        h.model.stop()
    }

    @Test func aCatchFillsTheCardAndUndoPutsTheOriginalBack() async throws {
        let h = try Harness()
        let folder = h.root.appendingPathComponent("Shots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Screenshot 2026-10-26 at 9.41.12 AM.png")
        let original = SampleData.terminalPNG(covered: false)
        try original.write(to: file)
        // A watched folder, as the person's settings would have it (F26: Undo writes only into watched folders).
        h.store.update { $0.extraFolders = [folder.path] }
        #expect(await h.engine.confirmFolder(folder), "confirmed in Obscura (G-36)")

        let outcome = await h.engine.scan(imageData: original, source: .file, displayName: file.lastPathComponent,
                                          filePath: file, origin: .watched(folder))
        guard case .redacted(let entryID, _, _) = outcome else {
            Issue.record("expected a catch, got \(outcome)")
            return
        }
        #expect(try Data(contentsOf: file) != original)
        await h.engine.catalogueChanged()
        // The model reloads on the engine's outcome stream, which may have subscribed after this direct scan.
        await h.model.reloadEntries()
        #expect(await eventually { h.model.status.lastCatch?.entryID == entryID && h.model.entries.contains { $0.id == entryID } })

        let s = h.snapshot()
        let card = try #require(s.lastCatch)
        #expect(card.entryID == entryID)
        #expect(card.timeLabel == "just now")
        #expect(card.title.hasPrefix("Stripe secret"))
        #expect(s.header.sentence == "Blacked out 1 secret just now.")
        let undo = try #require(card.buttons.first { $0.title == "Undo" })
        #expect(undo.shortcut == KeyChord("z", .command))

        await h.performer().perform(undo.action)
        #expect(try Data(contentsOf: file) == original)
        #expect(h.router.calls.isEmpty)

        let review = try #require(card.buttons.first { $0.title == "Review" })
        await h.performer().perform(review.action)
        #expect(h.router.calls == ["viewer:\(entryID.uuidString)"])
        h.model.stop()
    }
}
