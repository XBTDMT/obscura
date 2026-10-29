// Security scan 2026-10-28 F23: an imported rules file could install a regular expression that backtracks without end,
// which the scanner and the Settings test footer (on the main thread) then ran with no limit. Every value is made up.
import Foundation
import Testing
@testable import ObscuraSettingsUI
import ObscuraDetect
import ObscuraJournal
import ObscuraUIKit

@MainActor
private func loadedSession() async throws -> SettingsSession {
    let session = SettingsSession(journal: try SampleData.makeJournal())
    await session.load()
    return session
}

private func rulesFile(rules: [RuleRecord], overrides: [OverrideRecord] = []) throws -> Data {
    let document = RulesDocument(exportedAt: Date(timeIntervalSince1970: 1_793_000_000), rules: rules, detectorOverrides: overrides,
                                 detectorState: [:], defaultStyle: .builtInDefault)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(document)
}

@Suite @MainActor struct ImportedRegexTests {
    static let created = Date(timeIntervalSince1970: 1_793_000_000)

    /// The finding's file: a black-out rule `^(\w+\s?)*$` and an edited detector with a nested repeat. Neither runs; the
    /// import notice says how many are not used; the built-in detector keeps its own patterns.
    @Test func aCatastrophicImportedPatternIsNotUsedAndTheNoticeSaysSo() async throws {
        let session = try await loadedSession()
        let bad = RuleRecord(action: .blackOut, kind: .regex, value: #"^(\w+\s?)*$"#, createdAt: Self.created, sortOrder: 0)
        let good = RuleRecord(action: .blackOut, kind: .exactText, value: "EXAMPLE-falcon-7731", createdAt: Self.created, sortOrder: 1)
        let override = OverrideRecord(detectorID: "config.env.secret", specsJSON: #"[{"kind":"regex","pattern":"(a+)+"}]"#, updatedAt: Self.created)
        let report = try await session.importRules(try rulesFile(rules: [bad, good], overrides: [override]))
        #expect(report.rulesAdded.count == 2)
        #expect(session.unusableImports(report) == 2)
        #expect(ImportCopy.summary(report, unusable: 2).contains("2 of them aren’t used"))
        let catalogue = try #require(session.compiledCatalogue())
        #expect(!catalogue.detectors.contains { $0.detector.id == bad.id })
        #expect(catalogue.detectors.contains { $0.detector.id.caseInsensitiveCompare(good.id) == .orderedSame })
        #expect(catalogue.detectors.first { $0.detector.id == "config.env.secret" }?.detector.source == .builtIn)
    }

    /// The test footer with a rule that is slow on the typed line (an exponential shape no static check refuses):
    /// the line is reported "not checked", never clean, within the search budget.
    @Test func aSlowRuleMakesTheTestLineNotChecked() throws {
        let slow = CustomRule(name: "slow", action: .blackOut, pattern: .regex(#"^(?:a|a)*$"#))
        let catalogue = try Catalogue.resolved(rules: [slow])
        let limits = ObscuraDetect.Scanner.Limits(maxLineLength: 4_096, matching: MatchBudget.Limits(searchTime: .milliseconds(50), totalTime: .seconds(30)))
        let started = ContinuousClock.now
        let result = LineTester.evaluate(String(repeating: "a", count: 40) + "!", catalogue: catalogue, limits: limits)
        #expect(ContinuousClock.now - started < .seconds(5))
        guard case .notChecked = result.outcome else { Issue.record("\(result.outcome)"); return }
        #expect(result.reason.contains("too long"))
        #expect(result.tail == nil)
    }

    /// The footer's evaluation runs off the main actor and gives the same answer.
    @Test func theFooterEvaluatesOffTheMainActor() async throws {
        let session = try await loadedSession()
        let catalogue = try #require(session.compiledCatalogue())
        let line = "ANTHROPIC_API_KEY=sk-ant-api03-EXAMPLE000000000000000000"
        let background = await LineTester.evaluateInBackground(line, catalogue: catalogue)
        #expect(background == LineTester.evaluate(line, catalogue: catalogue))
        guard case .blackedOut = background.outcome else { Issue.record("not blacked out"); return }
    }
}
