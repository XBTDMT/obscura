// The test footer's engine: one typed line through the real `Scanner` on the catalogue compiled from what is stored,
// read back as a sentence. Nothing is saved and nothing is logged; the line lives only in the field.
import Foundation
import ObscuraDetect

struct LineTestResult: Equatable {
    struct Hit: Equatable {
        let detectorID: String
        let title: String
        let severity: Detector.Severity
        /// The part to black out, in UTF-16 units of the typed line.
        let secretRange: NSRange
        /// 1-based index of the pattern that fired, and how many the detector has.
        let patternNumber: Int?
        let patternCount: Int
    }

    enum Outcome: Equatable {
        case blackedOut([Hit])
        /// Nothing was blacked out because a Never black out rule covers `text`.
        case allowed(text: String)
        case nothing
        /// The line was not searched to the end (too long, or a pattern took too long on it: security scan F23), so it
        /// is not called clean. `hits` are what was found before the stop.
        case notChecked(hits: [Hit])
    }

    let line: String
    let outcome: Outcome

    /// The sentence after the token: "because it is an Anthropic API key".
    var reason: String {
        switch outcome {
        case .blackedOut(let hits) where hits.count == 1:
            return LineTester.becauseItIs(hits[0].title)
        case .blackedOut(let hits):
            var seen = Set<String>()
            let names = LineTester.list(hits.map(\.title).filter { seen.insert($0).inserted })
            return String(localized: "because they are \(names)")
        case .allowed(let text):
            return String(localized: "because “\(text)” is on your Never black out list")
        case .nothing:
            return String(localized: "no detector or rule that is on matches this line")
        case .notChecked:
            return String(localized: "checking this line took too long, so it was stopped — a rule may be too slow, or the line too long")
        }
    }

    /// "· 1 secret, pattern 1 of 2"
    var tail: String? { tail(showingPatternNumber: true) }

    /// The tail with or without "pattern N of M" (G-19 #6: `Settings.showsPatternNumber`, plain-words mode).
    func tail(showingPatternNumber: Bool) -> String? {
        guard case .blackedOut(let hits) = outcome, !hits.isEmpty else { return nil }
        let count = hits.count == 1 ? String(localized: "1 secret") : String(localized: "\(hits.count) secrets")
        if showingPatternNumber, hits.count == 1, let n = hits[0].patternNumber {
            return String(localized: "\(count), pattern \(n) of \(hits[0].patternCount)")
        }
        return count
    }
}

enum LineTester {
    /// The test footer's evaluation, off the main actor (security scan F23): a line or a rule that is slow to search
    /// never holds the window, and a newer keystroke cancels the older evaluation, which then stops its searches.
    @concurrent
    static func evaluateInBackground(_ line: String, catalogue: CompiledCatalogue,
                                     allowRuleMode: ObscuraDetect.AllowRuleMode = .trim) async -> LineTestResult {
        evaluate(line, catalogue: catalogue, allowRuleMode: allowRuleMode)
    }

    static func evaluate(_ line: String, catalogue: CompiledCatalogue, allowRuleMode: ObscuraDetect.AllowRuleMode = .trim,
                         limits: ObscuraDetect.Scanner.Limits = .standard) -> LineTestResult {
        let result = Scanner(catalogue: catalogue, allowRuleMode: allowRuleMode, limits: limits).check([ScanLine(index: 0, text: line)])
        let findings = result.findings
        let folded = ConfusableFold.fold(line)
        let hits = findings.sorted { $0.secretRange.location < $1.secretRange.location }.map { finding -> LineTestResult.Hit in
            let id = finding.detectorIDs.first ?? ""
            let compiled = catalogue.detectors.first { $0.detector.id == id }
            let number = compiled?.matchers.firstIndex { matcher in
                matcher.matches(in: folded).contains { NSIntersectionRange($0.range, finding.range).length > 0 }
            }.map { $0 + 1 }
            return LineTestResult.Hit(detectorID: id, title: compiled?.detector.title ?? id, severity: finding.severity,
                                      secretRange: finding.secretRange, patternNumber: number,
                                      patternCount: compiled?.matchers.count ?? 1)
        }
        guard result.isComplete else { return LineTestResult(line: line, outcome: .notChecked(hits: hits)) }
        if !hits.isEmpty { return LineTestResult(line: line, outcome: .blackedOut(hits)) }
        for allow in catalogue.allowRules {
            if let match = allow.matcher.matches(in: folded).first, let range = Range(match.redactRange, in: line) {
                return LineTestResult(line: line, outcome: .allowed(text: String(line[range])))
            }
        }
        return LineTestResult(line: line, outcome: .nothing)
    }

    /// "because it is an Anthropic API key" / "because it is a GitHub token".
    static func becauseItIs(_ title: String) -> String {
        if startsWithVowelSound(title) { return String(localized: "because it is an \(title)") }
        return String(localized: "because it is a \(title)")
    }

    static func startsWithVowelSound(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        // Initialisms read letter by letter ("an SSH key", "an IBAN", "a US number"): judge by the letter's name.
        let word = s.prefix { $0.isLetter }
        if word.count >= 2, word.allSatisfy(\.isUppercase) {
            return "AEFHILMNORSX".contains(first)
        }
        return "AEIOUaeiou".contains(first)
    }

    static func list(_ items: [String]) -> String {
        ListFormatter.localizedString(byJoining: items)
    }
}
