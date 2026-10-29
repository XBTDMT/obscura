import AppKit
import Foundation
import Testing
import ObscuraCapture
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSupport
@testable import ObscuraEngine

/// Settings reach the capture sources at once, and a disabled source's late event is skipped with a reason.
@Suite(.serialized) @MainActor struct SettingsApplyTests {
    func makeEngine(settings: InMemorySettingsStore, watcher: FolderWatcher?, guard clipboard: ClipboardGuard?,
                    folders: TestFolders = TestFolders()) throws -> (ShieldEngine, URL) {
        let root = try Fixture.tempDirectory("apply")
        let journal = try SQLiteJournalStore(root: root, ruleKeys: InMemoryRuleKeyStore(), clock: ManualClock())
        let engine = ShieldEngine(sources: [], recognizer: StubTextRecognizer(lines: [Fixture.keyLine]), journal: journal,
                                  settings: settings, clock: ManualClock(), folderWatcher: watcher, clipboardGuard: clipboard,
                                  locations: folders.locations, folderApprovals: folders.approvals)
        return (engine, root)
    }

    @Test func clipboardGuardFollowsItsSwitch() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("obscura-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let clipboard = ClipboardGuard(pasteboard: board)
        let settings = InMemorySettingsStore(.default)
        let (engine, root) = try makeEngine(settings: settings, watcher: nil, guard: clipboard)
        defer { try? FileManager.default.removeItem(at: root) }

        await engine.applySettings(settings.current())
        #expect(clipboard.isRunning)

        settings.update { $0.guardsClipboard = false }
        await engine.applySettings(settings.current())
        #expect(!clipboard.isRunning)

        settings.update { $0.guardsClipboard = true }
        await engine.applySettings(settings.current())
        #expect(clipboard.isRunning)
        await clipboard.stop()
    }

    @Test func folderSwitchesReachTheWatcherImmediately() async throws {
        let settings = InMemorySettingsStore(.default)
        let folders = TestFolders()
        let downloads = try Fixture.tempDirectory("apply-downloads")
        defer { try? FileManager.default.removeItem(at: downloads) }
        folders.downloads = downloads
        let watcher = FolderWatcher(roots: ShieldEngine.watchedRoots(from: settings.current(), locations: folders.locations, approvals: []))
        let (engine, root) = try makeEngine(settings: settings, watcher: watcher, guard: nil, folders: folders)
        defer { try? FileManager.default.removeItem(at: root) }

        let before = await watcher.currentRoots.map(\.origin)
        #expect(!before.contains(.downloads))

        // Switched on in Obscura: the switch confirms Downloads (G-36), then the setting changes.
        folders.confirm(downloads)
        settings.update { $0.guardsDownloads = true }
        await engine.applySettings(settings.current())
        let after = await watcher.currentRoots.map(\.origin)
        #expect(after.contains(.downloads))
    }

    @Test func clipboardEventAfterSwitchOffIsSkippedWithAReason() async throws {
        var off = Settings.default
        off.guardsClipboard = false
        let settings = InMemorySettingsStore(off)
        let (engine, root) = try makeEngine(settings: settings, watcher: nil, guard: nil)
        defer { try? FileManager.default.removeItem(at: root) }

        let stream = engine.outcomes
        await engine.submit(.pasteboardImage(Fixture.pngData(), uti: .png, changeCount: 7, preservedText: nil))
        let reports = await collect(stream, count: 1, timeout: .seconds(5))
        #expect(reports.first?.outcome.skipReason == .sourceOff)
    }
}

@Suite struct ScanStartTests {
    @Test func aFileEventAnnouncesItsStartBeforeItsOutcome() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("start")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Screenshot.png")
        try Fixture.pngData().write(to: file)
        var events = h.engine.events.makeAsyncIterator()
        await h.engine.submit(.file(file, origin: .screenshotFolder))
        guard case .started(let start)? = await events.next() else { Issue.record("the start must come first"); return }
        #expect(start.fileURL == file)
        #expect(start.origin == .screenshotFolder)
        guard case .finished(let report)? = await events.next() else { Issue.record("then its report"); return }
        #expect(report.key == start.key)
        #expect(report.fileURL == file, "the report names its file")
        #expect(report.origin == .screenshotFolder, "and where it came from")
    }
}
