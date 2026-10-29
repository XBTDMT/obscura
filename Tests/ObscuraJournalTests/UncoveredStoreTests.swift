// Fail-open #7: the schema-5 `uncovered_files` table (files on disk that still show what was caught), migrated from a
// schema-4 Journal, and its store API.
import Foundation
import Testing
import ObscuraSupport
@testable import ObscuraJournal

@Suite struct UncoveredStoreTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])
    private static let cleanPNG = Data([0x89, 0x50, 0x4E, 0x47, 9, 9, 9, 9])

    private static func entry(_ name: String = "Screenshot.png") -> NewEntry {
        NewEntry(source: .file, displayName: name, filePath: "/home/x/Desktop/\(name)", containerUTI: "public.png", pixelWidth: 8, pixelHeight: 8,
                 findings: [NewFinding(lineIndex: 0, rect: CGRect(x: 1, y: 1, width: 4, height: 2), detectorIDs: ["fake.token"], category: "tokens")])
    }

    /// A schema-4 Journal as the fail-open lane A merge left it: migrations 1–4, an entry with a finding, a Not checked row,
    /// a covered-file record and a rule.
    private static func makeVersionFourJournal(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let path = root.appendingPathComponent(SQLiteJournalStore.databaseName).path
        let db = try SQLiteConnection(path: path)
        try db.transaction {
            for migration in Migrations.all where migration.version <= 4 {
                try db.exec(SQLiteJournalStore.stripPragmas(migration.sql))
                try db.run("INSERT INTO schema_version (version, applied_at) VALUES (?, '2026-10-27T09:00:00Z')", [.integer(Int64(migration.version))])
            }
            try db.run("INSERT INTO styles (id, kind, color_rgba, roundness, padding, label_mode, is_default) VALUES (1, 'solid', '0,0,0,1', 0.07, 0.14, 'none', 1)")
            try db.run("""
                INSERT INTO entries (id, created_at, source, display_name, file_path, container_uti, pixel_width, pixel_height, style_id)
                VALUES ('6F1C2D3E-0000-4000-8000-000000000001', '2026-10-27T09:00:00.000Z', 'file', 'Screenshot old.png',
                        '/home/example/Desktop/Screenshot old.png', 'public.png', 800, 600, 1)
                """)
            try db.run("""
                INSERT INTO findings (id, entry_id, line_index, rect_x, rect_y, rect_w, rect_h, detector_ids, category, enabled)
                VALUES ('6F1C2D3E-0000-4000-8000-0000000000F1', '6F1C2D3E-0000-4000-8000-000000000001', 0, 10, 20, 100, 14, '["fake.token"]', 'tokens', 1)
                """)
            try db.run("""
                INSERT INTO unchecked (id, file_path, origin, reason, first_seen, last_seen, attempts)
                VALUES ('6F1C2D3E-0000-4000-8000-0000000000B1', '/home/example/Downloads/a.png', 'downloads', 'multiFrame',
                        '2026-10-27T09:00:00.000Z', '2026-10-27T09:00:00.000Z', 2)
                """)
            try db.run("""
                INSERT INTO covered_files (id, file_path, detector_ids, categories, caught_at, updated_at)
                VALUES ('6F1C2D3E-0000-4000-8000-000000000001', '/home/example/Desktop/Screenshot old.png', '["fake.token"]', '["tokens"]',
                        '2026-10-27T09:00:00.000Z', '2026-10-27T09:00:00.000Z')
                """)
            try db.run("""
                INSERT INTO rules (id, action, kind, value, enabled, created_at, sort_order)
                VALUES ('custom.6F1C2D3E-0000-4000-8000-0000000000A1', 'allow', 'exactText', 'EXAMPLE-NOT-A-SECRET', 1, '2026-10-27T09:00:00Z', 0)
                """)
        }
        db.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    @Test func migratesASchemaFourJournalToSchemaFiveKeepingEverything() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        try Self.makeVersionFourJournal(at: root.url)
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: ManualClock(Date(timeIntervalSince1970: 1_793_000_000)))
        let db = try SQLiteConnection(path: root.url.appendingPathComponent(SQLiteJournalStore.databaseName).path)
        #expect(try db.scalarInt("SELECT max(version) FROM schema_version") >= 5)
        #expect(try db.tableExists("uncovered_files"))
        #expect(try await store.uncoveredFiles().isEmpty, "the migration adds an empty table")
        let entries = try await store.entries(matching: .all)
        #expect(entries.map(\.displayName) == ["Screenshot old.png"])
        #expect(entries.first?.findings.count == 1)
        #expect(try await store.uncheckedFiles().map(\.attempts) == [2])
        #expect(try await store.coveredFiles().count == 1)
        #expect(try await store.rules().map { $0.readable?.value } == ["EXAMPLE-NOT-A-SECRET"])
        // The attempts constraint holds in the new table.
        #expect(throws: (any Error).self) {
            try db.run("""
                INSERT INTO uncovered_files (id, file_path, source_path, first_seen, last_seen, attempts)
                VALUES ('6F1C2D3E-0000-4000-8000-0000000000C1', '/a.png', '/a.png', '2026-10-27T09:00:00.000Z', '2026-10-27T09:00:00.000Z', 0)
                """)
        }
    }

    @Test func recordingTheSamePathAgainCountsAnAttemptAndKeepsItsIdentity() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_793_000_000))
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        let id = UUID()
        let first = try await store.recordUncovered(path: "/home/x/Desktop/a.png", sourcePath: "/home/x/Desktop/a.png", entryID: id)
        #expect(first.attempts == 1 && first.entryID == id && !first.isCleanCopy)
        clock.advance(by: 60)
        let second = try await store.recordUncovered(path: "/home/x/Desktop/a.png", sourcePath: "/home/x/Desktop/a.png", entryID: id)
        #expect(second.id == first.id && second.attempts == 2 && second.firstSeen == first.firstSeen && second.lastSeen > first.lastSeen)
        clock.advance(by: 60)
        let copy = try await store.recordUncovered(path: "/home/x/Desktop/b (clean).png", sourcePath: "/home/x/Desktop/b.png", entryID: nil)
        #expect(copy.isCleanCopy && copy.entryID == nil)
        #expect(try await store.uncoveredFiles().map(\.id) == [copy.id, first.id], "most recently seen first")
    }

    @Test func aWriteOrAVerdictOrAnUndoClearsExactlyItsRows() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        let e1 = UUID(), e2 = UUID()
        _ = try await store.recordUncovered(path: "/d/a.png", sourcePath: "/d/a.png", entryID: e1)
        _ = try await store.recordUncovered(path: "/d/b (clean).png", sourcePath: "/d/b.png", entryID: e2)
        _ = try await store.recordUncovered(path: "/d/c.png", sourcePath: "/d/c.png", entryID: e2)
        // A verdict on the caught file b.png settles its clean copy's row.
        #expect(try await store.clearUncovered(path: "/d/b.png").map(\.filePath) == ["/d/b (clean).png"])
        // A write to a.png settles a.png.
        #expect(try await store.clearUncovered(path: "/d/a.png").map(\.filePath) == ["/d/a.png"])
        #expect(try await store.clearUncovered(path: "/d/nothing.png").isEmpty)
        // An Undo of e2 settles what is left of it.
        #expect(try await store.clearUncovered(entryID: e2).map(\.filePath) == ["/d/c.png"])
        #expect(try await store.uncoveredFiles().isEmpty)
    }

    @Test func dismissAndItsUndoPutTheRowBackExactly() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        let row = try await store.recordUncovered(path: "/d/a.png", sourcePath: "/d/a.png", entryID: UUID())
        try await store.dismissUncovered(row.id)
        #expect(try await store.uncoveredFiles().isEmpty)
        await #expect(throws: JournalError.uncoveredNotFound(row.id)) { try await store.dismissUncovered(row.id) }
        try await store.restoreUncovered(row)
        #expect(try await store.uncoveredFiles() == [row])
    }

    /// The secret is in the file, not in the Journal: retention, the stale sweep and Delete All leave the rows.
    @Test func rowsOutliveTheirEntries() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let clock = ManualClock()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        let e = try await store.create(Self.entry(), original: Self.png, clean: Self.cleanPNG)
        let row = try await store.recordUncovered(path: "/home/x/Desktop/Screenshot.png", sourcePath: "/home/x/Desktop/Screenshot.png", entryID: e.id)
        clock.advance(by: 3 * 24 * 3600)
        #expect(try await store.pruneExpired(olderThan: .seconds(3600)) == 1)
        _ = try await store.sweepStale()
        try await store.deleteAll()
        #expect(try await store.uncoveredFiles() == [row])
    }
}
