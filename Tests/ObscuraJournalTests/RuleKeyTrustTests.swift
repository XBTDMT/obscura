// F21 (G-34): a key another process put in the key store first (one it knows) never becomes the key a person's rule
// values are sealed with. Obscura seals only with a key it generated itself, and opens a value only with a key whose
// bytes produce the id the value names. Every key store here lives in memory; no test touches the real Keychain. Every
// value is made up.
import CryptoKit
import Foundation
import Testing
import ObscuraSupport
@testable import ObscuraJournal

@Suite struct RuleKeyTrustTests {
    private static func sealedBlobs(_ root: URL) throws -> [String: Data] {
        let db = try SQLiteConnection(path: RuleFixtures.databasePath(root), readOnly: true)
        defer { db.close() }
        return Dictionary(uniqueKeysWithValues: try db.query("SELECT id, sealed_value FROM rules", []) { ($0.string(0), $0.data(1)) })
    }

    private static func keyID(of blob: Data) -> Data? { try? RuleSeal.keyID(ofSealed: blob).get() }

    /// The key id of the first sealed value in the file.
    private static func firstKeyID(_ root: URL) throws -> Data {
        guard let blob = try sealedBlobs(root).values.first, let id = keyID(of: blob) else {
            throw JournalError.corruptRecord("no sealed value")
        }
        return id
    }

    /// The reported exploit: an item planted before Obscura's first rule (here under the id its bytes give, and so
    /// found by any lookup) is never sealed with, and goes from the key store once nothing uses it.
    @Test func aKeyPlantedBeforeTheFirstRuleIsNeverSealedWith() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let planted = SymmetricKey(size: .bits256)
        let keys = CountingKeyStore()
        keys.plant(planted, id: RuleSeal.keyID(planted))

        let store = try SQLiteJournalStore(root: root.url, ruleKeys: keys)
        for r in RuleFixtures.rules { try await store.upsertRule(r) }
        #expect(try await store.rules() == RuleFixtures.rules.map(StoredRule.readable))

        let blobs = try Self.sealedBlobs(root.url)
        #expect(blobs.count == RuleFixtures.rules.count)
        for (id, blob) in blobs {
            #expect(Self.keyID(of: blob) != RuleSeal.keyID(planted), "rule \(id) is sealed with the planted key")
            let rule = try #require(RuleFixtures.rules.first { $0.id == id })
            let withPlanted = RuleSeal.open(blob, id: rule.id, action: rule.action, kind: rule.kind, keys: RuleSeal.single(planted))
            #expect(withPlanted == .failure(.otherKey), "the planted key opens a sealed value")
        }
        #expect(try keys.storedKeyIDs() == [try Self.firstKeyID(root.url)], "the planted key is retired once no value names it")
    }

    /// A planted key plus a row sealed with it (another process can write obscura.sqlite too): that row opens (it is the
    /// planter's own), but the first write seals everything again with Obscura's own new key, so the person's values
    /// never sit under a key the planter knows.
    @Test func aPlantedKeyWithAPlantedRowStillNeverSealsThePersonsValues() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let planted = SymmetricKey(size: .bits256)
        let keys = CountingKeyStore()
        keys.plant(planted, id: RuleSeal.keyID(planted))
        let plantedRule = RuleFixtures.rules[4]
        do {
            // The planter's row, sealed with the planter's key, written behind Obscura's back.
            let store = try SQLiteJournalStore(root: root.url, ruleKeys: InMemoryRuleKeyStore())
            _ = try await store.rules()
            let db = try SQLiteConnection(path: RuleFixtures.databasePath(root.url))
            let blob = try RuleSeal.seal(plantedRule.value, id: plantedRule.id, action: plantedRule.action, kind: plantedRule.kind, key: planted)
            try db.run("""
                INSERT INTO rules (id, action, kind, sealed_value, token_length, name, enabled, created_at, sort_order)
                VALUES (?, ?, ?, ?, NULL, ?, 1, ?, 4)
                """, [.text(plantedRule.id), .text(plantedRule.action.rawValue), .text(plantedRule.kind.rawValue), .blob(blob),
                      SQLValue(plantedRule.name), .text(ISO.string(plantedRule.createdAt))])
            db.close()
        }
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: keys)
        #expect(try await store.rules() == [.readable(plantedRule)], "positive control: the planted row opens with the planted key")

        try await store.upsertRule(RuleFixtures.rules[0])
        let blobs = try Self.sealedBlobs(root.url)
        let ids = Set(blobs.values.compactMap(Self.keyID(of:)))
        #expect(ids.count == 1 && !ids.contains(RuleSeal.keyID(planted)), "every value is under Obscura's own new key")
        #expect(!(try keys.storedKeyIDs()).contains(RuleSeal.keyID(planted)))
        #expect(try await store.rules().compactMap(\.readable).count == 2)
    }

    /// Bytes put under the id of Obscura's own key (another process replaced the item): they are never used to open a
    /// value (the id they produce differs), and never sealed with; the write is refused instead.
    @Test func otherBytesUnderObscurasIdAreNeverUsed() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let keys = CountingKeyStore()
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: keys)
        try await store.upsertRule(RuleFixtures.rules[0])
        let ownID = try Self.firstKeyID(root.url)
        try keys.removeKey(id: ownID)
        let replacement = SymmetricKey(size: .bits256)
        keys.plant(replacement, id: ownID)

        let reader = try SQLiteJournalStore(root: root.url, ruleKeys: keys)
        #expect(try await reader.rules().map(\.unreadable?.problem) == [.otherKey])
        await #expect(throws: JournalError.ruleKeyUnavailable) { try await store.upsertRule(RuleFixtures.rules[1]) }
        #expect(try Self.sealedBlobs(root.url).count == 1, "nothing was written with the replaced key")
    }

    /// Each launch that writes seals with its own new key and re-seals what it can open; an earlier launch's key is
    /// retired, and a store still running with it stores it again before it writes, so no value is ever left without
    /// its key.
    @Test func eachWritingLaunchSealsWithItsOwnKeyAndNoValueLosesItsKey() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let keys = CountingKeyStore()
        let first = try SQLiteJournalStore(root: root.url, ruleKeys: keys)
        try await first.upsertRule(RuleFixtures.rules[0])
        let firstID = try Self.firstKeyID(root.url)

        let second = try SQLiteJournalStore(root: root.url, ruleKeys: keys)
        try await second.upsertRule(RuleFixtures.rules[1])
        let afterSecond = Set(try Self.sealedBlobs(root.url).values.compactMap(Self.keyID(of:)))
        #expect(afterSecond.count == 1 && !afterSecond.contains(firstID), "the second launch re-sealed the first one's value")
        #expect(!(try keys.storedKeyIDs()).contains(firstID), "the first launch's key was retired")

        // The first store is still running and writes again: its key is stored again first.
        try await first.upsertRule(RuleFixtures.rules[2])
        #expect(try keys.storedKeyIDs().contains(firstID))
        let fresh = try SQLiteJournalStore(root: root.url, ruleKeys: keys)
        #expect(try await fresh.rules().compactMap(\.readable).count == 3, "every value still opens")
    }

    /// The Keychain store's account names: one per key id, the old single item's name never read as an id. Pure
    /// functions; the Keychain itself is never touched.
    @Test func keychainAccountsNameTheKeyID() throws {
        let id = Data([0x00, 0x01, 0xab, 0xcd, 0xef, 0x10, 0x7f, 0xff])
        let account = KeychainRuleKeyStore.account(for: id)
        #expect(account == "rule-value-key.v2.0001abcdef107fff")
        #expect(KeychainRuleKeyStore.id(fromAccount: account) == id)
        #expect(KeychainRuleKeyStore.id(fromAccount: KeychainRuleKeyStore.legacyAccount) == nil)
        #expect(KeychainRuleKeyStore.id(fromAccount: "rule-value-key.v2.0001") == nil)
        #expect(KeychainRuleKeyStore.id(fromAccount: "rule-value-key.v2.zz01abcdef107fff") == nil)
    }
}
