// Fail-open #19 (G-29): `findings.text_hash` kept an unsalted SHA-256 of every caught secret in obscura.sqlite (which is
// backed up); a low-entropy kind can be brute-forced back from it, and nothing read it. Schema 7 drops the column and
// the store rewrites the file so no copy of a hash is left in the database or its log.
import Foundation
import Testing
import ObscuraSupport
@testable import ObscuraJournal

@Suite struct TextHashRemovalTests {
    /// A made-up 64-hex value standing in for a stored hash; distinctive so its bytes can be searched for on disk.
    private static let hash = String(repeating: "c0ffee5a", count: 8)

    /// A schema-6 Journal holding findings with `text_hash` filled, as every Obscura before schema 7 wrote them.
    private static func makeVersionSixJournal(at root: URL) throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(SQLiteJournalStore.databaseName).path
        let db = try SQLiteConnection(path: path)
        try db.transaction {
            for migration in Migrations.all where migration.version <= 6 {
                try db.exec(SQLiteJournalStore.stripPragmas(migration.sql))
                try db.run("INSERT INTO schema_version (version, applied_at) VALUES (?, '2026-10-28T09:00:00Z')", [.integer(Int64(migration.version))])
            }
            try db.run("INSERT INTO styles (id, kind, color_rgba, roundness, padding, label_mode, is_default) VALUES (1, 'solid', '0,0,0,1', 0.07, 0.14, 'none', 1)")
            try db.run("""
                INSERT INTO entries (id, created_at, source, display_name, container_uti, pixel_width, pixel_height, style_id)
                VALUES ('6F1C2D3E-0000-4000-8000-000000000001', '2026-10-28T09:00:00.000Z', 'file', 'Shot.png', 'public.png', 8, 8, 1)
                """)
            for i in 0..<40 {
                try db.run("""
                    INSERT INTO findings (id, entry_id, line_index, rect_x, rect_y, rect_w, rect_h, detector_ids, category, text_hash, enabled)
                    VALUES (?, '6F1C2D3E-0000-4000-8000-000000000001', ?, 1, 2, 3, 4, '["fake.token"]', 'tokens', ?, ?)
                    """, [.text(UUID().uuidString), .integer(Int64(i)), .text(hash), .integer(Int64(i % 2))])
            }
        }
        db.close()
        return path
    }

    private static func onDiskBytes(_ path: String) -> Data {
        var all = Data()
        for suffix in ["", "-wal", "-shm"] { if let d = FileManager.default.contents(atPath: path + suffix) { all.append(d) } }
        return all
    }

    @Test func migratingToSchemaSevenLeavesNoHashInTheDatabaseFileOrItsLog() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let path = try Self.makeVersionSixJournal(at: root.url)
        let needle = Data(Self.hash.utf8)
        // Positive control: before the migration the hash's bytes are on disk.
        #expect(Self.onDiskBytes(path).range(of: needle) != nil, "the probe finds a hash where there is one")

        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        let db = try SQLiteConnection(path: path)
        #expect(try db.scalarInt("SELECT max(version) FROM schema_version") >= 7)
        #expect(try !db.query("PRAGMA table_info(findings)", []) { $0.string(1) }.contains("text_hash"))
        db.close()
        #expect(Self.onDiskBytes(path).range(of: needle) == nil, "no copy of a hash in the database, its WAL or its index")

        // Every finding is still there, as it was.
        let entry = try await store.entry(UUID(uuidString: "6F1C2D3E-0000-4000-8000-000000000001")!)
        #expect(entry.findings.count == 40)
        #expect(entry.enabledFindings.count == 20)
        #expect(entry.findings.allSatisfy { $0.rect == CGRect(x: 1, y: 2, width: 3, height: 4) && $0.detectorIDs == ["fake.token"] })
    }

    @Test func aNewCatchStoresNoHash() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        let e = try await store.create(NewEntry(source: .file, displayName: "a.png", containerUTI: "public.png", pixelWidth: 8, pixelHeight: 8,
                                                findings: [NewFinding(lineIndex: 0, rect: CGRect(x: 1, y: 1, width: 2, height: 2),
                                                                      detectorIDs: ["fake.token"], category: "tokens")]),
                                       original: Data([1]), clean: Data([2]))
        #expect(try await store.entry(e.id).findings.count == 1)
        let db = try SQLiteConnection(path: root.url.appendingPathComponent(SQLiteJournalStore.databaseName).path)
        #expect(try db.query("PRAGMA table_info(findings)", []) { $0.string(1) } ==
                ["id", "entry_id", "line_index", "rect_x", "rect_y", "rect_w", "rect_h", "detector_ids", "category", "enabled"])
    }
}
