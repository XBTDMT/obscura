// G-30: every custom rule's value is sealed at rest with a per-install key the store gets from a `RuleKeyStore`. These
// tests use `CountingKeyStore` (memory only): no test here ever touches the real Keychain. Every value below is made up.
import CryptoKit
import Foundation
import Synchronization
import Testing
import ObscuraSupport
@testable import ObscuraJournal

/// A key store in memory that counts how it is asked, can refuse to answer, and remembers every key it handed out.
/// `reads` counts key lookups, `creates` counts stored keys, `lists` counts id listings.
final class CountingKeyStore: RuleKeyStore {
    private struct State {
        var keys: [Data: SymmetricKey] = [:]
        var latest: SymmetricKey?
        var reads = 0, creates = 0, lists = 0, removes = 0
        var refuses = false
        var handedOut: [SymmetricKey] = []
    }
    private let state: Mutex<State>

    init(key: SymmetricKey? = nil, refuses: Bool = false) {
        var s = State(refuses: refuses)
        if let key { s.keys[RuleSeal.keyID(key)] = key; s.latest = key }
        state = Mutex(s)
    }

    var reads: Int { state.withLock { $0.reads } }
    var creates: Int { state.withLock { $0.creates } }
    var lists: Int { state.withLock { $0.lists } }
    var removes: Int { state.withLock { $0.removes } }
    /// The key stored last.
    var key: SymmetricKey? { state.withLock { $0.latest } }
    var storedCount: Int { state.withLock { $0.keys.count } }
    var handedOut: [SymmetricKey] { state.withLock { $0.handedOut } }
    func setRefuses(_ refuses: Bool) { state.withLock { $0.refuses = refuses } }
    /// Puts `key` under `id` behind the Journal's back, the way another process can add a Keychain item.
    func plant(_ key: SymmetricKey, id: Data) { state.withLock { $0.keys[id] = key } }

    func key(id: Data) throws -> SymmetricKey? {
        try state.withLock { s in
            s.reads += 1
            if s.refuses { throw RuleKeyStoreError.keychain(-25308) }   // errSecInteractionNotAllowed
            if let key = s.keys[id] { s.handedOut.append(key) }
            return s.keys[id]
        }
    }

    func store(_ key: SymmetricKey, id: Data) throws {
        try state.withLock { s in
            s.creates += 1
            if s.refuses { throw RuleKeyStoreError.keychain(-25308) }
            guard s.keys[id] == nil else { throw RuleKeyStoreError.alreadyStored }
            s.keys[id] = key
            s.latest = key
        }
    }

    func storedKeyIDs() throws -> Set<Data> {
        try state.withLock { s in
            s.lists += 1
            if s.refuses { throw RuleKeyStoreError.keychain(-25308) }
            return Set(s.keys.keys)
        }
    }

    func removeKey(id: Data) throws {
        try state.withLock { s in
            if s.refuses { throw RuleKeyStoreError.keychain(-25308) }
            if s.keys.removeValue(forKey: id) != nil { s.removes += 1 }
        }
    }
}

enum RuleFixtures {
    /// Made-up values, distinctive so their bytes can be searched for on disk. None is a real credential.
    static let launchCode = "EXAMPLE-kumquat-launch-code-7f3a9c"
    static let projectName = "EXAMPLE-Project-Falcon-a71e"
    static let prefix = "EXAMPLEtok_"
    static let label = "EXAMPLE Employee Badge"
    static let regex = #"\bEXAMPLE-[0-9]{6}\b"#
    static var needles: [String] { [launchCode, projectName, prefix, label, regex] }

    static let created = Date(timeIntervalSince1970: 1_793_000_000)
    static let rules: [RuleRecord] = [
        RuleRecord(id: "custom.6F1C2D3E-0000-4000-8000-0000000000B1", action: .blackOut, kind: .exactText, value: launchCode,
                   name: "Launch code", createdAt: created, sortOrder: 0),
        RuleRecord(id: "custom.6F1C2D3E-0000-4000-8000-0000000000B2", action: .allow, kind: .exactText, value: projectName,
                   enabled: false, createdAt: created, sortOrder: 1),
        RuleRecord(id: "custom.6F1C2D3E-0000-4000-8000-0000000000B3", action: .blackOut, kind: .prefix, value: prefix, tokenLength: 24,
                   createdAt: created, sortOrder: 2),
        RuleRecord(id: "custom.6F1C2D3E-0000-4000-8000-0000000000B4", action: .blackOut, kind: .label, value: label, createdAt: created, sortOrder: 3),
        RuleRecord(id: "custom.6F1C2D3E-0000-4000-8000-0000000000B5", action: .blackOut, kind: .regex, value: regex, name: "Six digits",
                   createdAt: created, sortOrder: 4),
    ]

    static func databasePath(_ root: URL) -> String { root.appendingPathComponent(SQLiteJournalStore.databaseName).path }

    /// The database, its WAL and its shared-memory index, as one byte string.
    static func onDiskBytes(_ root: URL) -> Data {
        let path = databasePath(root)
        var all = Data()
        for suffix in ["", "-wal", "-shm"] { if let d = FileManager.default.contents(atPath: path + suffix) { all.append(d) } }
        return all
    }

    /// A schema-7 Journal as every Obscura before G-30 wrote it: one entry with findings, and the rules above in plain text.
    static func makeVersionSevenJournal(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try SQLiteConnection(path: databasePath(root))
        try db.transaction {
            for migration in Migrations.all where migration.version <= 7 {
                try db.exec(SQLiteJournalStore.stripPragmas(migration.sql))
                try db.run("INSERT INTO schema_version (version, applied_at) VALUES (?, '2026-10-28T09:00:00Z')", [.integer(Int64(migration.version))])
            }
            try db.run("INSERT INTO styles (id, kind, color_rgba, roundness, padding, label_mode, is_default) VALUES (1, 'solid', '0,0,0,1', 0.07, 0.14, 'none', 1)")
            try db.run("""
                INSERT INTO entries (id, created_at, source, display_name, container_uti, pixel_width, pixel_height, style_id)
                VALUES ('6F1C2D3E-0000-4000-8000-000000000007', '2026-10-28T09:00:00.000Z', 'file', 'Shot.png', 'public.png', 8, 8, 1)
                """)
            for i in 0..<12 {
                try db.run("""
                    INSERT INTO findings (id, entry_id, line_index, rect_x, rect_y, rect_w, rect_h, detector_ids, category, enabled)
                    VALUES (?, '6F1C2D3E-0000-4000-8000-000000000007', ?, 1, 2, 3, 4, '["fake.token"]', 'tokens', 1)
                    """, [.text(UUID().uuidString), .integer(Int64(i))])
            }
            for r in rules {
                try db.run("""
                    INSERT INTO rules (id, action, kind, value, token_length, name, enabled, created_at, sort_order) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.text(r.id), .text(r.action.rawValue), .text(r.kind.rawValue), .text(r.value), SQLValue(r.tokenLength), SQLValue(r.name),
                          SQLValue(r.enabled), .text(ISO.string(r.createdAt)), .integer(Int64(r.sortOrder))])
            }
        }
        db.close()
    }
}

@Suite struct RuleSealingTests {
    @Test func everyKindRoundTripsAndOnlyCiphertextReachesTheFile() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let keys = CountingKeyStore()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: keys)
        for r in RuleFixtures.rules { try await store.upsertRule(r) }
        #expect(try await store.rules() == RuleFixtures.rules.map(StoredRule.readable))

        // The column is a sealed blob in format 1; no value's bytes are anywhere in the file, its WAL or its index.
        let db = try SQLiteConnection(path: RuleFixtures.databasePath(root.url))
        #expect(try db.query("PRAGMA table_info(rules)", []) { $0.string(1) }
                == ["id", "action", "kind", "sealed_value", "token_length", "name", "enabled", "created_at", "sort_order"])
        let blobs = try db.query("SELECT typeof(sealed_value), sealed_value FROM rules", []) { ($0.string(0), $0.data(1)) }
        #expect(blobs.count == RuleFixtures.rules.count)
        #expect(blobs.allSatisfy { $0.0 == "blob" && $0.1.first == RuleSeal.formatVersion && $0.1.count >= RuleSeal.minimumLength })
        db.close()
        let bytes = RuleFixtures.onDiskBytes(root.url)
        for needle in RuleFixtures.needles { #expect(bytes.range(of: Data(needle.utf8)) == nil, "a plain rule value is on disk") }

        // Editing a rule seals the new value; the same value sealed twice never gives the same bytes (fresh nonce).
        var edited = RuleFixtures.rules[0]
        edited.value = "EXAMPLE-new-launch-code-0b2d"
        try await store.upsertRule(edited)
        #expect(try await store.rules().first == .readable(edited))
        let a = try RuleSeal.seal("same", id: "custom.x", action: .blackOut, kind: .exactText, key: try #require(keys.key))
        let b = try RuleSeal.seal("same", id: "custom.x", action: .blackOut, kind: .exactText, key: try #require(keys.key))
        #expect(a != b)
    }

    @Test func theKeyIsCreatedOnceOnFirstNeedAndNeverAskedForWithoutRules() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let keys = CountingKeyStore()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: keys)
        #expect(try await store.rules().isEmpty)
        _ = try await store.exportRules()
        #expect(keys.reads == 0 && keys.creates == 0 && keys.lists == 0, "a Journal without rules never asks the key store")

        try await store.upsertRule(RuleFixtures.rules[0])
        #expect(keys.creates == 1)
        try await store.upsertRule(RuleFixtures.rules[1])
        _ = try await store.rules()
        #expect(keys.creates == 1, "one key per store: the second write seals with the same one")
        let readsBefore = keys.reads
        _ = try await store.rules()
        #expect(keys.reads == readsBefore, "the key is cached once handed over")

        // A second launch that only reads makes no key.
        let reopened = try SQLiteJournalStore(root: root.url, ruleKeys: keys)
        #expect(try await reopened.rules().compactMap(\.readable).count == 2)
        #expect(keys.creates == 1)
    }

    /// The key is written to the key store and nowhere else: not the database, its WAL or index, any other file under
    /// the root, or an export.
    @Test func theKeyNeverLeavesTheKeyStore() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let keys = CountingKeyStore()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: keys)
        for r in RuleFixtures.rules { try await store.upsertRule(r) }
        let export = try await store.exportRules()
        let key = try #require(keys.key)
        let raw = key.withUnsafeBytes { Data($0) }
        let hex = raw.map { String(format: "%02x", $0) }.joined()
        let forms = [raw, Data(raw.base64EncodedString().utf8), Data(hex.utf8), Data(hex.uppercased().utf8)]

        var everything = export
        let files = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL } ?? []
        for file in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            everything.append(try Data(contentsOf: file))
        }
        #expect(!files.isEmpty)
        for form in forms { #expect(everything.range(of: form) == nil, "the key is somewhere outside the key store") }
        #expect(keys.handedOut.allSatisfy { $0 == key }, "one key, the same every time")
    }

    // MARK: Migration and scrub

    @Test func schemaSevenMigratesWithEveryRuleAndFindingIntactAndNoPlainValueLeftOnDisk() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        try RuleFixtures.makeVersionSevenJournal(at: root.url)
        // Positive control: before the migration every value's bytes are in the file.
        let before = RuleFixtures.onDiskBytes(root.url)
        for needle in RuleFixtures.needles { #expect(before.range(of: Data(needle.utf8)) != nil, "the probe finds \(needle.count)-byte value") }

        let keys = CountingKeyStore()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: keys)
        #expect(keys.creates == 1, "the migration made the key, because there were values to seal")
        let db = try SQLiteConnection(path: RuleFixtures.databasePath(root.url))
        #expect(try db.scalarInt("SELECT max(version) FROM schema_version") == Migrations.latestVersion)
        #expect(try !db.query("PRAGMA table_info(rules)", []) { $0.string(1) }.contains("value"))
        db.close()

        let after = RuleFixtures.onDiskBytes(root.url)
        for needle in RuleFixtures.needles {
            #expect(after.range(of: Data(needle.utf8)) == nil, "a plain rule value survived in the file, its WAL or its index")
        }
        // Every rule reads back exactly as it was stored (ids, actions, kinds, values, lengths, names, switches, order).
        #expect(try await store.rules() == RuleFixtures.rules.map(StoredRule.readable))
        let entry = try await store.entry(UUID(uuidString: "6F1C2D3E-0000-4000-8000-000000000007")!)
        #expect(entry.findings.count == 12)
        #expect(entry.findings.allSatisfy { $0.detectorIDs == ["fake.token"] && $0.rect == CGRect(x: 1, y: 2, width: 3, height: 4) })
    }

    /// The key store does not answer at the first launch after the update: the Journal still opens (at schema 7, rows
    /// untouched), every rule reads as unavailable (never as its plain value), a write is refused, and the next read
    /// after the key store answers seals and scrubs.
    @Test func aSilentKeyStoreAtMigrationDefersTheSealButNeverReadsPlainValues() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        try RuleFixtures.makeVersionSevenJournal(at: root.url)
        let keys = CountingKeyStore(refuses: true)
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: keys)
        let db = try SQLiteConnection(path: RuleFixtures.databasePath(root.url))
        #expect(try db.scalarInt("SELECT max(version) FROM schema_version") == 7)
        let waiting = try await store.rules()
        #expect(waiting.count == RuleFixtures.rules.count)
        #expect(waiting.allSatisfy { $0.unreadable?.problem == .keyUnavailable })
        #expect(waiting.map(\.id) == RuleFixtures.rules.map(\.id))
        await #expect(throws: JournalError.ruleKeyUnavailable) { try await store.upsertRule(RuleFixtures.rules[0]) }
        #expect(try await store.entries(matching: .all).count == 1, "the rest of the Journal works meanwhile")

        keys.setRefuses(false)
        #expect(try await store.rules() == RuleFixtures.rules.map(StoredRule.readable))
        #expect(try db.scalarInt("SELECT max(version) FROM schema_version") == Migrations.latestVersion)
        db.close()
        let after = RuleFixtures.onDiskBytes(root.url)
        for needle in RuleFixtures.needles { #expect(after.range(of: Data(needle.utf8)) == nil) }
    }

    // MARK: Fail closed

    @Test func aMissingKeyLeavesEveryRuleListedAsUnreadable() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        do {
            let store = try SQLiteJournalStore(root: root.url, ruleKeys: CountingKeyStore())
            for r in RuleFixtures.rules { try await store.upsertRule(r) }
        }
        // Restored onto another Mac, or the login keychain was reset: no key at all.
        let empty = CountingKeyStore()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: empty)
        let rules = try await store.rules()
        #expect(rules.map(\.id) == RuleFixtures.rules.map(\.id), "listed, in order, none dropped")
        #expect(rules.allSatisfy { $0.unreadable?.problem == .keyMissing && $0.unreadable?.problem.needsReentry == true })
        #expect(empty.creates == 0, "reading never creates a key")
        let first = try #require(rules.first?.unreadable)
        #expect(first.action == .blackOut && first.kind == .exactText && first.name == "Launch code" && first.sortOrder == 0)

        // Re-entering one under its id seals it with this Mac's new key; the others stay unreadable (another key now).
        var again = first.reentryTemplate
        again.value = RuleFixtures.launchCode
        try await store.upsertRule(again)
        let now = try await store.rules()
        #expect(now.first == .readable(again))
        #expect(now.dropFirst().allSatisfy { $0.unreadable?.problem == .otherKey })
        // Reorder and delete need no value.
        try await store.reorderRules([RuleFixtures.rules[4].id])
        #expect(try await store.rules().first?.id == RuleFixtures.rules[4].id)
        try await store.deleteRule(RuleFixtures.rules[4].id)
        #expect(try await store.rules().count == 4)
    }

    @Test func anotherMacsKeyReadsAsOtherKey() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        do {
            let store = try SQLiteJournalStore(root: root.url, ruleKeys: CountingKeyStore())
            try await store.upsertRule(RuleFixtures.rules[0])
        }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: CountingKeyStore(key: SymmetricKey(size: .bits256)))
        #expect(try await store.rules().map(\.unreadable?.problem) == [.otherKey])
    }

    /// A changed byte, a cut-short value, a value moved onto another row, a flipped action and an unknown format each
    /// read as unreadable; none is ever handed out as a value.
    @Test func tamperedValuesFailClosed() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: CountingKeyStore())
        for r in RuleFixtures.rules { try await store.upsertRule(r) }
        let db = try SQLiteConnection(path: RuleFixtures.databasePath(root.url))
        func sealed(_ i: Int) throws -> Data {
            try #require(try db.first("SELECT sealed_value FROM rules WHERE id = ?", [.text(RuleFixtures.rules[i].id)]) { $0.data(0) })
        }
        func put(_ i: Int, _ data: Data) throws {
            try db.run("UPDATE rules SET sealed_value = ? WHERE id = ?", [.blob(data), .text(RuleFixtures.rules[i].id)])
        }
        var flipped = try sealed(0); flipped[flipped.count - 3] ^= 0x01
        try put(0, flipped)
        try put(1, try sealed(1).prefix(RuleSeal.minimumLength - 1))
        try put(2, try sealed(3))                                               // row 3's value moved onto row 2
        try db.run("UPDATE rules SET action = 'allow' WHERE id = ?", [.text(RuleFixtures.rules[3].id)])   // block → allow behind our back
        var future = try sealed(4); future[0] = 2
        try put(4, future)
        db.close()

        let problems = try await store.rules().map(\.unreadable?.problem)
        #expect(problems == [.damaged, .damaged, .damaged, .damaged, .unknownFormat])
    }

    // MARK: Export and import

    /// Export stays plain (the user's explicit act, to a file they choose; how rules move to another Mac) and leaves an
    /// unreadable rule out; importing that file on a Mac where the rules are unreadable restores them, whatever the policy.
    @Test func exportIsPlainAndImportRecoversUnreadableRules() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let first = try SQLiteJournalStore(root: root.url, ruleKeys: CountingKeyStore())
        for r in RuleFixtures.rules { try await first.upsertRule(r) }
        let exported = try await first.exportRules()
        for needle in [RuleFixtures.launchCode, RuleFixtures.projectName] {
            #expect(exported.range(of: Data(needle.utf8)) != nil, "the export holds the value as typed")
        }

        // The same Journal on a Mac without the key (a restore): every rule unreadable, and none exported.
        let restored = try SQLiteJournalStore(root: root.url, ruleKeys: CountingKeyStore())
        let empty = try JSONDecoder.iso.decode(RulesDocument.self, from: try await restored.exportRules())
        #expect(empty.rules.isEmpty)

        let report = try await restored.importRules(exported, conflicts: .keepExisting)
        #expect(report.rulesRecovered == RuleFixtures.rules.map(\.id))
        #expect(report.rulesAdded.isEmpty && report.conflicts.isEmpty)
        #expect(try await restored.rules() == RuleFixtures.rules.map(StoredRule.readable))
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
