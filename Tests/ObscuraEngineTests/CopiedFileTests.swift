// F6/F12 (G-35): any process running as the user can put a file reference on the clipboard. Obscura opens one only when
// it is a regular file inside a folder it already guards; anything else is never read, never stored in the Journal and
// never written back, and the person is told it was not checked. Every pasteboard here is a private, named one; every
// folder a temporary one; every secret made up.
import AppKit
import Foundation
import Testing
import ObscuraCapture
import ObscuraJournal
@testable import ObscuraEngine

@Suite(.serialized) @MainActor struct CopiedFileTests {
    static func submit(_ rig: ClipboardRig, _ url: URL) async -> ScanReport? {
        rig.board.clearContents()
        rig.board.writeObjects([url as NSURL])
        let stream = rig.engine.outcomes
        await rig.engine.submit(.pasteboardFiles([url], changeCount: rig.board.changeCount, preservedText: nil))
        return await collect(stream, count: 1, timeout: .seconds(10)).first
    }

    /// A folder beside the rig's guarded one, which Obscura does not watch.
    static func outside(_ rig: ClipboardRig) throws -> URL {
        let folder = rig.folder.deletingLastPathComponent().appendingPathComponent("obscura-f6-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The reported exploit: a reference to a file outside every guarded folder (one the writer may have no access to).
    /// It is never opened: no Journal entry (no original stored), nothing written to the clipboard, and a notice.
    @Test func aCopiedFileOutsideTheGuardedFoldersIsNeverOpened() async throws {
        let rig = try ClipboardRig()
        defer { rig.tearDown() }
        let folder = try Self.outside(rig)
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = folder.appendingPathComponent("Statement.png")
        try Fixture.pngData().write(to: secret)

        let report = await Self.submit(rig, secret)
        #expect(report?.outcome.skipReason == .copiedFileNotGuarded)
        #expect(try await rig.journalEntries().isEmpty, "no original was stored")
        #expect(rig.board.data(forType: .png) == nil, "nothing was written to the clipboard")
        #expect(await rig.engine.currentStatus().problems.first { $0.kind == .scanFailure }?.detail == "1", "counted as not checked")
    }

    /// Positive control: the same picture, copied from the guarded folder, is checked and caught.
    @Test func aCopiedFileInsideAGuardedFolderIsChecked() async throws {
        let rig = try ClipboardRig()
        defer { rig.tearDown() }
        let report = await Self.submit(rig, try rig.shot("Copied.png"))
        guard case .redacted = report?.outcome else { Issue.record("not redacted: \(String(describing: report?.outcome))"); return }
    }

    /// A link inside the guarded folder that points outside it is resolved first: never opened.
    @Test func aLinkInTheGuardedFolderToAFileOutsideIsNeverOpened() async throws {
        let rig = try ClipboardRig()
        defer { rig.tearDown() }
        let folder = try Self.outside(rig)
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = folder.appendingPathComponent("Statement.png")
        try Fixture.pngData().write(to: secret)
        let link = rig.folder.appendingPathComponent("Looks-local.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        let report = await Self.submit(rig, link)
        #expect(report?.outcome.skipReason == .copiedFileNotGuarded)
        #expect(try await rig.journalEntries().isEmpty)
    }

    @Test func theReaderInUnitForm() throws {
        let base = try Fixture.tempDirectory("f6-unit")
        defer { try? FileManager.default.removeItem(at: base) }
        let guarded = base.appendingPathComponent("Guarded", isDirectory: true)
        try FileManager.default.createDirectory(at: guarded, withIntermediateDirectories: true)
        let roots = [WatchedRoot(url: guarded, origin: .watched(guarded))]
        let inside = guarded.appendingPathComponent("a.png")
        try Data("made-up".utf8).write(to: inside)
        #expect(CopiedFileRead.read(inside, roots: roots, maxBytes: 100) == .data(Data("made-up".utf8)))
        #expect(CopiedFileRead.read(inside, roots: roots, maxBytes: 3) == .tooLarge)
        #expect(CopiedFileRead.read(guarded, roots: roots, maxBytes: 100) == .notGuarded, "a folder is not a file")
        #expect(CopiedFileRead.read(inside, roots: [], maxBytes: 100) == .notGuarded, "nothing guarded, nothing opened")
        if case .unreadable = CopiedFileRead.read(guarded.appendingPathComponent("gone.png"), roots: roots, maxBytes: 100) {} else {
            Issue.record("a missing file is unreadable")
        }
        #expect(CopiedFileRead.read(URL(string: "https://example.com/a.png")!, roots: roots, maxBytes: 100) == .notGuarded)
    }
}

extension ClipboardRig {
    /// Every entry in the rig's Journal, trashed or not, read through a second store on the same folder.
    func journalEntries() async throws -> [Entry] {
        try await SQLiteJournalStore(root: root, ruleKeys: InMemoryRuleKeyStore()).entries(matching: .all)
    }
}
