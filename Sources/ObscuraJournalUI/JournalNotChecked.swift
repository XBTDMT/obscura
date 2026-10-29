// The Journal's Not checked section (G-13): every file Obscura could not check, from the engine's persisted list
// (`EngineStatus.unchecked`), each with Check Again, Show in Finder and Dismiss. Built from the kit's pieces on the
// journal.html list-row pattern: a status box saying what is true of these files, then a card of rows. No image is
// drawn for a file, because Obscura never read one to the end and keeps no copy of it.
import AppKit
import SwiftUI
import ObscuraUIKit
import ObscuraEngine
import ObscuraJournal
import ObscuraCapture

struct JournalNotChecked: View {
    @Bindable var controller: JournalController
    /// G-40: the record of spot rows already settled (loaded when the section shows, and again when the list changes).
    @State private var settled: [UncheckedFile] = []

    var body: some View {
        let files = controller.visibleUnchecked
        // G-40: pictures whose only unread parts are spots waiting for the person are listed apart, with plain words and
        // no alarm; the orange header counts only the files that went unread for another reason.
        let alarms = files.filter { !$0.isUnreadSpots }
        let spots = files.filter(\.isUnreadSpots)
        Group {
            if controller.model.status.unchecked.isEmpty && settled.isEmpty {
                JournalNotCheckedEmpty()
            } else if files.isEmpty && settled.isEmpty {
                JournalNoMatches(sidebar: .notChecked, search: controller.search)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: OMetric.Space.l) {
                        if !alarms.isEmpty {
                            header(total: controller.model.status.unchecked.filter { !$0.isUnreadSpots }.count)
                            rows(alarms)
                        }
                        if !spots.isEmpty {
                            spotHeader(spots)
                            rows(spots)
                        }
                        if !settled.isEmpty {
                            StatusBox(title: SpotCopy.recordTitle, detail: SpotCopy.recordDetail, tone: .quiet, symbol: "checkmark.circle")
                            rows(settled)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
            }
        }
        .task(id: controller.model.status.unchecked) { settled = await controller.model.settledSpotFiles() }
    }

    private func rows(_ files: [UncheckedFile]) -> some View {
        RowCard {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                NotCheckedRow(controller: controller, file: file)
                if index < files.count - 1 {
                    Rectangle().fill(OColor.separator).frame(height: OMetric.hairline).padding(.leading, 88)
                }
            }
        }
    }

    /// G-40: the spots waiting for the person, in plain words (no orange fix: the person looks first).
    private func spotHeader(_ files: [UncheckedFile]) -> some View {
        let n = files.reduce(0) { $0 + max(1, $1.pendingSpots) }
        return StatusBox(title: SpotCopy.title(n), detail: SpotCopy.body(spots: n, files: files.count, name: files.count == 1 ? files.first?.displayName : nil),
                         tone: .accent, symbol: "viewfinder")
    }

    /// What is true of every file here, and the one orange fix for all of them.
    private func header(total: Int) -> some View {
        HStack(alignment: .center, spacing: OMetric.Space.l) {
            StatusBox(title: total == 1 ? String(localized: "1 image wasn't checked") : String(localized: "\(total) images weren't checked"),
                      detail: String(localized: "Obscura couldn't finish reading these, so a secret in them would still show. The files are untouched."),
                      tone: .needs, symbol: JournalFormat.notCheckedSymbol)
            Button(total == 1 ? String(localized: "Check Again") : String(localized: "Check All Again")) {
                Task { await controller.checkAllAgain() }
            }
            .buttonStyle(OButtonStyle(.warn))
            .disabled(!controller.model.status.unchecked.contains { controller.fileExists($0) })
        }
    }
}

/// One file: a plain tile (no image is kept), its name, folder and when, why it wasn't checked, and the three verbs.
struct NotCheckedRow: View {
    let controller: JournalController
    let file: UncheckedFile

    var body: some View {
        let exists = controller.fileExists(file)
        let reason = file.settledAt != nil ? SpotCopy.settledSummary(file.spots)
            : JournalFormat.uncheckedReason(file.uncheckedReason, timeoutSeconds: timeoutSeconds)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: OMetric.Space.l) {
                tile
                words(exists: exists, reason: reason)
                Spacer(minLength: OMetric.Space.m)
                buttons(exists: exists)
            }
            HStack(alignment: .top, spacing: OMetric.Space.l) {
                tile
                VStack(alignment: .leading, spacing: OMetric.Space.s) {
                    words(exists: exists, reason: reason)
                    buttons(exists: exists)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, OMetric.Space.l)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            if file.isUnreadSpots {
                Button(SpotCopy.review) { controller.model.router?.openSpots(fileID: file.id) }
                if file.pendingSpots > 0 {
                    Button(SpotCopy.notText) { Task { await controller.model.settleSpots(file, .notText) } }
                    Button(SpotCopy.coverIt) { Task { await controller.model.settleSpots(file, .cover) } }.disabled(!exists)
                }
                Button(String(localized: "Show in Finder")) { controller.showInFinder(file) }.disabled(!exists)
            } else {
                Button(String(localized: "Check Again")) { Task { await controller.checkAgain(file) } }.disabled(!exists)
                Button(String(localized: "Show in Finder")) { controller.showInFinder(file) }.disabled(!exists)
                Divider()
                Button(String(localized: "Dismiss")) { Task { await controller.dismiss(file) } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(file.displayName), \(exists ? reason : String(localized: "moved or deleted"))"))
    }

    private var timeoutSeconds: Int { Int(controller.model.settings.ocrTimeoutSeconds.rounded()) }

    /// The list rows' thumbnail size, on the quiet fill, with the file's kind as a symbol.
    private var tile: some View {
        RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous)
            .fill(OColor.fill)
            .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous).strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
            .overlay(Image(systemName: "photo").font(.system(size: 16, weight: .regular)).foregroundStyle(OColor.text3))
            .frame(width: OMetric.thumbSmall.width, height: OMetric.thumbSmall.height)
            .accessibilityHidden(true)
    }

    private func words(exists: Bool, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(file.displayName).font(.system(size: 12.5, weight: .medium)).foregroundStyle(OColor.text1)
                .lineLimit(1).truncationMode(.middle)
                .help(file.fileURL.path)
            HStack(spacing: 5) {
                Image(systemName: Self.originSymbol(file.origin)).font(.system(size: 10))
                Text(JournalFormat.uncheckedMeta(folder: JournalFormat.folderName(of: file.fileURL), date: file.date,
                                                 attempts: file.attempts, now: controller.now(), calendar: controller.calendar))
                    .lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(OColor.text3)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: !exists ? "questionmark.folder" : file.isUnreadSpots ? "viewfinder" : JournalFormat.notCheckedSymbol)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(exists ? reason : String(localized: "The file was moved or deleted, so it can't be checked again."))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(exists && !file.isUnreadSpots ? OColor.needsText : OColor.text2)
        }
        .layoutPriority(1)
    }

    @ViewBuilder private func buttons(exists: Bool) -> some View {
        if file.isUnreadSpots { spotButtons(exists: exists) } else { checkButtons(exists: exists) }
    }

    /// G-40: a picture with spots to look at: Review… (the spot viewer), the two answers while one waits, and Finder.
    private func spotButtons(exists: Bool) -> some View {
        HStack(spacing: OMetric.Space.s) {
            Button(SpotCopy.review) { controller.model.router?.openSpots(fileID: file.id) }
                .buttonStyle(OButtonStyle(file.pendingSpots > 0 ? .primary : .quiet, size: .small))
            if file.pendingSpots > 0 {
                Button(SpotCopy.notText) { Task { await controller.model.settleSpots(file, .notText) } }
                    .buttonStyle(OButtonStyle(.quiet, size: .small)).help(SpotCopy.notTextHelp)
                Button(SpotCopy.coverIt) { Task { await controller.model.settleSpots(file, .cover) } }
                    .buttonStyle(OButtonStyle(.quiet, size: .small)).help(SpotCopy.coverItHelp).disabled(!exists)
            }
            Button(String(localized: "Show in Finder")) { controller.showInFinder(file) }
                .buttonStyle(OButtonStyle(.quiet, size: .small))
                .disabled(!exists)
        }
        .fixedSize()
    }

    private func checkButtons(exists: Bool) -> some View {
        HStack(spacing: OMetric.Space.s) {
            Button(String(localized: "Check Again")) { Task { await controller.checkAgain(file) } }
                .buttonStyle(OButtonStyle(.quiet, size: .small))
                .disabled(!exists)
            Button(String(localized: "Show in Finder")) { controller.showInFinder(file) }
                .buttonStyle(OButtonStyle(.quiet, size: .small))
                .disabled(!exists)
            Button(String(localized: "Dismiss")) { Task { await controller.dismiss(file) } }
                .buttonStyle(OButtonStyle(.quiet, size: .small))
                .help(String(localized: "Remove it from this list without checking it"))
        }
        .fixedSize()
    }

    /// The source symbols the catches use, so a screenshot reads the same in both lists.
    static func originSymbol(_ origin: FileOrigin) -> String {
        switch origin {
        case .screenshotFolder: return JournalFormat.sourceSymbol(.file)
        case .downloads: return "arrow.down.circle"
        case .watched: return "folder"
        case .imported: return JournalFormat.sourceSymbol(.imported)
        }
    }
}

/// The quiet empty state: shown only while the section is on screen and its last file just left (checked or dismissed);
/// the sidebar row goes once another section is chosen.
struct JournalNotCheckedEmpty: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 24)).foregroundStyle(OColor.text3)
                .accessibilityHidden(true)
            Text("Every image was checked").font(.system(size: 13, weight: .semibold)).foregroundStyle(OColor.text1)
            Text("Images Obscura couldn't read are listed here until they're checked or dismissed.")
                .font(.system(size: 12)).foregroundStyle(OColor.text2)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
