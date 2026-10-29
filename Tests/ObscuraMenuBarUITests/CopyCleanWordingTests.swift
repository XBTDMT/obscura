// Fail-open #4 (G-28): Copy Clean says what it copied, from the flags read with the bytes. After an Undo the "clean"
// picture is the original, so it is never announced as clean. Made-up key only; a private pasteboard, never the user's.
import AppKit
import Foundation
import Testing
import ObscuraCapture
import ObscuraUIKit
import ObscuraEngine
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSupport
@testable import ObscuraMenuBarUI

@Suite(.serialized) @MainActor struct CopyCleanWordingTests {
    @Test func copyCleanAfterAnUndoSaysItIsTheOriginalAndOnlyACoveredPictureIsCalledClean() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("obscura-copy-wording-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("obscura-copy-wording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteJournalStore(root: root.appendingPathComponent("journal", isDirectory: true), ruleKeys: InMemoryRuleKeyStore(), clock: SystemClock())
        let store = InMemorySettingsStore(.default)
        let engine = ShieldEngine(sources: [], recognizer: StubTextRecognizer(lines: [PanelModelTests.keyLine]), journal: journal, settings: store,
                                  clock: SystemClock(), folderWatcher: nil, clipboardGuard: ClipboardGuard(pasteboard: board))
        let model = AppModel(engine: engine, journal: journal, settings: store)
        let outcome = await engine.scan(imageData: SampleData.terminalPNG(covered: false), source: .imported, displayName: "Shot.png",
                                        filePath: nil, origin: nil)
        guard case .redacted(let id, _, _) = outcome else { Issue.record("not redacted: \(outcome)"); return }

        await model.copy(id, original: false)
        #expect(model.toast?.text == "Clean copy is on the clipboard.")
        #expect(model.toast?.isError == false)

        #expect(await model.restoreOriginal(id))
        await model.copy(id, original: false)
        #expect(model.toast?.text == "Copied as shown: the original, with every secret visible.")
        #expect(model.toast?.isError == true)
    }
}
