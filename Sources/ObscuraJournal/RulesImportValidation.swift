// ObscuraJournal — a rules file is untrusted input (security scan 2026-10-28 F16, F22). Every field that reaches the
// store is checked here first; nothing in a file can make Obscura trap, now or on a later read.
import Foundation

/// Where a rule's order may lie. Orders are compared, and the next rule's order is the largest plus one, so a stored
/// order near `Int.max` once made that `+ 1` trap (F16). Every order written is inside this range, and the next order
/// is computed without overflow (`next(after:)`).
public enum RuleOrder {
    public static let range = 0...1_000_000_000

    /// `order` moved into `range`.
    public static func clamped(_ order: Int) -> Int { min(max(order, range.lowerBound), range.upperBound) }

    /// The order a new rule appended after `orders` gets: the largest plus one, inside `range` (at its top, ties are
    /// ordered by creation time, so a new rule still comes last). Never traps, whatever `orders` hold.
    public static func next(after orders: [Int]) -> Int {
        guard let top = orders.max() else { return range.lowerBound }
        return top >= range.upperBound ? range.upperBound : max(top, range.lowerBound - 1) + 1
    }
}

/// A rules document checked field by field before it is stored.
public enum RulesImportValidation {
    /// The longest rule value accepted, in UTF-16 units (a value becomes a pattern; RegexComplexity's limit for a
    /// written regular expression is the same).
    public static let maxValueLength = 1_024
    /// The longest rule name accepted, in UTF-16 units.
    public static let maxNameLength = 256
    /// The token length a prefix rule may ask for.
    public static let tokenLengthRange = 1...1_024

    /// The document with every item that may be stored, and the items refused (each once, with why). Rule ids are
    /// rewritten to their one canonical spelling (`custom.` and the upper-case UUID, as Obscura writes them); orders
    /// are clamped into `RuleOrder.range`; the second and later items with the same canonical id are refused as
    /// duplicates.
    public static func validate(_ document: RulesDocument) -> (document: RulesDocument, rejected: [ImportReport.Rejection]) {
        var rejected: [ImportReport.Rejection] = []
        var out = document

        var seenRules = Set<String>()
        out.rules = document.rules.compactMap { incoming in
            guard let id = canonicalRuleID(incoming.id) else {
                rejected.append(.init(item: .rule, id: incoming.id, reason: .badID)); return nil
            }
            guard seenRules.insert(id).inserted else { rejected.append(.init(item: .rule, id: id, reason: .duplicate)); return nil }
            guard !incoming.value.isEmpty, incoming.value.utf16.count <= maxValueLength else {
                rejected.append(.init(item: .rule, id: id, reason: .valueLength)); return nil
            }
            if let name = incoming.name, name.utf16.count > maxNameLength {
                rejected.append(.init(item: .rule, id: id, reason: .nameLength)); return nil
            }
            if let length = incoming.tokenLength, !tokenLengthRange.contains(length) {
                rejected.append(.init(item: .rule, id: id, reason: .tokenLength)); return nil
            }
            var rule = incoming
            rule.id = id
            rule.sortOrder = RuleOrder.clamped(incoming.sortOrder)
            return rule
        }

        var seenOverrides = Set<String>()
        out.detectorOverrides = document.detectorOverrides.filter { override in
            guard isDetectorID(override.detectorID) else {
                rejected.append(.init(item: .override, id: override.detectorID, reason: .badID)); return false
            }
            guard seenOverrides.insert(override.detectorID).inserted else {
                rejected.append(.init(item: .override, id: override.detectorID, reason: .duplicate)); return false
            }
            return true
        }

        // A JSON object's keys are distinct as bytes but may be canonically equal; Swift's dictionary already merged
        // those on decoding. The ASCII shape check leaves no two keys that SQLite and Swift would compare differently.
        var states: [String: Bool] = [:]
        for (id, enabled) in document.detectorState.sorted(by: { $0.key < $1.key }) {
            guard isDetectorID(id) else { rejected.append(.init(item: .detectorState, id: id, reason: .badID)); continue }
            states[id] = enabled
        }
        out.detectorState = states
        return (out, rejected)
    }

    /// `custom.` and the upper-case UUID, or nil when `id` is not a custom rule id.
    public static func canonicalRuleID(_ id: String) -> String? {
        guard id.hasPrefix("custom."), let uuid = UUID(uuidString: String(id.dropFirst("custom.".count))) else { return nil }
        return "custom." + uuid.uuidString
    }

    /// Whether `id` has the shape of a built-in detector id (`Catalogue.idPattern` in ObscuraDetect,
    /// `^[a-z]+\.[a-z0-9]+\.[a-z0-9]+$`): ASCII only, so two ids that are canonically equal in Swift are always the same
    /// bytes in SQLite (F22).
    public static func isDetectorID(_ id: String) -> Bool {
        let units = Array(id.utf16)
        guard units.count <= 128 else { return false }
        let parts = units.split(separator: 0x2E, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        func lower(_ u: UInt16) -> Bool { (0x61...0x7A).contains(u) }
        func digit(_ u: UInt16) -> Bool { (0x30...0x39).contains(u) }
        return parts.enumerated().allSatisfy { index, part in
            !part.isEmpty && part.allSatisfy { lower($0) || (index > 0 && digit($0)) }
        }
    }
}
