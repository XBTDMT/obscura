// G-30: the keys that seal custom rule values in obscura.sqlite. The store asks a `RuleKeyStore` for them; the app and
// the CLI pass the Keychain one, tests and temporary Journals pass an in-memory one, so a test never touches the real
// Keychain. A key is never logged, never exported and never written anywhere but its key store.
//
// F21 (G-34): a key is stored under its own key id (the 8-byte id every sealed value carries), and Obscura seals only
// with a key it generated itself in the running process. A key read back is used only to open values whose id its
// bytes produce. So an item another process put in the Keychain first (a key it knows) can never become the key a
// person's values are sealed with: at most it opens values sealed with it, which only that process could have written.
public import CryptoKit
public import Foundation
import Security
import ObscuraSupport
import Synchronization

/// Where rule keys live. Every call is synchronous and cheap; the Journal caches what it is handed.
public protocol RuleKeyStore: Sendable {
    /// The stored key for `id`, or nil when none is stored under it. The Journal checks that the bytes produce `id`
    /// (`RuleSeal.keyID`) and treats anything else as no key. Throws when the store cannot be asked right now (a locked
    /// keychain, access refused): that is not "no key".
    func key(id: Data) throws -> SymmetricKey?
    /// Stores a key the caller has just generated, under `id`. Never replaces or adopts what is already there: an item
    /// under that id makes this throw.
    func store(_ key: SymmetricKey, id: Data) throws
    /// The ids of every stored key (attributes only where possible). Used to tell "no key at all" from "another key", and
    /// to remove keys no value uses any more.
    func storedKeyIDs() throws -> Set<Data>
    /// Removes the key stored under `id`, if any.
    func removeKey(id: Data) throws
}

public enum RuleKeyStoreError: Error, Sendable, Equatable, LocalizedError {
    /// The Keychain answered with this status.
    case keychain(OSStatus)
    /// The stored item is not a 256-bit key.
    case malformedKey
    /// A key is already stored under this id; it is never adopted.
    case alreadyStored

    public var errorDescription: String? {
        switch self {
        case .keychain(let status): return "The keychain refused the rule key (status \(status))"
        case .malformedKey: return "The stored rule key is not a 256-bit key"
        case .alreadyStored: return "A rule key is already stored under that id"
        }
    }
}

extension RuleKeyStore {
    /// The key a sealed value names, when the key store holds one whose bytes produce that id (G-34); otherwise
    /// `keyMissing` (no key at all), `otherKey` (only others) or `keyUnavailable` (the store cannot be asked).
    func lookup(_ id: Data) -> Result<SymmetricKey, RuleValueProblem> {
        do {
            if let key = try key(id: id), RuleSeal.keyID(key) == id { return .success(key) }
            return .failure(try storedKeyIDs().isEmpty ? .keyMissing : .otherKey)
        } catch {
            return .failure(.keyUnavailable)
        }
    }
}

/// Keys held in memory only: for tests, previews and the CLI's temporary Journals. Nothing persists past the process,
/// which is exactly right for a Journal in a temporary folder. Shared by every store handed the same instance.
public final class InMemoryRuleKeyStore: RuleKeyStore {
    private let state: Mutex<[Data: SymmetricKey]>

    /// `key`: a key to start with (a test that reopens a Journal with "the same Mac's key"); nil starts empty.
    public init(key: SymmetricKey? = nil) {
        var keys: [Data: SymmetricKey] = [:]
        if let key { keys[RuleSeal.keyID(key)] = key }
        state = Mutex(keys)
    }

    public func key(id: Data) throws -> SymmetricKey? { state.withLock { $0[id] } }

    public func store(_ key: SymmetricKey, id: Data) throws {
        try state.withLock { keys in
            guard keys[id] == nil else { throw RuleKeyStoreError.alreadyStored }
            keys[id] = key
        }
    }

    public func storedKeyIDs() throws -> Set<Data> { state.withLock { Set($0.keys) } }

    public func removeKey(id: Data) throws { _ = state.withLock { $0.removeValue(forKey: id) } }
}

/// The real key store: generic-password items in the login keychain, one per key, readable by Obscura only (the default
/// access list trusts the app that created the item), never synchronized. Account `rule-value-key.v2.<id hex>`.
///
/// An item made by schema 8 before G-34 (account `rule-value-key.v1`) is still read, but only to open the values whose
/// id its bytes produce; the next write re-seals those under a new key and removes it.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is set as G-30 rules. On macOS the file-based login keychain
/// records it but only the data-protection keychain enforces it, and that keychain needs a team-signed entitlement a
/// self-signed Obscura cannot carry (G-11); the item is not synchronizable either way. The login keychain is encrypted
/// with the login password, so a backup that holds both obscura.sqlite and the keychain file still needs that password.
public struct KeychainRuleKeyStore: RuleKeyStore {
    public static let service = AppIdentity.current.ruleKeyService
    static let accountPrefix = "rule-value-key.v2."
    /// The single item G-30's first build used.
    static let legacyAccount = "rule-value-key.v1"

    private let service: String

    /// `service`: this identity's by default; `RuleKeyMigration` also opens an earlier identity's (G-38).
    public init(service: String = KeychainRuleKeyStore.service) {
        self.service = service
    }

    static func account(for id: Data) -> String { accountPrefix + id.map { String(format: "%02x", $0) }.joined() }

    static func id(fromAccount account: String) -> Data? {
        guard account.hasPrefix(accountPrefix) else { return nil }
        let hex = Array(account.dropFirst(accountPrefix.count))
        guard hex.count == RuleSeal.keyIDLength * 2 else { return nil }
        var out = Data()
        var i = 0
        while i < hex.count {
            guard let byte = UInt8(String(hex[i...i + 1]), radix: 16) else { return nil }
            out.append(byte)
            i += 2
        }
        return out
    }

    private func query(account: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    private func data(account: String) throws -> SymmetricKey? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else { throw RuleKeyStoreError.malformedKey }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw RuleKeyStoreError.keychain(status)
        }
    }

    public func key(id: Data) throws -> SymmetricKey? {
        if let key = try data(account: Self.account(for: id)) { return key }
        // The schema-8 item: only when its bytes are the key this value was sealed with.
        if let legacy = try data(account: Self.legacyAccount), RuleSeal.keyID(legacy) == id { return legacy }
        return nil
    }

    public func store(_ key: SymmetricKey, id: Data) throws {
        var attributes = query(account: Self.account(for: id))
        attributes[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel as String] = "Obscura rule key"
        attributes[kSecAttrDescription as String] = "Seals the custom rules Obscura keeps in its Journal"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess: return
        case errSecDuplicateItem: throw RuleKeyStoreError.alreadyStored   // never adopted (F21)
        default: throw RuleKeyStoreError.keychain(status)
        }
    }

    public func storedKeyIDs() throws -> Set<Data> {
        var q = query(account: nil)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: return []
        default: throw RuleKeyStoreError.keychain(status)
        }
        let items = result as? [[String: Any]] ?? []
        var ids: Set<Data> = []
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            if let id = Self.id(fromAccount: account) {
                ids.insert(id)
            } else if account == Self.legacyAccount, let legacy = try? data(account: account) {
                ids.insert(RuleSeal.keyID(legacy))
            }
        }
        return ids
    }

    public func removeKey(id: Data) throws {
        try delete(account: Self.account(for: id))
        if let legacy = try? data(account: Self.legacyAccount), RuleSeal.keyID(legacy) == id {
            try delete(account: Self.legacyAccount)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RuleKeyStoreError.keychain(status) }
    }
}
