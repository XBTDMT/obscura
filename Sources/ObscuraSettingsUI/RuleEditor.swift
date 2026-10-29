// Add Rule as a sentence (`.ruleed`): [Black out | Never black out] · a kind popup that reads as the sentence tail ·
// the value; under it the live preview "Things like “CUS-004213” will be blacked out" with the plain-word description
// (and the regex in Regular expressions mode), the validations, the name and the phone/space note.
import SwiftUI
import ObscuraUIKit
import ObscuraDetect
import ObscuraEngine
import ObscuraJournal

struct RuleDraft: Equatable {
    /// The rule being edited; nil for a new one.
    var original: RuleRecord?
    var action: RuleAction
    var kind: PatternSpec.Kind
    var value: String
    var name: String
    var tokenLength: Int?
    var touched = false
    /// A plain-word rule edited as a regex in Regular expressions mode; it is stored as a regex rule on save.
    var converted = false
    /// Re-entering an unreadable rule (G-30): there is no stored value to show as a regex, so the value starts empty.
    var reentering = false

    init(action: RuleAction) {
        self.action = action; kind = .example; value = ""; name = ""
    }

    /// Re-entering a rule whose value can't be read on this Mac (G-30): its action, kind, name and order, an empty value;
    /// saving stores it under the same id, which replaces the unreadable one.
    init(reentering rule: UnreadableRule) {
        self.init(rule: rule.reentryTemplate)
        reentering = true
    }

    init(rule: RuleRecord) {
        original = rule
        action = rule.action
        kind = KindCopy.patternKind(rule.kind)
        value = rule.value
        name = rule.name ?? ""
        tokenLength = rule.tokenLength
    }

    var spec: PatternSpec { CatalogueBuilder.patternSpec(kind: KindCopy.ruleKind(kind), value: value, tokenLength: tokenLength) }
    var result: Result<String, PatternError> { PatternCopy.compile(spec) }
    var isValid: Bool { if case .success = result { return true } else { return false } }

    func record(sortOrder: Int, now: Date = Date()) -> RuleRecord {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = kind == .regex ? value : value.trimmingCharacters(in: .whitespacesAndNewlines)
        if var rule = original {
            rule.action = action
            rule.kind = KindCopy.ruleKind(kind)
            rule.value = trimmedValue
            rule.tokenLength = kind == .prefix ? tokenLength : nil
            rule.name = trimmedName.isEmpty ? nil : trimmedName
            return rule
        }
        return RuleRecord(action: action, kind: KindCopy.ruleKind(kind), value: trimmedValue,
                          tokenLength: kind == .prefix ? tokenLength : nil,
                          name: trimmedName.isEmpty ? nil : trimmedName, createdAt: now, sortOrder: sortOrder)
    }
}

struct RuleEditor: View {
    @Binding var draft: RuleDraft
    let session: SettingsSession
    var regexMode: Bool
    var cancel: () -> Void
    var save: (RuleRecord) -> Void
    var delete: (String) -> Void
    @FocusState private var focus: Field?

    enum Field { case value, name }

    /// In Regular expressions mode an existing plain-word rule is edited as its regex; typing converts it.
    private var editsAsRegex: Bool { regexMode && draft.original != nil && !draft.reentering }
    private var origin: RuleRecord? {
        guard editsAsRegex, let o = draft.original, o.kind != .regex else { return nil }
        return o
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowLayout(spacing: 8, lineAlignment: .top) {
                Picker(String(localized: "Action"), selection: $draft.action) {
                    Text("Black out").tag(RuleAction.blackOut)
                    Text("Never black out").tag(RuleAction.allow)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                if editsAsRegex {
                    Text(KindCopy.sentenceTail(.regex)).font(.system(size: 13.5)).foregroundStyle(OColor.text1).padding(.top, 3)
                } else {
                    KindMenu(kind: Binding(get: { draft.kind }, set: { changeKind($0) }), label: KindCopy.sentenceTail(draft.kind))
                        .frame(minWidth: 168)
                }
                TextField(KindCopy.placeholder(editsAsRegex ? .regex : draft.kind), text: valueBinding)
                    .focused($focus, equals: .value)
                    .fieldChrome(focused: focus == .value, invalid: errorText != nil, mono: editsAsRegex || draft.kind == .regex)
                    .frame(minWidth: 170, maxWidth: 260)
                    .onSubmit(commit)
                    .accessibilityLabel(Text(KindCopy.fieldLabel(editsAsRegex ? .regex : draft.kind)))
            }
            if let errorText { InlineError(text: errorText).padding(.top, 6) }
            if let origin {
                HStack(spacing: 6) {
                    Badge(String(localized: "from \(KindCopy.title(KindCopy.patternKind(origin.kind))) “\(origin.value)”"), tone: .accent)
                    Text("Saving turns this rule into a regular expression; the plain-word reading becomes “whatever your regular expression matches”.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12)).foregroundStyle(OColor.text2).padding(.top, 8)
            }
            preview.padding(.top, 10)
            HStack(spacing: 8) {
                Text("Name").font(.system(size: 11.5)).foregroundStyle(OColor.text3)
                TextField(String(localized: "Optional"), text: $draft.name)
                    .focused($focus, equals: .name)
                    .fieldChrome(focused: focus == .name)
                    .frame(width: 150)
                    .onSubmit(commit)
                    .accessibilityLabel(Text("Rule name"))
                Text("A “Starts with” rule never crosses a space, so it won’t catch a phone number. For spaced values use “Looks like this”.")
                    .font(.system(size: 11.5)).foregroundStyle(OColor.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let id = draft.original?.id {
                    Button(String(localized: "Delete")) { delete(id) }.buttonStyle(OButtonStyle(.danger, size: .small))
                }
                Button(String(localized: "Cancel"), action: cancel).buttonStyle(OButtonStyle(.quiet, size: .small))
                    .keyboardShortcut(.cancelAction)
                Button(draft.original == nil ? String(localized: "Add Rule") : String(localized: "Save"), action: commit)
                    .buttonStyle(OButtonStyle(.primary, size: .small))
                    .disabled(!canSave)
            }
            .padding(.top, 10)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).fill(OColor.card))
        .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).strokeBorder(OColor.accent, lineWidth: 1.5))
        .onAppear { focus = .value }
    }

    // MARK: Value

    private var valueBinding: Binding<String> {
        Binding(get: {
            if let origin, !draft.converted { return (try? CatalogueBuilder.patternSpec(kind: origin.kind, value: origin.value, tokenLength: origin.tokenLength)
                .compiledPattern()) ?? origin.value }
            return draft.value
        }, set: { text in
            if editsAsRegex { draft.kind = .regex; draft.converted = true }
            draft.value = text
            draft.touched = true
        })
    }

    private func changeKind(_ kind: PatternSpec.Kind) {
        guard kind != draft.kind else { return }
        if kind == .regex, draft.isValid, case .success(let regex) = draft.result { draft.value = regex }
        draft.kind = kind
        if kind != .prefix { draft.tokenLength = nil }
    }

    private var duplicate: Bool {
        let spec = draft.spec
        return session.rules.contains { r in
            r.id != draft.original?.id && r.action == draft.action
                && CatalogueBuilder.patternSpec(kind: r.kind, value: r.value, tokenLength: r.tokenLength) == spec
        }
    }

    private var errorText: String? {
        guard draft.touched, !draft.value.isEmpty else { return nil }
        if case .failure(let error) = draft.result { return PatternCopy.message(for: error) }
        if duplicate { return String(localized: "Already in your rules") }
        return nil
    }

    private var canSave: Bool { draft.isValid && !duplicate && (draft.original == nil || draft.record(sortOrder: 0) != draft.original) }

    private func commit() {
        guard canSave else { draft.touched = true; return }
        save(draft.record(sortOrder: 0))
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        VStack(alignment: .leading, spacing: 3) {
            if draft.isValid, case .success(let regex) = draft.result {
                let verb = RulePreview.verb(draft.action)
                FlowLayout(spacing: 6, lineAlignment: .top) {
                    Text(subject).font(.system(size: 12.5)).foregroundStyle(OColor.text1).padding(.top, 2)
                    Text(verb.lead).font(.system(size: 12.5)).foregroundStyle(OColor.text1).padding(.top, 2)
                    Token(text: verb.token, kind: draft.action == .blackOut ? .blackOut : .allow)
                }
                HStack(spacing: 4) {
                    Text(draft.spec.humanDescription)
                    if regexMode && draft.kind != .regex {
                        Text(verbatim: "·")
                        Text(regex).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .font(.system(size: 11.5)).foregroundStyle(OColor.text2)
                if let warning = RulePreview.literalOnlyWarning(kind: draft.kind, value: draft.value, regex: regex) {
                    Text(warning).font(.system(size: 11.5)).foregroundStyle(OColor.needsText)
                }
            } else {
                Text(draft.kind == .regex ? "Type a regular expression to see what it will match."
                                          : "Type a value to see what the rule will match.")
                    .font(.system(size: 12)).foregroundStyle(OColor.text3)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: OMetric.Radius.l, style: .continuous).fill(OColor.fill))
        .accessibilityElement(children: .combine)
    }

    /// The subject with its value in bold: Things like **“CUS-004213”**.
    private var subject: AttributedString {
        let plain = RulePreview.subject(kind: draft.kind, value: draft.value)
        var text = AttributedString(plain)
        let v = draft.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = text.range(of: draft.kind == .regex ? v : "“\(v)”") { text[r].font = .system(size: 12.5, weight: .semibold) }
        return text
    }
}
