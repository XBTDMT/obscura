// Fail-open #17: in keep-both mode an Undo used to write the original into "X (clean).png", so a file named clean held
// every secret. Now the clean copy goes to the Trash whenever the entry's picture covers nothing, and Black Out Again
// (or covering any finding again) re-creates it. The test Trash is a folder of the test's own, never the user's.
import Foundation
import Testing
import ObscuraCapture
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSearch
import ObscuraSupport
@testable import ObscuraEngine

@Suite(.serialized) struct KeepBothUndoTests {
    private static func keepBoth() -> Settings {
        var s = Settings.default
        s.fileHandling = .keepBoth
        return s
    }

    /// A ".Trash" folder inside the test's own directory: moving there is what the Finder Trash does to a path.
    private static func useTestTrash(_ engine: ShieldEngine, in dir: URL) async throws -> URL {
        let trash = dir.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        await engine.setTrash { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)"))
        }
        return trash
    }

    @Test func undoTrashesTheCleanCopyAndBlackOutAgainRecreatesIt() async throws {
        let h = try Harness(settings: Self.keepBoth())
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("keepboth-undo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let trash = try await Self.useTestTrash(h.engine, in: dir)
        let file = dir.appendingPathComponent("Shot.png")
        let original = Fixture.pngData()
        try original.write(to: file)
        guard case .redacted(let id, _, _) = await h.scan(original, name: "Shot.png", filePath: file, origin: .watched(dir)) else {
            Issue.record("not redacted"); return
        }
        let sibling = dir.appendingPathComponent("Shot (clean).png")
        #expect(try Data(contentsOf: sibling) != original)

        try await h.engine.restoreOriginal(id)
        #expect(!FileManager.default.fileExists(atPath: sibling.path), "no file named clean is left holding the original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).count == 1, "the clean copy went to the Trash")
        #expect(try Data(contentsOf: file) == original, "the caught file is never written in keep-both mode")
        // Nothing anywhere in the folder named "(clean)" holds the original.
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.contains("(clean)") {
            #expect(try Data(contentsOf: dir.appendingPathComponent(name)) != original)
        }

        try await h.engine.blackOutAll(id)
        let clean = try await h.journal.cleanImage(id)
        #expect(clean.coversEverything)
        #expect(try Data(contentsOf: sibling) == clean.data, "Black Out Again re-creates the clean copy")
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func leavingEveryFindingVisibleOneByOneTrashesItAndCoveringOneAgainRecreatesIt() async throws {
        let second = OCRLine(index: 1, text: "STRIPE_SECRET_KEY=\(Fixture.fakeKey)", rect: CGRect(x: 20, y: 70, width: 440, height: 28))
        let h = try Harness(recognizer: StubTextRecognizer(lines: [Fixture.keyLine, second]), settings: Self.keepBoth())
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("keepboth-toggle")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await Self.useTestTrash(h.engine, in: dir)
        let file = dir.appendingPathComponent("Shot.png")
        let original = Fixture.pngData()
        try original.write(to: file)
        guard case .redacted(let id, _, _) = await h.scan(original, name: "Shot.png", filePath: file, origin: .watched(dir)) else {
            Issue.record("not redacted"); return
        }
        let sibling = dir.appendingPathComponent("Shot (clean).png")
        let findings = try await h.journal.entry(id).findings
        try #require(findings.count == 2)
        try await h.engine.setFinding(findings[0].id, enabled: false, in: id)
        #expect(FileManager.default.fileExists(atPath: sibling.path), "one finding still covered: the clean copy stays")
        try await h.engine.setFinding(findings[1].id, enabled: false, in: id)
        #expect(!FileManager.default.fileExists(atPath: sibling.path), "nothing covered: the clean copy would be the original, so it goes")
        try await h.engine.setFinding(findings[1].id, enabled: true, in: id)
        #expect(try Data(contentsOf: sibling) == (try await h.journal.cleanData(id)))
    }

    /// A clean copy that could not be written is listed (#7); if the catch is then shown in full by leaving every finding
    /// visible, Try Again must not write the original into a "(clean)" file: the row is settled with nothing written.
    @Test func tryAgainNeverWritesTheOriginalIntoACleanCopy() async throws {
        let h = try Harness(settings: Self.keepBoth())
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("keepboth-retry")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path); try? FileManager.default.removeItem(at: dir) }
        _ = try await Self.useTestTrash(h.engine, in: dir)
        let file = dir.appendingPathComponent("Shot.png")
        try Fixture.pngData().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        guard case .failed(.writeBack) = await h.scan(Fixture.pngData(), name: "Shot.png", filePath: file, origin: .watched(dir)) else {
            Issue.record("expected a failed write-back"); return
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let listed = try #require(await h.engine.currentStatus().uncovered.first)
        #expect(listed.isCleanCopy)
        let id = try #require(listed.entryID)
        let finding = try #require(try await h.journal.entry(id).findings.first)
        try await h.engine.setFinding(finding.id, enabled: false, in: id)
        let again = await h.engine.currentStatus().uncovered.first ?? listed
        #expect(await h.engine.retryUncovered(again) == .written)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Shot (clean).png").path), "no clean copy holding the original")
        #expect(try await h.journal.uncoveredFiles().isEmpty)
    }

    @Test func theRecreatedCleanCopyIsLabelledForSearchAgain() async throws {
        let rig = try SearchRig(settings: Self.keepBoth()); defer { rig.tearDown() }
        _ = try await Self.useTestTrash(rig.engine, in: rig.root)
        let file = try rig.shot()
        guard case .redacted(let id, _, _) = await rig.engine.scan(imageData: try Data(contentsOf: file), source: .file, displayName: "shot",
                                                                   filePath: file, origin: .screenshotFolder) else {
            Issue.record("not redacted"); return
        }
        #expect(await rig.index.items[id.uuidString] != nil)
        try await rig.engine.restoreOriginal(id)
        #expect(await rig.index.items[id.uuidString] == nil, "the clean copy is in the Trash: no item")
        try await rig.engine.blackOutAll(id)
        let item = try #require(await rig.index.items[id.uuidString], "the re-created clean copy is findable again")
        #expect(item.displayName.hasSuffix("(clean).png"))
    }
}
