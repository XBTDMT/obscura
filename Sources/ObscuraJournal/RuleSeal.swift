// G-30: how a custom rule's value is kept at rest. `rules.sealed_value` holds, per row:
//
//   byte 0        format version (1 = AES-256-GCM as below; any other value is refused, never guessed)
//   bytes 1...8   key id: the first 8 bytes of HMAC-SHA-256(key, "obscura.rule-key-id.v1"), so a value sealed with
//                 another key (another Mac, a reset keychain) is told apart from a damaged one without trying it
//   bytes 9...20  AES-GCM nonce (12 bytes, random per seal)
//   bytes 21...   ciphertext (the value's UTF-8 bytes, same length), then the 16-byte GCM tag
//
// The additional authenticated data binds the value to its row: "obscura.rules.value.v1", the rule id, its action and
// its kind, NUL-separated. A sealed value copied onto another row, or a row whose action was flipped from black-out
// to allow behind Obscura's back, no longer opens: it reads as damaged, never as a different rule.
import CryptoKit
public import Foundation

/// Why a stored rule value could not be read. Every case keeps the rule out of the scan and raises a Problem.
public enum RuleValueProblem: String, Error, Sendable, Hashable, Codable, CaseIterable {
    /// The key store has no key at all (a restore onto another Mac, a reset or replaced login keychain).
    case keyMissing
    /// Sealed with a key this Mac does not hold (another Mac's, or one replaced since).
    case otherKey
    /// The bytes do not open with this Mac's key: changed, cut short, or moved onto another row.
    case damaged
    /// A format version this Obscura does not know (written by a newer one).
    case unknownFormat
    /// The key store could not be asked right now (a locked keychain, access refused). The value itself may be fine;
    /// the next read tries again.
    case keyUnavailable

    /// The value is gone for good on this Mac and must be typed again (or imported from an export). `keyUnavailable`
    /// is the one case that can heal by itself.
    public var needsReentry: Bool { self != .keyUnavailable }
}

enum RuleSeal {
    static let formatVersion: UInt8 = 1
    static let keyIDLength = 8
    static let nonceLength = 12
    static let tagLength = 16
    /// The shortest sealed value: header, nonce and tag around an empty plaintext.
    static let minimumLength = 1 + keyIDLength + nonceLength + tagLength

    /// How the Journal finds the key a sealed value names: the key, or why there is none to open it with.
    typealias KeyLookup = (Data) -> Result<SymmetricKey, RuleValueProblem>

    static func keyID(_ key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("obscura.rule-key-id.v1".utf8), using: key).prefix(keyIDLength))
    }

    static func associatedData(id: String, action: RuleAction, kind: RuleKind) -> Data {
        Data(["obscura.rules.value.v1", id, action.rawValue, kind.rawValue].joined(separator: "\u{0}").utf8)
    }

    /// The same format with any authenticated data: the rule values above, and detector-override patterns (F15, G-30).
    static func seal(_ plaintext: Data, authenticating aad: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(), authenticating: aad)
        guard let combined = box.combined else { throw JournalError.corruptRecord("sealed value has no combined form") }
        var out = Data([formatVersion])
        out.append(keyID(key))
        out.append(combined)
        return out
    }

    static func seal(_ value: String, id: String, action: RuleAction, kind: RuleKind, key: SymmetricKey) throws -> Data {
        try seal(Data(value.utf8), authenticating: associatedData(id: id, action: action, kind: kind), key: key)
    }

    /// The key id a sealed value names, or why it cannot be read at all (a format this Obscura does not know, or too
    /// short to hold one).
    static func keyID(ofSealed sealed: Data) -> Result<Data, RuleValueProblem> {
        let bytes = [UInt8](sealed)
        guard let version = bytes.first else { return .failure(.damaged) }
        guard version == formatVersion else { return .failure(.unknownFormat) }
        guard bytes.count >= minimumLength else { return .failure(.damaged) }
        return .success(Data(bytes[1...keyIDLength]))
    }

    /// The plaintext, or why it cannot be read. The key comes from `keys` by the id the value names. Never returns the
    /// stored bytes: anything that does not open is a problem, not a value.
    static func open(_ sealed: Data, authenticating aad: Data, keys: KeyLookup) -> Result<Data, RuleValueProblem> {
        let storedID: Data
        switch keyID(ofSealed: sealed) {
        case .success(let id): storedID = id
        case .failure(let problem): return .failure(problem)
        }
        let key: SymmetricKey
        switch keys(storedID) {
        case .success(let k): key = k
        case .failure(let problem): return .failure(problem)
        }
        guard storedID == keyID(key) else { return .failure(.otherKey) }
        do {
            let box = try AES.GCM.SealedBox(combined: Data([UInt8](sealed)[(1 + keyIDLength)...]))
            return .success(try AES.GCM.open(box, using: key, authenticating: aad))
        } catch {
            return .failure(.damaged)
        }
    }

    static func open(_ sealed: Data, id: String, action: RuleAction, kind: RuleKind, keys: KeyLookup) -> Result<String, RuleValueProblem> {
        switch open(sealed, authenticating: associatedData(id: id, action: action, kind: kind), keys: keys) {
        case .success(let plain):
            guard let value = String(data: plain, encoding: .utf8) else { return .failure(.damaged) }
            return .success(value)
        case .failure(let problem):
            return .failure(problem)
        }
    }

    /// One key, or none (`keyMissing`): for a caller that already holds the only key that matters.
    static func single(_ key: SymmetricKey?) -> KeyLookup {
        { id in
            guard let key else { return .failure(.keyMissing) }
            return keyID(key) == id ? .success(key) : .failure(.otherKey)
        }
    }
}

/// A stored rule whose value could not be read on this Mac. Everything but the value is known, so the rule can be
/// listed, re-entered under the same id, or deleted; it is never compiled.
public struct UnreadableRule: Sendable, Hashable, Identifiable {
    public var id: String
    public var action: RuleAction
    public var kind: RuleKind
    public var tokenLength: Int?
    public var name: String?
    public var enabled: Bool
    public var createdAt: Date
    public var sortOrder: Int
    public var problem: RuleValueProblem

    public init(id: String, action: RuleAction, kind: RuleKind, tokenLength: Int? = nil, name: String? = nil, enabled: Bool = true,
                createdAt: Date, sortOrder: Int, problem: RuleValueProblem) {
        self.id = id; self.action = action; self.kind = kind; self.tokenLength = tokenLength; self.name = name
        self.enabled = enabled; self.createdAt = createdAt; self.sortOrder = sortOrder; self.problem = problem
    }

    /// The rule to start re-entering it from: the same id, action, kind, name, order and switch, with an empty value.
    /// Saving it replaces the unreadable row.
    public var reentryTemplate: RuleRecord {
        RuleRecord(id: id, action: action, kind: kind, value: "", tokenLength: tokenLength, name: name, enabled: enabled,
                   createdAt: createdAt, sortOrder: sortOrder)
    }
}

/// One row of the rules table as read on this Mac: its value opened, or the reason it did not (G-30). A caller has to
/// handle both, so an unreadable rule can never be dropped without a word or compiled from something that is not its
/// value.
public enum StoredRule: Sendable, Hashable, Identifiable {
    case readable(RuleRecord)
    case unreadable(UnreadableRule)

    public var id: String {
        switch self {
        case .readable(let r): return r.id
        case .unreadable(let u): return u.id
        }
    }

    public var action: RuleAction {
        switch self {
        case .readable(let r): return r.action
        case .unreadable(let u): return u.action
        }
    }

    public var sortOrder: Int {
        switch self {
        case .readable(let r): return r.sortOrder
        case .unreadable(let u): return u.sortOrder
        }
    }

    public var readable: RuleRecord? { if case .readable(let r) = self { return r } else { return nil } }
    public var unreadable: UnreadableRule? { if case .unreadable(let u) = self { return u } else { return nil } }
}

/// Scan F15/F24: an edited detector's pattern list (`detector_overrides.sealed_specs`, schema 9) in the same format and
/// with the same keys as rule values. The authenticated data binds it to its detector: "obscura.detector-overrides.specs.v1"
/// and the detector id, NUL-separated, so a list moved onto another detector reads as damaged.
enum OverrideSeal {
    static func associatedData(detectorID: String) -> Data {
        Data(["obscura.detector-overrides.specs.v1", detectorID].joined(separator: "\u{0}").utf8)
    }

    static func seal(_ specsJSON: String, detectorID: String, key: SymmetricKey) throws -> Data {
        try RuleSeal.seal(Data(specsJSON.utf8), authenticating: associatedData(detectorID: detectorID), key: key)
    }

    static func open(_ sealed: Data, detectorID: String, keys: RuleSeal.KeyLookup) -> Result<String, RuleValueProblem> {
        switch RuleSeal.open(sealed, authenticating: associatedData(detectorID: detectorID), keys: keys) {
        case .success(let plain):
            guard let json = String(data: plain, encoding: .utf8) else { return .failure(.damaged) }
            return .success(json)
        case .failure(let problem):
            return .failure(problem)
        }
    }
}

/// An edited detector whose sealed pattern list could not be read on this Mac (F15). The detector runs on its built-in
/// patterns and a Problem says so; re-editing it in Detectors, or importing a rules file, replaces it.
public struct UnreadableOverride: Sendable, Hashable, Identifiable {
    public var detectorID: String
    public var updatedAt: Date
    public var problem: RuleValueProblem
    public var id: String { detectorID }

    public init(detectorID: String, updatedAt: Date, problem: RuleValueProblem) {
        self.detectorID = detectorID; self.updatedAt = updatedAt; self.problem = problem
    }
}
