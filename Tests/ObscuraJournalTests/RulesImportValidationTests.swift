// Security scan 2026-10-28 F16 and F22: a rules file is untrusted input. F16: a `sort_order` of Int.max was stored as
// is, and the next rule's order (`max + 1`) trapped. F22: two detector ids that are canonically equal but differ in
// bytes were two SQLite rows and one Swift key, and `Dictionary(uniqueKeysWithValues:)` trapped on every catalogue
// build. Every value here is made up; key stores live in memory.
import Foundation
import Testing
import ObscuraSupport
@testable import ObscuraJournal

@Suite struct RulesImportValidationTests {
    static let created = Date(timeIntervalSince1970: 1_793_000_000)
    static let nfc = "x\u{E9}.a.b"          // "xé.a.b", é as one scalar
    static let nfd = "xe\u{301}.a.b"        // "xé.a.b", e + combining acute

    static func store() throws -> SQLiteJournalStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("obscura-import-\(UUID().uuidString)")
        return try SQLiteJournalStore(root: root, ruleKeys: InMemoryRuleKeyStore())
    }

    /// A rules file; `stateJSON` replaces the detector-state object verbatim (to hold keys Swift would merge).
    static func file(rules: [RuleRecord] = [], overrides: [OverrideRecord] = [], stateJSON: String? = nil) throws -> Data {
        let document = RulesDocument(exportedAt: created, rules: rules, detectorOverrides: overrides,
                                     detectorState: ["placeholder.state.id": true], defaultStyle: .builtInDefault)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var text = String(decoding: try encoder.encode(document), as: UTF8.self)
        if let stateJSON { text = text.replacingOccurrences(of: #"{"placeholder.state.id":true}"#, with: stateJSON) }
        return Data(text.utf8)
    }

    // MARK: F16

    /// The mechanism: the old next order was `max + 1`, which overflows (a trap in Swift) on Int.max.
    @Test func theOldNextOrderOverflowsOnIntMax() {
        #expect(Int.max.addingReportingOverflow(1).overflow)
    }

    @Test func theNextOrderNeverTraps() {
        #expect(RuleOrder.next(after: []) == 0)
        #expect(RuleOrder.next(after: [0, 4, 2]) == 5)
        #expect(RuleOrder.next(after: [Int.max]) == RuleOrder.range.upperBound)
        #expect(RuleOrder.next(after: [Int.min]) == 0)
        #expect(RuleOrder.next(after: [RuleOrder.range.upperBound]) == RuleOrder.range.upperBound)
    }

    /// The finding's file: one rule at Int.max. It is stored inside the range, and a rule added after it (the Live Text
    /// "Always Black Out" path computes the next order the same way) gets an order without trapping.
    @Test func anImportedOrderIsClampedAndTheNextRuleIsAdded() async throws {
        let store = try Self.store()
        let rule = RuleRecord(action: .blackOut, kind: .exactText, value: "EXAMPLE-falcon-7731", createdAt: Self.created, sortOrder: .max)
        let low = RuleRecord(action: .allow, kind: .exactText, value: "EXAMPLE-heron-1122", createdAt: Self.created, sortOrder: .min)
        let report = try await store.importRules(try Self.file(rules: [rule, low]), conflicts: .preferIncoming)
        #expect(report.rulesAdded.count == 2)
        let stored = try await store.rules()
        #expect(Set(stored.map(\.sortOrder)) == [RuleOrder.range.upperBound, RuleOrder.range.lowerBound])
        let next = RuleOrder.next(after: stored.map(\.sortOrder))
        try await store.upsertRule(RuleRecord(action: .blackOut, kind: .exactText, value: "EXAMPLE-ibis-3344", createdAt: Self.created, sortOrder: next))
        #expect(try await store.rules().count == 3)
        #expect(try await store.rules().last?.readable?.value == "EXAMPLE-ibis-3344", "the new rule still comes last")
    }

    // MARK: F22

    /// The finding: two files, one with the composed id and one with the decomposed id. Both ids are refused (not a
    /// detector id's ASCII shape), nothing is stored, and reading the state never traps.
    @Test func canonicallyEqualDetectorIDsAreRefusedAndNeverTrap() async throws {
        let store = try Self.store()
        let first = try await store.importRules(try Self.file(stateJSON: #"{"\#(Self.nfc)":true}"#), conflicts: .preferIncoming)
        let second = try await store.importRules(try Self.file(stateJSON: #"{"\#(Self.nfd)":false}"#), conflicts: .preferIncoming)
        #expect(first.rejected == [.init(item: .detectorState, id: Self.nfc, reason: .badID)])
        #expect(second.rejected.count == 1 && second.rejected.first?.reason == .badID)
        #expect(try await store.detectorState().isEmpty)
        // One file holding both spellings decodes and is refused too.
        let both = try await store.importRules(try Self.file(stateJSON: #"{"\#(Self.nfc)":true,"\#(Self.nfd)":false}"#), conflicts: .preferIncoming)
        #expect(!both.rejected.isEmpty && both.rejected.allSatisfy { $0.reason == .badID })
        #expect(try await store.detectorState().isEmpty)
    }

    /// Rows written before imports were checked (the store API itself takes any id): two canonically equal ids are
    /// merged on read, never trapped on, and the detector is on when they disagree (the side that covers more).
    @Test func storedCanonicallyEqualIDsAreMergedOnRead() async throws {
        let store = try Self.store()
        try await store.setDetectorEnabled(Self.nfc, enabled: false)
        try await store.setDetectorEnabled(Self.nfd, enabled: true)
        let state = try await store.detectorState()
        #expect(state.count == 1)
        #expect(state[Self.nfc] == true)
        // An import over that state still runs (its existing-rule and override maps merge the same way).
        _ = try await store.importRules(try Self.file(stateJSON: #"{"cloud.aws.accesskey":false}"#), conflicts: .preferIncoming)
        #expect(try await store.detectorState()["cloud.aws.accesskey"] == false)
    }

    @Test func ruleIDsAreCanonicalAndDuplicatesAreRefused() async throws {
        let store = try Self.store()
        let uuid = UUID()
        let lower = RuleRecord(id: "custom." + uuid.uuidString.lowercased(), action: .blackOut, kind: .exactText, value: "EXAMPLE-one",
                               createdAt: Self.created, sortOrder: 0)
        let upper = RuleRecord(id: "custom." + uuid.uuidString, action: .blackOut, kind: .exactText, value: "EXAMPLE-two",
                               createdAt: Self.created, sortOrder: 1)
        let bad = RuleRecord(id: "rule-7", action: .blackOut, kind: .exactText, value: "EXAMPLE-three", createdAt: Self.created, sortOrder: 2)
        let long = RuleRecord(action: .blackOut, kind: .exactText, value: String(repeating: "E", count: RulesImportValidation.maxValueLength + 1),
                              createdAt: Self.created, sortOrder: 3)
        let token = RuleRecord(action: .blackOut, kind: .prefix, value: "zq_", tokenLength: .max, createdAt: Self.created, sortOrder: 4)
        let report = try await store.importRules(try Self.file(rules: [lower, upper, bad, long, token]), conflicts: .preferIncoming)
        #expect(report.rulesAdded == ["custom." + uuid.uuidString])
        #expect(Set(report.rejected.map(\.reason)) == [.duplicate, .badID, .valueLength, .tokenLength])
        #expect(!report.rejected.contains { $0.id.contains("EXAMPLE") }, "a rejection never carries a value")
        #expect(try await store.rules().map(\.id) == ["custom." + uuid.uuidString])
        #expect(try await store.rules().first?.readable?.value == "EXAMPLE-one", "the first of the duplicates is kept")
    }

    @Test func overrideIDsMustBeDetectorIDs() async throws {
        let store = try Self.store()
        let good = OverrideRecord(detectorID: "config.env.secret", specsJSON: #"[{"kind":"regex","pattern":"x"}]"#, updatedAt: Self.created)
        let bad = OverrideRecord(detectorID: Self.nfc, specsJSON: "[]", updatedAt: Self.created)
        let report = try await store.importRules(try Self.file(overrides: [good, bad, good]), conflicts: .preferIncoming)
        #expect(report.overridesAdded == ["config.env.secret"])
        #expect(report.rejected.map(\.reason) == [.badID, .duplicate])
    }

    @Test(arguments: ["config.env.secret", "cloud.aws.accesskey", "a.b1.c2"])
    func detectorIDShapesAreAccepted(_ id: String) { #expect(RulesImportValidation.isDetectorID(id)) }

    @Test(arguments: ["", "config.env", "Config.env.secret", "a.b.c.d", "1a.b.c", "a..c", "custom.\(UUID().uuidString)", nfc, nfd, "a.b.c "])
    func otherIDsAreRefused(_ id: String) { #expect(!RulesImportValidation.isDetectorID(id)) }
}
