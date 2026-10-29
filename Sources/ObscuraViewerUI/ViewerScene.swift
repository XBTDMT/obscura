// The window body shared by ViewerWindow and TestShotResultView: toolbar, banner, canvas (or compare), inspector,
// strip, keyboard, Live Text rules and toasts.
import SwiftUI
import ObscuraUIKit
import ObscuraJournal
import ObscuraEngine

enum ViewerVariant: Equatable {
    case standard
    case testShot(durationMS: Int)
}

struct ViewerScene: View {
    let model: AppModel
    let entryID: UUID
    let variant: ViewerVariant
    var rulesChanged: (@MainActor () async -> Void)?
    var runAgain: (@MainActor () -> Void)?
    var continueSetup: (@MainActor () -> Void)?

    @State private var state: ViewerState
    @State private var liveText = LiveTextController()
    @State private var windowBox = WindowBox()
    @State private var localToast: LocalToast?
    /// Key texts under findings left visible (G-17): view state of this window only.
    @State private var keyTexts: UncoveredKeyText
    /// G-40: the picture's spots no reading could read (its Not checked row, or the record of how they were settled).
    @State private var spotRows: [UncheckedFile] = []

    init(model: AppModel, entryID: UUID, variant: ViewerVariant, state: ViewerState = ViewerState(),
         rulesChanged: (@MainActor () async -> Void)? = nil, runAgain: (@MainActor () -> Void)? = nil,
         continueSetup: (@MainActor () -> Void)? = nil) {
        self.model = model
        self.entryID = entryID
        self.variant = variant
        self.rulesChanged = rulesChanged
        self.runAgain = runAgain
        self.continueSetup = continueSetup
        // The verdict is known now, so the inspector is decided before the first frame and the window opens at its
        // final width (720, or 880 with the inspector) instead of opening narrow and growing (recon T-4, M-4).
        if state.inspectorChoice == nil, let entry = model.entries.first(where: { $0.id == entryID }) {
            state.inspectorChoice = Self.opensInspector(variant: variant, verdict: model.verdict(for: entry))
        }
        _state = State(initialValue: state)
        _keyTexts = State(initialValue: UncoveredKeyText(model: model))
    }

    /// Whether the inspector opens by itself: always for the test shot, else when a finding is left visible.
    static func opensInspector(variant: ViewerVariant, verdict: Verdict) -> Bool {
        variant != .standard || ViewerState.autoOpensInspector(for: verdict)
    }

    private var entry: Entry? { model.entries.first { $0.id == entryID } }

    var body: some View {
        Group {
            if let entry { content(entry) } else { missing }
        }
        .navigationTitle(entry?.displayName ?? String(localized: "Viewer"))
        .toolbar { toolbar }
        .toolbar(removing: .title)
        .background(WindowKeyHandler(bindings: { model.settings.keyBindings }, handle: handleKey, windowChanged: { window in
            windowBox.window = window
            // Before the window is on screen: make sure it starts at the width its layout needs, without motion.
            if state.showsInspector { windowBox.ensureWidth(atLeast: OMetric.viewerWidthWithInspector) }
        }))
        .task(id: entry?.revision) {
            guard let entry else { return }
            // Only when the entry was not in the model yet at init (a catch that just landed).
            if state.inspectorChoice == nil {
                setInspector(Self.opensInspector(variant: variant, verdict: model.verdict(for: entry)))
            }
            await state.load(entry, from: model.journal)
            spotRows = await model.spotFiles(entryID: entry.id)
        }
        .onChange(of: state.mode) { _, mode in
            if mode == .original, let url = state.originalURL { liveText.analyze(originalAt: url) }
        }
        .onChange(of: entry?.findings) { _, _ in syncKeyTexts() }
        .onChange(of: model.settings.showsUncoveredKeyText) { _, _ in syncKeyTexts() }
        .onAppear { liveText.onRule = { text, intent in addRule(text, intent) } }
        .onDisappear {
            liveText.cancel()
            keyTexts.clear()
        }
    }

    // MARK: Layout

    private func content(_ entry: Entry) -> some View {
        let names = Self.names(for: entry)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                canvas(entry, names: names)
                if state.showsInspector { inspector(entry, names: names) }
            }
            if variant == .standard, let row = spotRows.first(where: { !$0.spots.isEmpty }) { SpotStrip(row: row) { model.router?.openSpots(fileID: row.id) } }
            FindingsStrip(keys: model.settings.keyBindings, findings: entry.findings, names: names, pillVerdict: stripVerdict(entry), caption: caption(entry),
                          showsBlackOutAll: variant == .standard && !state.showsOriginalImage && entry.findings.contains { !$0.enabled },
                          blackOutAll: { Task { await model.blackOutAll(entryID) } },
                          openInspector: { setInspector(true) })
        }
        .frame(minWidth: state.windowWidth, idealWidth: state.windowWidth, maxWidth: .infinity,
               minHeight: 460, idealHeight: 560, maxHeight: .infinity)
        .background(OColor.window)
    }

    private func canvas(_ entry: Entry, names: [UUID: String]) -> some View {
        ZStack(alignment: .top) {
            OColor.canvas
            if state.isComparing {
                switch model.settings.compareStyle {
                case .sideBySide: ComparePanes(clean: state.cleanImage, original: state.originalImage)
                case .wipe:
                    WipeCompare(clean: state.cleanImage, original: state.originalImage, pixelSize: state.pixelSize,
                                position: Binding(get: { state.wipePosition }, set: { state.setWipePosition($0) }))
                }
            } else if let image = state.showsOriginalImage ? state.originalImage : state.cleanImage {
                ImageCanvas(state: state, image: image, pixelSize: state.pixelSize, findings: entry.findings, names: names,
                            showsMarks: !state.showsOriginalImage, liveText: liveText,
                            liveTextActive: state.mode == .original && !state.isPeeking,
                            onToggle: { f in toggle(f) })
            } else if state.loadFailed {
                Text(ViewerCopy.loadFailed).font(OFont.body).foregroundStyle(OColor.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DelayedProgress().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if state.isPeeking { PeekPill().padding(.top, 14).allowsHitTesting(false) }
            // T-12 (G-19): the red banner floats over the picture's top strip instead of pushing it down, so a fitted
            // image never resizes on Tab; the strip it covers is hidden only while the original shows.
            if state.mode == .original && !state.isComparing { OriginalBanner() }
        }
        .oToasts(toastItems, placement: .bottom, expire: { id in if localToast?.id == id { localToast = nil } })
        .frame(maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder private func inspector(_ entry: Entry, names: [UUID: String]) -> some View {
        switch variant {
        case .standard:
            ViewerInspector(keys: model.settings.keyBindings, entry: entry, names: names, verdict: model.verdict(for: entry), retentionHours: model.settings.journalRetentionHours,
                            originalAvailable: state.originalAvailable, toggle: { toggle($0) }, blackOutAll: { Task { await model.blackOutAll(entryID) } },
                            keyText: { keyTexts.state(for: $0, switchOn: model.settings.showsUncoveredKeyText) },
                            requestKeyText: { keyTexts.request($0, in: entryID, switchOn: model.settings.showsUncoveredKeyText) },
                            copyKeyText: { copyKeyText($0) },
                            copyClean: { Task { await model.copy(entryID, original: false) } },
                            copyOriginal: { Task { await model.copy(entryID, original: true) } })
        case .testShot(let ms):
            TestShotInspector(entry: entry, names: names, durationMS: ms, retentionHours: model.settings.journalRetentionHours,
                              toggle: { toggle($0) }, runAgain: { runAgain?() },
                              continueSetup: { if let continueSetup { continueSetup() } else { model.router?.openSetup() } })
        }
    }

    private var missing: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo").font(.system(size: 28, weight: .light)).foregroundStyle(OColor.text3).accessibilityHidden(true)
            Text(ViewerCopy.entryGone).font(OFont.body).foregroundStyle(OColor.text2)
        }
        .frame(minWidth: OMetric.viewerWidth, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
        .background(OColor.canvas)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            TitleBlock(name: entry?.displayName ?? "", subtitle: subtitle, isLive: state.mode == .original)
        }
        ToolbarItem(placement: .principal) {
            ToolbarCenter(mode: state.mode, originalAvailable: state.originalAvailable, isPeeking: state.isPeeking) { state.setMode($0) }
        }
        ToolbarItem(placement: .primaryAction) {
            ToolbarTrailing(keys: model.settings.keyBindings, zoomLabel: state.zoomLabel, zoomEnabled: state.canZoom, inspectorOn: state.showsInspector,
                            zoomOut: { state.zoomOut() }, zoomIn: { state.zoomIn() }, actual: { state.actualSize() },
                            fit: { state.zoomToFit() }, copy: copy, toggleInspector: { setInspector(!state.showsInspector) })
        }
    }

    /// The one toast this window shows: its own (Live Text copies and rules) before the app model's. The model's toast
    /// expires itself; this window's own expires through the stack.
    private var toastItems: [ToastItem] {
        if let t = localToast {
            return [ToastItem(id: t.id, text: t.text, actionTitle: t.undo == nil ? nil : String(localized: "Undo"), action: t.undo)]
        }
        return model.toast.map { [$0.item] } ?? []
    }

    // MARK: Derived words

    private var subtitle: String {
        guard let entry else { return "" }
        if state.mode == .original { return ViewerCopy.originalWarning }
        return ViewerCopy.subtitle(enabled: entry.enabledFindings.count, total: entry.findings.count)
    }

    private func stripVerdict(_ entry: Entry) -> Verdict {
        state.showsOriginalImage && !state.isComparing ? .originalShowing(total: entry.findings.count) : model.verdict(for: entry)
    }

    private func caption(_ entry: Entry) -> String? {
        if state.showsOriginalImage && !state.isComparing { return nil }
        switch variant {
        case .testShot: return ViewerCopy.testShotCaption
        case .standard:
            if case .safeToShare = model.verdict(for: entry) { return ViewerCopy.fileMatches }
            return nil
        }
    }

    static func names(for entry: Entry) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: entry.findings.map { ($0.id, ViewerCopy.name(of: $0)) })
    }

    // MARK: Actions

    /// Shows or hides the inspector as one change: the window widens or narrows by the column's width in the same
    /// frame as the column appears or leaves, so the canvas keeps its width and a fitted image does not move. It is
    /// instant (G-15: instant or one fade, and a window resize is not a fade), which is also what Reduce Motion asks.
    /// Opening grows the window before the layout asks for its wider minimum; closing narrows the layout first, so
    /// neither minimum ever pushes the window a second time (recon T-3).
    private func setInspector(_ shown: Bool) {
        guard shown != state.showsInspector || state.inspectorChoice == nil else { return }
        let wasShown = state.showsInspector
        if shown && !wasShown { windowBox.setInspectorShown(true) }
        state.inspectorChoice = shown
        if !shown && wasShown { windowBox.setInspectorShown(false) }
    }

    /// Drops key texts whose findings are covered again, or all of them when the switch is off.
    private func syncKeyTexts() {
        keyTexts.sync(entry?.findings ?? [], switchOn: model.settings.showsUncoveredKeyText)
    }

    /// Copy beside a key: the text goes on the clipboard marked concealed; the window's toast says so.
    private func copyKeyText(_ f: Finding) {
        localToast = LocalToast(text: keyTexts.copy(f.id) ? KeyTextCopy.copied : KeyTextCopy.copyFailed)
    }

    private func toggle(_ f: Finding) {
        Task { await model.setFinding(f.id, enabled: !f.enabled, in: entryID) }
    }

    private func copy() {
        switch state.copyTarget(liveTextSelection: liveText.selectedText) {
        case .text(let s):
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(s, forType: .string)
            localToast = LocalToast(text: String(localized: "Selected text copied."))
        case .clean: Task { await model.copy(entryID, original: false) }
        case .original: Task { await model.copy(entryID, original: true) }
        }
    }

    private func handleKey(_ key: ViewerKey) -> Bool {
        switch key {
        case .toggleMode: state.toggleMode()
        case .compare: state.toggleCompare()
        case .escape: if !state.handleEscape() { windowBox.close() }
        case .copy: copy()
        case .zoomIn: if state.canZoom { state.zoomIn() }
        case .zoomOut: if state.canZoom { state.zoomOut() }
        case .actualSize: if state.canZoom { state.actualSize() }
        case .fit: if state.canZoom { state.zoomToFit() }
        case .inspector: setInspector(!state.showsInspector)
        }
        return true
    }

    /// Live Text → a rule in the Journal, then the host recompiles the engine's catalogue.
    private func addRule(_ selection: String, _ intent: LiveTextRuleIntent) {
        Task { @MainActor in
            do {
                let outcome = try await LiveTextRules.add(selection, intent: intent, to: model.journal)
                let message = LiveTextRules.message(for: outcome, intent: intent)
                var undo: (() -> Void)?
                if case .added(let rule) = outcome {
                    await rulesChanged?()
                    let journal = model.journal, changed = rulesChanged
                    undo = {
                        Task { @MainActor in
                            try? await journal.deleteRule(rule.id)
                            await changed?()
                        }
                    }
                }
                localToast = LocalToast(text: message.text, undo: undo)
            } catch {
                localToast = LocalToast(text: String(localized: "Couldn't save the rule."))
            }
        }
    }
}

/// A toast this window raises itself (AppModel's toast has no public initializer).
struct LocalToast: Identifiable {
    let id = UUID()
    var text: String
    var undo: (() -> Void)?
}
