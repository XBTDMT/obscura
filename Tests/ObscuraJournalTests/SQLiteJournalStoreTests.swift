import Foundation
import Testing
import ObscuraSupport
@testable import ObscuraJournal

/// A fresh root per test, removed afterwards.
struct TempRoot {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("obscura-journal-\(UUID().uuidString)", isDirectory: true)
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

private func mode(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? -1) & 0o777
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])
private let cleanPNG = Data([0x89, 0x50, 0x4E, 0x47, 9, 9, 9, 9])

private func sample(_ name: String = "Screenshot.png", findings: Int = 2, uti: String = "public.png") -> NewEntry {
    NewEntry(source: .file, displayName: name, filePath: "/home/x/Desktop/\(name)", containerUTI: uti, pixelWidth: 800, pixelHeight: 600,
             findings: (0..<findings).map { i in
                 NewFinding(lineIndex: i, rect: CGRect(x: 10, y: Double(20 * i), width: 100, height: 14), detectorIDs: ["fake.token", "generic.entropy"],
                            category: "ai")
             })
}

@Suite struct SchemaTests {
    @Test func createsSchemaAndReopensIdempotently() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        do {
            let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
            _ = try await store.defaultStyle()
        }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        let db = try SQLiteConnection(path: root.url.appendingPathComponent("obscura.sqlite").path)
        #expect(try db.scalarInt("SELECT count(*) FROM schema_version") == Migrations.all.count, "each migration recorded once")
        #expect(try db.scalarInt("SELECT max(version) FROM schema_version") == Migrations.latestVersion)
        for table in ["entries", "findings", "styles", "rules", "detector_overrides", "detector_state", "stats_days", "unchecked", "covered_files"] {
            #expect(try db.tableExists(table), "\(table) exists")
        }
        #expect(try db.first("PRAGMA journal_mode", []) { $0.string(0) } == "wal")
        #expect(try mode(root.url.appendingPathComponent("obscura.sqlite")) == 0o600)
        #expect(try mode(root.url) == 0o700)
        #expect(try mode(root.url.appendingPathComponent(SQLiteJournalStore.journalFolderName)) == 0o700)
        _ = try await store.defaultStyle()
    }

    @Test func refusesNewerSchema() throws {
        let root = TempRoot(); defer { root.cleanup() }
        _ = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        let db = try SQLiteConnection(path: root.url.appendingPathComponent("obscura.sqlite").path)
        try db.run("INSERT INTO schema_version (version, applied_at) VALUES (99, '2030-01-01T00:00:00Z')")
        db.close()
        #expect(throws: JournalError.newerSchema(found: 99, supported: Migrations.latestVersion)) {
            _ = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        }
    }

    @Test func embeddedMigrationMatchesSQLFile() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ObscuraJournal/Migrations", isDirectory: true)
        let onDisk = try String(contentsOf: folder.appendingPathComponent("001_initial.sql"), encoding: .utf8)
        #expect(onDisk.trimmingCharacters(in: .newlines) == Migrations.initial001.trimmingCharacters(in: .newlines))
        #expect(onDisk.contains("PRAGMA journal_mode = WAL;"))
        #expect(!SQLiteJournalStore.stripPragmas(onDisk).contains("PRAGMA"))
        let second = try String(contentsOf: folder.appendingPathComponent("002_unchecked.sql"), encoding: .utf8)
        #expect(second.trimmingCharacters(in: .newlines) == Migrations.unchecked002.trimmingCharacters(in: .newlines))
        let third = try String(contentsOf: folder.appendingPathComponent("003_covered_files.sql"), encoding: .utf8)
        #expect(third.trimmingCharacters(in: .newlines) == Migrations.coveredFiles003.trimmingCharacters(in: .newlines))
        let fourth = try String(contentsOf: folder.appendingPathComponent("004_unchecked_reasons.sql"), encoding: .utf8)
        #expect(fourth.trimmingCharacters(in: .newlines) == Migrations.uncheckedReasons004.trimmingCharacters(in: .newlines))
        // One SQL file per migration, numbered as the list is.
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".sql") }.sorted()
        let fifth = try String(contentsOf: folder.appendingPathComponent("005_uncovered_files.sql"), encoding: .utf8)
        #expect(fifth.trimmingCharacters(in: .newlines) == Migrations.uncoveredFiles005.trimmingCharacters(in: .newlines))
        let sixth = try String(contentsOf: folder.appendingPathComponent("006_clean_digest.sql"), encoding: .utf8)
        #expect(sixth.trimmingCharacters(in: .newlines) == Migrations.cleanDigest006.trimmingCharacters(in: .newlines))
        let seventh = try String(contentsOf: folder.appendingPathComponent("007_drop_text_hash.sql"), encoding: .utf8)
        #expect(seventh.trimmingCharacters(in: .newlines) == Migrations.dropTextHash007.trimmingCharacters(in: .newlines))
        // Schema 8 (G-30) runs in two halves around the sealing the store does in Swift; the file holds both, in order.
        let eighth = try String(contentsOf: folder.appendingPathComponent("008_seal_rule_values.sql"), encoding: .utf8)
        #expect(eighth.trimmingCharacters(in: .newlines)
                == (Migrations.sealRuleValues008 + "\n" + Migrations.sealRuleValues008Finish).trimmingCharacters(in: .newlines))
        // Schema 9 (F15/F24) the same way, for detector-override patterns.
        let ninth = try String(contentsOf: folder.appendingPathComponent("009_seal_detector_overrides.sql"), encoding: .utf8)
        #expect(ninth.trimmingCharacters(in: .newlines)
                == (Migrations.sealDetectorOverrides009 + "\n" + Migrations.sealDetectorOverrides009Finish).trimmingCharacters(in: .newlines))
        // Schema 10 (G-40): the unread-spot reason, the settled record and the spots' rects.
        let tenth = try String(contentsOf: folder.appendingPathComponent("010_unread_spots.sql"), encoding: .utf8)
        #expect(tenth.trimmingCharacters(in: .newlines) == Migrations.unreadSpots010.trimmingCharacters(in: .newlines))
        #expect(files == ["001_initial.sql", "002_unchecked.sql", "003_covered_files.sql", "004_unchecked_reasons.sql",
                          "005_uncovered_files.sql", "006_clean_digest.sql", "007_drop_text_hash.sql", "008_seal_rule_values.sql",
                          "009_seal_detector_overrides.sql", "010_unread_spots.sql"])
        #expect(Migrations.all.map(\.version) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    }
}

/// G-13: the schema-2 migration from a real schema-1 Journal, and the `unchecked` store API.
@Suite struct UncheckedStoreTests {
    /// A schema-1 Journal as Obscura before G-13 wrote it: migration 1 only, one entry with findings, a rule, a stat.
    private static func makeVersionOneJournal(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let path = root.appendingPathComponent(SQLiteJournalStore.databaseName).path
        let db = try SQLiteConnection(path: path)
        try db.transaction {
            try db.exec(SQLiteJournalStore.stripPragmas(Migrations.initial001))
            try db.run("INSERT INTO schema_version (version, applied_at) VALUES (1, '2026-10-20T09:00:00Z')")
            try db.run("INSERT INTO styles (id, kind, color_rgba, roundness, padding, label_mode, is_default) VALUES (1, 'solid', '0,0,0,1', 0.07, 0.14, 'none', 1)")
            try db.run("""
                INSERT INTO entries (id, created_at, source, display_name, file_path, container_uti, pixel_width, pixel_height, style_id)
                VALUES ('6F1C2D3E-0000-4000-8000-000000000001', '2026-10-20T09:00:00.000Z', 'file', 'Screenshot old.png',
                        '/home/example/Desktop/Screenshot old.png', 'public.png', 800, 600, 1)
                """)
            try db.run("""
                INSERT INTO findings (id, entry_id, line_index, rect_x, rect_y, rect_w, rect_h, detector_ids, category, text_hash, enabled)
                VALUES ('6F1C2D3E-0000-4000-8000-0000000000F1', '6F1C2D3E-0000-4000-8000-000000000001', 0, 10, 20, 100, 14,
                        '["fake.token"]', 'tokens', NULL, 1)
                """)
            try db.run("""
                INSERT INTO rules (id, action, kind, value, enabled, created_at, sort_order)
                VALUES ('custom.6F1C2D3E-0000-4000-8000-0000000000A1', 'allow', 'exactText', 'EXAMPLE-NOT-A-SECRET', 1, '2026-10-20T09:00:00Z', 0)
                """)
            try db.run("INSERT INTO stats_days (day, checked, caught, secrets) VALUES ('2026-10-20', 4, 1, 1)")
        }
        db.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    @Test func migratesASchemaOneJournalWithItsDataToTheCurrentSchema() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        try Self.makeVersionOneJournal(at: root.url)
        let clock = ManualClock(Date(timeIntervalSince1970: 1_793_000_000))
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)

        let db = try SQLiteConnection(path: root.url.appendingPathComponent(SQLiteJournalStore.databaseName).path)
        #expect(try db.query("SELECT version FROM schema_version ORDER BY version", []) { $0.int(0) } == Array(1...Migrations.latestVersion))
        #expect(try db.tableExists("unchecked"))
        #expect(try db.scalarInt("SELECT count(*) FROM unchecked") == 0, "the migration adds an empty table")

        // Everything schema 1 held is still there and still reads.
        let entries = try await store.entries(matching: .all)
        #expect(entries.count == 1)
        #expect(entries.first?.displayName == "Screenshot old.png")
        #expect(entries.first?.findings.count == 1)
        #expect(try await store.rules().map { $0.readable?.value } == ["EXAMPLE-NOT-A-SECRET"])
        #expect(try await store.defaultStyle().kind == .solid)

        // The new table works over the migrated file, and the file keeps its 0600.
        let record = try await store.recordUnchecked(path: "/home/example/Desktop/Screenshot new.png", origin: .screenshotFolder, reason: .ocrTimeout)
        #expect(try await store.uncheckedFiles() == [record])
        #expect(try mode(root.url.appendingPathComponent(SQLiteJournalStore.databaseName)) == 0o600)
        #expect(try mode(root.url) == 0o700)

        // Reopening a current Journal applies nothing again.
        _ = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        #expect(try db.scalarInt("SELECT count(*) FROM schema_version") == Migrations.all.count)
    }

    @Test func aSchemaOneJournalStillRefusesASchemaTheBuildDoesNotKnow() throws {
        let root = TempRoot(); defer { root.cleanup() }
        try Self.makeVersionOneJournal(at: root.url)
        let db = try SQLiteConnection(path: root.url.appendingPathComponent(SQLiteJournalStore.databaseName).path)
        try db.run("INSERT INTO schema_version (version, applied_at) VALUES (\(Migrations.latestVersion + 1), '2030-01-01T00:00:00Z')")
        db.close()
        #expect(throws: JournalError.newerSchema(found: Migrations.latestVersion + 1, supported: Migrations.latestVersion)) { _ = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore()) }
    }

    /// Schema 4 (fail-open #2): a schema-2 Journal, as G-13 wrote it, with Not checked rows of every origin. Schema 2's
    /// CHECK refuses the new reasons; the migration rebuilds the table, keeps every row exactly, and then takes them.
    @Test func migratesASchemaTwoJournalKeepingEveryUncheckedRowAndAcceptingTheNewReasons() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        try Self.makeVersionOneJournal(at: root.url)
        let path = root.url.appendingPathComponent(SQLiteJournalStore.databaseName).path
        do {
            let db = try SQLiteConnection(path: path)
            try db.transaction {
                try db.exec(SQLiteJournalStore.stripPragmas(Migrations.unchecked002))
                try db.run("INSERT INTO schema_version (version, applied_at) VALUES (2, '2026-10-27T09:00:00Z')")
                try db.run("""
                    INSERT INTO unchecked (id, file_path, origin, watched_folder, reason, first_seen, last_seen, attempts) VALUES
                    ('6F1C2D3E-0000-4000-8000-0000000000B1', '/home/example/Desktop/Screenshot a.png', 'screenshotFolder', NULL, 'ocrTimeout',
                     '2026-10-27T09:00:00.000Z', '2026-10-27T09:05:00.000Z', 3),
                    ('6F1C2D3E-0000-4000-8000-0000000000B2', '/home/example/Projects/shots/b.png', 'watched', '/home/example/Projects/shots',
                     'renderFailed', '2026-10-27T09:01:00.000Z', '2026-10-27T09:01:00.000Z', 1)
                    """)
            }
            // The constraint the migration exists for: schema 2 refuses a reason it does not list.
            #expect(throws: (any Error).self) {
                try db.run("""
                    INSERT INTO unchecked (id, file_path, origin, reason, first_seen, last_seen)
                    VALUES ('6F1C2D3E-0000-4000-8000-0000000000B3', '/x.png', 'imported', 'decodeFailed', '2026-10-27T09:00:00.000Z', '2026-10-27T09:00:00.000Z')
                    """)
            }
            db.close()
        }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_793_000_000))
        let before: Set<UncheckedRecord> = [
            UncheckedRecord(id: UUID(uuidString: "6F1C2D3E-0000-4000-8000-0000000000B1")!, filePath: "/home/example/Desktop/Screenshot a.png",
                            origin: .screenshotFolder, reason: .ocrTimeout, firstSeen: try ISO.date("2026-10-27T09:00:00.000Z"),
                            lastSeen: try ISO.date("2026-10-27T09:05:00.000Z"), attempts: 3),
            UncheckedRecord(id: UUID(uuidString: "6F1C2D3E-0000-4000-8000-0000000000B2")!, filePath: "/home/example/Projects/shots/b.png",
                            origin: .watched(folder: "/home/example/Projects/shots"), reason: .renderFailed,
                            firstSeen: try ISO.date("2026-10-27T09:01:00.000Z"), lastSeen: try ISO.date("2026-10-27T09:01:00.000Z"), attempts: 1),
        ]
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)

        let db = try SQLiteConnection(path: path)
        #expect(try db.query("SELECT version FROM schema_version ORDER BY version", []) { $0.int(0) } == Array(1...Migrations.latestVersion))
        let rows = try await store.uncheckedFiles()
        #expect(rows.count == 2)
        #expect(Set(rows) == before, "ids, paths, origins, reasons, sightings and attempts unchanged")
        #expect(try db.scalarInt("SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'unchecked_last_seen'") == 1)
        #expect(try db.scalarInt("SELECT count(*) FROM sqlite_master WHERE name = 'unchecked_v4'") == 0)
        // Every reason the engine writes is now accepted, and the other constraints still hold.
        for (i, reason) in UncheckedReason.allCases.enumerated() {
            let row = try await store.recordUnchecked(path: "/home/example/Downloads/\(i).png", origin: .downloads, reason: reason)
            #expect(row.reason == reason)
        }
        #expect(throws: (any Error).self) {
            try db.run("""
                INSERT INTO unchecked (id, file_path, origin, reason, first_seen, last_seen)
                VALUES ('6F1C2D3E-0000-4000-8000-0000000000B4', '/y.png', 'imported', 'notAReason', '2026-10-27T09:00:00.000Z', '2026-10-27T09:00:00.000Z')
                """)
        }
        #expect(try mode(root.url.appendingPathComponent(SQLiteJournalStore.databaseName)) == 0o600)
    }

    @Test func recordingTheSamePathAgainCountsAnAttemptAndKeepsItsIdentity() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_793_000_000))
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        let path = "/home/example/Downloads/IMG_0412.heic"
        let first = try await store.recordUnchecked(path: path, origin: .downloads, reason: .ocrTimeout)
        #expect(first.attempts == 1 && first.firstSeen == first.lastSeen)
        clock.advance(by: 90)
        let second = try await store.recordUnchecked(path: path, origin: .watched(folder: "/home/example/Downloads"), reason: .renderFailed)
        #expect(second.id == first.id)
        #expect(second.attempts == 2)
        #expect(second.firstSeen == first.firstSeen)
        #expect(second.lastSeen == first.lastSeen.addingTimeInterval(90))
        #expect(second.reason == .renderFailed)
        #expect(second.origin == .watched(folder: "/home/example/Downloads"))
        #expect(try await store.uncheckedFiles().count == 1)
    }

    @Test func listIsNewestFirstAndClearDismissRestoreAct() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_793_000_000))
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        let a = try await store.recordUnchecked(path: "/home/example/Desktop/a.png", origin: .screenshotFolder, reason: .ocrTimeout)
        clock.advance(by: 5)
        let b = try await store.recordUnchecked(path: "/home/example/Desktop/b.png", origin: .imported, reason: .queueFull)
        clock.advance(by: 5)
        let c = try await store.recordUnchecked(path: "/home/example/Projects/c.png", origin: .watched(folder: "/home/example/Projects"),
                                                reason: .catalogueFailed)
        #expect(try await store.uncheckedFiles().map(\.id) == [c.id, b.id, a.id])

        try await store.clearUnchecked(path: b.filePath)
        try await store.clearUnchecked(path: "/home/example/never-listed.png")
        #expect(try await store.uncheckedFiles().map(\.id) == [c.id, a.id])

        try await store.dismissUnchecked(c.id)
        #expect(try await store.uncheckedFiles().map(\.id) == [a.id])
        await #expect(throws: JournalError.uncheckedNotFound(c.id)) { try await store.dismissUnchecked(c.id) }

        try await store.restoreUnchecked(c)
        #expect(try await store.uncheckedFiles() == [c, a], "a dismiss undone puts the row back exactly")
    }

    @Test func everyReasonAndOriginRoundTripsAndUnknownValuesAreRefusedBySQLite() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: ManualClock())
        let origins: [UncheckedOrigin] = [.screenshotFolder, .downloads, .watched(folder: "/home/example/Shots"), .imported]
        for (i, reason) in UncheckedReason.allCases.enumerated() {
            let origin = origins[i % origins.count]
            let record = try await store.recordUnchecked(path: "/home/example/\(reason.rawValue).png", origin: origin, reason: reason)
            #expect(record.reason == reason && record.origin == origin)
        }
        #expect(try await store.uncheckedFiles().count == UncheckedReason.allCases.count)
        let db = try SQLiteConnection(path: root.url.appendingPathComponent(SQLiteJournalStore.databaseName).path)
        #expect(throws: JournalError.self) {
            try db.run("INSERT INTO unchecked (id, file_path, origin, reason, first_seen, last_seen) VALUES ('x', '/p', 'imported', 'notAReason', 't', 't')")
        }
        #expect(throws: JournalError.self, "a watched origin needs its folder") {
            try db.run("INSERT INTO unchecked (id, file_path, origin, reason, first_seen, last_seen) VALUES ('y', '/q', 'watched', 'ocrTimeout', 't', 't')")
        }
    }

    @Test func aStoredDateReadBackAndWrittenAgainIsTheSameString() throws {
        // The fractional ISO format truncates; a parsed ".913" is the Double just below it. Rounding first keeps every
        // round trip exact, which is what makes a restored row equal to the row it was.
        var drift = 0
        for i in 0..<5_000 {
            let date = Date(timeIntervalSince1970: 1_793_000_000 + Double(i) * 0.000_731)
            let once = ISO.string(date)
            if ISO.string(try ISO.date(once)) != once { drift += 1 }
        }
        #expect(drift == 0)
    }

    @Test func deleteAllLeavesTheNotCheckedListAlone() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: ManualClock())
        _ = try await store.create(sample(), original: png, clean: cleanPNG)
        let record = try await store.recordUnchecked(path: "/home/example/Desktop/x.png", origin: .screenshotFolder, reason: .ocrFailed)
        try await store.deleteAll()
        #expect(try await store.entries(matching: .all).isEmpty)
        #expect(try await store.uncheckedFiles() == [record], "Delete All removes catches; a file still to check is not a catch")
    }
}

@Suite struct EntryTests {
    @Test func createWritesFilesAndRows() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let clock = ManualClock()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        let entry = try await store.create(sample(), original: png, clean: cleanPNG)
        #expect(entry.findings.count == 2)
        #expect(entry.revision == 1)
        #expect(entry.style.isDefault)
        #expect(entry.createdAt == clock.now())
        let folder = root.url.appendingPathComponent("Journal.noindex/\(entry.id.uuidString)")
        #expect(try mode(folder) == 0o700)
        #expect(try mode(folder.appendingPathComponent("original.png")) == 0o600)
        #expect(try mode(folder.appendingPathComponent("clean.png")) == 0o600)
        #expect(try await store.originalData(entry.id) == png)
        #expect(try await store.cleanData(entry.id) == cleanPNG)
        #expect(try await store.cleanURL(entry.id).lastPathComponent == "clean.png")
        let db = try SQLiteConnection(path: root.url.appendingPathComponent("obscura.sqlite").path)
        #expect(try db.scalarInt("SELECT count(*) FROM entries") == 1)
        #expect(try db.scalarInt("SELECT count(*) FROM findings") == 2)
        // The store never holds text, nor a hash of it (fail-open #19).
        let columns = try db.query("PRAGMA table_info(findings)", []) { $0.string(1) }
        #expect(!columns.contains("text"))
        #expect(!columns.contains("text_hash"))
    }

    @Test func containerDecidesExtensionAndUnknownIsRefused() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        let jpg = try await store.create(sample("a.jpg", uti: "public.jpeg"), original: png, clean: cleanPNG)
        #expect(try await store.originalURL(jpg.id).pathExtension == "jpg")
        let heic = try await store.create(sample("a.heic", uti: "public.heic"), original: png, clean: cleanPNG)
        #expect(try await store.cleanURL(heic.id).pathExtension == "heic")
        await #expect(throws: JournalError.unsupportedContainer("public.tiff")) {
            _ = try await store.create(sample("a.tif", uti: "public.tiff"), original: png, clean: cleanPNG)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.url.appendingPathComponent(SQLiteJournalStore.journalFolderName).path).count == 2)
    }

    @Test func queryFilters() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let clock = ManualClock()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        let a = try await store.create(sample("alpha.png"), original: png, clean: cleanPNG)
        clock.advance(by: 60)
        let b = try await store.create(sample("Beta.png"), original: png, clean: cleanPNG)
        clock.advance(by: 60)
        let c = try await store.create(sample("gamma_1.png"), original: png, clean: cleanPNG)
        try await store.trash([a.id])

        #expect(try await store.entries(matching: .live).map(\.id) == [c.id, b.id], "newest first, live only")
        #expect(try await store.entries(matching: .trash).map(\.id) == [a.id])
        #expect(try await store.entries(matching: .all).count == 3)
        #expect(try await store.entries(matching: EntryQuery(trashed: nil, search: "beta")).map(\.id) == [b.id], "case-insensitive")
        #expect(try await store.entries(matching: EntryQuery(search: "_")).map(\.id) == [c.id], "underscore is literal")
        #expect(try await store.entries(matching: EntryQuery(trashed: nil, from: b.createdAt)).count == 2)
        #expect(try await store.entries(matching: EntryQuery(trashed: nil, to: b.createdAt)).map(\.id) == [a.id])
        #expect(try await store.entries(matching: EntryQuery(trashed: nil, limit: 1)).map(\.id) == [c.id])
        #expect(try await store.entries(matching: EntryQuery(trashed: nil, limit: 1, offset: 1)).map(\.id) == [b.id])
        let page = try await store.entries(matching: EntryQuery(trashed: nil, limit: 2))
        #expect(page.allSatisfy { $0.findings.count == 2 }, "findings load for every entry in a page")
    }

    /// G-28: the flags, the picture, the style and the revision change together, only through `commitRender`.
    @Test func commitRenderChangesFlagsPictureAndRevisionTogether() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        let entry = try await store.create(sample(), original: png, clean: cleanPNG)
        let first = entry.findings[0], second = entry.findings[1]
        let newer = Data([7, 7, 7])
        let committed = try await store.commitRender(entry.id, clean: newer, enabled: [second.id], style: nil, expectedRevision: 1)
        #expect(committed.revision == 2)
        #expect(committed.findings.first { $0.id == first.id }?.enabled == false)
        #expect(committed.enabledFindings.map(\.id) == [second.id])
        let image = try await store.cleanImage(entry.id)
        #expect(image.data == newer && image.entry == committed)
        #expect(!image.coversEverything)
        #expect(try await store.cleanData(entry.id) == newer)
        #expect(try mode(try await store.cleanURL(entry.id)) == 0o600)
        #expect(try await store.originalData(entry.id) == png, "original is never rewritten")
        await #expect(throws: JournalError.findingNotFound(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)) {
            try await store.commitRender(entry.id, clean: newer, enabled: [UUID(uuidString: "00000000-0000-0000-0000-000000000001")!],
                                         style: nil, expectedRevision: 2)
        }
        #expect(try await store.entry(entry.id) == committed, "a refused change leaves the entry as it was")
    }

    @Test func aStyleChangesOnlyWithItsPicture() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        let entry = try await store.create(sample(), original: png, clean: cleanPNG)
        _ = try await store.commitRender(entry.id, clean: Data([5]), enabled: Set(entry.findings.map(\.id)),
                                     style: StyleRecord(kind: .blur, color: "1,0,0,1", roundness: 0.5, padding: 0.1, labelMode: .kind), expectedRevision: 1)
        let reloaded = try await store.entry(entry.id)
        #expect(reloaded.style.kind == .blur)
        #expect(!reloaded.style.isDefault)
        #expect(try await store.defaultStyle().kind == .solid, "default untouched")

        let other = try await store.create(sample("b.png"), original: png, clean: cleanPNG)
        try await store.setDefaultStyle(StyleRecord(kind: .mosaic, color: "0,0,0,1", roundness: 0, padding: 0.2, labelMode: .redacted))
        let def = try await store.defaultStyle()
        #expect(def.kind == .mosaic && def.isDefault)
        #expect(try await store.entry(other.id).style.kind == .mosaic, "entries on the default follow it")
        #expect(try await store.entry(entry.id).style.kind == .blur, "per-entry style stays")
    }

    @Test func trashRestorePurge() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let clock = ManualClock()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        let entry = try await store.create(sample(), original: png, clean: cleanPNG)
        let live = root.url.appendingPathComponent("Journal.noindex/\(entry.id.uuidString)")
        let trashed = root.url.appendingPathComponent("Journal.noindex/.trash/\(entry.id.uuidString)")

        clock.advance(by: 30)
        try await store.trash([entry.id])
        #expect(!exists(live) && exists(trashed.appendingPathComponent("original.png")))
        let t = try await store.entry(entry.id)
        #expect(t.trashedAt == clock.now())
        #expect(try await store.entries(matching: .live).isEmpty)
        #expect(try await store.originalData(entry.id) == png, "readable from the trash")
        #expect(try mode(root.url.appendingPathComponent("Journal.noindex/.trash")) == 0o700)

        try await store.restore([entry.id])
        #expect(exists(live.appendingPathComponent("clean.png")) && !exists(trashed))
        #expect(try await store.entry(entry.id).trashedAt == nil)

        try await store.trash([entry.id])
        try await store.purgeTrash()
        #expect(!exists(trashed) && !exists(live))
        await #expect(throws: JournalError.entryNotFound(entry.id)) { _ = try await store.entry(entry.id) }
    }

    @Test func trashIsPurgedAtInit() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let id: UUID
        do {
            let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
            id = try await store.create(sample(), original: png, clean: cleanPNG).id
            try await store.trash([id])
        }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        #expect(try await store.entries(matching: .all).isEmpty)
        #expect(!exists(root.url.appendingPathComponent("Journal.noindex/.trash")))
    }

    @Test func pruneExpiredUsesClock() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let clock = ManualClock()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        let old = try await store.create(sample("old.png"), original: png, clean: cleanPNG)
        clock.advance(by: 20 * 3600)
        let fresh = try await store.create(sample("fresh.png"), original: png, clean: cleanPNG)
        let binned = try await store.create(sample("binned.png"), original: png, clean: cleanPNG)
        try await store.trash([binned.id])
        clock.advance(by: 5 * 3600)   // old is 25 h, fresh 5 h

        let removed = try await store.pruneExpired(olderThan: .seconds(24 * 3600))
        #expect(removed == 1)
        let remaining = try await store.entries(matching: .all).map(\.id)
        #expect(remaining == [fresh.id])
        #expect(!exists(root.url.appendingPathComponent("Journal.noindex/\(old.id.uuidString)")))
        #expect(!exists(root.url.appendingPathComponent("Journal.noindex/.trash")), "prune also purges the trash")
        #expect(exists(root.url.appendingPathComponent("Journal.noindex/\(fresh.id.uuidString)/original.png")))
    }

    @Test func sweepStaleRemovesEntriesWithMissingFiles() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        let a = try await store.create(sample("a.png"), original: png, clean: cleanPNG)
        let b = try await store.create(sample("b.png"), original: png, clean: cleanPNG)
        let c = try await store.create(sample("c.png"), original: png, clean: cleanPNG)
        try FileManager.default.removeItem(at: try await store.originalURL(a.id))
        try FileManager.default.removeItem(at: try await store.cleanURL(b.id))
        #expect(try await store.sweepStale() == 2)
        #expect(try await store.entries(matching: .all).map(\.id) == [c.id])
        #expect(!exists(root.url.appendingPathComponent("Journal.noindex/\(a.id.uuidString)")))
        #expect(try await store.sweepStale() == 0)
    }

    @Test func deleteAllEmptiesStoreAndFolder() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        for n in 0..<3 { _ = try await store.create(sample("\(n).png"), original: png, clean: cleanPNG) }
        try await store.trash([try await store.entries(matching: .live)[0].id])
        try await store.deleteAll()
        #expect(try await store.entries(matching: .all).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.url.appendingPathComponent(SQLiteJournalStore.journalFolderName).path).isEmpty)
        #expect(exists(root.url.appendingPathComponent(SQLiteJournalStore.journalFolderName)))
        _ = try await store.create(sample(), original: png, clean: cleanPNG)   // still usable
    }
}

@Suite struct StatsTests {
    @Test func weekStatsZeroFillsLocalDays() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let clock = ManualClock()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        try await store.record(stat: .clean)
        try await store.record(stat: .clean)
        try await store.record(stat: .caught(secrets: 3, categories: ["ai": 2, "cloud": 1]))
        try await store.record(stat: .caught(secrets: 1, categories: ["ai": 1]))
        try await store.record(stat: .skipped(reason: "ocrTimeout"))
        clock.advance(by: 2 * 86_400)
        try await store.record(stat: .clean)

        let week = try await store.weekStats()
        #expect(week.count == 7)
        let cal = Calendar.current
        let today = cal.startOfDay(for: clock.now())
        let expectedKeys = (0..<7).reversed().map { LocalDay.key(cal.date(byAdding: .day, value: -$0, to: today)!) }
        #expect(week.map(\.day) == expectedKeys)
        #expect(week.last?.checked == 1)
        let twoAgo = week[4]
        #expect(twoAgo.checked == 4 && twoAgo.caught == 2 && twoAgo.secrets == 4, "two clean and two caught images are four checked")
        #expect(twoAgo.categories == ["ai": 3, "cloud": 1])
        #expect(twoAgo.skipped == ["ocrTimeout": 1])
        #expect(week[0...3].allSatisfy { $0.checked == 0 && $0.caught == 0 }, "zero-filled")
        #expect(try await store.stats(days: 1).count == 1)
    }

    @Test func statsPruneAfterNinetyDays() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let clock = ManualClock()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        try await store.record(stat: .clean)
        let db = try SQLiteConnection(path: root.url.appendingPathComponent("obscura.sqlite").path)
        #expect(try db.scalarInt("SELECT count(*) FROM stats_days") == 1)
        clock.advance(by: 89 * 86_400)
        try await store.record(stat: .clean)
        #expect(try db.scalarInt("SELECT count(*) FROM stats_days") == 2, "89 days old survives")
        clock.advance(by: 2 * 86_400)
        try await store.record(stat: .clean)
        #expect(try db.scalarInt("SELECT count(*) FROM stats_days") == 2, "91-day-old row pruned on write")
        #expect(try await store.stats(days: 100).count == 100)
    }
}

@Suite struct RulesTests {
    private func rule(_ value: String, order: Int, clock: ManualClock) -> RuleRecord {
        RuleRecord(action: .blackOut, kind: .exactText, value: value, name: "r-\(value)", createdAt: clock.now(), sortOrder: order)
    }

    @Test func rulesCRUDAndReorder() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let clock = ManualClock()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        let a = rule("A", order: 0, clock: clock), b = rule("B", order: 1, clock: clock), c = rule("C", order: 2, clock: clock)
        for r in [a, b, c] { try await store.upsertRule(r) }
        #expect(try await store.rules().map { $0.readable?.value } == ["A", "B", "C"])

        var b2 = b; b2.enabled = false; b2.kind = .prefix; b2.tokenLength = 32
        try await store.upsertRule(b2)
        let stored = try await store.rules()
        #expect(stored.count == 3)
        #expect(stored[1] == .readable(b2))

        try await store.reorderRules([c.id, a.id])
        #expect(try await store.rules().map { $0.readable?.value } == ["C", "A", "B"], "unlisted ids follow")
        try await store.deleteRule(a.id)
        #expect(try await store.rules().map { $0.readable?.value } == ["C", "B"])
        await #expect(throws: JournalError.ruleNotFound(a.id)) { try await store.deleteRule(a.id) }
        await #expect(throws: JournalError.ruleNotFound("custom.nope")) { try await store.reorderRules(["custom.nope"]) }
    }

    @Test func overridesStateAndStyle() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let clock = ManualClock()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        try await store.setOverride("aws.accessKey", specsJSON: #"[{"kind":"prefix","value":"AKIA","token_length":20}]"#)
        var o = try await store.overrides()
        #expect(o.count == 1 && o[0].detectorID == "aws.accessKey" && o[0].updatedAt == clock.now())
        clock.advance(by: 10)
        try await store.setOverride("aws.accessKey", specsJSON: "[]")
        o = try await store.overrides()
        #expect(o[0].specsJSON == "[]" && o[0].updatedAt == clock.now())
        await #expect(throws: JournalError.self) { try await store.setOverride("x", specsJSON: "not json") }
        try await store.clearOverride("aws.accessKey")
        #expect(try await store.overrides().isEmpty)

        try await store.setDetectorEnabled("phone", enabled: false)
        try await store.setDetectorEnabled("iban", enabled: true)
        try await store.setDetectorEnabled("phone", enabled: true)
        #expect(try await store.detectorState() == ["phone": true, "iban": true])

        let def = try await store.defaultStyle()
        #expect(def.sameAppearance(as: .builtInDefault) && def.isDefault && def.id != nil)
    }

    @Test func exportImportRoundTripWithConflict() async throws {
        let rootA = TempRoot(); defer { rootA.cleanup() }
        let rootB = TempRoot(); defer { rootB.cleanup() }
        let clock = ManualClock()
        let a = try SQLiteJournalStore(root: rootA.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        let shared = rule("shared", order: 0, clock: clock)
        let onlyA = rule("onlyA", order: 1, clock: clock)
        try await a.upsertRule(shared)
        try await a.upsertRule(onlyA)
        try await a.setOverride("cloud.aws.accesskey", specsJSON: "[]")
        try await a.setDetectorEnabled("personal.phone.e164", enabled: false)
        try await a.setDefaultStyle(StyleRecord(kind: .erase, color: "1,1,1,1", roundness: 0, padding: 0, labelMode: .none))
        let exported = try await a.exportRules()
        let text = String(decoding: exported, as: UTF8.self)
        #expect(text.contains("\"format_version\"") && text.contains("\"detector_overrides\"") && text.contains("\"sort_order\""))

        let b = try SQLiteJournalStore(root: rootB.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        var conflicting = shared; conflicting.value = "different"
        try await b.upsertRule(conflicting)
        try await b.setDetectorEnabled("personal.phone.e164", enabled: true)

        let report = try await b.importRules(exported)
        #expect(report.rulesAdded == [onlyA.id])
        #expect(report.overridesAdded == ["cloud.aws.accesskey"])
        #expect(report.conflicts.count == 3, "rule, detector state, default style")
        #expect(report.defaultStyleChanged)
        #expect(try await b.rules().compactMap { $0.readable?.value }.sorted() == ["onlyA", "shared"], "incoming won")
        #expect(try await b.detectorState()["personal.phone.e164"] == false)
        #expect(try await b.defaultStyle().kind == .erase)

        // Importing the same document again is a no-op with no conflicts.
        let again = try await b.importRules(exported)
        #expect(again.conflicts.isEmpty && again.rulesAdded.isEmpty && again.rulesUnchanged.count == 2)

        // keepExisting leaves the stored values and still reports.
        let c = try SQLiteJournalStore(root: TempRoot().url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        try await c.upsertRule(conflicting)
        let kept = try await c.importRules(exported, conflicts: .keepExisting)
        #expect(kept.conflicts.count == 2)
        #expect(try await c.rules().first { $0.id == shared.id }?.readable?.value == "different")
        #expect(try await c.defaultStyle().kind == .solid)

        await #expect(throws: JournalError.self) { _ = try await b.importRules(Data("{}".utf8)) }
    }
}

/// G-24: the schema-3 `covered_files` table, migrated from a schema-2 Journal, and its store API.
@Suite struct CoveredFilesStoreTests {
    @Test func migratesASchemaTwoJournalToSchemaThreeWithAnEmptyTable() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        let path = root.url.appendingPathComponent(SQLiteJournalStore.databaseName).path
        do {
            let db = try SQLiteConnection(path: path)
            try db.transaction {
                try db.exec(SQLiteJournalStore.stripPragmas(Migrations.initial001))
                try db.run("INSERT INTO schema_version (version, applied_at) VALUES (1, '2026-10-20T09:00:00Z')")
                try db.exec(Migrations.unchecked002)
                try db.run("INSERT INTO schema_version (version, applied_at) VALUES (2, '2026-10-27T09:00:00Z')")
                try db.run("INSERT INTO styles (id, kind, color_rgba, roundness, padding, label_mode, is_default) VALUES (1, 'solid', '0,0,0,1', 0.07, 0.14, 'none', 1)")
                try db.run("""
                    INSERT INTO rules (id, action, kind, value, enabled, created_at, sort_order)
                    VALUES ('custom.6F1C2D3E-0000-4000-8000-0000000000A1', 'allow', 'exactText', 'EXAMPLE-NOT-A-SECRET', 1, '2026-10-20T09:00:00Z', 0)
                    """)
            }
            db.close()
        }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        let db = try SQLiteConnection(path: path)
        #expect(try db.query("SELECT version FROM schema_version ORDER BY version", []) { $0.int(0) } == Array(1...Migrations.latestVersion))
        #expect(try await store.coveredFiles().isEmpty)
        #expect(try await store.rules().count == 1, "schema-2 data survives")
    }

    @Test func upsertReadsBackDisplacesTheSamePathAndDeletes() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let a = CoveredFileRecord(id: UUID(), filePath: "/home/x/Desktop/a.png", bookmark: Data([1, 2]), detectorIDs: ["ai.anthropic.api_key"],
                                  categories: ["ai"], isScreenshot: true, caughtAt: date, updatedAt: date, tagsWritten: ["Obscura"])
        #expect(try await store.upsertCoveredFile(a).isEmpty)
        #expect(try await store.coveredFile(a.id) == a)
        var changed = a
        changed.covered = false
        changed.tagsWritten = []
        try await store.upsertCoveredFile(changed)
        #expect(try await store.coveredFiles() == [changed])
        let again = CoveredFileRecord(id: UUID(), filePath: a.filePath, bookmark: nil, detectorIDs: [], categories: [], isScreenshot: false,
                                      caughtAt: date, updatedAt: date)
        #expect(try await store.upsertCoveredFile(again) == [a.id], "the same file caught again replaces its record")
        #expect(try await store.coveredFiles() == [again])
        try await store.deleteCoveredFile(again.id)
        #expect(try await store.coveredFiles().isEmpty)
        try await store.deleteCoveredFile(again.id)
    }

    /// The records outlive the entries: retention, the stale sweep and Delete All leave them to the search coordinator.
    @Test func recordsOutliveTheirEntries() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let clock = ManualClock()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore(), clock: clock)
        let e = try await store.create(sample(), original: png, clean: cleanPNG)
        try await store.upsertCoveredFile(CoveredFileRecord(id: e.id, filePath: "/home/x/Desktop/Screenshot.png", bookmark: nil, detectorIDs: [],
                                                            categories: [], isScreenshot: true, caughtAt: clock.now(), updatedAt: clock.now()))
        clock.advance(by: 48 * 3600)
        #expect(try await store.pruneExpired(olderThan: .seconds(3600)) == 1)
        #expect(try await store.coveredFiles().count == 1)
    }
}
