// ObscuraSettingsUI — the Settings window (design/mockups/unified/settings.html and rules.html): 880 × 620 for every
// pane, a 236 pt sidebar of coloured tiles whose items carry their current values, and the foot strip that always says
// the protection state, "Nothing leaves this Mac" and how long originals are kept.
public import SwiftUI
public import ObscuraUIKit
import ObscuraCapture
import ObscuraDetect
import ObscuraEngine
import ObscuraPrefs

/// The Settings window's content. The app target hosts it in its Settings scene at `OMetric.settingsSize`.
public struct SettingsWindow: View {
    let model: AppModel
    @Binding var pane: SettingsPane
    let services: SystemServices
    private var catalogueChanged: (@MainActor () -> Void)?

    @State private var session: SettingsSession
    @State private var system: SystemSnapshot
    @State private var search = ""
    @FocusState private var sidebarFocused: Bool

    public init(model: AppModel, pane: Binding<SettingsPane>) {
        self.init(model: model, pane: pane, services: .live, snapshot: nil)
    }

    init(model: AppModel, pane: Binding<SettingsPane>, services: SystemServices, snapshot: SystemSnapshot?) {
        self.model = model
        self._pane = pane
        self.services = services
        self._session = State(initialValue: SettingsSession(journal: model.journal))
        self._system = State(initialValue: snapshot ?? .placeholder)
    }

    /// Runs `action` after every change to detectors, overrides or custom rules, so the app can ask the engine to
    /// recompile its catalogue (`ShieldEngine.catalogueChanged()`). The engine reads these lists only at compile time.
    public func onCatalogueChange(_ action: @escaping @MainActor () -> Void) -> SettingsWindow {
        var copy = self
        copy.catalogueChanged = action
        return copy
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: OMetric.settingsSidebarWidth)
                .background(OColor.sidebar)
            Rectangle().fill(OColor.separator).frame(width: OMetric.hairline)
            paneView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(OColor.window)
        }
        .frame(width: OMetric.settingsSize.width, height: OMetric.settingsSize.height)
        .background(OColor.window)
        .oToasts(noticeItems, placement: .bottom, expire: { id in if id == session.noticeID { session.notice = nil } })
        .task {
            session.onCatalogueChange = { [catalogueChanged] in catalogueChanged?() }
            await session.load()
        }
        .task(id: probeKey) {
            // The screenshot folder and folder grants have no change notification: re-read while the window is open.
            while !Task.isCancelled {
                let snapshot = await services.snapshot(model.settings.extraFolders, model.settings.guardsDownloads)
                if snapshot != system { system = snapshot }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var probeKey: [String] { model.settings.extraFolders + [model.settings.guardsDownloads ? "d1" : "d0"] }

    func refreshSystem() async {
        system = await services.snapshot(model.settings.extraFolders, model.settings.guardsDownloads)
    }

    // MARK: Panes

    @ViewBuilder private var paneView: some View {
        if pane.usesJournalLists, !session.loaded {
            // Never show default lists the user could edit over the stored ones.
            VStack(spacing: 10) {
                if session.loadFailed {
                    Text("Couldn’t read your detector and rule settings.").font(OFont.body).foregroundStyle(OColor.text2)
                    Button(String(localized: "Try Again")) { Task { await session.load() } }.buttonStyle(OButtonStyle(.quiet, size: .small))
                } else {
                    DelayedProgress()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            loadedPane
        }
    }

    @ViewBuilder private var loadedPane: some View {
        switch pane {
        case .protection:
            ProtectionPane(model: model, system: system, services: services, refresh: { await refreshSystem() })
        case .detectors:
            DetectorsPane(model: model, session: session)
        case .redactionStyle:
            StylePane(session: session)
        case .customRules:
            RulesPane(model: model, session: session)
        case .journalPrivacy:
            JournalPrivacyPane(model: model, session: session, services: services)
        case .shortcuts:
            ShortcutsPane(model: model)
        case .about:
            AboutPane(model: model, system: system, services: services, refresh: { await refreshSystem() })
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(OColor.text3)
                TextField(String(localized: "Search"), text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .accessibilityLabel(Text("Search settings"))
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.ml, style: .continuous).fill(OColor.fill))
            .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.ml, style: .continuous).strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
            .padding(.bottom, 8)
            .padding(.top, 30)

            VStack(spacing: 2) {
                ForEach(visiblePanes) { item in sidebarItem(item) }
            }
            .focusable()
            .focused($sidebarFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { step(-1) }
            .onKeyPress(.downArrow) { step(1) }

            Spacer(minLength: 8)
            footStrip
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var visiblePanes: [SettingsPane] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return SettingsPane.allCases }
        return SettingsPane.allCases.filter { p in SidebarCopy.keywords(p).contains { $0.lowercased().contains(q) } }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        let panes = visiblePanes
        guard let i = panes.firstIndex(of: pane) else { return .ignored }
        let next = i + delta
        guard panes.indices.contains(next) else { return .handled }
        pane = panes[next]
        return .handled
    }

    private func sidebarItem(_ item: SettingsPane) -> some View {
        let selected = item == pane
        return Button { pane = item } label: {
            HStack(spacing: 9) {
                SymbolTile(SidebarCopy.symbol(item), color: SidebarCopy.color(item))
                VStack(alignment: .leading, spacing: 1) {
                    Text(SidebarCopy.title(item)).font(.system(size: 13)).foregroundStyle(OColor.text1).lineLimit(1)
                    Text(value(for: item)).font(.system(size: 11)).foregroundStyle(OColor.text2).lineLimit(1)
                }
                Spacer(minLength: 4)
                if needsAttention(item) { StatusDot(.needs) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.ml, style: .continuous).fill(selected ? OColor.fill2 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(SidebarCopy.title(item)), \(value(for: item))\(needsAttention(item) ? String(localized: ", needs attention") : "")"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The current value under each sidebar item.
    func value(for item: SettingsPane) -> String {
        let s = model.settings
        switch item {
        case .protection:
            if isPaused { return ProtectionCopy.title(.paused) }
            return String(localized: "\(ProtectionFacts.sourcesOn(s)) of 4 sources on")
        case .detectors:
            return CountCopy.on(session.onCount, of: session.totalCount)
        case .redactionStyle:
            return StyleCopy.summary(session.defaultStyle)
        case .customRules:
            return CountCopy.rulesSidebar(blackOut: session.blackOutRules.count, never: session.allowRules.count)
        case .journalPrivacy:
            return String(localized: "Originals kept \(RetentionCopy.duration(s.journalRetention))")
        case .shortcuts:
            return ShortcutsCopy.sidebarValue(changed: s.keyBindings.changedCount)
        case .about:
            let v = BuildInfo.version.map { "\($0) · " } ?? ""
            if let offer = model.updateOffer { return v + String(localized: "\(offer.version) ready") }
            return v + (s.updatesCheckAutomatically ? String(localized: "up to date") : String(localized: "checks off"))
        }
    }

    /// One rule (CHANGES.md 24): a trailing orange dot only on a pane holding an unfixed problem.
    func needsAttention(_ item: SettingsPane) -> Bool {
        switch item {
        case .protection: return ProtectionFacts.foldersNeedingYou(model.settings, system, unconfirmed: model.unconfirmedFolders) > 0
        case .about: return system.loginItem == .requiresApproval
        default: return false
        }
    }

    private var isPaused: Bool {
        if case .paused = model.status.protection { return true }
        return model.settings.protectionPaused
    }

    // MARK: Foot strip

    private var footStrip: some View {
        let state: ProtectionState = isPaused ? .paused : model.status.protection
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                StatusDot(ProtectionCopy.tone(state, pausedColor: model.settings.pausedColor)).frame(width: 13)
                Text(ProtectionCopy.title(state))
            }
            HStack(spacing: 7) {
                Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(OColor.text3).frame(width: 13)
                Text("Nothing leaves this Mac")
            }
            HStack(spacing: 7) {
                Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(OColor.text3).frame(width: 13)
                Text(RetentionCopy.deletedAfter(model.settings.journalRetention))
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(OColor.text2)
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(OColor.separator).frame(height: OMetric.hairline) }
        .accessibilityElement(children: .combine)
    }

    // MARK: Notice toast

    /// The session's notice as this window's one toast: bottom centre, the one lifetime and fade (G-15). OK dismisses
    /// it early.
    private var noticeItems: [ToastItem] {
        guard let notice = session.notice else { return [] }
        return [ToastItem(id: session.noticeID, text: notice, actionTitle: String(localized: "OK")) { session.notice = nil }]
    }
}

extension SettingsPane {
    /// Panes that edit the lists stored in the Journal (detector state, overrides, rules, the default style).
    var usesJournalLists: Bool { self == .detectors || self == .customRules || self == .redactionStyle }
}

/// Sidebar titles, tiles and search words.
enum SidebarCopy {
    static func title(_ p: SettingsPane) -> String {
        switch p {
        case .protection: return String(localized: "Protection")
        case .detectors: return String(localized: "Detectors")
        case .redactionStyle: return String(localized: "Redaction Style")
        case .customRules: return String(localized: "Custom Rules")
        case .journalPrivacy: return String(localized: "Journal & Privacy")
        case .shortcuts: return String(localized: "Keyboard Shortcuts")
        case .about: return String(localized: "About")
        }
    }

    static func symbol(_ p: SettingsPane) -> String {
        switch p {
        case .protection: return "checkmark.shield"
        case .detectors: return "slider.horizontal.3"
        case .redactionStyle: return "paintbrush"
        case .customRules: return "pencil"
        case .journalPrivacy: return "book"
        case .shortcuts: return "keyboard"
        case .about: return "info"
        }
    }

    static func color(_ p: SettingsPane) -> Color {
        switch p {
        case .protection: return OColor.SettingsTile.protection
        case .detectors: return OColor.SettingsTile.detectors
        case .redactionStyle: return OColor.SettingsTile.style
        case .customRules: return OColor.SettingsTile.rules
        case .journalPrivacy: return OColor.SettingsTile.journal
        case .shortcuts: return OColor.SettingsTile.shortcuts
        case .about: return OColor.SettingsTile.about
        }
    }

    static func keywords(_ p: SettingsPane) -> [String] {
        let words: [String]
        switch p {
        case .protection: words = [String(localized: "screenshot folder downloads clipboard folders notification thumbnail pause replace")]
        case .detectors: words = [String(localized: "detectors patterns regex regular expression keys tokens categories")]
        case .redactionStyle: words = [String(localized: "style colour color blur mosaic erase solid corners padding label")]
        case .customRules: words = [String(localized: "custom rules never black out allow import export")]
        case .journalPrivacy: words = [String(localized: "journal privacy originals retention delete folder online")]
        case .shortcuts: words = [String(localized: "keyboard shortcuts keys key bindings hotkeys commands record reset")]
        case .about: words = [String(localized: "about version updates login theme language menu bar icon mark colour feedback open source")]
        }
        return [title(p)] + words
    }
}

/// Facts about the capture paths that the sidebar, the headline and the Protection pane share.
enum ProtectionFacts {
    /// Screenshot folder, Downloads, Clipboard and the extra folders (as one source).
    static func sourcesOn(_ s: ObscuraPrefs.Settings) -> Int {
        [s.guardsScreenshotFolder, s.guardsDownloads, s.guardsClipboard, !s.extraFolders.isEmpty].filter { $0 }.count
    }

    /// Folders that are switched on but cannot be read, or that the person has not confirmed in Obscura (G-36).
    static func foldersNeedingYou(_ s: ObscuraPrefs.Settings, _ system: SystemSnapshot, unconfirmed: Set<String> = []) -> Int {
        var n = 0
        if s.guardsScreenshotFolder, system.screenshotAccess != .granted { n += 1 }
        if s.guardsDownloads, system.downloadsAccess != .granted || unconfirmed.contains(system.downloads.standardizedFileURL.path) { n += 1 }
        n += s.extraFolders.filter {
            (system.folderAccess[$0] ?? .granted) != .granted || unconfirmed.contains(URL(fileURLWithPath: $0).standardizedFileURL.path)
        }.count
        return n
    }
}

/// View state a preview or snapshot test can open the panes in (a picked tile, an open detector, an open rule editor).
/// The app never sets it; every pane starts closed.
struct SettingsInitialState {
    var tile: Detector.Category?
    var expanded: Set<String> = []
    var openCategories: Set<Detector.Category> = []
    var ruleDraft: RuleDraft?
    var testLine = ""
}

extension EnvironmentValues {
    @Entry var settingsInitialState = SettingsInitialState()
}
