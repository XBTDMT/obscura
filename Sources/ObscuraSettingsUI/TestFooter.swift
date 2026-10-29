// The sticky test footer of the Detectors and Custom Rules panes: one line until used, the material bar, the result
// read as a sentence. The line is view state only: never stored, never logged.
import SwiftUI
import ObscuraUIKit
import ObscuraDetect

struct TestFooter: View {
    var session: SettingsSession
    var allowRuleMode: ObscuraDetect.AllowRuleMode
    /// Whether the result names the pattern that fired ("pattern 1 of 2"): always in regex mode, and in plain words
    /// unless `Settings.showsPatternNumber` is off (G-19 #6).
    var showsPatternNumber = true
    @State private var line = ""
    /// The last finished evaluation of `line` (security scan F23: evaluated off the main actor, see `evaluation`).
    @State private var result: LineTestResult?
    @FocusState private var focused: Bool
    @Environment(\.settingsInitialState) private var initial

    var body: some View {
        StickyBar {
            HStack(spacing: 8) {
                Image(systemName: "flask").font(.system(size: 13)).foregroundStyle(OColor.text2).accessibilityHidden(true)
                TextField(String(localized: "Paste a line to test, e.g. an .env entry"), text: $line)
                    .focused($focused)
                    .fieldChrome(focused: focused, mono: !line.isEmpty)
                    .accessibilityLabel(Text("Test a line"))
                if line.isEmpty {
                    Text("Runs the detectors and rules that are on. Nothing is saved.")
                        .font(.system(size: 11.5)).foregroundStyle(OColor.text3).lineLimit(1).fixedSize()
                } else {
                    Button { line = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(OColor.text3) }
                        .buttonStyle(.plain).accessibilityLabel(Text("Clear the test line"))
                }
            }
            if let result {
                TestResultLine(result: result, showsPatternNumber: showsPatternNumber).padding(.leading, 24).padding(.top, 7)
            }
        }
        .onAppear { if line.isEmpty { line = initial.testLine } }
        .task(id: EvaluationKey(line: line, lists: session.changeCount, allowRuleMode: allowRuleMode)) { await evaluation() }
    }

    /// What an evaluation depends on: the typed line, the stored lists (`changeCount`) and the allow-rule mode.
    private struct EvaluationKey: Equatable {
        let line: String
        let lists: Int
        let allowRuleMode: ObscuraDetect.AllowRuleMode
    }

    /// Evaluates the line off the main actor; a newer key cancels this one, whose result is then dropped.
    private func evaluation() async {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let catalogue = session.compiledCatalogue() else {
            result = nil
            return
        }
        let evaluated = await LineTester.evaluateInBackground(line, catalogue: catalogue, allowRuleMode: allowRuleMode)
        guard !Task.isCancelled else { return }
        result = evaluated
    }
}

/// "ANTHROPIC_API_KEY=████  [Blacked out] because it is an ▮ Anthropic API key · 1 secret, pattern 1 of 2"
struct TestResultLine: View {
    var result: LineTestResult
    var showsPatternNumber = true

    var body: some View {
        FlowLayout(spacing: 6, lineAlignment: .top) {
            Text(maskedLine).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            switch result.outcome {
            case .blackedOut(let hits):
                Token(text: String(localized: "Blacked out"), kind: .blackOut)
                if hits.count == 1, let level = SeverityLevel.from(hits[0].severity) {
                    HStack(spacing: 5) {
                        Text(reasonLead(hits[0]))
                        SeverityMark(level)
                        Text(hits[0].title).fontWeight(.semibold)
                    }
                } else {
                    Text(result.reason)
                }
            case .allowed:
                Token(text: String(localized: "Nothing blacked out"), kind: .allow)
                Text(result.reason)
            case .nothing:
                Token(text: String(localized: "Nothing blacked out"), kind: .value)
                Text(result.reason).foregroundStyle(OColor.text2)
            case .notChecked:
                Token(text: String(localized: "Not checked"), kind: .value)
                Text(result.reason).foregroundStyle(OColor.text2)
            }
            if let tail = result.tail(showingPatternNumber: showsPatternNumber) { Text("· \(tail)").foregroundStyle(OColor.text3) }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(OColor.text1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    /// "because it is an" — the sentence up to the detector name.
    private func reasonLead(_ hit: LineTestResult.Hit) -> String {
        let full = LineTester.becauseItIs(hit.title)
        return full.hasSuffix(hit.title) ? String(full.dropLast(hit.title.count)).trimmingCharacters(in: .whitespaces) : full
    }

    /// The typed line with every blacked-out range drawn as the mark.
    private var maskedLine: AttributedString {
        var text = AttributedString(result.line)
        let hits: [LineTestResult.Hit]
        switch result.outcome {
        case .blackedOut(let found), .notChecked(let found): hits = found
        case .allowed, .nothing: return text
        }
        for hit in hits {
            guard let r = Range(hit.secretRange, in: result.line),
                  let lower = AttributedString.Index(r.lowerBound, within: text),
                  let upper = AttributedString.Index(r.upperBound, within: text) else { continue }
            text[lower..<upper].backgroundColor = OColor.mark
            text[lower..<upper].foregroundColor = OColor.mark
        }
        return text
    }

    private var accessibilityText: String {
        switch result.outcome {
        case .blackedOut:
            return [String(localized: "Blacked out"), result.reason, result.tail(showingPatternNumber: showsPatternNumber) ?? ""].joined(separator: " ")
        case .allowed, .nothing: return String(localized: "Nothing blacked out") + " " + result.reason
        case .notChecked: return String(localized: "Not checked") + " " + result.reason
        }
    }
}

enum SeverityLevel {
    static func from(_ s: Detector.Severity) -> SeverityMark.Level? {
        switch s {
        case .critical: return .critical
        case .high: return .high
        case .medium: return .medium
        case .low: return .low
        }
    }
}
