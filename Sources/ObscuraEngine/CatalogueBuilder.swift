// ObscuraEngine — compiles the catalogue once from the Journal's lists (ARCHITECTURE.md §4 rows 9–10,
// DETECTORS.md §1 principle 6). Called at launch and on `catalogueChanged()`, never per image.
import Foundation
public import ObscuraDetect
public import ObscuraJournal
import ObscuraSupport

public enum CatalogueBuilder {
    /// What one build produced: the catalogue the Scanner runs and the problems to surface.
    public struct Result: Sendable {
        public let catalogue: CompiledCatalogue
        public let problems: [Problem]
    }

    /// Rules whose value cannot be read on this Mac and must be typed again (G-30); `detail` is how many.
    public static let unreadableKey = "problem.rule.unreadable"
    /// Rules not read because the key store did not answer; the next build tries again. `detail` is how many.
    public static let keychainUnavailableKey = "problem.rule.keychainUnavailable"

    public static func build(journal: any JournalStore) async throws -> Result {
        let rules = try await journal.rules()
        let overrides = try await journal.overrides()
        let unreadable = try await journal.unreadableOverrides()
        let state = try await journal.detectorState()
        return try build(rules: rules, overrides: overrides, unreadableOverrides: unreadable, state: state)
    }

    /// G-30: a rule whose value cannot be read on this Mac is never compiled (its stored bytes are not a pattern) and
    /// never dropped without a word. Unreadable rules raise one Problem naming how many (`problem.rule.unreadable`, or
    /// `problem.rule.keychainUnavailable` when the key store only did not answer and the next build may read them),
    /// which keeps protection at Partly protected while the built-in detectors and every readable rule keep running.
    /// Both actions count: an unreadable black-out rule covers less than the person asked for (the unsafe direction);
    /// an unreadable never-black-out rule covers more (the safe direction, but still not what they asked for).
    ///
    /// F15: an edited detector whose sealed pattern list cannot be read here runs on its built-in patterns (it is simply
    /// not in `overrides`) and raises the "detector change skipped" Problem with its id, like an undecodable one.
    public static func build(rules: [StoredRule], overrides: [OverrideRecord], unreadableOverrides: [UnreadableOverride] = [],
                             state: [String: Bool]) throws -> Result {
        var problems: [Problem] = []
        for override in unreadableOverrides {
            problems.append(Problem(kind: .ruleCompile, messageKey: "problem.override.undecodable", detail: override.detectorID))
        }
        if !unreadableOverrides.isEmpty { Log.engine.error("detector overrides not in use unreadable=\(unreadableOverrides.count)") }
        var customRules: [CustomRule] = []
        var lost = 0, waiting = 0
        for stored in rules.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            switch stored {
            case .readable(let record):
                if let rule = customRule(from: record) {
                    customRules.append(rule)
                } else {
                    problems.append(Problem(kind: .ruleCompile, messageKey: "problem.rule.badId", detail: record.id))
                }
            case .unreadable(let rule):
                if rule.problem.needsReentry { lost += 1 } else { waiting += 1 }
            }
        }
        if lost > 0 { problems.append(Problem(kind: .ruleCompile, messageKey: unreadableKey, detail: String(lost))) }
        if waiting > 0 { problems.append(Problem(kind: .ruleCompile, messageKey: keychainUnavailableKey, detail: String(waiting))) }
        if lost + waiting > 0 { Log.engine.error("rules not in use unreadable=\(lost) keychainUnavailable=\(waiting)") }
        var specs: [String: [PatternSpec]] = [:]
        for record in overrides {
            do {
                specs[record.detectorID] = try JSONDecoder().decode([PatternSpec].self, from: Data(record.specsJSON.utf8))
            } catch {
                problems.append(Problem(kind: .ruleCompile, messageKey: "problem.override.undecodable", detail: record.detectorID))
            }
        }
        let catalogue: CompiledCatalogue
        do {
            catalogue = try Catalogue.resolved(with: specs, state: state, rules: customRules)
        } catch {
            throw EngineError.catalogue("built-in pattern failed to compile")
        }
        // An edited detector that does not compile runs on its built-in patterns (Catalogue.resolved); its own key, so the
        // words say exactly that and the fix is in Detectors, not Custom Rules.
        for (id, message) in catalogue.overrideErrors.sorted(by: { $0.key < $1.key }) {
            problems.append(Problem(kind: .ruleCompile, messageKey: "problem.override.compile", detail: "\(id): \(message)"))
        }
        for (id, message) in catalogue.compileErrors.sorted(by: { $0.key < $1.key }) {
            problems.append(Problem(kind: .ruleCompile, messageKey: "problem.rule.compile", detail: "\(id): \(message)"))
        }
        Log.engine.info("catalogue compiled detectors=\(catalogue.detectors.count) allow=\(catalogue.allowRules.count) errors=\(catalogue.compileErrors.count) overrideFallbacks=\(catalogue.overrideErrors.count)")
        return Result(catalogue: catalogue, problems: problems)
    }

    /// RuleRecord → CustomRule. The id must be `custom.<UUID>`; anything else is reported, not guessed. An unnamed rule
    /// is named `CoverLabels.customRule`, never its pattern's description: for an exact-text rule that description
    /// quotes the very text the rule blacks out (security scan 2026-10-28 F5), and the name becomes the detector title.
    public static func customRule(from record: RuleRecord) -> CustomRule? {
        guard record.id.hasPrefix("custom."), let uuid = UUID(uuidString: String(record.id.dropFirst("custom.".count))) else { return nil }
        let spec = patternSpec(kind: record.kind, value: record.value, tokenLength: record.tokenLength)
        let action: CustomRule.Action = record.action == .allow ? .allow : .blackOut
        let named = record.name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return CustomRule(id: uuid, name: named ?? CoverLabels.customRule, action: action, pattern: spec,
                          isEnabled: record.enabled, createdAt: record.createdAt)
    }

    /// Journal rule kind/value → PatternSpec. A `regex` rule keeps its source in `pattern`.
    public static func patternSpec(kind: RuleKind, value: String, tokenLength: Int?) -> PatternSpec {
        switch kind {
        case .exactText: return PatternSpec(kind: .exactText, value: value)
        case .prefix: return PatternSpec(kind: .prefix, value: value, tokenLength: tokenLength)
        case .label: return PatternSpec(kind: .label, value: value)
        case .example: return PatternSpec(kind: .example, value: value)
        case .regex: return PatternSpec(kind: .regex, pattern: value)
        }
    }
}
