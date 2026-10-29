// G-38: the rule keys move from an earlier identity's key store to this one's, once, and every rule still opens. Both
// stores are in memory (`CountingKeyStore`); no test touches the real Keychain. Every value is made up.
import CryptoKit
import Foundation
import Testing
import ObscuraSupport
@testable import ObscuraJournal

@Suite struct RuleKeyMigrationTests {
    private static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    /// A Journal whose rules were written under the earlier identity's key store.
    private static func journalWithRules(_ root: URL, keys: any RuleKeyStore) async throws {
        let store = try SQLiteJournalStore(root: root, ruleKeys: keys)
        for r in RuleFixtures.rules { try await store.upsertRule(r) }
    }

    @Test func everyKeyMovesTheOldOnesGoAndEveryRuleStillOpens() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let old = CountingKeyStore(), new = CountingKeyStore()
        try await Self.journalWithRules(root.url, keys: old)
        let oldIDs = try old.storedKeyIDs()
        #expect(!oldIDs.isEmpty)
        let oldBytes = try oldIDs.map { try Self.bytes(#require(try old.key(id: $0))) }

        let outcome = RuleKeyMigration.move(from: old, to: new)
        #expect(outcome == RuleKeyMigration.Outcome(moved: oldIDs.count))
        #expect(outcome.isComplete)
        #expect(try old.storedKeyIDs().isEmpty, "the earlier items are deleted")
        #expect(try new.storedKeyIDs() == oldIDs)
        #expect(try Set(oldIDs.map { try Self.bytes(#require(try new.key(id: $0))) }) == Set(oldBytes), "the same key bytes")

        let reopened = try SQLiteJournalStore(root: root.url, ruleKeys: new)
        #expect(try await reopened.rules() == RuleFixtures.rules.map(StoredRule.readable), "the person loses no rule")
    }

    @Test func runningAgainChangesNothing() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let old = CountingKeyStore(), new = CountingKeyStore()
        try await Self.journalWithRules(root.url, keys: old)
        _ = RuleKeyMigration.move(from: old, to: new)
        let after = try new.storedKeyIDs()
        let creates = new.creates

        #expect(RuleKeyMigration.move(from: old, to: new) == RuleKeyMigration.Outcome())
        #expect(try new.storedKeyIDs() == after)
        #expect(new.creates == creates, "nothing is stored again")
    }

    /// G-34 for the new service: an item planted under one of the moved ids (wrong bytes) is not kept; the migration
    /// stores its own item there, so the person's values open.
    @Test func anItemPlantedUnderAMovedIDIsReplacedByObscurasOwn() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let old = CountingKeyStore(), new = CountingKeyStore()
        try await Self.journalWithRules(root.url, keys: old)
        let id = try #require(try old.storedKeyIDs().first)
        let original = try #require(try old.key(id: id))
        new.plant(SymmetricKey(size: .bits256), id: id)

        #expect(RuleKeyMigration.move(from: old, to: new).moved == 1)
        #expect(Self.bytes(try #require(try new.key(id: id))) == Self.bytes(original))
        let reopened = try SQLiteJournalStore(root: root.url, ruleKeys: new)
        #expect(try await reopened.rules() == RuleFixtures.rules.map(StoredRule.readable))
    }

    /// G-34 for the new service: a key planted there under its own id is never adopted by the migration and never
    /// sealed with by the Journal afterwards.
    @Test func aKeyPlantedUnderTheNewServiceIsStillRefused() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let old = CountingKeyStore(), new = CountingKeyStore()
        try await Self.journalWithRules(root.url, keys: old)
        let planted = SymmetricKey(size: .bits256)
        new.plant(planted, id: RuleSeal.keyID(planted))

        _ = RuleKeyMigration.move(from: old, to: new)
        let store = try SQLiteJournalStore(root: root.url, ruleKeys: new)
        var changed = RuleFixtures.rules[0]
        changed.name = "Launch code (renamed)"
        try await store.upsertRule(changed)

        let db = try SQLiteConnection(path: RuleFixtures.databasePath(root.url), readOnly: true)
        defer { db.close() }
        let blobs = try db.query("SELECT sealed_value FROM rules", []) { $0.data(0) }
        #expect(blobs.count == RuleFixtures.rules.count)
        for blob in blobs {
            #expect((try? RuleSeal.keyID(ofSealed: blob).get()) != RuleSeal.keyID(planted), "a value is sealed with the planted key")
        }
        #expect(!(try new.storedKeyIDs()).contains(RuleSeal.keyID(planted)), "the planted key is retired once no value names it")
    }

    @Test func anItemWhoseBytesAreNotItsIDIsDroppedNotCopied() throws {
        let old = CountingKeyStore(), new = CountingKeyStore()
        let good = SymmetricKey(size: .bits256)
        try old.store(good, id: RuleSeal.keyID(good))
        let wrongID = Data(repeating: 7, count: RuleSeal.keyIDLength)
        old.plant(SymmetricKey(size: .bits256), id: wrongID)

        let outcome = RuleKeyMigration.move(from: old, to: new)
        #expect(outcome == RuleKeyMigration.Outcome(moved: 1, dropped: 1))
        #expect(try new.storedKeyIDs() == [RuleSeal.keyID(good)])
        #expect(try old.storedKeyIDs().isEmpty)
    }

    /// A locked keychain or a refused prompt: nothing moves, nothing is deleted, and the next launch finishes the move.
    @Test func aRefusedReadKeepsTheEarlierKeysForTheNextLaunch() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let old = CountingKeyStore(), new = CountingKeyStore()
        try await Self.journalWithRules(root.url, keys: old)
        let ids = try old.storedKeyIDs()
        old.setRefuses(true)

        let refused = RuleKeyMigration.move(from: old, to: new)
        #expect(!refused.isComplete)
        #expect(try new.storedKeyIDs().isEmpty)
        old.setRefuses(false)
        #expect(try old.storedKeyIDs() == ids, "nothing was deleted")

        #expect(RuleKeyMigration.move(from: old, to: new).isComplete)
        #expect(try new.storedKeyIDs() == ids)
        #expect(try await SQLiteJournalStore(root: root.url, ruleKeys: new).rules() == RuleFixtures.rules.map(StoredRule.readable))
    }

    @Test func aRefusingNewStoreKeepsTheEarlierKeys() async throws {
        let root = TempRoot(); defer { root.cleanup() }
        let old = CountingKeyStore(), new = CountingKeyStore(refuses: true)
        try await Self.journalWithRules(root.url, keys: old)
        let ids = try old.storedKeyIDs()

        let outcome = RuleKeyMigration.move(from: old, to: new)
        #expect(outcome.failed == ids.count)
        #expect(try old.storedKeyIDs() == ids)
    }

    @Test func theKeychainStoreNamesItsServiceFromTheIdentity() {
        #expect(KeychainRuleKeyStore.service == AppIdentity.current.ruleKeyService)
        #expect(KeychainRuleKeyStore.service == "io.github.xbtdmt.obscura.rule-values")
    }
}
