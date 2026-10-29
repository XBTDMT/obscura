// G-13: the engine writes every file it leaves without a verdict into the Journal's `unchecked` table, clears it when a
// later check reaches one, and a new engine over the same Journal (a relaunch) lists the same files.
import Foundation
import Testing
import ObscuraCapture
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSupport
@testable import ObscuraEngine

@Suite(.serialized) struct UncheckedPersistenceTests {
    /// A second engine over the first one's Journal: what the app has after it quits and opens again.
    private static func relaunch(_ h: Harness, recognizer: any TextRecognizer) -> ShieldEngine {
        ShieldEngine(sources: [], recognizer: recognizer, journal: h.journal, settings: h.settings, clock: h.clock,
                     folderWatcher: nil, clipboardGuard: nil, locations: h.folders.locations,
                     folderApprovals: h.folders.approvals)
    }

    @Test func aTimedOutFileSurvivesARelaunchAndCheckAgainOnTheNewEngineClearsIt() async throws {
        let h = try Harness(recognizer: ScriptedRecognizer(error: .timeout))
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("relaunch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Screenshot 2026-10-27 at 9.44.08 AM.png")
        try Fixture.pngData().write(to: file)
        let origin = FileOrigin.watched(dir)
        h.watch(dir, as: origin)

        let first = h.engine.outcomes
        await h.engine.submit(.file(file, origin: origin))
        #expect(try #require(await collect(first, count: 1, timeout: .seconds(5)).first).outcome.skipReason == .ocrTimeout)

        let rows = try await h.journal.uncheckedFiles()
        #expect(rows.count == 1)
        #expect(rows.first?.filePath == file.resolvingSymlinksInPath().path)
        #expect(rows.first?.origin == .watched(folder: dir.standardizedFileURL.path))
        #expect(rows.first?.reason == .ocrTimeout)
        #expect(await h.engine.currentStatus().unchecked.map(\.id) == rows.map(\.id), "the status and the Journal name the same row")

        // Relaunch: a new engine, nothing submitted yet. Its status lists the file before run() and before any scan.
        let recognizer = SequenceRecognizer([.lines([])])
        let engine = Self.relaunch(h, recognizer: recognizer)
        let after = await engine.currentStatus()
        let kept = try #require(after.unchecked.first)
        #expect(after.unchecked.count == 1)
        #expect(kept.id == rows.first?.id)
        #expect(kept.displayName == file.lastPathComponent)
        #expect(kept.fileURL.path == file.resolvingSymlinksInPath().path)
        #expect(kept.origin == origin, "the watched folder comes back as the origin")
        #expect(kept.reason == "ocrTimeout")
        #expect(after.problems.first { $0.kind == .scanFailure }?.detail == "1", "the panel's count survives the relaunch")
        if case .needsAttention = after.protection {} else { Issue.record("a persisted unchecked file holds needs attention") }

        // Check Again on the new engine re-submits it with the origin it first came from; the clean verdict clears it.
        let second = engine.outcomes
        #expect(await engine.retry(file) == origin)
        let checked = try #require(await collect(second, count: 1, timeout: .seconds(5)).first)
        #expect(checked.outcome.isClean)
        #expect(checked.origin == origin)
        #expect(recognizer.calls == 1)
        #expect(await engine.currentStatus().unchecked.isEmpty)
        #expect(try await h.journal.uncheckedFiles().isEmpty, "a verdict removes the Journal row")

        // And a third launch has nothing to show.
        #expect(await Self.relaunch(h, recognizer: recognizer).currentStatus().unchecked.isEmpty)
    }

    @Test func checkAgainForAllAfterARelaunchResubmitsEveryPersistedFile() async throws {
        let h = try Harness(recognizer: ScriptedRecognizer(error: .timeout))
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("relaunch-all")
        defer { try? FileManager.default.removeItem(at: dir) }
        // F26: each file sits in the folder its origin names, watched as the settings would have it.
        let shots = dir.appendingPathComponent("Shots", isDirectory: true), downloads = dir.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        h.watch(shots, as: .screenshotFolder)
        h.watch(downloads, as: .downloads)
        let a = shots.appendingPathComponent("A.png"), b = downloads.appendingPathComponent("B.png")
        try Fixture.pngData().write(to: a)
        try Fixture.pngData().write(to: b)
        let first = h.engine.outcomes
        await h.engine.submit(.file(a, origin: .screenshotFolder))
        await h.engine.submit(.file(b, origin: .downloads))
        #expect(await collect(first, count: 2, timeout: .seconds(5)).count == 2)

        let engine = Self.relaunch(h, recognizer: StubTextRecognizer(lines: []))
        let second = engine.outcomes
        #expect(await engine.retryUnchecked() == 2)
        let checked = await collect(second, count: 2, timeout: .seconds(5))
        #expect(checked.allSatisfy { $0.outcome.isClean })
        #expect(Set(checked.compactMap(\.origin)) == [.screenshotFolder, .downloads], "each with its persisted origin")
        #expect(try await h.journal.uncheckedFiles().isEmpty)
    }

    @Test func aSecondFailureCountsAnAttemptAndKeepsTheFirstSighting() async throws {
        let h = try Harness(recognizer: ScriptedRecognizer(error: .timeout))
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("attempts")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Slow.png")
        try Fixture.pngData().write(to: file)

        let stream = h.engine.outcomes
        await h.engine.submit(.file(file, origin: .imported))
        _ = await collect(stream, count: 1, timeout: .seconds(5))
        let firstSeen = h.clock.now()
        h.clock.advance(by: 120)
        let again = h.engine.outcomes
        await h.engine.retry(file)
        _ = await collect(again, count: 1, timeout: .seconds(5))

        let kept = try #require(await h.engine.currentStatus().unchecked.first)
        #expect(kept.attempts == 2)
        #expect(kept.firstSeen == firstSeen)
        #expect(kept.date == firstSeen.addingTimeInterval(120))
        let row = try #require(try await h.journal.uncheckedFiles().first)
        #expect(row.id == kept.id && row.attempts == 2 && row.firstSeen == firstSeen)
    }

    @Test func dismissRemovesTheFileEverywhereAndRestorePutsItBackExactly() async throws {
        let h = try Harness(recognizer: ScriptedRecognizer(error: .failed(underlying: CocoaError(.fileReadUnknown))))
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("dismiss")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Broken.png")
        try Fixture.pngData().write(to: file)
        let stream = h.engine.outcomes
        await h.engine.submit(.file(file, origin: .downloads))
        _ = await collect(stream, count: 1, timeout: .seconds(5))
        let kept = try #require(await h.engine.currentStatus().unchecked.first)
        #expect(kept.reason == "ocrFailed")

        await h.engine.dismissUnchecked(kept)
        let dismissed = await h.engine.currentStatus()
        #expect(dismissed.unchecked.isEmpty)
        #expect(!dismissed.problems.contains { $0.kind == .scanFailure }, "a dismissed file no longer holds needs attention")
        #expect(try await h.journal.uncheckedFiles().isEmpty)
        #expect(await Self.relaunch(h, recognizer: StubTextRecognizer(lines: [])).currentStatus().unchecked.isEmpty,
                "a dismissed file stays dismissed after a relaunch")

        await h.engine.restoreUnchecked(kept)
        #expect(await h.engine.currentStatus().unchecked == [kept])
        #expect(try await h.journal.uncheckedFiles() == [try #require(kept.record)])
    }

    @Test func anUncheckedFileDoesNotAgeOutWithTheFailureWindow() async throws {
        let h = try Harness(recognizer: ScriptedRecognizer(error: .timeout))
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("window")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Old.png")
        try Fixture.pngData().write(to: file)
        let stream = h.engine.outcomes
        await h.engine.submit(.file(file, origin: .screenshotFolder))
        _ = await collect(stream, count: 1, timeout: .seconds(5))
        h.clock.advance(by: PipelineConstants.recentFailureWindow.seconds * 4)
        let status = await h.engine.currentStatus()
        #expect(status.unchecked.count == 1, "never silently forgotten: only a verdict or a dismiss removes it")
        #expect(status.problems.first { $0.kind == .scanFailure }?.detail == "1")
    }

    /// Fail-open #2: a Check Again that now fails to decode used to drop the row with no verdict. It keeps the row, with
    /// the new reason, one more attempt and the first sighting.
    @Test func aCheckAgainThatNowFailsToDecodeKeepsTheRowWithTheNewReason() async throws {
        let h = try Harness(recognizer: ScriptedRecognizer(error: .timeout))
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("gone")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Gone.png")
        try Fixture.pngData().write(to: file)
        let stream = h.engine.outcomes
        await h.engine.submit(.file(file, origin: .imported))
        _ = await collect(stream, count: 1, timeout: .seconds(5))
        let first = try #require(try await h.journal.uncheckedFiles().first)
        #expect(first.reason == .ocrTimeout)
        try Fixture.corruptPNG.write(to: file)
        let again = h.engine.outcomes
        await h.engine.retry(file)
        #expect(try #require(await collect(again, count: 1, timeout: .seconds(5)).first).outcome.skipReason == .decodeFailed)
        let kept = try #require(await h.engine.currentStatus().unchecked.first)
        #expect(kept.reason == "decodeFailed")
        #expect(kept.attempts == 2)
        let row = try #require(try await h.journal.uncheckedFiles().first)
        #expect(row.id == first.id && row.reason == .decodeFailed && row.attempts == 2 && row.firstSeen == first.firstSeen)
    }

    @Test func everyOutcomeThatLeavesAFileUncheckedHasAJournalReason() {
        let outcomes: [ScanOutcome] = SkipReason.allCases.map { .skipped($0) } + [
            .failed(.render("x")), .failed(.encode("x")), .failed(.journal("x")), .failed(.writeBack("x")), .failed(.ocr("x")),
            .failed(.catalogue("x")), .failed(.entryNotFound(UUID())),
        ]
        // Every outcome that leaves the picture as it was gets a row, except a failed write-back (its entry exists) and
        // the SkipReason that only names a write-back.
        for outcome in outcomes where outcome.needsAttention {
            switch outcome {
            case .failed(.writeBack), .failed(.entryNotFound), .skipped(.writeFailed): continue
            case .skipped(.severalFiles), .skipped(.copiedFileNotGuarded): continue   // clipboard only: never a file's row
            default: #expect(ShieldEngine.uncheckedReason(for: outcome) != nil, "\(outcome.statLabel) has a row in the unchecked table")
            }
        }
        #expect(Set(outcomes.compactMap(ShieldEngine.uncheckedReason(for:)).map(\.rawValue)) == Set(UncheckedReason.allCases.map(\.rawValue)),
                "the Journal lists exactly the reasons the engine writes")
    }

    @Test func originsRoundTripThroughTheJournalsForm() {
        let folder = URL(fileURLWithPath: "/home/example/Projects/shots", isDirectory: true)
        for origin: FileOrigin in [.screenshotFolder, .downloads, .watched(folder), .imported] {
            #expect(FileOrigin(UncheckedOrigin(origin)) == origin)
        }
        #expect(UncheckedOrigin(.watched(folder)) == .watched(folder: "/home/example/Projects/shots"))
    }
}
