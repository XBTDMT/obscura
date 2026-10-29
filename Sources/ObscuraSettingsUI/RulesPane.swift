// Custom Rules: three tiles (Black out · Never black out · Add Rule), Add Rule written as a sentence with a live
// preview, rules read as sentences in two groups, Export / Import, the empty state and the test footer.
// Rules are `RuleRecord`s in the Journal; the engine turns them into detectors and allow rules (DETECTORS.md §2.4, §6).
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ObscuraUIKit
import ObscuraDetect
import ObscuraEngine
import ObscuraJournal

struct RulesPane: View {
    let model: AppModel
    let session: SettingsSession

    @State private var editor: RuleDraft?
    @State private var group: RuleAction?
    @Environment(\.settingsInitialState) private var initial

    private var regexMode: Bool { model.settings.showsPatterns(in: .customRules) }

    var body: some View {
        PaneScaffold(String(localized: "Custom Rules")) {
            ModePicker(model: model, pane: .customRules)
            Button(String(localized: "Add Rule")) { startAdding() }.buttonStyle(OButtonStyle(.quiet, size: .small))
            Button(String(localized: "Export…")) { exportRules() }.buttonStyle(OButtonStyle(.quiet, size: .small))
                .disabled(!session.loaded)
            Button(String(localized: "Import…")) { importRules() }.buttonStyle(OButtonStyle(.quiet, size: .small))
        } content: {
            Lead(tone: session.unreadableRules.isEmpty ? .ok : .needs, title: headline,
                 detail: String(localized: "Say a rule as a sentence. Rules run with the detectors; Never black out wins over everything."))
            tiles
            if let draft = Binding($editor) {
                RuleEditor(draft: draft, session: session, regexMode: regexMode,
                           // The list changes in the same frame the editor closes; only the store write is async.
                           cancel: { editor = nil },
                           save: { record in
                               let staged = session.stageRule(record)
                               editor = nil
                               Task { await session.storeRule(staged) }
                           },
                           delete: { id in
                               session.stageDeletion(id)
                               editor = nil
                               Task { await session.storeDeletion(id) }
                           })
                    .padding(.bottom, 14)
            }
            if !session.unreadableRules.isEmpty { unreadableGroup }
            if session.rules.isEmpty {
                if editor == nil && session.unreadableRules.isEmpty { emptyState }
            } else {
                if group != .allow { ruleGroup(.blackOut) }
                if group != .blackOut { ruleGroup(.allow) }
            }
            PatternDisplayOptions(model: model)
        } footer: {
            TestFooter(session: session, allowRuleMode: model.settings.allowRuleMode.detectMode,
                       showsPatternNumber: PatternDisplayOptions.showsPatternNumber(model.settings, regexMode: regexMode))
        }
        .onAppear { editor = initial.ruleDraft }
    }

    private var headline: String {
        let b = session.blackOutRules.count, n = session.allowRules.count
        if b == 0 && n == 0 {
            let unreadable = session.unreadableRules.count
            return unreadable == 0 ? String(localized: "No rules of your own yet") : UnreadableRuleCopy.heading(unreadable)
        }
        let first = b == 1 ? String(localized: "1 rule blacks out things of yours") : String(localized: "\(b) rules black out things of yours")
        let second = n == 1 ? String(localized: "1 is never blacked out") : String(localized: "\(n) are never blacked out")
        if n == 0 { return first }
        if b == 0 { return n == 1 ? String(localized: "1 thing is never blacked out") : String(localized: "\(n) things are never blacked out") }
        return "\(first) · \(second)"
    }

    // MARK: Tiles

    private var tiles: some View {
        let black = session.blackOutRules, allow = session.allowRules
        return HStack(spacing: 8) {
            OverviewTile(symbol: "rectangle.fill", title: String(localized: "Black out"), count: blackCount(black),
                         dots: black.map { $0.enabled ? .accent : .quiet }, selected: group == .blackOut, dimmed: black.isEmpty) {
                group = group == .blackOut ? nil : .blackOut
            }
            OverviewTile(symbol: "eye", title: String(localized: "Never black out"),
                         count: allow.isEmpty ? String(localized: "None yet") : String(localized: "\(CountCopy.rules(allow.count)) · win over every detector"),
                         dots: allow.map { $0.enabled ? .ok : .quiet }, selected: group == .allow, dimmed: allow.isEmpty) {
                group = group == .allow ? nil : .allow
            }
            OverviewTile(symbol: "plus", title: String(localized: "Add Rule"), count: String(localized: "Say it as a sentence"),
                         dots: [], selected: false, isAdd: true) { startAdding() }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 10)
    }

    private func blackCount(_ rules: [RuleRecord]) -> String {
        guard !rules.isEmpty else { return String(localized: "None yet") }
        return String(localized: "\(CountCopy.rules(rules.count)) · \(rules.filter(\.enabled).count) on")
    }

    // MARK: Groups

    @ViewBuilder private func ruleGroup(_ action: RuleAction) -> some View {
        let rules = action == .blackOut ? session.blackOutRules : session.allowRules
        if !rules.isEmpty {
            HStack(spacing: 8) {
                Text(action == .blackOut ? String(localized: "Black out") : String(localized: "Never black out"))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(OColor.text1)
                    .accessibilityAddTraits(.isHeader)
                Text(action == .blackOut ? CountCopy.rules(rules.count)
                                         : String(localized: "\(CountCopy.rules(rules.count)) · win over every detector, so keep them specific"))
                    .font(.system(size: 11.5)).foregroundStyle(OColor.text2)
            }
            .padding(.horizontal, 2).padding(.top, 4).padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(Array(rules.enumerated()), id: \.element.id) { i, rule in
                    if i > 0 { RowDivider() }
                    RuleRow(rule: rule, regexMode: regexMode, session: session) { startEditing(rule) }
                }
            }
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).fill(OColor.card))
            .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).strokeBorder(OColor.separator, lineWidth: OMetric.hairline))
            .clipShape(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous))
            .padding(.bottom, 10)
            if action == .allow {
                NoteBox(text: String(localized: "A line that matches one of these is skipped before any detector runs and is never recorded in the Journal."),
                        tone: .ok, symbol: "checkmark.shield")
                    .padding(.top, -2).padding(.bottom, 10)
            }
        }
    }

    /// G-30: rules whose value can't be read on this Mac, apart from the working ones, each with Re-enter and Delete.
    private var unreadableGroup: some View {
        let rules = session.unreadableRules
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(UnreadableRuleCopy.heading(rules.count))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(OColor.text1)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.horizontal, 2).padding(.top, 4).padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(Array(rules.enumerated()), id: \.element.id) { i, rule in
                    if i > 0 { RowDivider() }
                    UnreadableRuleRow(rule: rule, reenter: { editor = RuleDraft(reentering: rule) },
                                      delete: { Task { await session.deleteRule(rule.id) } })
                }
            }
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).fill(OColor.card))
            .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).strokeBorder(OColor.needs, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous))
            .padding(.bottom, 8)
            NoteBox(text: UnreadableRuleCopy.note(rules), tone: .needs, symbol: "lock.trianglebadge.exclamationmark")
                .padding(.bottom, 10)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No rules yet").font(.system(size: 14, weight: .semibold)).foregroundStyle(OColor.text1)
            Text("Add a rule to black out something of your own, like customer ids or a project name. You can also select text in a preview and choose “Always black out things like this”.")
                .font(.system(size: 12)).foregroundStyle(OColor.text2).multilineTextAlignment(.center)
                .frame(maxWidth: 380).fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "Add Rule")) { startAdding() }.buttonStyle(OButtonStyle(.primary))
            HStack(spacing: 3) {
                Text("or")
                Button(String(localized: "Import…")) { importRules() }.buttonStyle(.plain).foregroundStyle(OColor.accentText)
                Text("a rules file")
            }
            .font(.system(size: 11.5)).foregroundStyle(OColor.text3)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20).padding(.top, 30).padding(.bottom, 24)
        .background(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).fill(OColor.card))
        .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).strokeBorder(OColor.separator, lineWidth: OMetric.hairline))
        .padding(.bottom, 10)
    }

    // MARK: Actions

    private func startAdding() {
        editor = RuleDraft(action: group ?? .blackOut)
    }

    private func startEditing(_ rule: RuleRecord) {
        editor = RuleDraft(rule: rule)
    }

    private func exportRules() {
        Task {
            do {
                let data = try await session.exportRules()
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = String(localized: "Obscura Rules.json")
                panel.message = ExportCopy.panelMessage(unreadable: session.unreadableRules.count)
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
            } catch {
                session.notice = String(localized: "Couldn’t export your rules.")
            }
        }
    }

    private func importRules() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose an Obscura rules file. Rules with the same id are replaced by the file’s version.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try Data(contentsOf: url)
                let report = try await session.importRules(data)
                session.notice = ImportCopy.summary(report, unusable: session.unusableImports(report))
            } catch {
                session.notice = String(localized: "That file isn’t an Obscura rules file, so nothing was imported.")
            }
        }
    }
}

enum ExportCopy {
    /// The save panel's words. G-30: Obscura keeps rule text sealed, but the file holds it as typed, so it can be read
    /// on another Mac; the person is told before they choose where it goes.
    static func panelMessage(unreadable: Int) -> String {
        let base = String(localized: "Your rules, edited detectors and default style, as one file. The file holds your rules’ text as you typed it, not encrypted, so keep it somewhere safe.")
        guard unreadable > 0 else { return base }
        let left = unreadable == 1 ? String(localized: "1 rule that can’t be read on this Mac is left out.")
                                   : String(localized: "\(unreadable) rules that can’t be read on this Mac are left out.")
        return base + " " + left
    }
}

/// G-30: the words for a rule whose value can't be read on this Mac.
enum UnreadableRuleCopy {
    static func heading(_ n: Int) -> String {
        n == 1 ? String(localized: "1 rule can’t be read on this Mac") : String(localized: "\(n) rules can’t be read on this Mac")
    }

    /// The row's sentence: what kind of rule it was (never a value: there is none), and what to do.
    static func row(_ rule: UnreadableRule) -> String {
        let action = rule.action == .blackOut ? String(localized: "Black out") : String(localized: "Never black out")
        let what = rule.name.map { "“\($0)”" } ?? KindCopy.sentenceTail(KindCopy.patternKind(rule.kind))
        return rule.problem.needsReentry
            ? String(localized: "\(action) \(what): can’t be read on this Mac — re-enter it")
            : String(localized: "\(action) \(what): waiting for the keychain")
    }

    static func note(_ rules: [UnreadableRule]) -> String {
        let blackOut = rules.contains { $0.action == .blackOut }
        let lead = rules.allSatisfy { !$0.problem.needsReentry }
            ? String(localized: "The keychain didn’t hand over the key that protects your rules, so these aren’t in use yet. Obscura tries again.")
            : String(localized: "These were saved on another Mac or before the keychain was reset, so their text can’t be read here. Re-enter each one, or import a rules file you exported.")
        let effect = blackOut
            ? String(localized: "Until then, what they black out is not blacked out. Built-in detectors still run.")
            : String(localized: "Until then, what they keep visible may be blacked out.")
        return lead + " " + effect
    }
}

/// An unreadable rule (G-30): the action, the kind or name it had, and why it isn't in use, never compiled.
struct UnreadableRuleRow: View {
    let rule: UnreadableRule
    var reenter: () -> Void
    var delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            FlowLayout(spacing: 6, lineAlignment: .top) {
                Token(text: rule.action == .blackOut ? String(localized: "Black out") : String(localized: "Never black out"),
                      kind: rule.action == .blackOut ? .blackOut : .allow)
                Image(systemName: "lock.trianglebadge.exclamationmark").font(.system(size: 12)).foregroundStyle(OColor.needs).padding(.top, 2)
                Text(UnreadableRuleCopy.row(rule)).font(.system(size: 12.5)).foregroundStyle(OColor.text1).padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(UnreadableRuleCopy.row(rule)))
            if rule.problem.needsReentry {
                Button(String(localized: "Re-enter…"), action: reenter).buttonStyle(OButtonStyle(.quiet, size: .small))
            }
            Button(String(localized: "Delete"), role: .destructive, action: delete).buttonStyle(OButtonStyle(.quiet, size: .small))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(minHeight: 36)
    }
}

enum ImportCopy {
    /// `unusable`: imported rules and edited detectors whose pattern is invalid or refused as too slow to check (F23).
    static func summary(_ r: ImportReport, unusable: Int = 0) -> String {
        let new = r.rulesAdded.count + r.overridesAdded.count + r.statesAdded.count
        let replaced = (r.policy == .preferIncoming ? r.conflicts.count : 0) + r.rulesRecovered.count
        let same = r.rulesUnchanged.count + r.overridesUnchanged.count + r.statesUnchanged.count
        var parts = [String(localized: "Imported: \(new) new, \(replaced) replaced, \(same) already here.")]
        // Security scan F16/F22: items the file held that were not valid (an id, a value length, a duplicate).
        let refused = r.rejected.count
        if refused == 1 { parts.append(String(localized: "1 item in the file wasn’t valid, so it wasn’t imported.")) }
        if refused > 1 { parts.append(String(localized: "\(refused) items in the file weren’t valid, so they weren’t imported.")) }
        if unusable == 1 { parts.append(String(localized: "1 of them isn’t used: its pattern is invalid or could take too long to check.")) }
        if unusable > 1 { parts.append(String(localized: "\(unusable) of them aren’t used: their patterns are invalid or could take too long to check.")) }
        return parts.joined(separator: " ")
    }
}

/// A rule read as a sentence: "[Black out] things that look like [CUS-004213] “CUS”, “-”, 6 digits".
struct RuleRow: View {
    let rule: RuleRecord
    var regexMode: Bool
    let session: SettingsSession
    var edit: () -> Void

    var body: some View {
        let spec = CatalogueBuilder.patternSpec(kind: rule.kind, value: rule.value, tokenLength: rule.tokenLength)
        let kind = KindCopy.patternKind(rule.kind)
        let showRegex = regexMode || kind == .regex
        let regex = (try? spec.compiledPattern()) ?? rule.value
        HStack(spacing: 10) {
            Button(action: edit) {
                FlowLayout(spacing: 6, lineAlignment: .top) {
                    Token(text: rule.action == .blackOut ? String(localized: "Black out") : String(localized: "Never black out"),
                          kind: rule.action == .blackOut ? .blackOut : .allow)
                    Text(showRegex ? KindCopy.sentenceTail(.regex) : KindCopy.sentenceTail(kind))
                        .font(.system(size: 12.5)).foregroundStyle(OColor.text1).padding(.top, 2)
                    Token(text: showRegex ? regex : rule.value, kind: showRegex ? .mono : .value)
                    Group {
                        if regexMode && kind != .regex {
                            Text("from \(KindCopy.sentenceTail(kind))") + Text(verbatim: " ") + Text(rule.value).font(.system(size: 11, design: .monospaced))
                        } else {
                            Text(spec.humanDescription)
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(OColor.text3).padding(.top, 3)
                }
                .opacity(rule.enabled ? 1 : 0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(rule.name ?? spec.humanDescription)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(RulePreview.rowSentence(rule)))
            .accessibilityHint(Text("Edits the rule"))
            .contextMenu {
                Button(String(localized: "Edit Rule…"), action: edit)
                Button(String(localized: "Delete Rule"), role: .destructive) { Task { await session.deleteRule(rule.id) } }
            }
            AsyncSwitch(label: RulePreview.rowSentence(rule), isOn: rule.enabled) { v in await session.setRuleEnabled(rule.id, v) }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(minHeight: 36)
    }
}

/// The preview sentences, one mapping per kind (system.html §5).
enum RulePreview {
    /// "Things like “CUS-004213”", "Anything that starts with “tok_”".
    static func subject(kind: PatternSpec.Kind, value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .example: return String(localized: "Things like “\(v)”")
        case .exactText: return String(localized: "The text “\(v)”")
        case .prefix: return String(localized: "Anything that starts with “\(v)”")
        case .label: return String(localized: "The value after “\(v)”")
        case .regex: return String(localized: "Anything matching \(v)")
        }
    }

    /// "will be" + token "blacked out" / "will" + token "never be blacked out".
    static func verb(_ action: RuleAction) -> (lead: String, token: String) {
        action == .blackOut ? (String(localized: "will be"), String(localized: "blacked out"))
                            : (String(localized: "will"), String(localized: "never be blacked out"))
    }

    /// The whole preview as one plain sentence: "Things like “CUS-004213” will be blacked out".
    static func sentence(action: RuleAction, kind: PatternSpec.Kind, value: String) -> String {
        let v = verb(action)
        return "\(subject(kind: kind, value: value)) \(v.lead) \(v.token)"
    }

    /// A stored rule as a sentence, for VoiceOver: "Black out things that look like CUS-004213".
    static func rowSentence(_ rule: RuleRecord) -> String {
        let action = rule.action == .blackOut ? String(localized: "Black out") : String(localized: "Never black out")
        let state = rule.enabled ? "" : String(localized: ", off")
        return "\(action) \(KindCopy.sentenceTail(KindCopy.patternKind(rule.kind))) \(rule.value)\(state)"
    }

    /// For a "Looks like this" example that generalises to nothing but itself (DETECTORS.md §3.5).
    static func literalOnlyWarning(kind: PatternSpec.Kind, value: String, regex: String) -> String? {
        guard kind == .example else { return nil }
        let generalised = ["\\d", "[A-Z]", "[a-z]", "[A-Za-z0-9]", "\\s"].contains { regex.contains($0) }
        guard !generalised else { return nil }
        return String(localized: "This will only match exactly “\(value.trimmingCharacters(in: .whitespacesAndNewlines))”.")
    }
}
