import AppKit
import Foundation
import Testing
@testable import ObscuraCapture
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSupport
@testable import ObscuraEngine

/// Undo (restoreOriginal) and redo (blackOutAll) are exact inverses, for file and clipboard catches.
@Suite(.serialized) struct UndoRedoTests {
    @Test func undoShowsEveryFindingAndPutsTheOriginalBack() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("undo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Shot.png")
        let original = Fixture.pngData()
        try original.write(to: file)

        let outcome = await h.scan(original, name: "Shot.png", filePath: file, origin: .screenshotFolder)
        guard case .redacted(let id, _, _) = outcome else { Issue.record("not redacted: \(outcome)"); return }
        let cleanOnDisk = try Data(contentsOf: file)
        #expect(cleanOnDisk != original)

        try await h.engine.restoreOriginal(id)
        let afterUndo = try await h.journal.entry(id)
        #expect(afterUndo.enabledFindings.isEmpty, "every finding is visible after undo")
        #expect(try Data(contentsOf: file) == original, "the original bytes are back on disk")
        #expect(try await h.journal.cleanData(id) == original, "the entry's current image is the original")

        try await h.engine.blackOutAll(id)
        let afterRedo = try await h.journal.entry(id)
        #expect(afterRedo.enabledFindings.count == afterRedo.findings.count, "every finding is covered again")
        #expect(try Data(contentsOf: file) != original, "a clean image is on disk again")
    }

    @Test @MainActor func clipboardCatchUndoGoesBackToTheClipboard() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("obscura-undo-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let clipboard = ClipboardGuard(pasteboard: board)
        let root = try Fixture.tempDirectory("undo-clip")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteJournalStore(root: root, ruleKeys: InMemoryRuleKeyStore(), clock: ManualClock())
        let engine = ShieldEngine(sources: [], recognizer: StubTextRecognizer(lines: [Fixture.keyLine]), journal: journal,
                                  settings: InMemorySettingsStore(.default), clock: ManualClock(), folderWatcher: nil, clipboardGuard: clipboard)

        let outcome = await engine.scan(imageData: Fixture.pngData(), source: .clipboard, displayName: "Clipboard", filePath: nil, origin: nil)
        guard case .redacted(let id, _, _) = outcome else { Issue.record("not redacted: \(outcome)"); return }

        try await engine.restoreOriginal(id)
        #expect(try await journal.entry(id).enabledFindings.isEmpty)
        #expect(board.data(forType: .png) != nil, "the original is on the clipboard")

        try await engine.blackOutAll(id)
        #expect(try await journal.entry(id).enabledFindings.count == 1)
    }
}

@Suite(.serialized) @MainActor struct CopyToClipboardTests {
    @Test func copyOriginalReachesTheClipboardAndTheGuardIgnoresIt() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("obscura-copy-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let clipboard = ClipboardGuard(pasteboard: board)
        let root = try Fixture.tempDirectory("copy")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteJournalStore(root: root, ruleKeys: InMemoryRuleKeyStore(), clock: ManualClock())
        let engine = ShieldEngine(sources: [], recognizer: StubTextRecognizer(lines: [Fixture.keyLine]), journal: journal,
                                  settings: InMemorySettingsStore(.default), clock: ManualClock(), folderWatcher: nil, clipboardGuard: clipboard)
        let outcome = await engine.scan(imageData: Fixture.pngData(), source: .file, displayName: "Shot.png", filePath: nil, origin: nil)
        guard case .redacted(let id, _, _) = outcome else { Issue.record("not redacted"); return }

        try await clipboard.start()
        defer { Task { await clipboard.stop() } }
        var events = clipboard.events.makeAsyncIterator()
        try await engine.copyToClipboard(id, original: true)
        #expect(board.data(forType: .png) != nil)

        // The guard must treat our write as its own: no catch event follows. A plain write afterwards proves it is listening.
        clipboard.tick()
        board.clearContents(); board.setData(Fixture.pngData(), forType: .png)
        clipboard.tick()
        let next = await events.next()
        if case .pasteboardImage(_, _, let count, _) = next { #expect(count == board.changeCount) } else { Issue.record("no event") }
    }
}
