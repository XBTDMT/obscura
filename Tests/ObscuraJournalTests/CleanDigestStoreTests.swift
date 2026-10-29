// Fail-open #4 (G-28): the schema-6 digest of each entry's clean file, and `commitRender`, the one way its picture,
// flags and style change. A read never hands out a clean picture its row was not committed with.
import Foundation
import Testing
import ObscuraSupport
@testable import ObscuraJournal

@Suite struct CleanDigestStoreTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])
    private static let cleanPNG = Data([0x89, 0x50, 0x4E, 0x47, 9, 9, 9, 9])

    private static func newEntry() -> NewEntry {
        NewEntry(source: .file, displayName: "Shot.png", filePath: "/home/x/Desktop/Shot.png", containerUTI: "public.png", pixelWidth: 8, pixelHeight: 8,
                 findings: [NewFinding(lineIndex: 0, rect: CGRect(x: 1, y: 1, width: 4, height: 2), detectorIDs: ["fake.token"], category: "tokens"),
                            NewFinding(lineIndex: 1, rect: CGRect(x: 1, y: 4, width: 4, height: 2), detectorIDs: ["fake.token"], category: "tokens")])
    }

    @Test func aChangeWhoseRowsFailPutsThePreviousPictureBack() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        let entry = try await store.create(Self.newEntry(), original: Self.png, clean: Self.cleanPNG)
        let before = try await store.cleanImage(entry.id)
        await store.setCommitFault(.afterFileWrite)
        // An Undo-like change: nothing covered, the picture is the original.
        await #expect(throws: (any Error).self) {
            try await store.commitRender(entry.id, clean: Self.png, enabled: [], style: nil, expectedRevision: entry.revision)
        }
        #expect(try await store.cleanImage(entry.id) == before, "flags, bytes and revision as they were")
        #expect(try await store.entriesNeedingRender().isEmpty)
    }

    @Test func whenEvenThePreviousPictureCannotBePutBackEveryReadRefusesIt() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        let entry = try await store.create(Self.newEntry(), original: Self.png, clean: Self.cleanPNG)
        await store.setCommitFault(.afterFileWriteAndRestore)
        await #expect(throws: (any Error).self) {
            try await store.commitRender(entry.id, clean: Self.png, enabled: [], style: nil, expectedRevision: entry.revision)
        }
        // The rows still say "covered", the file holds the original: no reader gets it as the covered picture.
        #expect(try await store.entry(entry.id).enabledFindings.count == 2)
        await #expect(throws: JournalError.cleanOutOfDate(entry.id)) { try await store.cleanImage(entry.id) }
        await #expect(throws: JournalError.cleanOutOfDate(entry.id)) { try await store.cleanData(entry.id) }
        await #expect(throws: JournalError.cleanOutOfDate(entry.id)) { try await store.cleanURL(entry.id) }
        #expect(try await store.entriesNeedingRender() == [entry.id], "the engine renders it again")
        // A fresh render committed at the current revision makes it readable again.
        await store.setCommitFault(nil)
        let fixed = try await store.commitRender(entry.id, clean: Data([3, 3]), enabled: Set(entry.findings.map(\.id)), style: nil,
                                                 expectedRevision: entry.revision)
        #expect(try await store.cleanImage(entry.id) == CleanImage(entry: fixed, data: Data([3, 3])))
    }

    @Test func aChangeStartedFromAnOlderRevisionIsRefused() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        let entry = try await store.create(Self.newEntry(), original: Self.png, clean: Self.cleanPNG)
        let first = entry.findings[0].id, second = entry.findings[1].id
        _ = try await store.commitRender(entry.id, clean: Data([1]), enabled: [second], style: nil, expectedRevision: 1)
        // A second toggle rendered from revision 1 would undo the first one's flag: refused, so it is applied again on top.
        await #expect(throws: JournalError.revisionConflict(entry.id)) {
            try await store.commitRender(entry.id, clean: Data([2]), enabled: [first], style: nil, expectedRevision: 1)
        }
        let image = try await store.cleanImage(entry.id)
        #expect(image.data == Data([1]) && image.entry.enabledFindings.map(\.id) == [second] && image.entry.revision == 2)
    }

    /// Schema 5 → 6: every existing entry is kept but has no digest, so its clean picture is refused until re-rendered.
    @Test func migratesASchemaFiveJournalAndRefusesItsCleanPicturesUntilRendered() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let id: UUID
        do {
            let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
            id = try await store.create(Self.newEntry(), original: Self.png, clean: Self.cleanPNG).id
        }
        // Back to schema 5 as it was: no digest column, no version-6 row.
        do {
            let db = try SQLiteConnection(path: root.url.appendingPathComponent(SQLiteJournalStore.databaseName).path)
            try db.exec("ALTER TABLE entries DROP COLUMN clean_sha256")
            try db.run("DELETE FROM schema_version WHERE version >= 6")
            // (Schema 10, G-40: unread_spots is new there, so it goes too; schema 10 rebuilds `unchecked` from its columns.)
            // Schema 5's rules table held plain values (schema 8, G-30, seals them), and its detector_overrides plain
            // pattern lists (schema 9, F15, seals them).
            try db.exec("""
                DROP TABLE rules;
                CREATE TABLE rules (id TEXT PRIMARY KEY, action TEXT NOT NULL, kind TEXT NOT NULL, value TEXT NOT NULL, token_length INTEGER,
                                    name TEXT, enabled INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL, sort_order INTEGER NOT NULL);
                DROP TABLE detector_overrides;
                CREATE TABLE detector_overrides (detector_id TEXT PRIMARY KEY, specs_json TEXT NOT NULL, updated_at TEXT NOT NULL);
                DROP TABLE unread_spots;
                """)
            db.close()
        }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        let db = try SQLiteConnection(path: root.url.appendingPathComponent(SQLiteJournalStore.databaseName).path)
        #expect(try db.scalarInt("SELECT max(version) FROM schema_version") >= 6)
        let entry = try await store.entry(id)
        #expect(entry.findings.count == 2 && entry.displayName == "Shot.png", "the entry survives")
        #expect(try await store.originalData(id) == Self.png)
        await #expect(throws: JournalError.cleanOutOfDate(id)) { try await store.cleanData(id) }
        #expect(try await store.entriesNeedingRender() == [id])
    }
}
