// A detector opened to its patterns (`.exp`). Plain words: a kind popup, the value, its plain-word description and
// the generated regex one click away. Regular expressions: every pattern is a mono regex field; editing a derived
// pattern converts it to a regex of its own (badge "from Starts with “sk-ant-”"), and nothing changes until it is
// edited, so switching modes is lossless (open decision 3). Edits are kept as drafts and stored only when every
// pattern compiles: an override that does not compile would drop the whole detector from the scan.
import SwiftUI
import ObscuraUIKit
import ObscuraDetect

struct PatternDraft: Identifiable, Equatable {
    let id = UUID()
    var spec: PatternSpec
    /// Set once the user typed in this line (errors show only then).
    var touched = false

    var result: Result<String, PatternError> { PatternCopy.compile(spec) }
    var isValid: Bool { if case .success = result { return true } else { return false } }
    var error: PatternError? { if case .failure(let e) = result { return e } else { return nil } }
}

struct PatternEditor: View {
    let detector: Detector
    let session: SettingsSession
    var regexMode: Bool

    @State private var drafts: [PatternDraft] = []
    @State private var lastStored: [PatternSpec]?
    @State private var revealed: Set<UUID> = []
    @State private var saveTask: Task<Void, Never>?

    private var stored: [PatternSpec] { session.patterns(for: detector) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if drafts.isEmpty {
                NoteBox(text: String(localized: "No patterns. This detector will never match."), tone: .needs, symbol: "exclamationmark.triangle")
            }
            ForEach($drafts) { $draft in
                PatternLine(draft: $draft, regexMode: regexMode, revealed: revealed.contains(draft.id),
                            toggleReveal: { if revealed.contains(draft.id) { revealed.remove(draft.id) } else { revealed.insert(draft.id) } },
                            remove: { remove(draft.id) })
            }
            HStack(spacing: 8) {
                Button(String(localized: "Add Pattern")) { add() }.buttonStyle(OButtonStyle(.quiet, size: .small))
                Button(String(localized: "Reset to Default")) { reset() }.buttonStyle(OButtonStyle(.quiet, size: .small))
                    .disabled(!session.isEdited(detector.id))
                Text(hint).font(.system(size: 11.5)).foregroundStyle(OColor.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
            }
            .padding(.top, 2)
        }
        .padding(.top, 10).padding(.bottom, 12).padding(.leading, 44).padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OColor.fill)
        .onAppear { load(stored) }
        .onChange(of: stored) { _, new in
            // Changed under us (an import, a reset elsewhere): take the stored list unless it is our own write.
            if new != lastStored, new != drafts.map(\.spec) { load(new) }
        }
        .onChange(of: drafts) { _, _ in scheduleSave() }
        .onDisappear { flush() }
    }

    private var hint: String {
        if drafts.isEmpty {
            let n = detector.patterns.count
            return n == 1 ? String(localized: "Reset restores the one built-in pattern.")
                          : String(localized: "Reset restores the \(n) built-in patterns.")
        }
        if !session.isEdited(detector.id) && drafts.map(\.spec) == detector.patterns && hasOnlyRegex {
            return String(localized: "Reset is dimmed: this detector is unchanged.")
        }
        if regexMode {
            return String(localized: "Patterns are OR’d. A named group (?<secret>…) limits the black-out to that part; otherwise the whole match is covered.")
        }
        if case .block = detector.scope {
            return String(localized: "Matches when any pattern does. The whole block is covered, from this line to its end.")
        }
        return String(localized: "Matches when any pattern does. Only the secret is covered; the label before it stays readable.")
    }

    private var hasOnlyRegex: Bool { drafts.allSatisfy { $0.spec.kind == .regex } }

    // MARK: Editing

    private func load(_ specs: [PatternSpec]) {
        drafts = specs.map { PatternDraft(spec: $0) }
        lastStored = specs
    }

    private func add() {
        let spec = regexMode ? PatternSpec(kind: .regex, pattern: "") : PatternSpec(kind: .example)
        drafts.append(PatternDraft(spec: spec))
    }

    private func remove(_ id: UUID) {
        drafts.removeAll { $0.id == id }
    }

    private func reset() {
        saveTask?.cancel()
        Task {
            await session.reset(detector)
            load(detector.patterns)
        }
    }

    private func scheduleSave() {
        let specs = drafts.map(\.spec)
        guard specs != lastStored, drafts.allSatisfy(\.isValid) else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await store(specs)
        }
    }

    /// Stores what is valid now, when the editor closes before the debounce fired.
    private func flush() {
        guard let task = saveTask else { return }
        task.cancel()
        let specs = drafts.map(\.spec)
        guard specs != lastStored, drafts.allSatisfy(\.isValid) else { return }
        Task { await store(specs) }
    }

    private func store(_ specs: [PatternSpec]) async {
        lastStored = specs
        try? await session.savePatterns(specs, for: detector)
    }
}

/// One pattern line: kind popup (plain words only), the field, Remove Pattern, and under it the description,
/// the regex disclosure, the conversion badge or the inline error.
struct PatternLine: View {
    @Binding var draft: PatternDraft
    var regexMode: Bool
    var revealed: Bool
    var toggleReveal: () -> Void
    var remove: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if !regexMode {
                KindMenu(kind: Binding(get: { draft.spec.kind }, set: { changeKind(to: $0) }),
                         label: KindCopy.title(draft.spec.kind))
                    .frame(width: 150, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 5) {
                TextField(placeholder, text: Binding(get: { fieldText }, set: { edit($0) }))
                    .focused($focused)
                    .fieldChrome(focused: focused, invalid: showsError, mono: isMono)
                    .accessibilityLabel(Text(regexMode ? "Regular expression" : KindCopy.fieldLabel(draft.spec.kind)))
                under
            }
            Button(action: remove) {
                Image(systemName: "minus").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 24)
            }
            .buttonStyle(OButtonStyle(.quiet, size: .small))
            .help(String(localized: "Remove Pattern"))
            .accessibilityLabel(Text("Remove Pattern"))
        }
    }

    private var isMono: Bool { regexMode || draft.spec.kind == .regex }

    private var placeholder: String { regexMode ? KindCopy.placeholder(.regex) : KindCopy.placeholder(draft.spec.kind) }

    /// Plain words: the value (or the regex of a regex pattern). Regular expressions: the regex, derived for the
    /// four plain kinds.
    private var fieldText: String {
        if draft.spec.kind == .regex { return draft.spec.pattern ?? "" }
        if regexMode { return (try? draft.spec.compiledPattern()) ?? "" }
        return draft.spec.value
    }

    private var showsError: Bool { draft.touched && draft.error != nil }

    @ViewBuilder private var under: some View {
        if showsError, let error = draft.error {
            InlineError(text: PatternCopy.message(for: error))
        } else if regexMode {
            if draft.spec.kind != .regex {
                HStack(spacing: 6) {
                    Badge(String(localized: "from \(KindCopy.title(draft.spec.kind)) “\(draft.spec.value)”"), tone: .accent)
                    Text("Editing this line turns the pattern into a regular expression of its own.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12)).foregroundStyle(OColor.text2)
            }
        } else if draft.isValid {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.spec.humanDescription).font(.system(size: 12)).foregroundStyle(OColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if draft.spec.kind == .regex {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 10))
                        Text("Regular expression")
                        Text("this pattern is already one; nothing more to show").foregroundStyle(OColor.text3)
                    }
                    .font(.system(size: 11.5)).foregroundStyle(OColor.text2)
                } else {
                    Button(action: toggleReveal) {
                        HStack(spacing: 6) {
                            Image(systemName: revealed ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            Text("Regular expression")
                        }
                        .font(.system(size: 11.5)).foregroundStyle(OColor.text2).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(Text(revealed ? "Shown" : "Hidden"))
                    if revealed, case .success(let regex) = draft.result {
                        FlowLayout(spacing: 6, lineAlignment: .top) {
                            Text(regex).font(.system(size: 11, design: .monospaced)).foregroundStyle(OColor.text1)
                                .textSelection(.enabled)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: OMetric.Radius.s, style: .continuous).fill(OColor.fill2))
                            Text("generated · read-only here, editable in Regular expressions mode")
                                .font(.system(size: 11.5)).foregroundStyle(OColor.text3)
                        }
                    }
                }
            }
        }
    }

    private func edit(_ text: String) {
        draft.touched = true
        if regexMode || draft.spec.kind == .regex {
            // A derived pattern edited as a regex becomes a regex of its own; its plain value is dropped.
            draft.spec = PatternSpec(kind: .regex, pattern: text)
        } else {
            draft.spec.value = text
        }
    }

    private func changeKind(to kind: PatternSpec.Kind) {
        guard kind != draft.spec.kind else { return }
        let old = draft.spec
        if kind == .regex {
            // Start the regex from what the old pattern generated, so nothing typed is lost.
            draft.spec = PatternSpec(kind: .regex, pattern: (try? old.compiledPattern()) ?? "")
        } else {
            draft.spec = PatternSpec(kind: kind, value: old.kind == .regex ? "" : old.value,
                                     tokenLength: kind == .prefix ? old.tokenLength : nil)
        }
        draft.touched = !draft.spec.value.isEmpty || kind == .regex
    }
}

/// The kind popup: one copy set (CHANGES.md 37), each item with its one-line explanation and a check on the current one.
struct KindMenu: View {
    @Binding var kind: PatternSpec.Kind
    var label: String

    var body: some View {
        Menu {
            ForEach(KindCopy.menuOrder, id: \.self) { k in
                Toggle(isOn: Binding(get: { kind == k }, set: { if $0 { kind = k } })) {
                    Text(KindCopy.title(k))
                    Text(KindCopy.subtitle(k))
                }
            }
        } label: {
            Text(label).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.button)
        .menuIndicator(.visible)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(Text("Kind of pattern"))
        .accessibilityValue(Text(KindCopy.title(kind)))
    }
}
