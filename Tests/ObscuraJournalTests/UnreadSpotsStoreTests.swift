// G-40, schema 10: the `unreadPatch` and `textNotRead` reasons, the spots' rects kept with their row, a settled row kept
// as the record (not listed), and G-26's copy of the database taken before the table is rebuilt. Paths and rects are
// made up.
import CoreGraphics
import Foundation
import ObscuraSupport
import Testing
@testable import ObscuraJournal

enum SpotStoreFixtures {
    static let path = "/home/example/Downloads/photo.png"
    static let spot = SpotRecord(rect: CGRect(x: 1875, y: 298, width: 68, height: 14), coverRect: CGRect(x: 1844, y: 279, width: 130, height: 52),
                                 state: .pending)
    static let second = SpotRecord(rect: CGRect(x: 40, y: 50, width: 60, height: 12), coverRect: CGRect(x: 20, y: 30, width: 100, height: 52),
                                   state: .pending)

    /// A schema-9 Journal as the last build before G-40 wrote it: every migration up to 9, a style, one entry row and two
    /// Not checked rows.
    static func makeVersionNineJournal(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try SQLiteConnection(path: root.appendingPathComponent(SQLiteJournalStore.databaseName).path)
        defer { db.close() }
        try db.transaction {
            for migration in Migrations.all where migration.version <= 9 {
                try db.exec(SQLiteJournalStore.stripPragmas(migration.sql))
                if migration.version == 8 { try db.exec(Migrations.sealRuleValues008Finish) }
                if migration.version == 9 { try db.exec(Migrations.sealDetectorOverrides009Finish) }
                try db.run("INSERT INTO schema_version (version, applied_at) VALUES (?, '2026-10-28T09:00:00Z')", [.integer(Int64(migration.version))])
            }
            try db.run("INSERT INTO styles (kind, color_rgba, roundness, padding, label_mode, is_default) VALUES ('solid', '0,0,0,1', 0.07, 0.14, 'none', 1)")
            try db.run("""
                INSERT INTO unchecked (id, file_path, origin, watched_folder, reason, first_seen, last_seen, attempts) VALUES
                ('8B0C1D2E-0000-4000-8000-000000000001', '/home/example/Downloads/a.png', 'downloads', NULL, 'ocrFailed', '2026-10-27T09:00:00.000Z', '2026-10-28T09:00:00.000Z', 3),
                ('8B0C1D2E-0000-4000-8000-000000000002', '/home/example/Shots/b.png', 'watched', '/home/example/Shots', 'ocrTimeout', '2026-10-28T08:00:00.000Z', '2026-10-28T08:30:00.000Z', 1)
                """)
        }
    }

    static func schema(_ root: URL) throws -> Int {
        let db = try SQLiteConnection(path: root.appendingPathComponent(SQLiteJournalStore.databaseName).path, readOnly: true)
        defer { db.close() }
        return try db.scalarInt("SELECT max(version) FROM schema_version")
    }

    static func schemaBackups(_ backups: URL) -> [URL] { SchemaMigrationBackup.all(in: backups) }
}

@Suite("Schema 10: unread spots (G-40)", .serialized)
struct UnreadSpotsStoreTests {
    // MARK: Migration 9 → 10, with G-26's copy

    @Test func schemaNineMigratesWithEveryRowKeptAndAVerifiedCopyFirst() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let backups = root.url.appendingPathComponent("Backups", isDirectory: true)
        try SpotStoreFixtures.makeVersionNineJournal(at: root.url)
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: ManualClock(), backupsRoot: backups)
        #expect(try SpotStoreFixtures.schema(root.url) == 10)
        let rows = try await store.uncheckedFiles()
        #expect(rows.map(\.filePath) == ["/home/example/Downloads/a.png", "/home/example/Shots/b.png"])
        #expect(rows.map(\.reason) == [.ocrFailed, .ocrTimeout] && rows.map(\.attempts) == [3, 1])
        #expect(rows.allSatisfy { $0.spots.isEmpty && $0.settledAt == nil })
        #expect(rows.last?.origin == .watched(folder: "/home/example/Shots"))

        // The copy was taken before the rebuild, is at schema 9, holds both rows, and is verified, out of Time Machine.
        let copies = SpotStoreFixtures.schemaBackups(backups)
        #expect(copies.count == 1)
        let copy = try #require(copies.first)
        let manifest = try SchemaMigrationBackup.manifest(at: copy)
        #expect(manifest.state == .verified && manifest.fromVersion == 9 && manifest.toVersion == 10 && manifest.uncheckedRows == 2)
        #expect(try SchemaMigrationBackup.copyVersion(copy) == 9)
        #expect(BackupExclusion.isExcluded(copy))
        #expect(copy.lastPathComponent.hasSuffix(".noindex"), "never indexed by Spotlight")
    }

    @Test func aNewJournalTakesNoCopy() throws {
        let root = TempRoot(); defer { root.cleanup() }
        let backups = root.url.appendingPathComponent("Backups", isDirectory: true)
        _ = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: ManualClock(), backupsRoot: backups)
        #expect(SpotStoreFixtures.schemaBackups(backups).isEmpty)
    }

    @Test func aLaunchStoppedAfterTheCopyUsesTheSameCopyNextTime() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let backups = root.url.appendingPathComponent("Backups", isDirectory: true)
        try SpotStoreFixtures.makeVersionNineJournal(at: root.url)
        // Stopped after the copy, before the migration: the file stays at 9 (the migration waits), the copy as `copied`.
        _ = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: ManualClock(), backupsRoot: backups,
                                   layoutFault: nil, schemaFault: { if $0 == .copied { throw CocoaError(.userCancelled) } })
        #expect(try SpotStoreFixtures.schema(root.url) == 9)
        let first = try #require(SpotStoreFixtures.schemaBackups(backups).first)
        #expect(try SchemaMigrationBackup.manifest(at: first).state == .copied)
        // The next launch finishes with that copy, never a second one.
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: ManualClock(), backupsRoot: backups)
        #expect(try SpotStoreFixtures.schema(root.url) == 10)
        #expect(SpotStoreFixtures.schemaBackups(backups) == [first])
        #expect(try SchemaMigrationBackup.manifest(at: first).state == .verified)
        #expect(try await store.uncheckedFiles().count == 2)
        // Opening again changes nothing.
        _ = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: ManualClock(), backupsRoot: backups)
        #expect(SpotStoreFixtures.schemaBackups(backups) == [first])
    }

    @Test func withoutACopyTheMigrationWaitsAndTheJournalStillWorks() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        try SpotStoreFixtures.makeVersionNineJournal(at: root.url)
        // The copy cannot be made (a full disk, a folder that refuses writes): the migration does not run.
        let backups = root.url.appendingPathComponent("Backups", isDirectory: true)
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: ManualClock(), backupsRoot: backups,
                                           layoutFault: nil, schemaFault: { if $0 == .copying { throw CocoaError(.fileWriteOutOfSpace) } })
        #expect(try SpotStoreFixtures.schema(root.url) == 9, "no copy, no rebuild")
        #expect(SpotStoreFixtures.schemaBackups(backups).isEmpty)
        #expect(try await store.uncheckedFiles().count == 2)
        // A spot row at schema 9 is still listed, never clean: kept under the reason that schema knows.
        let row = try await store.recordUnchecked(path: SpotStoreFixtures.path, origin: .downloads, reason: .unreadPatch, spots: [SpotStoreFixtures.spot])
        #expect(row.reason == .ocrFailed && row.spots.isEmpty && row.settledAt == nil)
        #expect(try SpotStoreFixtures.schema(root.url) == 9, "every later try waits too while no copy can be made")
        // Once a copy can be made, the next launch takes it and migrates.
        let later = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: ManualClock(), backupsRoot: backups)
        #expect(try SpotStoreFixtures.schema(root.url) == 10)
        #expect(try await later.uncheckedFiles().count == 3)
        #expect(SpotStoreFixtures.schemaBackups(backups).count == 1)
    }

    @Test func aVerifiedCopyGoesAfterTheRetentionWindowAndAnUnfinishedOneStays() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let backups = root.url.appendingPathComponent("Backups", isDirectory: true)
        let clock = ManualClock()
        try SpotStoreFixtures.makeVersionNineJournal(at: root.url)
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock, backupsRoot: backups)
        let copy = try #require(SpotStoreFixtures.schemaBackups(backups).first)
        // An unfinished one beside it (a launch that stopped) is kept.
        var waiting = try SchemaMigrationBackup.manifest(at: copy)
        waiting.state = .copied
        let other = backups.appendingPathComponent("2026-10-01-000000-abcdef12-before-schema-10.noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try SchemaMigrationBackup.write(waiting, to: other)
        _ = try await store.pruneExpired(olderThan: .seconds(3600))
        #expect(FileManager.default.fileExists(atPath: copy.path), "inside the window")
        clock.advance(by: 7200)
        _ = try await store.pruneExpired(olderThan: .seconds(3600))
        #expect(!FileManager.default.fileExists(atPath: copy.path), "the window passed")
        #expect(FileManager.default.fileExists(atPath: other.path), "an unfinished copy stays")
    }

    // MARK: Rows, rects and settling

    @Test func aSpotRowRoundTripsItsReasonAndRects() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: ManualClock())
        let row = try await store.recordUnchecked(path: SpotStoreFixtures.path, origin: .downloads, reason: .unreadPatch,
                                                  spots: [SpotStoreFixtures.spot, SpotStoreFixtures.second])
        #expect(row.reason == .unreadPatch && row.spots == [SpotStoreFixtures.spot, SpotStoreFixtures.second] && row.settledAt == nil)
        #expect(try await store.uncheckedFiles() == [row])
        #expect(try await store.uncheckedFile(row.id) == row)
        // Seen again: the spots are replaced, the identity and first sighting kept.
        let again = try await store.recordUnchecked(path: SpotStoreFixtures.path, origin: .downloads, reason: .unreadPatch, spots: [SpotStoreFixtures.spot])
        #expect(again.id == row.id && again.attempts == 2 && again.spots == [SpotStoreFixtures.spot])
        // Another reason keeps no spots.
        let other = try await store.recordUnchecked(path: SpotStoreFixtures.path, origin: .downloads, reason: .textNotRead, spots: [SpotStoreFixtures.spot])
        #expect(other.reason == .textNotRead && other.spots.isEmpty)
        // The CHECK refuses a settled row with another reason, and a covered spot with no cover named.
        let db = try SQLiteConnection(path: root.url.appendingPathComponent(SQLiteJournalStore.databaseName).path)
        #expect(throws: JournalError.self) { try db.run("UPDATE unchecked SET settled_at = 't' WHERE id = ?", [.text(row.id.uuidString)]) }
        #expect(throws: JournalError.self) {
            try db.run("INSERT INTO unread_spots (unchecked_id, ordinal, rect_x, rect_y, rect_w, rect_h, cover_x, cover_y, cover_w, cover_h, state) VALUES (?, 5, 1, 1, 1, 1, 1, 1, 1, 1, 'covered')",
                       [.text(row.id.uuidString)])
        }
    }

    @Test func settlingEverySpotKeepsTheRowAsARecordAndUndoListsItAgain() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let clock = ManualClock()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        let row = try await store.recordUnchecked(path: SpotStoreFixtures.path, origin: .downloads, reason: .unreadPatch,
                                                  spots: [SpotStoreFixtures.spot, SpotStoreFixtures.second])
        var spots = row.spots
        spots[0].state = .notText
        let half = try await store.updateSpots(row.id, spots: spots)
        #expect(half.settledAt == nil && half.pendingSpots == [SpotStoreFixtures.second], "one still waits: still listed")
        #expect(try await store.uncheckedFiles().count == 1)

        let entry = UUID(), finding = UUID()
        spots[1].state = .covered; spots[1].entryID = entry; spots[1].findingID = finding
        let settled = try await store.updateSpots(row.id, spots: spots)
        #expect(settled.settledAt == clock.now() && settled.spots.map(\.state) == [.notText, .covered])
        #expect(settled.spots[1].entryID == entry && settled.spots[1].findingID == finding)
        #expect(try await store.uncheckedFiles().isEmpty, "settled: no longer listed")
        #expect(try await store.settledSpotFiles() == [settled], "kept as the record")
        #expect(try await store.spotFiles(entryID: entry) == [settled])

        // Undo: the states as they were.
        let back = try await store.updateSpots(row.id, spots: row.spots)
        #expect(back.settledAt == nil && back.spots == row.spots)
        #expect(try await store.uncheckedFiles() == [back])
        // A mismatched list is refused.
        await #expect(throws: JournalError.self) { try await store.updateSpots(row.id, spots: [SpotStoreFixtures.spot]) }
        await #expect(throws: JournalError.uncheckedNotFound(UUID(uuidString: "00000000-0000-4000-8000-000000000000")!)) {
            try await store.updateSpots(UUID(uuidString: "00000000-0000-4000-8000-000000000000")!, spots: row.spots)
        }
    }

    @Test func aSettledRecordFollowsTheRetentionWindowAndAListedOneStays() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let clock = ManualClock()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        var skipped = SpotStoreFixtures.spot
        skipped.state = .tooSmall
        let record = try await store.recordUnchecked(path: SpotStoreFixtures.path, origin: .downloads, reason: .unreadPatch, spots: [skipped])
        #expect(record.settledAt != nil, "a row whose every spot is settled when found is the record at once")
        let listed = try await store.recordUnchecked(path: "/home/example/Downloads/other.png", origin: .downloads, reason: .unreadPatch,
                                                     spots: [SpotStoreFixtures.second])
        clock.advance(by: 7200)
        _ = try await store.pruneExpired(olderThan: .seconds(3600))
        #expect(try await store.settledSpotFiles().isEmpty)
        #expect(try await store.uncheckedFiles() == [listed], "a spot waiting for the person never ages out (G-13)")
    }

    @Test func aDismissedSpotRowRestoresWithItsSpots() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: ManualClock())
        let row = try await store.recordUnchecked(path: SpotStoreFixtures.path, origin: .downloads, reason: .unreadPatch, spots: [SpotStoreFixtures.spot])
        try await store.dismissUnchecked(row.id)
        #expect(try await store.uncheckedFiles().isEmpty)
        try await store.restoreUnchecked(row)
        #expect(try await store.uncheckedFiles() == [row])
    }

    @Test func findingsAddedLeftVisibleDoNotChangeThePicture() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: ManualClock())
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])
        let entry = try await store.create(NewEntry(source: .file, displayName: "photo.png", filePath: SpotStoreFixtures.path, containerUTI: "public.png",
                                                    pixelWidth: 10, pixelHeight: 10, findings: []), original: png, clean: png)
        let added = try await store.addVisibleFindings(entry.id, [NewFinding(lineIndex: -1, rect: SpotStoreFixtures.spot.coverRect,
                                                                            detectorIDs: [SpotRecord.coverDetectorID], category: SpotRecord.coverCategory)],
                                                       expectedRevision: entry.revision)
        #expect(added.findings.count == 1 && added.findings.allSatisfy { !$0.enabled && $0.isSpotCover })
        #expect(added.revision == entry.revision + 1)
        #expect(try await store.cleanImage(entry.id).data == png)
        await #expect(throws: JournalError.revisionConflict(entry.id)) {
            try await store.addVisibleFindings(entry.id, [], expectedRevision: entry.revision)
        }
    }
}
