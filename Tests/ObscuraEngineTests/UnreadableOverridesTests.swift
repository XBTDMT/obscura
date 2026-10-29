// Scan F15/F24: an edited detector whose sealed pattern list cannot be read on this Mac is never compiled from its stored
// bytes and never dropped silently: the detector runs on its built-in patterns and a Problem names it. Every key store
// lives in memory; no test touches the real Keychain. Every value is made up.
import CryptoKit
import Foundation
import Testing
import ObscuraDetect
@testable import ObscuraJournal
import ObscuraSupport
@testable import ObscuraEngine

@Suite struct UnreadableOverridesTests {
    static let specs = #"[{"kind":"exact_text","value":"EXAMPLE-override-exact-9d41c7"}]"#

    @Test func anUnreadableOverrideIsAProblemAndTheDetectorKeepsItsBuiltInPatterns() async throws {
        let detector = try #require(Catalogue.builtIn.first)
        let root = try Fixture.tempDirectory("journal")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            // Sealed with a key that is then thrown away (a restore onto another Mac).
            let store = try SQLiteJournalStore(root: root, ruleKeys: InMemoryRuleKeyStore())
            try await store.setOverride(detector.id, specsJSON: Self.specs)
        }
        let journal = try SQLiteJournalStore(root: root, ruleKeys: InMemoryRuleKeyStore())
        #expect(try await journal.unreadableOverrides().map(\.detectorID) == [detector.id])

        let result = try await CatalogueBuilder.build(journal: journal)
        let problem = try #require(result.problems.first { $0.messageKey == "problem.override.undecodable" })
        #expect(problem.kind == .ruleCompile && problem.detail == detector.id)
        let compiled = try #require(result.catalogue.detectors.first { $0.detector.id == detector.id })
        #expect(compiled.detector.patterns == detector.patterns, "the detector runs on its built-in patterns")
    }

    /// Positive control: with its key the edited list is the one compiled, and no Problem is raised.
    @Test func aReadableOverrideIsCompiled() async throws {
        let detector = try #require(Catalogue.builtIn.first)
        let root = try Fixture.tempDirectory("journal")
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = InMemoryRuleKeyStore()
        let journal = try SQLiteJournalStore(root: root, ruleKeys: keys)
        try await journal.setOverride(detector.id, specsJSON: Self.specs)
        let result = try await CatalogueBuilder.build(journal: journal)
        #expect(!result.problems.contains { $0.messageKey.hasPrefix("problem.override.") })
        let compiled = try #require(result.catalogue.detectors.first { $0.detector.id == detector.id })
        #expect(compiled.detector.patterns != detector.patterns)
    }
}
