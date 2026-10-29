// G-38: moving the keys that seal custom rule values (G-30) from an earlier identity's Keychain service to this one's,
// once, so every rule still opens after the bundle identifier changed. Expressed over two `RuleKeyStore`s, so the tests
// run it on in-memory stores and never touch the real Keychain.
//
// G-34 still holds for the new service: the migration never uses an item it finds there. For each key it removes
// whatever the new service holds under that key's id (a planted item, or its own copy from an interrupted run) and
// stores the key itself, so the item is one Obscura created. A key is copied only when its bytes produce the id it is
// stored under (anything else could never open a value, and is dropped). The earlier item is deleted only after the copy
// reads back byte for byte; until then it stays, and the next launch tries again. Sealing is untouched: the Journal still
// seals only with a key it generated in the running process.
import CryptoKit
import Foundation
import ObscuraSupport

public enum RuleKeyMigration {
    public struct Outcome: Sendable, Equatable {
        /// Keys now stored under the new service and gone from the old one.
        public var moved = 0
        /// Items under the old service that were not usable keys (wrong bytes for their id, not 256 bits), removed.
        public var dropped = 0
        /// Keys left under the old service because a step failed (a locked keychain, access refused); retried later.
        public var failed = 0
        /// The old service could not be listed at all.
        public var unreadable = false

        public init(moved: Int = 0, dropped: Int = 0, failed: Int = 0, unreadable: Bool = false) {
            self.moved = moved; self.dropped = dropped; self.failed = failed; self.unreadable = unreadable
        }

        /// Nothing is left to move.
        public var isComplete: Bool { failed == 0 && !unreadable }
    }

    /// Moves every key from `source` (the earlier identity's store) to `destination` (this identity's). Idempotent: with
    /// nothing under the old service it does nothing.
    public static func move(from source: any RuleKeyStore, to destination: any RuleKeyStore) -> Outcome {
        var outcome = Outcome()
        let ids: Set<Data>
        do { ids = try source.storedKeyIDs() } catch {
            Log.journal.error("rule key migration: the earlier keychain service could not be listed")
            outcome.unreadable = true
            return outcome
        }
        for id in ids.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let key: SymmetricKey?
            do { key = try source.key(id: id) } catch RuleKeyStoreError.malformedKey {
                drop(id, from: source, into: &outcome)
                continue
            } catch {
                outcome.failed += 1
                continue
            }
            guard let key else { continue }
            guard RuleSeal.keyID(key) == id else {
                drop(id, from: source, into: &outcome)
                continue
            }
            do {
                try destination.removeKey(id: id)
                try destination.store(key, id: id)
                guard let back = try destination.key(id: id), bytes(back) == bytes(key) else {
                    outcome.failed += 1
                    continue
                }
                try source.removeKey(id: id)
                outcome.moved += 1
            } catch {
                outcome.failed += 1
            }
        }
        Log.journal.info("rule key migration moved=\(outcome.moved) dropped=\(outcome.dropped) failed=\(outcome.failed)")
        return outcome
    }

    private static func drop(_ id: Data, from source: any RuleKeyStore, into outcome: inout Outcome) {
        do {
            try source.removeKey(id: id)
            outcome.dropped += 1
        } catch {
            outcome.failed += 1
        }
    }

    private static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
}
