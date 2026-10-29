// The window's frame: sidebar (sources, "By state", retention footer), the centre toolbar, the bottom bar and the
// selection bar, the empty state, the drop overlay and the undo ladder.
import AppKit
import SwiftUI
import ObscuraUIKit
import ObscuraJournal
import ObscuraPrefs

// MARK: - Sidebar

struct JournalSidebar: View {
    @Bindable var controller: JournalController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Room for the window's traffic lights (the window uses a hidden title bar).
            Color.clear.frame(height: 30)
            header(String(localized: "Library"))
            ForEach(SidebarItem.library) { row($0) }
            header(String(localized: "By state"))
            ForEach(SidebarItem.states) { row($0) }
            // G-13: the files Obscura could not check sit with the states, in the orange that needs you. The row is there
            // only while there is something to show (or while it is the section on screen), so the sidebar does not carry
            // a permanent zero for what is almost always nothing.
            if controller.showsNotChecked { row(.notChecked) }
            // Fail-open #7: files that still show what was caught, in the same orange, only while there is one.
            if controller.showsNotCovered { row(.notCovered) }
            Spacer(minLength: 8)
            footer
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(OColor.sidebar)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(OColor.text3)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ item: SidebarItem) -> some View {
        let selected = controller.sidebar == item
        let n = controller.count(item)
        return Button {
            controller.sidebar = item
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(item.tone.color)
                    .frame(width: 14)
                Text(item.title).font(OFont.body).foregroundStyle(OColor.text1).lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .layoutPriority(1)
                Spacer(minLength: 2)
                Text(n.formatted()).font(.system(size: 11).monospacedDigit()).foregroundStyle(OColor.text3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.ml, style: .continuous).fill(selected ? OColor.fill2 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(item.title), \(n)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "clock").font(.system(size: 11)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text("Originals: \(JournalFormat.retention(controller.retention))")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(OColor.text1)
                Text("Auto-deleted after that. Stored on this Mac only.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(OColor.text2)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: OMetric.Radius.l, style: .continuous).fill(OColor.fill))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Toolbar

struct JournalToolbar: View {
    @Bindable var controller: JournalController
    @Binding var selection: Set<UUID>
    var onImport: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let notChecked = controller.sidebar.listsFiles
        let single = selection.count == 1 && !notChecked ? controller.entry(selection.first!) : nil
        HStack(spacing: 12) {
            Text(controller.sidebar.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
            if !notChecked {
                Picker(String(localized: "View as"), selection: Binding(get: { controller.viewMode }, set: { controller.setViewMode($0) })) {
                    Image(systemName: "square.grid.2x2").accessibilityLabel(Text("Grid")).tag(JournalView.grid)
                    Image(systemName: "list.bullet").accessibilityLabel(Text("List")).tag(JournalView.list)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(String(localized: "Show as grid or list"))
            }
            Spacer(minLength: 0)
            // At the default 1040 × 660 the centre is 550 wide: the stats line shows when it fits, the search field
            // gives up width before it does, and below that only the search field stays.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { stats; searchField(width: 220) }
                HStack(spacing: 12) { stats; searchField(width: 150) }
                searchField(width: 180)
                searchField(width: 110)
            }
            if notChecked {
                // The section's rows carry their own verbs; the catches' verbs and the inspector have nothing to act on.
                IconButton(symbol: "square.and.arrow.down", label: importLabel, action: onImport)
            } else {
                entryButtons(single: single)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(OColor.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(OColor.separator).frame(height: OMetric.hairline) }
        .onChange(of: searchFocused) { _, focused in controller.searchFocused = focused }
    }

    private var keys: KeyBindings { controller.model.settings.keyBindings }
    private var importLabel: String { ShortcutText.withChord(String(localized: "Import Images…"), .journalImport, keys) }

    private func entryButtons(single: Entry?) -> some View {
        HStack(spacing: 2) {
            IconButton(symbol: "square.and.arrow.down", label: importLabel, action: onImport)
            IconButton(symbol: "doc.on.doc", label: ShortcutText.withChord(String(localized: "Copy Clean"), .journalCopyClean, keys)) {
                if let single { Task { await controller.copyClean(single.id) } }
            }
            .disabled(single.map { !controller.model.verdict(for: $0).isSafe } ?? true)
            IconButton(symbol: "eye", label: String(localized: "Peek at the Original"), isOn: controller.peekLatched) {
                controller.peekLatched.toggle()
            }
            .disabled(single == nil)
            IconButton(symbol: "trash", label: ShortcutText.withChord(String(localized: "Delete"), .journalDelete, keys)) {
                let ids = Array(selection)
                Task { await controller.delete(ids) }
            }
            .disabled(selection.isEmpty)
            IconButton(symbol: "sidebar.right", label: String(localized: "Show or Hide the Inspector"), isOn: controller.showsInspector) {
                controller.setShowsInspector(!controller.showsInspector)
            }
        }
    }

    private var stats: some View {
        Text(controller.statsLine).font(.system(size: 12)).foregroundStyle(OColor.text2).lineLimit(1).fixedSize()
    }

    private func searchField(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(OColor.text3)
            TextField(String(localized: "Search file names"), text: $controller.search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onExitCommand { controller.search = ""; searchFocused = false }
            if !controller.search.isEmpty {
                Button { controller.search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(OColor.text3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: 24)
        .background(RoundedRectangle(cornerRadius: OMetric.Radius.ml, style: .continuous).fill(OColor.fill))
        .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.ml, style: .continuous).strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
    }
}

// MARK: - Bottom bars

struct JournalBottomBar: View {
    @Bindable var controller: JournalController
    @Binding var selection: Set<UUID>

    var body: some View {
        Group {
            if selection.count > 1 && !controller.sidebar.listsFiles { selectionBar } else { retentionBar }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 37)
        .overlay(alignment: .top) { Rectangle().fill(OColor.separator).frame(height: OMetric.hairline) }
    }

    private var retentionBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock").font(.system(size: 12))
            ViewThatFits(in: .horizontal) {
                retentionLine(String(localized: "Nothing leaves this Mac · originals deleted after \(JournalFormat.retention(controller.retention)) ·"))
                retentionLine(String(localized: "Originals deleted after \(JournalFormat.retention(controller.retention)) ·"))
                retentionLine(nil)
            }
            Spacer(minLength: 8)
            Button(String(localized: "Open originals folder")) { Task { await controller.openOriginalsFolder() } }
                .buttonStyle(OButtonStyle(.plain, size: .small))
        }
        .foregroundStyle(OColor.text2)
        .background(OColor.sidebar.padding(.horizontal, -14).padding(.vertical, -8))
    }

    private func retentionLine(_ lead: String?) -> some View {
        HStack(spacing: 4) {
            if let lead { Text(lead).lineLimit(1).fixedSize() }
            Text("\(controller.allEntries.count) stored").fontWeight(.medium).foregroundStyle(OColor.text1).fixedSize()
        }
    }

    private var selectionBar: some View {
        let ids = Array(selection)
        let n = ids.count
        return HStack(spacing: 6) {
            Text("\(n) of \(controller.visibleEntries.count) selected")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(OColor.accentText).fixedSize()
            Spacer(minLength: 8)
            // The short verbs from the mockup; when the window is narrow the disabled Copy goes first, then the
            // verbs shorten (the inspector keeps the full words).
            ViewThatFits(in: .horizontal) {
                batchButtons(ids, short: false, showsCopy: true)
                batchButtons(ids, short: false, showsCopy: false)
                batchButtons(ids, short: true, showsCopy: false)
            }
        }
        .foregroundStyle(OColor.text1)
        .background(OColor.accentSoft.padding(.horizontal, -14).padding(.vertical, -8))
    }
}

extension JournalBottomBar {
    func batchButtons(_ ids: [UUID], short: Bool, showsCopy: Bool) -> some View {
        let n = ids.count
        return HStack(spacing: 6) {
            Button(short ? String(localized: "Restore \(n)") : String(localized: "Restore Originals in \(n)")) {
                Task { await controller.restoreOriginals(ids) }
            }
            .buttonStyle(OButtonStyle(.quiet, size: .small))
            .help(String(localized: "Restore Originals in \(n)"))
            Button(short ? String(localized: "Black Out \(n)") : String(localized: "Black Out All in \(n)")) {
                Task { await controller.blackOutAll(ids) }
            }
            .buttonStyle(OButtonStyle(.quiet, size: .small))
            .help(String(localized: "Black Out All in \(n)"))
            Button(short ? String(localized: "Default Style") : String(localized: "Apply Default Style")) {
                Task { await controller.applyDefaultStyle(to: ids) }
            }
            .buttonStyle(OButtonStyle(.quiet, size: .small))
            .help(String(localized: "Apply Default Style"))
            Button(String(localized: "Delete \(n)")) { Task { await controller.delete(ids) } }
                .buttonStyle(OButtonStyle(.danger, size: .small))
            if showsCopy {
                Button(String(localized: "Copy")) {}
                    .buttonStyle(OButtonStyle(.quiet, size: .small))
                    .disabled(true)
                    .help(String(localized: "Select one screenshot to copy"))
            }
        }
        .fixedSize()
    }
}

// MARK: - Empty states

/// No entries at all: what the Journal keeps, for how long, and how to import.
struct JournalEmptyState: View {
    var retention: JournalRetention
    /// Import's current shortcut ("⌘O"); nil when the person cleared it, and the line then ends at "redact them".
    var importChord: String?
    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OColor.accentSoft)
                .frame(width: 68, height: 68)
                .overlay(Image(systemName: "checkmark.shield").font(.system(size: 30, weight: .regular)).foregroundStyle(OColor.accent))
                .accessibilityHidden(true)
            Text("Nothing caught yet").font(.system(size: 17, weight: .semibold)).foregroundStyle(OColor.text1)
            Text("When Obscura blacks out a secret, the original is kept here for \(JournalFormat.retention(retention)) so you can undo. Clean screenshots are never stored.")
                .font(.system(size: 12.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 12))
                if let importChord {
                    Text("Drop images here to redact them, or press")
                    KeyCap(importChord).accessibilityHidden(true)
                } else {
                    Text("Drop images here to redact them.")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous)
                .strokeBorder(OColor.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .padding(.top, 6)
            Text("Nothing leaves this Mac. Originals live in your Library, readable by you alone.")
                .font(.system(size: 11.5))
                .foregroundStyle(OColor.text3)
                .padding(.top, 4)
        }
        .foregroundStyle(OColor.text2)
        .padding(.horizontal, 20)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Entries exist but the filter or search hides them all.
struct JournalNoMatches: View {
    var sidebar: SidebarItem
    var search: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: search.isEmpty ? sidebar.symbol : "magnifyingglass")
                .font(.system(size: 24)).foregroundStyle(OColor.text3)
                .accessibilityHidden(true)
            Text(search.isEmpty ? String(localized: "Nothing in \(sidebar.title)") : String(localized: "No file names match “\(search)”"))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(OColor.text1)
            Text(search.isEmpty ? String(localized: "Catches from this source or in this state appear here.")
                                : String(localized: "Search looks at file names only, never at the secrets."))
                .font(.system(size: 12)).foregroundStyle(OColor.text2)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Overlays

/// The whole-window drop target.
struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: OMetric.Radius.xxl, style: .continuous)
            .fill(OColor.accentSoft)
            .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.xxl, style: .continuous)
                .strokeBorder(OColor.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
            .overlay {
                VStack(spacing: 2) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 18)).foregroundStyle(OColor.accent)
                    Text("Drop images to redact them").font(.system(size: 14, weight: .semibold)).foregroundStyle(OColor.text1).padding(.top, 6)
                    Text("Originals are not changed. Already-journaled files are skipped.").font(.system(size: 12)).foregroundStyle(OColor.text2)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: OMetric.Radius.xxl, style: .continuous).fill(OColor.popover))
                .shadow(color: .black.opacity(0.2), radius: 17, y: 12)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
    }
}

/// Up to three toasts, newest on top, right-aligned under the toolbar; each change that can be undone carries its own
/// Undo. Drawn by the shared `ToastStack`: they appear and leave with the one fade, never a slide (G-15, T-7).
struct UndoLadder: View {
    var controller: JournalController
    var body: some View { ToastStack(items, placement: .ladder) }

    var items: [ToastItem] {
        controller.ladder.map { item in
            guard item.undo != nil else { return ToastItem(id: item.id, text: item.text) }
            return ToastItem(id: item.id, text: item.text, actionTitle: ShortcutText.trailing(String(localized: "Undo"), .journalUndo, controller.model.settings.keyBindings)) { [controller] in
                Task { await controller.undo(item.id) }
            }
        }
    }
}
