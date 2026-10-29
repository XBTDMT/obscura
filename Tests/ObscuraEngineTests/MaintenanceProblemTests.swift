// Fail-open #11: a maintenance step that fails used to be logged only ("maintenance journal step failed"), and a prune
// failure skipped the stale sweep too. Now every step runs, and one that could not finish is a problem the status
// shows (originals may be kept past the retention promised) until a later tick finishes it.
import Foundation
import Testing
import ObscuraJournal
import ObscuraPrefs
import ObscuraSupport
@testable import ObscuraEngine

@Suite(.serialized) struct MaintenanceProblemTests {
    @Test func anOriginalThatCannotBePrunedIsAProblemUntilATickRemovesIt() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        guard case .redacted(let id, _, _) = await h.scan() else { Issue.record("not redacted"); return }
        let folder = try await h.journal.originalURL(id).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        // An orphan beside it: the orphan sweep still runs after the prune failed.
        let orphan = h.root.appendingPathComponent(SQLiteJournalStore.journalFolderName).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        h.clock.advance(by: Double(Settings.default.journalRetentionHours + 1) * 3600)

        await h.engine.maintenanceTick()
        var status = await h.engine.currentStatus()
        let problem = try #require(status.problems.first { $0.kind == .journalMaintenance })
        #expect(problem.detail == "prune")
        if case .needsAttention = status.protection {} else { Issue.record("an original kept past retention needs attention") }
        #expect(!FileManager.default.fileExists(atPath: orphan.path), "the later steps ran anyway")
        #expect(try await h.journal.entries(matching: .all).map(\.id) == [id], "the row stays while the original is on disk")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        await h.engine.maintenanceTick()
        status = await h.engine.currentStatus()
        #expect(!status.problems.contains { $0.kind == .journalMaintenance })
        #expect(try await h.journal.entries(matching: .all).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
