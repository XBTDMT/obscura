// Security scan 2026-10-28 F4/F5/F7: with the "kind of secret" label style, an unnamed exact-text rule printed the text
// it blacks out on its own cover, because an unnamed rule was titled with its pattern's description (“<value>”, in any
// letter case) and the render path used detector titles as labels. A cover label is now built only from Obscura's own
// words. Every value here is made up.
import CoreGraphics
import Foundation
import Testing
import ObscuraDetect
import ObscuraJournal
import ObscuraOCR
import ObscuraSearch
@testable import ObscuraEngine

@Suite struct CoverLabelTests {
    /// One made-up rule per kind, and a line that rule matches.
    static let cases: [(kind: RuleKind, value: String, tokenLength: Int?, line: String)] = [
        (.exactText, "EXAMPLE-falcon-7731", nil, "the vault word is EXAMPLE-falcon-7731 today"),
        (.prefix, "zqk_", 8, "token zqk_EXAMPLE1234 here"),
        (.label, "Vault phrase", nil, "Vault phrase: EXAMPLEkumquat99"),
        (.example, "ZQ-773100", nil, "ticket ZQ-118822 was filed"),
        (.regex, "zqx[0-9]{6}", nil, "ref zqx123456 end"),
    ]

    static let created = Date(timeIntervalSince1970: 1_793_000_000)

    /// The pre-fix mechanism, kept visible: an exact-text rule's description quotes its value, so a title made from it
    /// carries the secret.
    @Test func anExactTextDescriptionQuotesTheValue() {
        let spec = CatalogueBuilder.patternSpec(kind: .exactText, value: "EXAMPLE-falcon-7731", tokenLength: nil)
        #expect(spec.humanDescription.contains("EXAMPLE-falcon-7731"))
    }

    /// An unnamed rule (no name, or only spaces) is titled with the fixed phrase, never its description.
    @Test func anUnnamedRuleIsNotTitledWithItsPattern() throws {
        for name in [nil, "", "   "] as [String?] {
            let record = RuleRecord(action: .blackOut, kind: .exactText, value: "EXAMPLE-falcon-7731", name: name, createdAt: Self.created, sortOrder: 0)
            let rule = try #require(CatalogueBuilder.customRule(from: record))
            #expect(rule.name == CoverLabels.customRule)
            let title = try #require(rule.asDetector).title
            #expect(title == CoverLabels.customRule)
            #expect(title.range(of: "falcon", options: .caseInsensitive) == nil)
        }
    }

    /// Every rule kind, unnamed or named after its own value: the label placed on its cover is the fixed phrase and holds
    /// neither the rule's value nor the text it matched.
    @Test func noCoverLabelEverCarriesARulesValueOrMatchedText() throws {
        for c in Self.cases {
            for name in [nil, c.value, "my \(c.value) rule"] as [String?] {
                let record = RuleRecord(action: .blackOut, kind: c.kind, value: c.value, tokenLength: c.tokenLength, name: name,
                                        createdAt: Self.created, sortOrder: 0)
                let built = try CatalogueBuilder.build(rules: [.readable(record)], overrides: [], state: [:])
                let titles = CoverLabels.titles(for: built.catalogue)
                let scanner = ObscuraDetect.Scanner(catalogue: built.catalogue)
                let line = OCRLine(index: 0, text: c.line, rect: CGRect(x: 0, y: 0, width: 600, height: 30))
                let findings = scanner.scan([ScanLine(index: 0, text: c.line)]).filter { $0.detectorIDs.contains(record.id) }
                #expect(!findings.isEmpty, "\(c.kind): the rule must match its line")
                let areas = RecallPipeline.place(findings, on: [line], imageSize: CGSize(width: 600, height: 30), titles: titles)
                #expect(!areas.isEmpty)
                for area in areas {
                    #expect(area.label == CoverLabels.customRule, "\(c.kind) name=\(name ?? "nil")")
                    #expect(!area.label.localizedCaseInsensitiveContains(c.value), "\(c.kind) name=\(name ?? "nil")")
                    for finding in findings {
                        let matched = (c.line as NSString).substring(with: finding.secretRange)
                        #expect(!area.label.localizedCaseInsensitiveContains(matched))
                    }
                }
            }
        }
    }

    /// The label-site check holds even for a title map that still carries a rule's own words (the CLI, an old cache).
    @Test func theLabelSiteIgnoresACustomTitleInTheMap() {
        let id = "custom.\(UUID().uuidString)"
        let leaky = [id: "“EXAMPLE-falcon-7731”, in any letter case", "cloud.aws.accesskey": "AWS access key ID"]
        #expect(CoverLabels.label(for: [id], titles: leaky) == CoverLabels.customRule)
        #expect(CoverLabels.label(for: ["cloud.aws.accesskey", id], titles: leaky) == "AWS access key ID")
        #expect(CoverLabels.label(for: ["gone.detector.id"], titles: leaky) == CoverLabels.fallback)
        #expect(CoverLabels.label(for: [], titles: leaky) == CoverLabels.fallback)
        #expect(CoverLabels.customRule == SearchLabels.customRule)
    }

    /// Built-in detectors keep their own titles on covers.
    @Test func builtInsKeepTheirTitles() throws {
        let built = try CatalogueBuilder.build(rules: [], overrides: [], state: [:])
        let titles = CoverLabels.titles(for: built.catalogue)
        for compiled in built.catalogue.detectors { #expect(titles[compiled.detector.id] == compiled.detector.title) }
    }

    /// End to end through the engine: an unnamed exact-text rule catches its text and the cover the engine draws is
    /// labelled with the fixed phrase.
    @Test func theEngineLabelsAnUnnamedRuleWithTheFixedPhrase() async throws {
        let value = "EXAMPLE-falcon-7731"
        let line = OCRLine(index: 0, text: "the vault word is \(value) today", rect: CGRect(x: 20, y: 20, width: 440, height: 28))
        let h = try Harness(recognizer: StubTextRecognizer(lines: [line]))
        defer { h.tearDown() }
        let rule = RuleRecord(action: .blackOut, kind: .exactText, value: value, name: nil, createdAt: Self.created, sortOrder: 0)
        try await h.journal.upsertRule(rule)
        await h.engine.catalogueChanged()
        guard case .redacted(let entryID, _, _) = await h.scan() else { Issue.record("not redacted"); return }
        let entry = try await h.journal.entry(entryID)
        let labels = await h.engine.coverLabels(for: entry)
        #expect(!labels.isEmpty)
        for label in labels {
            #expect(label == CoverLabels.customRule)
            #expect(!label.localizedCaseInsensitiveContains(value))
        }
    }
}
