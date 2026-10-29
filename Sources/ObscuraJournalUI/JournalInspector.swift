// The right inspector: for one entry the preview with press-and-hold peek, the status row, the Black out checklist,
// Style, Details, the four main buttons, the More list and the retention line; for several, the stacked preview, the
// combined status and the batch verbs; for none, a prompt.
import AppKit
import SwiftUI
import ObscuraUIKit
import ObscuraJournal
import ObscuraPrefs

struct JournalInspector: View {
    @Bindable var controller: JournalController
    @Binding var selection: Set<UUID>
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let selected = controller.entries(selection)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if selected.count == 1, let entry = selected.first {
                    SingleInspector(controller: controller, entry: entry)
                } else if selected.count > 1 {
                    MultiInspector(controller: controller, entries: selected)
                } else {
                    Text(controller.allEntries.isEmpty ? String(localized: "Catches appear here.") : String(localized: "Select a screenshot to see what was blacked out."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(OColor.text3)
                        .frame(maxWidth: .infinity, minHeight: 160)
                        .multilineTextAlignment(.center)
                }
                RetentionNote(controller: controller, entry: selected.count == 1 ? selected.first : nil)
            }
            .padding(14)
        }
        .scrollIndicators(.automatic)
        .background(OColor.window)
    }
}

// MARK: - One entry

struct SingleInspector: View {
    @Bindable var controller: JournalController
    let entry: Entry
    private var keys: KeyBindings { controller.model.settings.keyBindings }

    var body: some View {
        let verdict = controller.model.verdict(for: entry)
        Group {
            PeekPreview(controller: controller, entry: entry)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(OColor.text1)
                    .lineLimit(1).truncationMode(.middle)
                Text(JournalFormat.subtitle(entry, now: controller.now())).font(.system(size: 11.5)).foregroundStyle(OColor.text3)
            }
            .accessibilityElement(children: .combine)
            StatusBox(verdict)
            findings
            style
            details(verdict)
            MainButtons(controller: controller, entry: entry, verdict: verdict)
            moreList(verdict)
        }
        .task(id: entry.id) {
            await controller.loadFileSize(for: entry)
        }
    }

    // MARK: Black out checklist

    private var findings: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(String(localized: "Black out"), symbol: "checkmark.shield") {
                HStack(spacing: 8) {
                    Button(String(localized: "Select All")) { Task { await controller.setAllFindings(in: entry.id, enabled: true) } }
                        .disabled(entry.findings.allSatisfy(\.enabled))
                    Button(String(localized: "Deselect All")) { Task { await controller.setAllFindings(in: entry.id, enabled: false) } }
                        .disabled(entry.findings.allSatisfy { !$0.enabled })
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(OColor.accentText)
            }
            VStack(spacing: 0) {
                ForEach(entry.findings.sorted { $0.lineIndex < $1.lineIndex }) { finding in
                    FindingRow(finding: finding) { Task { await controller.toggleFinding(finding, in: entry.id) } }
                    if let state = controller.keyTextState(for: finding) {
                        // Under the row, aligned with its name (checkbox 14 + tile 22 + two 8 pt gaps + the row's 7 pt inset).
                        UncoveredKeyField(state: state) { controller.copyKeyText(finding.id) }
                            .padding(.leading, 59).padding(.trailing, 7).padding(.bottom, 6)
                            .task(id: finding.id) { controller.requestKeyText(finding, in: entry.id) }
                    }
                }
            }
        }
    }

    // MARK: Style

    private var style: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { controller.styleExpanded.toggle() } label: {
                SectionHeader(String(localized: "Style"), symbol: "paintbrush.pointed") {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(OColor.text3)
                        .rotationEffect(.degrees(controller.styleExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Style"))
            .accessibilityValue(Text(controller.styleExpanded ? "Expanded" : "Collapsed"))
            if controller.styleExpanded {
                StyleEditor(controller: controller, entry: entry)
            }
        }
    }

    // MARK: Details

    private func details(_ verdict: Verdict) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { controller.detailsExpanded.toggle() } label: {
                SectionHeader(String(localized: "Details"), symbol: "info.circle", shortcut: keys.display(for: .journalShowDetails)) {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(OColor.text3)
                        .rotationEffect(.degrees(controller.detailsExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Details"))
            .accessibilityValue(Text(controller.detailsExpanded ? "Expanded" : "Collapsed"))
            if controller.detailsExpanded {
                let detectorCount = Set(entry.findings.flatMap(\.detectorIDs)).count
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                    detailRow(String(localized: "Source"), JournalFormat.sourceName(entry.source))
                    detailRow(String(localized: "Location"), JournalFormat.location(entry))
                    detailRow(String(localized: "Date"), JournalFormat.detailDate(entry.createdAt, now: controller.now(), calendar: controller.calendar))
                    detailRow(String(localized: "Kind"), JournalFormat.kindLine(entry, bytes: controller.fileSizes[entry.id]))
                    detailRow(String(localized: "Secrets"), JournalFormat.foundBy(secrets: entry.findings.count, detectors: detectorCount))
                    GridRow {
                        Text("Status").foregroundStyle(OColor.text3).frame(width: 72, alignment: .leading)
                        Text(verdict.title).foregroundStyle(verdict.isSafe ? OColor.text1 : verdict.tone.text)
                    }
                }
                .font(.system(size: 12))
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(OColor.text3).frame(width: 72, alignment: .leading)
            Text(value).foregroundStyle(OColor.text1).lineLimit(2).textSelection(.enabled)
        }
    }

    // MARK: More

    private func moreList(_ verdict: Verdict) -> some View {
        let original: Bool = { if case .originalShowing = verdict { return true } else { return false } }()
        let leftVisible: Bool = { if case .leftVisible = verdict { return true } else { return false } }()
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(String(localized: "More"), symbol: "slider.horizontal.3")
            VStack(spacing: 0) {
                if !original {
                    ActionRow(symbol: "doc.on.doc", title: String(localized: "Copy Original"), shortcut: keys.display(for: .journalCopyOriginal)) {
                        Task { await controller.copyOriginal(entry.id) }
                    }
                }
                ActionRow(symbol: "doc.on.doc", title: String(localized: "Copy As Shown"), shortcut: keys.display(for: .journalCopyAsShown)) {
                    Task { await controller.copyAsShown(entry.id) }
                }
                if leftVisible {
                    ActionRow(symbol: "folder", title: String(localized: "Show in Finder")) {
                        Task { await controller.showInFinder(entry.id) }
                    }
                }
                ActionRow(symbol: "arrow.uturn.backward", title: String(localized: "Undo"), shortcut: keys.display(for: .journalUndo)) {
                    Task { await controller.undoLatest() }
                }
                .disabled(!controller.canUndo)
            }
        }
    }
}

/// One finding: checkbox, detector tile, full detector name and what a click does.
struct FindingRow: View {
    let finding: Finding
    let toggle: () -> Void

    var body: some View {
        let id = finding.detectorIDs.first ?? ""
        let name = DetectorNames.title(for: id)
        Button(action: toggle) {
            HStack(spacing: 8) {
                Checkbox(isOn: finding.enabled)
                CategoryTile(category: finding.category, detectorID: id)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 12.5)).foregroundStyle(OColor.text1).lineLimit(1)
                    Text(finding.enabled ? String(localized: "Blacked out. Click to leave it visible.") : String(localized: "Visible. Click to black it out."))
                        .font(.system(size: 11))
                        .foregroundStyle(finding.enabled ? OColor.text3 : OColor.needsText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.ml, style: .continuous).fill(finding.enabled ? .clear : OColor.needsSoft))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text(finding.enabled ? String(localized: "Blacked out") : String(localized: "Left visible")))
        .accessibilityHint(Text(finding.enabled ? String(localized: "Leaves it visible") : String(localized: "Blacks it out")))
        .accessibilityAddTraits(.isToggle)
    }
}

/// A row in the More list.
struct ActionRow: View {
    var symbol: String
    var title: String
    var shortcut: String?
    var role: Role = .normal
    var action: () -> Void
    enum Role { case normal, danger }
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(role == .danger ? OColor.liveText : OColor.text2).frame(width: 14)
                Text(title).font(.system(size: 12.5)).foregroundStyle(role == .danger ? OColor.liveText : OColor.text1)
                Spacer(minLength: 4)
                if let shortcut { Text(shortcut).font(.system(size: 11)).foregroundStyle(OColor.text3) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}

/// The four main verbs as buttons; which four depends on what the file holds.
struct MainButtons: View {
    let controller: JournalController
    let entry: Entry
    let verdict: Verdict

    var body: some View {
        FlowLayout(spacing: 6) {
            switch verdict {
            case .safeToShare:
                button(String(localized: "Copy Clean"), "doc.on.doc", .primary) { await controller.copyClean(entry.id) }
                button(String(localized: "Restore Original"), "arrow.uturn.backward", .quiet) { await controller.restoreOriginals([entry.id]) }
                button(String(localized: "Show in Finder"), "folder", .quiet) { await controller.showInFinder(entry.id) }
            case .leftVisible:
                button(String(localized: "Black Out All"), "checkmark.shield", .primary) { await controller.blackOutAll([entry.id]) }
                button(String(localized: "Copy Clean"), "doc.on.doc", .quiet) { await controller.copyClean(entry.id) }
                    .disabled(true)
                    .opacity(0.45) // OButtonStyle has no disabled look yet (kit gap)
                    .help(String(localized: "Black out every secret first, or use Copy As Shown."))
                button(String(localized: "Restore Original"), "arrow.uturn.backward", .quiet) { await controller.restoreOriginals([entry.id]) }
            case .originalShowing:
                button(String(localized: "Black Out Again"), "checkmark.shield", .primary) { await controller.blackOutAll([entry.id]) }
                button(String(localized: "Copy Original"), "doc.on.doc", .danger) { await controller.copyOriginal(entry.id) }
                button(String(localized: "Show in Finder"), "folder", .quiet) { await controller.showInFinder(entry.id) }
            }
            button(String(localized: "Delete"), "trash", .danger) { await controller.delete([entry.id]) }
        }
    }

    private func button(_ title: String, _ symbol: String, _ role: OButtonStyle.Role, _ action: @escaping @MainActor () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Label { Text(title) } icon: { Image(systemName: symbol).font(.system(size: 11.5)) }
                .labelStyle(TightLabelStyle())
        }
        .buttonStyle(OButtonStyle(role))
    }
}

struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon; configuration.title }
    }
}

/// The preview with press-and-hold peek. Holding (or the toolbar's Peek switch) shows the original, marked in red.
struct PeekPreview: View {
    @Bindable var controller: JournalController
    let entry: Entry
    @State private var pressing = false

    var body: some View {
        let peeking = controller.isPeeking
        let image = peeking ? (controller.image(for: entry, original: true) ?? controller.image(for: entry)) : controller.image(for: entry)
        let aspect = entry.pixelHeight > 0 ? CGFloat(entry.pixelWidth) / CGFloat(entry.pixelHeight) : 1.6
        ZStack(alignment: .bottom) {
            ShotImage(image: image, contentMode: .fit)
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 180)
                .overlay {
                    if peeking {
                        RoundedRectangle(cornerRadius: OMetric.Radius.ml, style: .continuous).strokeBorder(OColor.live, lineWidth: 2)
                    }
                }
            HStack(spacing: 5) {
                Image(systemName: "eye").font(.system(size: 10.5, weight: .semibold))
                Text(peeking ? String(localized: "Original showing — release to hide") : String(localized: "Hold to peek at the original"))
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(OColor.markText)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(peeking ? OColor.live : OColor.mark.opacity(0.72)))
            .overlay { if peeking { Capsule().strokeBorder(OColor.liveSoft, lineWidth: 3).padding(-3) } }
            .padding(.bottom, 6)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: OMetric.Radius.l, style: .continuous).fill(OColor.fill))
        .contentShape(Rectangle())
        // Press and release go to the shared hold-to-peek rule; the gesture is simultaneous so the double-click
        // that opens the Viewer still lands (and, being two short presses, never peeks).
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !pressing else { return }
                pressing = true
                controller.peekHold.pressBegan()
            }
            .onEnded { _ in
                pressing = false
                controller.peekHold.pressEnded()
            })
        .onTapGesture(count: 2) { controller.model.router?.openViewer(entryID: entry.id) }
        .task(id: entry.revision) {
            await controller.loadImage(for: entry)
            await controller.loadImage(for: entry, original: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(peeking ? String(localized: "Preview, original showing") : String(localized: "Preview, as the file is now")))
        .accessibilityAction(named: Text(controller.peekLatched ? "Hide the original" : "Peek at the original")) { controller.peekLatched.toggle() }
    }
}

/// "Originals auto-delete after 24 hours …" and, for one entry, when its original goes.
struct RetentionNote: View {
    let controller: JournalController
    let entry: Entry?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "clock").font(.system(size: 11)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 0) {
                Text("Originals auto-delete after \(Text(JournalFormat.retention(controller.retention)).fontWeight(.medium).foregroundStyle(OColor.text2)). Stored on this Mac only, readable by you alone.")
                if let entry {
                    Text(JournalFormat.keptUntil(JournalFormat.expiry(of: entry, retention: controller.retention), now: controller.now(), calendar: controller.calendar))
                        .fontWeight(.medium)
                        .foregroundStyle(OColor.text2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(OColor.text3)
        .lineSpacing(2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Several entries

struct MultiInspector: View {
    @Bindable var controller: JournalController
    let entries: [Entry]
    private var keys: KeyBindings { controller.model.settings.keyBindings }

    var body: some View {
        let ids = entries.map(\.id)
        let n = entries.count
        let verdict = controller.combinedVerdict(entries)
        let secrets = entries.reduce(0) { $0 + $1.findings.count }
        Group {
            ZStack {
                ForEach(Array(entries.prefix(3).enumerated()), id: \.element.id) { i, entry in
                    ShotImage(image: controller.image(for: entry))
                        .frame(width: 170, height: 112)
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                        .rotationEffect(.degrees(Double(i - 1) * 3))
                        .offset(x: CGFloat(i - 1) * 22, y: CGFloat(i - 1) * 8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.l, style: .continuous).fill(OColor.fill))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(JournalFormat.screenshots(n)) selected").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(OColor.text1)
                Text("\(ProtectionCopy.secrets(secrets)) · \(n) of \(controller.visibleEntries.count) selected").font(.system(size: 11.5)).foregroundStyle(OColor.text3)
            }
            .accessibilityElement(children: .combine)
            StatusBox(title: verdict.title, detail: controller.batchSummary(entries), tone: verdict.tone, symbol: verdict.symbol)
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(String(localized: "Actions on \(JournalFormat.screenshots(n))"), symbol: "slider.horizontal.3")
                VStack(spacing: 0) {
                    ActionRow(symbol: "arrow.uturn.backward", title: String(localized: "Restore Originals in \(n)")) {
                        Task { await controller.restoreOriginals(ids) }
                    }
                    ActionRow(symbol: "checkmark.shield", title: String(localized: "Black Out All in \(n)")) {
                        Task { await controller.blackOutAll(ids) }
                    }
                    ActionRow(symbol: "paintbrush.pointed", title: String(localized: "Apply Default Style")) {
                        Task { await controller.applyDefaultStyle(to: ids) }
                    }
                    ActionRow(symbol: "doc.on.doc", title: String(localized: "Copy — select one screenshot"), shortcut: keys.display(for: .journalCopyClean)) {}
                        .disabled(true)
                    ActionRow(symbol: "trash", title: String(localized: "Delete \(n)"), shortcut: keys.display(for: .journalDelete), role: .danger) {
                        Task { await controller.delete(ids) }
                    }
                }
            }
        }
        .task(id: ids) { for e in entries.prefix(3) { await controller.loadImage(for: e) } }
    }
}
