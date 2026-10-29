// Live Text selection → a custom rule. "Always Black Out Things Like This" stores a looks-like-this (example) black-out
// rule; "Never Black Out This" stores an exact-text allow rule. The rule is written through the Journal (the one rule
// store); the engine recompiles its catalogue when the host tells it to (ViewerWindow.onRulesChanged).
// Nothing here logs the selection: it is secret text by definition.
import Foundation
import ObscuraJournal

/// Which of the two context-menu items was chosen.
enum LiveTextRuleIntent: Sendable, Hashable {
    case alwaysBlackOut
    case neverBlackOut

    var action: RuleAction { self == .alwaysBlackOut ? .blackOut : .allow }
    var kind: RuleKind { self == .alwaysBlackOut ? .example : .exactText }
}

/// What adding a rule from a selection did.
enum LiveTextRuleOutcome: Sendable, Hashable {
    case added(RuleRecord)
    /// A rule with the same action, kind and value is already stored.
    case alreadyExists
    /// Fewer than `LiveTextRules.minimumLength` characters after trimming.
    case tooShort
    /// The selection spans lines; the scanner matches within one line, so such a rule could never fire.
    case multipleLines
}

enum LiveTextRules {
    /// The shortest selection that can become a rule (shorter text matches far too much).
    static let minimumLength = 3

    /// The selection trimmed of surrounding whitespace, or the reason it cannot become a rule.
    static func normalized(_ selection: String) -> Result<String, Refusal> {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(where: \.isNewline) { return .failure(.multipleLines) }
        if trimmed.count < minimumLength { return .failure(.tooShort) }
        return .success(trimmed)
    }

    enum Refusal: Error, Sendable, Hashable { case tooShort, multipleLines }

    /// The record a selection becomes, or nil when it cannot become one.
    static func record(for selection: String, intent: LiveTextRuleIntent, sortOrder: Int, now: Date) -> RuleRecord? {
        guard case .success(let value) = normalized(selection) else { return nil }
        return RuleRecord(action: intent.action, kind: intent.kind, value: value, createdAt: now, sortOrder: sortOrder)
    }

    /// Stores the rule (appended after the existing ones) unless an identical one exists.
    static func add(_ selection: String, intent: LiveTextRuleIntent, to journal: any JournalStore, now: Date = Date()) async throws -> LiveTextRuleOutcome {
        let value: String
        switch normalized(selection) {
        case .failure(.tooShort): return .tooShort
        case .failure(.multipleLines): return .multipleLines
        case .success(let v): value = v
        }
        // Unreadable rules (G-30) cannot be compared by value; they still count for the order.
        let existing = try await journal.rules()
        if existing.compactMap(\.readable).contains(where: { $0.action == intent.action && $0.kind == intent.kind && $0.value == value }) {
            return .alreadyExists
        }
        let order = RuleOrder.next(after: existing.map(\.sortOrder))   // F16: never `max + 1` on an order from a file
        let rule = RuleRecord(action: intent.action, kind: intent.kind, value: value, createdAt: now, sortOrder: order)
        try await journal.upsertRule(rule)
        return .added(rule)
    }

    /// The toast for an outcome: the text and whether it reports a problem.
    static func message(for outcome: LiveTextRuleOutcome, intent: LiveTextRuleIntent) -> (text: String, isError: Bool) {
        switch outcome {
        case .added:
            switch intent {
            case .alwaysBlackOut: return (String(localized: "Added to your rules. Text shaped like this will be blacked out."), false)
            case .neverBlackOut: return (String(localized: "Added to your rules. This exact text will stay visible."), false)
            }
        case .alreadyExists: return (String(localized: "You already have a rule for this."), false)
        case .tooShort: return (String(localized: "Select at least \(minimumLength) characters to make a rule."), true)
        case .multipleLines: return (String(localized: "Select text on a single line to make a rule."), true)
        }
    }
}
