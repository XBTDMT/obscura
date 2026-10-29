// Fail-open #4 (G-28): the flags used to be committed before the clean picture was re-rendered, so a render that failed
// after an Undo left the Journal saying "covered" while the clean bytes held the original; Copy Clean, the banner crop
// and the thumbnails then showed the original as Obscura's clean picture. Now the picture is rendered first and
// committed with the flags in one Journal call, and every read of the clean picture comes with the flags it matches.
import Foundation
import Testing
import ObscuraCapture
@testable import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSupport
@testable import ObscuraEngine

@Suite(.serialized) struct CleanPictureInvariantTests {
    /// Two made-up keys on two lines: two findings.
    static let secondKeyLine = OCRLine(index: 1, text: "STRIPE_SECRET_KEY=\(Fixture.fakeKey)", rect: CGRect(x: 20, y: 70, width: 440, height: 28))

    private static func caught(_ h: Harness, in dir: URL) async throws -> (UUID, URL, Data) {
        let file = dir.appendingPathComponent("Shot.png")
        let original = Fixture.pngData()
        try original.write(to: file)
        guard case .redacted(let id, _, _) = await h.scan(original, name: "Shot.png", filePath: file, origin: .watched(dir)) else {
            throw EngineError.render("not redacted")
        }
        return (id, file, original)
    }

    @Test func aRenderThatFailsAfterAnUndoLeavesTheEntrySayingOriginalAndNothingCallsTheOriginalClean() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("g28-undo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (id, file, original) = try await Self.caught(h, in: dir)
        try await h.engine.restoreOriginal(id)

        await h.engine.setRenderFault(.render("injected"))
        await #expect(throws: EngineError.self) { try await h.engine.blackOutAll(id) }

        // The Journal still says what the bytes show: every finding visible, the original.
        let image = try await h.journal.cleanImage(id)
        #expect(image.entry.enabledFindings.isEmpty, "no flag claims a cover the picture does not have")
        #expect(image.data == original)
        #expect(!image.coversEverything)
        // Copy Clean hands back the entry it copied, so its caller says "the original", never "clean".
        let copied = try await h.engine.copyToClipboard(id, original: false)
        #expect(copied.enabledFindings.isEmpty)
        #expect(try Data(contentsOf: file) == original, "the file shows the original, as the Journal says")
        #expect(try await h.journal.uncoveredFiles().isEmpty, "an Undo on purpose is not a file left uncovered")

        // Once rendering works, Black Out Again covers it, picture and flags together.
        await h.engine.setRenderFault(nil)
        try await h.engine.blackOutAll(id)
        let covered = try await h.journal.cleanImage(id)
        #expect(covered.coversEverything)
        #expect(covered.data != original)
        #expect(try Data(contentsOf: file) == covered.data)
    }

    @Test func aToggleWhoseRenderFailsLeavesFlagsPictureAndRevisionAsTheyWere() async throws {
        // Two findings, so leaving one visible needs a render (the other stays covered).
        let h = try Harness(recognizer: StubTextRecognizer(lines: [Fixture.keyLine, Self.secondKeyLine]))
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("g28-toggle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (id, _, _) = try await Self.caught(h, in: dir)
        let before = try await h.journal.cleanImage(id)
        let finding = try #require(before.entry.findings.first)

        await h.engine.setRenderFault(.render("injected"))
        // Leaving the finding visible would need the picture rendered without its cover; that render fails, so nothing changes.
        await #expect(throws: EngineError.self) { try await h.engine.setFinding(finding.id, enabled: false, in: id) }
        let after = try await h.journal.cleanImage(id)
        #expect(after == before, "flags, bytes and revision unchanged")
    }

    @Test func aJournalOriginalThatNoLongerDecodesCannotBeCalledCovered() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("g28-decode")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (id, _, _) = try await Self.caught(h, in: dir)
        try await h.engine.restoreOriginal(id)
        // The disk under the Journal goes bad: the original no longer decodes, a real render failure.
        let originalURL = try await h.journal.originalURL(id)
        try Fixture.corruptPNG.write(to: originalURL)
        await #expect(throws: EngineError.self) { try await h.engine.blackOutAll(id) }
        #expect(try await h.journal.entry(id).enabledFindings.isEmpty, "still 'Original showing', the truth")
    }

    @Test func twoTogglesAtOnceBothLandAndThePictureMatchesBoth() async throws {
        let h = try Harness(recognizer: StubTextRecognizer(lines: [Fixture.keyLine, Self.secondKeyLine]))
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("g28-race")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (id, _, original) = try await Self.caught(h, in: dir)
        let findings = try await h.journal.entry(id).findings
        try #require(findings.count == 2)
        async let a: Void = h.engine.setFinding(findings[0].id, enabled: false, in: id)
        async let b: Void = h.engine.setFinding(findings[1].id, enabled: false, in: id)
        _ = try await (a, b)
        let image = try await h.journal.cleanImage(id)
        #expect(image.entry.enabledFindings.isEmpty, "neither toggle was lost")
        #expect(image.data == original, "nothing covered: the picture is the original, as the flags say")
        #expect(try await h.journal.entriesNeedingRender().isEmpty)
    }

    @Test func anEntryFromBeforeTheDigestIsRefusedUntilRenderedAgainAndAFileShowingTheOriginalIsListed() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("g28-legacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (id, file, original) = try await Self.caught(h, in: dir)
        // As schema 5 left it, and in the #4 state: flags say covered, the clean file and the file on disk hold the original.
        let cleanURL = try await h.journal.cleanURL(id)
        try original.write(to: cleanURL)
        try original.write(to: file)
        let db = try SQLiteConnection(path: h.root.appendingPathComponent(SQLiteJournalStore.databaseName).path)
        try db.run("UPDATE entries SET clean_sha256 = NULL WHERE id = ?", [.text(id.uuidString)])
        db.close()

        await #expect(throws: JournalError.cleanOutOfDate(id)) { try await h.journal.cleanData(id) }
        await #expect(throws: JournalError.cleanOutOfDate(id)) { try await h.journal.cleanImage(id) }
        await #expect(throws: JournalError.cleanOutOfDate(id)) { try await h.journal.cleanURL(id) }
        await #expect(throws: (any Error).self) { try await h.engine.copyToClipboard(id, original: false) }
        #expect(try await h.journal.entriesNeedingRender() == [id])

        await h.engine.repairCleanPictures()
        let image = try await h.journal.cleanImage(id)
        #expect(image.coversEverything && image.data != original, "re-rendered from the original and the flags")
        #expect(try await h.journal.entriesNeedingRender().isEmpty)
        // The file on disk still holds the original while the entry covers it: listed, not silently rewritten.
        #expect(try await h.journal.uncoveredFiles().map(\.filePath) == [file.path])
        #expect(try Data(contentsOf: file) == original)
    }
}
