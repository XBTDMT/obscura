// Fail-open #7: a write-back that fails leaves the original on disk. It used to live only in `recentFailures`, pruned
// after 15 minutes, after which the status said Protected again while the file still showed the secret. Now the file is
// listed in the Journal's `uncovered_files` table and in the status until a write there succeeds.
import Foundation
import Testing
import ObscuraCapture
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSupport
@testable import ObscuraEngine

@Suite(.serialized) struct NotCoveredOnDiskTests {
    /// A folder the engine can read from but not write into (the write-back's temporary file cannot be created).
    private static func lock(_ dir: URL) throws { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path) }
    private static func unlock(_ dir: URL) throws { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

    private static func relaunch(_ h: Harness) -> ShieldEngine {
        ShieldEngine(sources: [], recognizer: StubTextRecognizer(lines: [Fixture.keyLine, Fixture.plainLine]), journal: h.journal,
                     settings: h.settings, clock: h.clock, folderWatcher: nil, clipboardGuard: nil, locations: h.folders.locations,
                     folderApprovals: h.folders.approvals)
    }

    private static func isGreen(_ status: EngineStatus) -> Bool {
        if case .needsAttention = status.protection { return false }
        return !status.problems.contains { $0.kind == .notCovered }
    }

    @Test func aFailedWriteBackStaysListedPastTheFailureWindowAndARelaunchUntilAWriteLands() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("not-covered")
        defer { try? Self.unlock(dir); try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Screenshot.png")
        let original = Fixture.pngData()
        try original.write(to: file)
        try Self.lock(dir)

        // Through `submit`, as the folder watcher hands files in, so the failure has its capture key.
        h.watch(dir, as: .watched(dir))
        let reports = h.engine.outcomes
        await h.engine.submit(.file(file, origin: .watched(dir)))
        let outcome = try #require(await collect(reports, count: 1, timeout: .seconds(5)).first).outcome
        guard case .failed(.writeBack) = outcome else { Issue.record("expected a failed write-back, got \(outcome)"); return }
        #expect(try Data(contentsOf: file) == original, "the file on disk still shows the secret")

        let rows = try await h.journal.uncoveredFiles()
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.filePath == file.path && row.sourcePath == file.path)
        let entryID = try #require(row.entryID)
        #expect(try await h.journal.entry(entryID).enabledFindings.count == 1, "the catch is in the Journal")

        var status = await h.engine.currentStatus()
        #expect(status.uncovered.map(\.id) == [row.id])
        #expect(status.problems.first { $0.kind == .notCovered }?.detail == "1")
        #expect(!Self.isGreen(status))
        #expect(status.problems.first { $0.kind == .scanFailure } == nil, "counted once, as not covered, not also as not checked")

        // Before #7 the failure aged out here: 20 minutes and a maintenance tick later the status was green again.
        h.clock.advance(by: 20 * 60)
        await h.engine.maintenanceTick()
        status = await h.engine.currentStatus()
        #expect(status.uncovered.count == 1, "never pruned by time")
        #expect(!Self.isGreen(status))

        // A relaunch lists it too.
        let engine = Self.relaunch(h)
        let relaunched = await engine.currentStatus()
        #expect(relaunched.uncovered.map(\.id) == [row.id])
        #expect(!Self.isGreen(relaunched))

        // Still read-only: Try Again fails and the row stays, one attempt more.
        let file1 = try #require(relaunched.uncovered.first)
        #expect(await engine.retryUncovered(file1) == .failed)
        #expect(try await h.journal.uncoveredFiles().first?.attempts == 2)
        #expect(try Data(contentsOf: file) == original)

        // The cause goes away; Try Again writes the covered picture and only then does the status go green.
        try Self.unlock(dir)
        let file2 = try #require(await engine.currentStatus().uncovered.first)
        #expect(await engine.retryUncovered(file2) == .written)
        #expect(try Data(contentsOf: file) == (try await h.journal.cleanData(entryID)), "the covered picture is in the file")
        #expect(try Data(contentsOf: file) != original)
        #expect(try await h.journal.uncoveredFiles().isEmpty)
        #expect(Self.isGreen(await engine.currentStatus()))
    }

    @Test func aFailedBlackOutAgainIsListedAndUndoOnPurposeSettlesIt() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("not-covered-redo")
        defer { try? Self.unlock(dir); try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Shot.png")
        let original = Fixture.pngData()
        try original.write(to: file)

        guard case .redacted(let id, _, _) = await h.scan(original, name: "Shot.png", filePath: file, origin: .watched(dir)) else {
            Issue.record("not redacted"); return
        }
        try await h.engine.restoreOriginal(id)
        #expect(try Data(contentsOf: file) == original)
        #expect(Self.isGreen(await h.engine.currentStatus()), "an Undo on purpose is not a problem")

        // Black Out Again cannot write the file: the Journal says covered, the file shows the original, so it is listed.
        try Self.lock(dir)
        await #expect(throws: EngineError.self) { try await h.engine.blackOutAll(id) }
        #expect(try Data(contentsOf: file) == original)
        let row = try #require(try await h.journal.uncoveredFiles().first)
        #expect(row.entryID == id && row.filePath == file.path)
        #expect(!Self.isGreen(await h.engine.currentStatus()))

        // Undo again, on purpose: the file shows the original because the user asked, so the row goes.
        try Self.unlock(dir)
        try await h.engine.restoreOriginal(id)
        #expect(try await h.journal.uncoveredFiles().isEmpty)
        #expect(Self.isGreen(await h.engine.currentStatus()))
    }

    @Test func whenTheEntryIsGoneTryAgainChecksTheFileAgainAndItsCatchSettlesTheRow() async throws {
        let dir = try Fixture.tempDirectory("not-covered-gone")
        defer { try? Self.unlock(dir); try? FileManager.default.removeItem(at: dir) }
        var settings = Settings.default
        settings.extraFolders = [dir.path]
        let h = try Harness(settings: settings)
        defer { h.tearDown() }
        let file = dir.appendingPathComponent("Shot.png")
        let original = Fixture.pngData()
        try original.write(to: file)
        try Self.lock(dir)
        guard case .failed(.writeBack) = await h.scan(original, name: "Shot.png", filePath: file, origin: .watched(dir)) else {
            Issue.record("expected a failed write-back"); return
        }
        let row = try #require(try await h.journal.uncoveredFiles().first)
        // Retention removes the entry; the secret is still in the file, so the row stays.
        h.clock.advance(by: 48 * 3600)
        _ = try await h.journal.pruneExpired(olderThan: .seconds(3600))
        #expect(try await h.journal.entries(matching: .all).isEmpty)
        #expect(try await h.journal.uncoveredFiles().map(\.id) == [row.id], "retention never drops a file that still shows a secret")

        try Self.unlock(dir)
        let outcomes = h.engine.outcomes
        let file1 = try #require(await h.engine.currentStatus().uncovered.first)
        #expect(await h.engine.retryUncovered(file1) == .checkingAgain)
        let report = try #require(await collect(outcomes, count: 1, timeout: .seconds(5)).first)
        guard case .redacted = report.outcome else { Issue.record("not redacted: \(report.outcome)"); return }
        #expect(try Data(contentsOf: file) != original, "the new catch wrote the covered picture")
        #expect(try await h.journal.uncoveredFiles().isEmpty)
        #expect(Self.isGreen(await h.engine.currentStatus()))
    }

    @Test func aFileThatIsGoneOrNoLongerWatchedIsNeverWrittenByTryAgain() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("not-covered-unwatched")
        defer { try? Self.unlock(dir); try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Shot.png")
        try Fixture.pngData().write(to: file)
        try Self.lock(dir)
        guard case .failed(.writeBack) = await h.scan(Fixture.pngData(), name: "Shot.png", filePath: file, origin: .watched(dir)) else {
            Issue.record("expected a failed write-back"); return
        }
        try Self.unlock(dir)
        h.clock.advance(by: 48 * 3600)
        _ = try await h.journal.pruneExpired(olderThan: .seconds(3600))
        // The person stops watching the folder: a check would be an import, which never writes the file.
        h.settings.update { $0.extraFolders.removeAll() }
        let listed = try #require(await h.engine.currentStatus().uncovered.first)
        #expect(await h.engine.retryUncovered(listed) == .notWatched)
        #expect(try await h.journal.uncoveredFiles().count == 1)

        try FileManager.default.removeItem(at: file)
        #expect(await h.engine.retryUncovered(listed) == .fileMissing)
        #expect(!FileManager.default.fileExists(atPath: file.path), "a caught file that is gone is never re-created")

        // Dismiss is the user's way out; its undo lists it again exactly.
        await h.engine.dismissUncovered(listed)
        #expect(try await h.journal.uncoveredFiles().isEmpty)
        #expect(Self.isGreen(await h.engine.currentStatus()))
        await h.engine.restoreUncovered(listed)
        #expect(try await h.journal.uncoveredFiles().map(\.id) == [listed.id])
    }
}
