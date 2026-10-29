// Detectors: ten category tiles that filter one grouped list, "N of N on", per-detector switches with severity
// marks and Opt-in / Edited badges, a detector opened to its patterns (plain words or regular expressions, one
// app-wide choice), and the sticky test footer. Design: rules.html, rules-final/NOTES.md.
import SwiftUI
import ObscuraUIKit
import ObscuraDetect
import ObscuraPrefs

enum DetectorFilter: Hashable { case all, edited, off }

struct DetectorsPane: View {
    let model: AppModel
    let session: SettingsSession

    @State private var tile: Detector.Category?
    @State private var filter: DetectorFilter = .all
    @State private var search = ""
    @State private var expanded: Set<String> = []
    @State private var openCategories: Set<Detector.Category> = []
    @FocusState private var searchFocused: Bool
    @Environment(\.settingsInitialState) private var initial

    private var regexMode: Bool { model.settings.showsPatterns(in: .detectors) }

    var body: some View {
        PaneScaffold(String(localized: "Detectors")) {
            ModePicker(model: model, pane: .detectors)
            TextField(String(localized: "Search detectors"), text: $search)
                .focused($searchFocused)
                .fieldChrome(focused: searchFocused)
                .frame(width: 160)
                .accessibilityLabel(Text("Search detectors"))
            Text(CountCopy.on(session.onCount, of: session.totalCount))
                .font(.system(size: 11.5)).foregroundStyle(OColor.text2).fixedSize()
        } content: {
            Lead(tone: session.onCount > 0 ? .ok : .needs,
                 title: String(localized: "\(session.onCount) of \(session.totalCount) detectors are on"),
                 detail: tile == nil
                    ? String(localized: "No tile picked, so every category is listed. Closed categories keep their count; open the ones you came for.")
                    : String(localized: "Thirteen are off by default because they match ordinary things like emails and IP addresses. Pick a category to see what it catches; switch off anything you don’t want hidden."))
            tiles
            filterLine
            list
            PatternDisplayOptions(model: model)
        } footer: {
            TestFooter(session: session, allowRuleMode: model.settings.allowRuleMode.detectMode,
                       showsPatternNumber: PatternDisplayOptions.showsPatternNumber(model.settings, regexMode: regexMode))
        }
        .onAppear {
            tile = initial.tile
            expanded = initial.expanded
            openCategories = initial.openCategories
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        let rows = [Array(CategoryCopy.ordered.prefix(5)), Array(CategoryCopy.ordered.dropFirst(5))]
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r], id: \.self) { c in categoryTile(c) }
                }
            }
        }
        .padding(.bottom, 10)
    }

    private func categoryTile(_ c: Detector.Category) -> some View {
        let detectors = session.detectors(in: c)
        let on = session.onCount(in: c)
        return OverviewTile(symbol: CategoryCopy.symbol(c), title: CategoryCopy.title(c), shortTitle: CategoryCopy.shortTitle(c),
                            count: CountCopy.on(on, of: detectors.count),
                            dots: detectors.map { session.isOn($0) ? .accent : .quiet },
                            selected: tile == c, dimmed: on == 0) {
            tile = tile == c ? nil : c
        }
    }

    private var filterLine: some View {
        HStack(spacing: 10) {
            PillTabs(items: [(DetectorFilter.all, String(localized: "All")),
                             (.edited, String(localized: "Edited \(session.editedCount)")),
                             (.off, String(localized: "Off \(session.offCount)"))],
                     selection: $filter)
            if let tile {
                Button { self.tile = nil } label: {
                    HStack(spacing: 6) {
                        Text("Showing") + Text(verbatim: " ") + Text(CategoryCopy.title(tile)).foregroundColor(OColor.accentText).bold()
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(OColor.accentText)
                    }
                    .font(.system(size: 12)).foregroundStyle(OColor.text1)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: OMetric.Radius.ml, style: .continuous).fill(OColor.accentSoft))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Showing \(CategoryCopy.title(tile)). Show every category"))
            }
            Spacer(minLength: 4)
            SeverityLegend()
        }
        .padding(.bottom, 10)
    }

    // MARK: List

    private func matches(_ d: Detector) -> Bool {
        switch filter {
        case .all: break
        case .edited: guard session.isEdited(d.id) else { return false }
        case .off: guard !session.isOn(d) else { return false }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return d.title.localizedCaseInsensitiveContains(q) || d.hint.localizedCaseInsensitiveContains(q)
            || CategoryCopy.title(d.category).localizedCaseInsensitiveContains(q)
    }

    @ViewBuilder private var list: some View {
        let categories = tile.map { [$0] } ?? CategoryCopy.ordered
        let narrowed = filter != .all || !search.trimmingCharacters(in: .whitespaces).isEmpty
        let shown = categories.compactMap { c -> CategoryRows? in
            let rows = session.detectors(in: c).filter(matches)
            return rows.isEmpty && narrowed ? nil : CategoryRows(category: c, rows: rows)
        }
        if shown.isEmpty {
            NoteBox(text: String(localized: "No detector matches. Clear the search or pick All."), symbol: "magnifyingglass")
        }
        ForEach(shown) { group in
            let c = group.category, rows = group.rows
            let open = tile != nil || narrowed || openCategories.contains(c)
            CategoryHeader(category: c, session: session, collapsible: tile == nil && !narrowed, open: open) {
                if openCategories.contains(c) { openCategories.remove(c) } else { openCategories.insert(c) }
            }
            if open, !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, d in
                        if i > 0 { RowDivider() }
                        DetectorRow(detector: d, session: session, open: expanded.contains(d.id)) {
                            if expanded.contains(d.id) { expanded.remove(d.id) } else { expanded.insert(d.id) }
                        }
                        if expanded.contains(d.id) {
                            RowDivider()
                            PatternEditor(detector: d, session: session, regexMode: regexMode)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).fill(OColor.card))
                .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).strokeBorder(OColor.separator, lineWidth: OMetric.hairline))
                .clipShape(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous))
                .padding(.bottom, 10)
            }
        }
    }
}

struct CategoryRows: Identifiable {
    let category: Detector.Category
    let rows: [Detector]
    var id: Detector.Category { category }
}

/// `.cath`: a category header with its disclosure, "N of N on" and a switch for the whole category.
struct CategoryHeader: View {
    let category: Detector.Category
    let session: SettingsSession
    var collapsible: Bool
    var open: Bool
    var toggle: () -> Void

    var body: some View {
        let detectors = session.detectors(in: category)
        let on = session.onCount(in: category)
        HStack(spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    if collapsible {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(OColor.text2).frame(width: 10)
                    }
                    Image(systemName: CategoryCopy.symbol(category)).font(.system(size: 12)).foregroundStyle(OColor.text2)
                    Text(CategoryCopy.title(category)).font(.system(size: 13, weight: .semibold)).foregroundStyle(OColor.text1)
                    Text(CountCopy.on(on, of: detectors.count)).font(.system(size: 11.5)).foregroundStyle(OColor.text2)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!collapsible)
            .accessibilityLabel(Text("\(CategoryCopy.title(category)), \(CountCopy.on(on, of: detectors.count))"))
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(collapsible ? Text(open ? "Expanded" : "Collapsed") : Text(verbatim: ""))
            AsyncSwitch(label: String(localized: "All \(CategoryCopy.title(category)) detectors"), isOn: on > 0, dense: true) { v in
                await session.setCategory(category, v)
            }
        }
        .padding(.leading, 2).padding(.trailing, 4).padding(.vertical, 6)
    }
}

/// `.drow`: severity, title, badges and the greyed example shape; the switch on the right. The row opens its patterns.
struct DetectorRow: View {
    let detector: Detector
    let session: SettingsSession
    var open: Bool
    var toggle: () -> Void

    var body: some View {
        let on = session.isOn(detector)
        HStack(spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    if let level = SeverityLevel.from(detector.severity) { SeverityMark(level) }
                    FlowLayout(spacing: 8, lineAlignment: .top) {
                        Text(detector.title).font(.system(size: 13)).foregroundStyle(on ? OColor.text1 : OColor.text2)
                        if session.isEdited(detector.id) { Badge(String(localized: "Edited"), tone: .accent) }
                        if !detector.enabledByDefault {
                            Badge(String(localized: "Opt-in"), tone: .quiet, textColor: OColor.text3)
                        }
                        Text(detector.hint).font(.system(size: 11, design: .monospaced)).foregroundStyle(OColor.text3)
                            .lineLimit(1).truncationMode(.tail).frame(maxWidth: 220, alignment: .leading)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(OColor.text3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilityTitle(on: on)))
            .accessibilityHint(Text(open ? "Hides the patterns" : "Shows the patterns"))
            AsyncSwitch(label: detector.title, isOn: on, dense: true) { v in await session.setEnabled(detector.id, v) }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(minHeight: 36)
    }

    private func accessibilityTitle(on: Bool) -> String {
        var parts = [detector.title]
        if let level = SeverityLevel.from(detector.severity) { parts.append(SeverityWords.title(level)) }
        if session.isEdited(detector.id) { parts.append(String(localized: "Edited")) }
        if !detector.enabledByDefault { parts.append(String(localized: "Opt-in")) }
        parts.append(on ? String(localized: "On") : String(localized: "Off"))
        return parts.joined(separator: ", ")
    }
}

/// The Plain words / Regular expressions control: one app-wide choice by default, or each pane's own
/// (`Settings.patternModeScope`, G-19 #2).
struct ModePicker: View {
    let model: AppModel
    let pane: PatternPane
    var body: some View {
        Picker(String(localized: "Show patterns as"), selection: Binding(
            get: { model.settings.showsPatterns(in: pane) },
            set: { v in model.updateSettings { $0.setShowsPatterns(v, in: pane) } })) {
            Text("Plain words").tag(false)
            Text("Regular expressions").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
    }
}

extension ObscuraPrefs.AllowRuleMode {
    /// The detection package's own copy of the same choice.
    var detectMode: ObscuraDetect.AllowRuleMode {
        switch self {
        case .trim: return .trim
        case .containedOnly: return .containedOnly
        }
    }
}
