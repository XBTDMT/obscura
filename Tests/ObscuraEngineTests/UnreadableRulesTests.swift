// G-30: a custom rule whose sealed value cannot be read on this Mac is never compiled and never dropped silently. The
// engine raises one Problem naming how many, protection drops to Partly protected, and the built-in detectors keep
// running. Every key store here lives in memory; no test touches the real Keychain. Every value is made up.
import CoreGraphics
import CryptoKit
import Foundation
import Testing
import ObscuraDetect
@testable import ObscuraJournal
import ObscuraOCR
import ObscuraSupport
@testable import ObscuraEngine

/// A key store that never answers (a locked keychain, access refused).
private struct RefusingKeyStore: RuleKeyStore {
    func key(id: Data) throws -> SymmetricKey? { throw RuleKeyStoreError.keychain(-25308) }
    func store(_ key: SymmetricKey, id: Data) throws { throw RuleKeyStoreError.keychain(-25308) }
    func storedKeyIDs() throws -> Set<Data> { throw RuleKeyStoreError.keychain(-25308) }
    func removeKey(id: Data) throws { throw RuleKeyStoreError.keychain(-25308) }
}

@Suite struct UnreadableRulesTests {
    static let launchCode = "EXAMPLE-kumquat-launch-code-7f3a9c"
    static let lines = [
        Fixture.keyLine,
        OCRLine(index: 1, text: "the launch code is \(launchCode)", rect: CGRect(x: 20, y: 70, width: 440, height: 28)),
    ]
    static let blackOut = RuleRecord(action: .blackOut, kind: .exactText, value: launchCode, name: "Launch code",
                                     createdAt: Date(timeIntervalSince1970: 1_793_000_000), sortOrder: 0)
    static let allow = RuleRecord(action: .allow, kind: .exactText, value: "EXAMPLE-Project-Falcon-a71e",
                                  createdAt: Date(timeIntervalSince1970: 1_793_000_000), sortOrder: 1)

    /// A Journal folder holding the two rules above, sealed with a key that is then thrown away.
    static func rootWithRulesSealedElsewhere() async throws -> URL {
        let root = try Fixture.tempDirectory("journal")
        let store = try SQLiteJournalStore(root: root, ruleKeys: InMemoryRuleKeyStore())
        try await store.upsertRule(blackOut)
        try await store.upsertRule(allow)
        return root
    }

    /// Positive control: with its key the rule covers the launch code next to the built-in catch.
    @Test func withItsKeyTheRuleCovers() async throws {
        let keys = InMemoryRuleKeyStore()
        let h = try Harness(recognizer: StubTextRecognizer(lines: Self.lines), ruleKeys: keys)
        defer { h.tearDown() }
        try await h.journal.upsertRule(Self.blackOut)
        await h.engine.catalogueChanged()
        guard case .redacted(_, let count, _) = await h.scan() else { Issue.record("not redacted"); return }
        #expect(count == 2)
        #expect(!(await h.engine.currentStatus().problems.contains { $0.kind == .ruleCompile }))
    }

    @Test func aMissingKeyIsAProblemAndPartlyProtectedWhileBuiltInsRun() async throws {
        let root = try await Self.rootWithRulesSealedElsewhere()
        let h = try Harness(recognizer: StubTextRecognizer(lines: Self.lines), ruleKeys: InMemoryRuleKeyStore(), root: root)
        defer { h.tearDown() }
        await h.engine.catalogueChanged()

        let status = await h.engine.currentStatus()
        let problem = try #require(status.problems.first { $0.messageKey == CatalogueBuilder.unreadableKey })
        #expect(problem.kind == .ruleCompile)
        #expect(problem.detail == "2", "names how many rules could not be read: the black-out one and the allow one")
        guard case .partlyProtected(let reasons) = status.protection else {
            Issue.record("unreadable rules must lower protection, got \(status.protection)"); return
        }
        #expect(reasons.contains("protection.rulesSkipped"))

        // The built-in catch still happens; the unreadable rule covers nothing (it is not compiled from its bytes).
        guard case .redacted(let entryID, let count, _) = await h.scan() else { Issue.record("built-ins must still run"); return }
        #expect(count == 1)
        #expect(try await h.journal.entry(entryID).findings.map { $0.detectorIDs[0] } == ["payments.stripe.secretkey"])
    }

    @Test func aTamperedValueIsTheSameProblem() async throws {
        let keys = InMemoryRuleKeyStore()
        let h = try Harness(recognizer: StubTextRecognizer(lines: Self.lines), ruleKeys: keys)
        defer { h.tearDown() }
        try await h.journal.upsertRule(Self.blackOut)
        let db = try SQLiteConnection(path: h.root.appendingPathComponent(SQLiteJournalStore.databaseName).path)
        var sealed = try #require(try db.first("SELECT sealed_value FROM rules", []) { $0.data(0) })
        sealed[sealed.count - 1] ^= 0x80
        try db.run("UPDATE rules SET sealed_value = ?", [.blob(sealed)])
        db.close()
        await h.engine.catalogueChanged()

        let status = await h.engine.currentStatus()
        #expect(status.problems.first { $0.messageKey == CatalogueBuilder.unreadableKey }?.detail == "1")
        guard case .partlyProtected = status.protection else { Issue.record("got \(status.protection)"); return }
        guard case .redacted(_, let count, _) = await h.scan() else { Issue.record("built-ins must still run"); return }
        #expect(count == 1)
    }

    @Test func aSilentKeychainIsItsOwnProblemAndHealsOnTheNextBuild() async throws {
        let root = try await Self.rootWithRulesSealedElsewhere()
        let h = try Harness(recognizer: StubTextRecognizer(lines: Self.lines), ruleKeys: RefusingKeyStore(), root: root)
        defer { h.tearDown() }
        await h.engine.catalogueChanged()
        let status = await h.engine.currentStatus()
        #expect(status.problems.first { $0.messageKey == CatalogueBuilder.keychainUnavailableKey }?.detail == "2")
        #expect(!status.problems.contains { $0.messageKey == CatalogueBuilder.unreadableKey })
        guard case .partlyProtected = status.protection else { Issue.record("got \(status.protection)"); return }
        guard case .redacted(_, let count, _) = await h.scan() else { Issue.record("built-ins must still run"); return }
        #expect(count == 1)
    }

    @Test func theBuilderNeverCompilesAnUnreadableRule() throws {
        let unreadable = UnreadableRule(id: "custom." + UUID().uuidString, action: .blackOut, kind: .regex, createdAt: Date(), sortOrder: 0,
                                        problem: .damaged)
        let result = try CatalogueBuilder.build(rules: [.unreadable(unreadable)], overrides: [], state: [:])
        #expect(result.catalogue.detectors.allSatisfy { !$0.detector.id.hasPrefix("custom.") })
        #expect(result.catalogue.allowRules.isEmpty)
        #expect(result.problems.map(\.messageKey) == [CatalogueBuilder.unreadableKey])
    }
}
