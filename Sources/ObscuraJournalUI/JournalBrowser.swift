// The centre: day-grouped grid (cards with corner badges) or list (rows with a "kept until" column), selection by
// click, ⌘-click and ⇧-click, arrow keys, double-click to the viewer, a context menu with every verb, and drag-out of
// the clean file.
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ObscuraUIKit
import ObscuraJournal
import ObscuraPrefs

/// The grid's column rule (G-19 #14): as many columns of at least `minCard` as the centre's width holds, so a Journal
/// window made larger shows more shots, and one made smaller never squeezes a card under its minimum.
enum JournalGrid {
    static let minCard: CGFloat = 150
    static let gap: CGFloat = 14
    static let sidePadding: CGFloat = 18

    static func columns(forWidth width: CGFloat) -> Int {
        guard width.isFinite else { return 1 }
        return max(1, Int((width - sidePadding * 2 + gap) / (minCard + gap)))
    }

    /// The centre's width in a Journal window of `windowWidth`: the sidebar, and the inspector when it shows, are fixed.
    static func centreWidth(windowWidth: CGFloat, showsInspector: Bool) -> CGFloat {
        let hairline = OMetric.hairline
        let sides = OMetric.journalSidebarWidth + hairline + (showsInspector ? OMetric.journalInspectorWidth + hairline : 0)
        return max(0, windowWidth - sides)
    }
}

struct JournalBrowser: View {
    @Bindable var controller: JournalController
    @Binding var selection: Set<UUID>

    private let gap = JournalGrid.gap
    private let sidePadding = JournalGrid.sidePadding

    var body: some View {
        GeometryReader { geo in
            let columns = JournalGrid.columns(forWidth: geo.size.width)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.groups) { group in
                        dayHeader(group)
                        if controller.viewMode == .grid {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap, alignment: .top), count: columns), spacing: gap) {
                                ForEach(group.entries) { card($0) }
                            }
                            .padding(.horizontal, sidePadding)
                            .padding(.top, 12)
                            .padding(.bottom, 16)
                        } else {
                            VStack(spacing: 2) {
                                ForEach(group.entries) { row($0) }
                            }
                            .padding(.horizontal, 10)
                            .padding(.top, 6)
                            .padding(.bottom, 12)
                        }
                    }
                }
                .frame(minHeight: geo.size.height, alignment: .top)
                .background {
                    // A click on empty space clears the selection.
                    Color.clear.contentShape(Rectangle()).onTapGesture { selection = [] }
                }
            }
            .onAppear { controller.gridColumns = columns }
            .onChange(of: columns) { _, c in controller.gridColumns = c }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(-1, vertical: false) }
        .onKeyPress(.rightArrow) { move(1, vertical: false) }
        .onKeyPress(.upArrow) { move(-1, vertical: true) }
        .onKeyPress(.downArrow) { move(1, vertical: true) }
        .onKeyPress(.return) {
            guard selection.count == 1, let id = selection.first else { return .ignored }
            controller.model.router?.openViewer(entryID: id)
            return .handled
        }
    }

    private func move(_ step: Int, vertical: Bool) -> KeyPress.Result {
        selection = controller.selection(moving: step, vertical: vertical, from: selection)
        return .handled
    }

    // MARK: Day header

    private func dayHeader(_ group: DayGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(JournalFormat.dayTitle(group.day, now: controller.now(), calendar: controller.calendar))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(OColor.text2)
            Text(controller.dayLine(group)).font(.system(size: 11, weight: .medium)).foregroundStyle(OColor.text3)
        }
        .padding(.horizontal, sidePadding)
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Card

    private func card(_ entry: Entry) -> some View {
        let selected = selection.contains(entry.id)
        let multi = selection.count > 1
        let verdict = controller.model.verdict(for: entry)
        return VStack(alignment: .leading, spacing: 7) {
            ShotImage(image: controller.image(for: entry))
                .frame(height: 112)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) { Badge(verdict.title, tone: verdict.tone, symbol: verdict.symbol).padding(6) }
                .overlay(alignment: .topLeading) {
                    if multi { SelectionMark(isOn: selected).padding(6) }
                }
            Text(entry.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OColor.text1)
                .lineLimit(1)
                .truncationMode(.middle)
            meta(entry)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).fill(selected ? OColor.selection : .clear))
        .overlay {
            if selected && !multi {
                RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).strokeBorder(OColor.accent, lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous))
        .modifier(EntryInteractions(controller: controller, entry: entry, selection: $selection))
        .task(id: entry.revision) { await controller.loadImage(for: entry) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(entry.displayName), \(verdict.title), \(ProtectionCopy.secrets(entry.findings.count))"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func meta(_ entry: Entry) -> some View {
        JournalMetaLine(controller: controller, entry: entry)
    }

    // MARK: Row

    private func row(_ entry: Entry) -> some View {
        let selected = selection.contains(entry.id)
        let verdict = controller.model.verdict(for: entry)
        return JournalListRow(controller: controller, entry: entry, selected: selected, multi: selection.count > 1)
            .modifier(EntryInteractions(controller: controller, entry: entry, selection: $selection))
            .task(id: entry.revision) { await controller.loadImage(for: entry) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(entry.displayName), \(verdict.title), \(ProtectionCopy.secrets(entry.findings.count))"))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// One list row: thumbnail, name and meta, verdict, kept-until. With several rows picked, the selection mark sits on
/// the thumbnail's corner as on grid cards (G-19 T-10, ruled 2026-10-27: "overlay"), so no row keeps an empty
/// slot for it and ⌘-clicking a second row shifts nothing; the mark fades in and out with the multi-selection.
struct JournalListRow: View {
    let controller: JournalController
    let entry: Entry
    let selected: Bool
    let multi: Bool

    /// The row's own padding, which is also where the thumbnail starts: nothing is reserved before it.
    static let horizontalPadding: CGFloat = 10

    var body: some View {
        let verdict = controller.model.verdict(for: entry)
        let expiry = JournalFormat.expiry(of: entry, retention: controller.retention)
        HStack(spacing: 12) {
            ShotImage(image: controller.image(for: entry), radius: OMetric.Radius.m)
                .frame(width: OMetric.thumbSmall.width, height: OMetric.thumbSmall.height)
                .overlay(alignment: .topLeading) {
                    SelectionMark(isOn: selected)
                        .padding(3)
                        .opacity(multi ? 1 : 0)
                        .oFade(value: multi)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName).font(.system(size: 12.5, weight: .medium)).foregroundStyle(OColor.text1)
                    .lineLimit(1).truncationMode(.middle)
                JournalMetaLine(controller: controller, entry: entry)
            }
            Spacer(minLength: 8)
            Badge(verdict.title, tone: verdict.tone, symbol: verdict.symbol)
            Text(JournalFormat.keptUntilShort(expiry, now: controller.now(), calendar: controller.calendar))
                .font(.system(size: 11)).foregroundStyle(OColor.text3)
                .frame(width: 150, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: OMetric.Radius.l, style: .continuous).fill(selected ? OColor.selection : .clear))
        .contentShape(Rectangle())
    }
}

/// The source symbol, secret count and when, under a card's or a row's name.
struct JournalMetaLine: View {
    let controller: JournalController
    let entry: Entry

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: JournalFormat.sourceSymbol(entry.source)).font(.system(size: 10))
            Text("\(ProtectionCopy.secrets(entry.findings.count)) · \(JournalFormat.cardWhen(entry.createdAt, now: controller.now(), calendar: controller.calendar))")
                .lineLimit(1)
        }
        .font(.system(size: 11))
        .foregroundStyle(OColor.text3)
    }
}

/// Click, ⌘/⇧-click, double-click, the context menu and drag-out, shared by cards and rows.
struct EntryInteractions: ViewModifier {
    let controller: JournalController
    let entry: Entry
    @Binding var selection: Set<UUID>

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 2) { controller.model.router?.openViewer(entryID: entry.id) }
            .simultaneousGesture(TapGesture().onEnded {
                let flags = NSEvent.modifierFlags
                selection = controller.selection(afterClicking: entry.id, in: selection,
                                                 command: flags.contains(.command), shift: flags.contains(.shift))
            })
            .accessibilityAction { controller.model.router?.openViewer(entryID: entry.id) }
            .contextMenu { menu }
            .onDrag { cleanFileProvider() }
    }

    /// The verbs, acting on the whole selection when this entry is part of it.
    @ViewBuilder private var menu: some View {
        let ids = selection.contains(entry.id) ? Array(selection) : [entry.id]
        let verdict = controller.model.verdict(for: entry)
        if ids.count == 1 {
            Button(String(localized: "Open")) { controller.model.router?.openViewer(entryID: entry.id) }
            Divider()
            Button(String(localized: "Copy Clean")) { Task { await controller.copyClean(entry.id) } }.disabled(!verdict.isSafe)
            Button(String(localized: "Copy Original")) { Task { await controller.copyOriginal(entry.id) } }
            Button(String(localized: "Copy As Shown")) { Task { await controller.copyAsShown(entry.id) } }
            Divider()
            if verdict.isSafe {
                Button(String(localized: "Restore Original")) { Task { await controller.restoreOriginals(ids) } }
            } else {
                Button(String(localized: "Black Out Again")) { Task { await controller.blackOutAll(ids) } }
                Button(String(localized: "Restore Original")) { Task { await controller.restoreOriginals(ids) } }
                    .disabled({ if case .originalShowing = verdict { return true } else { return false } }())
            }
            Button(String(localized: "Apply Default Style")) { Task { await controller.applyDefaultStyle(to: ids) } }
            Button(String(localized: "Show in Finder")) { Task { await controller.showInFinder(entry.id) } }
            Divider()
            Button(String(localized: "Delete"), role: .destructive) { Task { await controller.delete(ids) } }
        } else {
            Button(String(localized: "Restore Originals in \(ids.count)")) { Task { await controller.restoreOriginals(ids) } }
            Button(String(localized: "Black Out All in \(ids.count)")) { Task { await controller.blackOutAll(ids) } }
            Button(String(localized: "Apply Default Style")) { Task { await controller.applyDefaultStyle(to: ids) } }
            Divider()
            Button(String(localized: "Delete \(ids.count)"), role: .destructive) { Task { await controller.delete(ids) } }
        }
    }

    /// Dragging a card out hands over the clean file (never the original).
    private func cleanFileProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let journal = controller.model.journal
        let id = entry.id
        let type = UTType(entry.containerUTI) ?? .png
        provider.suggestedName = entry.displayName
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            Task {
                do { completion(try await journal.cleanURL(id), false, nil) } catch { completion(nil, false, error) }
            }
            return nil
        }
        return provider
    }
}
