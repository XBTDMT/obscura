// Scan F15/F24: an edited detector's pattern list ("Exact text", "Looks like this") can be the secret itself, and
// obscura.sqlite is backed up on purpose (G-23). Schema 9 seals `detector_overrides` with G-30's format and G-34's keys.
// Every key store here lives in memory; no test touches the real Keychain. Every value is made up.
import CryptoKit
import Foundation
import Testing
import ObscuraSupport
@testable import ObscuraJournal

enum OverrideFixtures {
    static let exactSecret = "EXAMPLE-override-exact-9d41c7"
    static let exampleSecret = "EXAMPLEtok_overrideExample4b2e8a17"
    static var needles: [String] { [exactSecret, exampleSecret] }
    static let passwordSpecs = #"[{"kind":"exact_text","value":"\#(exactSecret)"}]"#
    static let tokenSpecs = #"[{"kind":"example","value":"\#(exampleSecret)"}]"#
    /// Real built-in ids (imports accept only that shape, F22), listed in the store's order (by detector id).
    static let overrides = [("config.env.secret", tokenSpecs), ("config.labelled.password", passwordSpecs)]

    /// A schema-8 Journal without rules, with the overrides above in plain text, as Obscura before F15 wrote it.
    static func makeVersionEightJournal(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try SQLiteConnection(path: RuleFixtures.databasePath(root))
        defer { db.close() }
        try db.transaction {
            for migration in Migrations.all where migration.version <= 8 {
                try db.exec(SQLiteJournalStore.stripPragmas(migration.sql))
                if migration.version == 8 { try db.exec(Migrations.sealRuleValues008Finish) }   // no rules to seal
                try db.run("INSERT INTO schema_version (version, applied_at) VALUES (?, '2026-10-28T09:00:00Z')", [.integer(Int64(migration.version))])
            }
            try db.run("INSERT INTO styles (kind, color_rgba, roundness, padding, label_mode, is_default) VALUES ('solid', '0,0,0,1', 0.07, 0.14, 'none', 1)")
            for (id, specs) in overrides {
                try db.run("INSERT INTO detector_overrides (detector_id, specs_json, updated_at) VALUES (?, ?, '2026-10-28T09:00:00.000Z')",
                           [.text(id), .text(specs)])
            }
        }
    }

    static func columns(_ root: URL) throws -> [String] {
        let db = try SQLiteConnection(path: RuleFixtures.databasePath(root), readOnly: true)
        defer { db.close() }
        return try db.query("PRAGMA table_info(detector_overrides)", []) { $0.string(1) }
    }

    static func schema(_ root: URL) throws -> Int {
        let db = try SQLiteConnection(path: RuleFixtures.databasePath(root), readOnly: true)
        defer { db.close() }
        return try db.scalarInt("SELECT max(version) FROM schema_version")
    }
}

@Suite struct OverrideSealingTests {
    @Test func overridesRoundTripAndOnlyCiphertextReachesTheFile() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: CountingKeyStore())
        for (id, specs) in OverrideFixtures.overrides { try await store.setOverride(id, specsJSON: specs) }
        #expect(try await store.overrides().map(\.specsJSON) == OverrideFixtures.overrides.map(\.1))
        #expect(try await store.unreadableOverrides().isEmpty)
        #expect(try OverrideFixtures.columns(root.url) == ["detector_id", "sealed_specs", "updated_at"])
        let bytes = RuleFixtures.onDiskBytes(root.url)
        for needle in OverrideFixtures.needles { #expect(bytes.range(of: Data(needle.utf8)) == nil, "a plain pattern is on disk") }
        // Reset to default removes it.
        try await store.clearOverride("config.labelled.password")
        #expect(try await store.overrides().map(\.detectorID) == ["config.env.secret"])
    }

    /// Schema 7 → 9 in one open: rules and overrides sealed with one new key, every value intact, none left in the file,
    /// its WAL or its index (positive control: all there before).
    @Test func schemaSevenMigratesRulesAndOverridesAndScrubs() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        try RuleFixtures.makeVersionSevenJournal(at: root.url)
        do {
            let db = try SQLiteConnection(path: RuleFixtures.databasePath(root.url))
            for (id, specs) in OverrideFixtures.overrides {
                try db.run("INSERT INTO detector_overrides (detector_id, specs_json, updated_at) VALUES (?, ?, '2026-10-28T09:00:00.000Z')",
                           [.text(id), .text(specs)])
            }
            db.close()
        }
        let before = RuleFixtures.onDiskBytes(root.url)
        for needle in OverrideFixtures.needles + RuleFixtures.needles { #expect(before.range(of: Data(needle.utf8)) != nil) }

        let keys = CountingKeyStore()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: keys)
        #expect(keys.creates == 1, "one key seals both")
        #expect(try OverrideFixtures.schema(root.url) == Migrations.latestVersion, "sealed at 9, then on to the latest (G-40's 10)")
        let after = RuleFixtures.onDiskBytes(root.url)
        for needle in OverrideFixtures.needles + RuleFixtures.needles {
            #expect(after.range(of: Data(needle.utf8)) == nil, "a plain value survived in the file, its WAL or its index")
        }
        #expect(try await store.overrides().map(\.specsJSON) == OverrideFixtures.overrides.map(\.1))
        #expect(try await store.rules() == RuleFixtures.rules.map(StoredRule.readable))
    }

    /// Schema 8 (sealed rules, plain overrides) → 9, with no rules at all.
    @Test func schemaEightMigratesOverridesOnly() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        try OverrideFixtures.makeVersionEightJournal(at: root.url)
        let before = RuleFixtures.onDiskBytes(root.url)
        for needle in OverrideFixtures.needles { #expect(before.range(of: Data(needle.utf8)) != nil) }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: CountingKeyStore())
        #expect(try OverrideFixtures.schema(root.url) == Migrations.latestVersion, "sealed at 9, then on to the latest (G-40's 10)")
        let after = RuleFixtures.onDiskBytes(root.url)
        for needle in OverrideFixtures.needles { #expect(after.range(of: Data(needle.utf8)) == nil) }
        #expect(try await store.overrides().map(\.specsJSON) == OverrideFixtures.overrides.map(\.1))
    }

    /// The key store does not answer at the first launch after the update: the file stays at 8 with its rows untouched,
    /// no plain list is ever handed out (every one reads as unavailable), a change is refused, and the next read after
    /// the key store answers seals and scrubs.
    @Test func aSilentKeyStoreDefersTheSealButNeverReadsPlainPatterns() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        try OverrideFixtures.makeVersionEightJournal(at: root.url)
        let keys = CountingKeyStore(refuses: true)
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: keys)
        #expect(try OverrideFixtures.schema(root.url) == 8)
        #expect(try await store.overrides().isEmpty)
        #expect(try await store.unreadableOverrides().map(\.problem) == [.keyUnavailable, .keyUnavailable])
        await #expect(throws: JournalError.ruleKeyUnavailable) { try await store.setOverride("config.labelled.password", specsJSON: "[]") }

        keys.setRefuses(false)
        #expect(try await store.overrides().map(\.specsJSON) == OverrideFixtures.overrides.map(\.1))
        #expect(try OverrideFixtures.schema(root.url) == Migrations.latestVersion, "sealed at 9, then on to the latest (G-40's 10)")
        let after = RuleFixtures.onDiskBytes(root.url)
        for needle in OverrideFixtures.needles { #expect(after.range(of: Data(needle.utf8)) == nil) }
    }

    /// Another Mac's key, a list moved onto another detector, a flipped byte: each is unreadable, never handed out.
    @Test func unreadableListsFailClosed() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        do {
            let store = try SQLiteJournalStore(root: root.url, ruleKeys: CountingKeyStore())
            for (id, specs) in OverrideFixtures.overrides { try await store.setOverride(id, specsJSON: specs) }
        }
        let other = try SQLiteJournalStore(root: root.url, ruleKeys: CountingKeyStore(key: SymmetricKey(size: .bits256)))
        #expect(try await other.overrides().isEmpty)
        #expect(try await other.unreadableOverrides().map(\.problem) == [.otherKey, .otherKey])
        #expect(try await SQLiteJournalStore(root: root.url, ruleKeys: CountingKeyStore()).unreadableOverrides().map(\.problem)
                == [.keyMissing, .keyMissing])

        let keys = CountingKeyStore()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: keys)
        for (id, specs) in OverrideFixtures.overrides { try await store.setOverride(id, specsJSON: specs) }
        let db = try SQLiteConnection(path: RuleFixtures.databasePath(root.url))
        let blob = try #require(try db.first("SELECT sealed_specs FROM detector_overrides WHERE detector_id = 'config.env.secret'", []) { $0.data(0) })
        try db.run("UPDATE detector_overrides SET sealed_specs = ? WHERE detector_id = 'config.labelled.password'", [.blob(blob)])   // moved
        var flipped = blob; flipped[flipped.count - 2] ^= 0x01
        try db.run("UPDATE detector_overrides SET sealed_specs = ? WHERE detector_id = 'config.env.secret'", [.blob(flipped)])
        db.close()
        #expect(try await store.unreadableOverrides().map(\.problem) == [.damaged, .damaged])
        #expect(try await store.overrides().isEmpty)
    }

    /// Export stays plain (the person's explicit act); importing it where the lists are unreadable restores them.
    @Test func exportIsPlainAndImportRestoresUnreadableLists() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let first = try SQLiteJournalStore(root: root.url, ruleKeys: CountingKeyStore())
        for (id, specs) in OverrideFixtures.overrides { try await first.setOverride(id, specsJSON: specs) }
        let exported = try await first.exportRules()
        for needle in OverrideFixtures.needles { #expect(exported.range(of: Data(needle.utf8)) != nil) }

        let restored = try SQLiteJournalStore(root: root.url, ruleKeys: CountingKeyStore())
        #expect(try await restored.overrides().isEmpty)
        let report = try await restored.importRules(exported, conflicts: .keepExisting)
        #expect(report.overridesAdded == OverrideFixtures.overrides.map(\.0))
        #expect(try await restored.overrides().map(\.specsJSON) == OverrideFixtures.overrides.map(\.1))
        #expect(try await restored.unreadableOverrides().isEmpty)
    }

    /// G-34 applies to overrides too: a key planted first is never sealed with.
    @Test func aPlantedKeyNeverSealsAnOverride() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let planted = SymmetricKey(size: .bits256)
        let keys = CountingKeyStore()
        keys.plant(planted, id: RuleSeal.keyID(planted))
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: keys)
        try await store.setOverride("config.labelled.password", specsJSON: OverrideFixtures.passwordSpecs)
        let db = try SQLiteConnection(path: RuleFixtures.databasePath(root.url), readOnly: true)
        let blob = try #require(try db.first("SELECT sealed_specs FROM detector_overrides", []) { $0.data(0) })
        db.close()
        #expect(OverrideSeal.open(blob, detectorID: "config.labelled.password", keys: RuleSeal.single(planted)) == .failure(.otherKey))
    }
}
