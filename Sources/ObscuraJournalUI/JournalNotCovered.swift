// The Journal's Not covered on disk section (fail-open #7): every file that still shows what Obscura caught because the
// covered picture could not be written to it, from the engine's persisted list (`EngineStatus.uncovered`), each with
// Try Again, Show in Finder and Dismiss. Built like the Not checked section (JournalNotChecked): a status box saying
// what is true of these files, then a card of rows. No image is drawn: the file on disk is the one that shows the secret.
import AppKit
import SwiftUI
import ObscuraUIKit
import ObscuraEngine

struct JournalNotCovered: View {
    @Bindable var controller: JournalController

    var body: some View {
        let files = controller.visibleUncovered
        if controller.model.status.uncovered.isEmpty {
            JournalNotCoveredEmpty()
        } else if files.isEmpty {
            JournalNoMatches(sidebar: .notCovered, search: controller.search)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: OMetric.Space.l) {
                    header(total: controller.model.status.uncovered.count)
                    RowCard {
                        ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                            NotCoveredRow(controller: controller, file: file)
                            if index < files.count - 1 {
                                Rectangle().fill(OColor.separator).frame(height: OMetric.hairline).padding(.leading, 88)
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
        }
    }

    /// What is true of every file here, and the one orange fix for all of them.
    private func header(total: Int) -> some View {
        HStack(alignment: .center, spacing: OMetric.Space.l) {
            StatusBox(title: total == 1 ? String(localized: "1 file still shows a secret") : String(localized: "\(total) files still show secrets"),
                      detail: String(localized: "Obscura caught these, but couldn't write the covered picture to the file. Until it can, the file shows what was caught."),
                      tone: .needs, symbol: JournalFormat.notCoveredSymbol)
            Button(total == 1 ? String(localized: "Try Again") : String(localized: "Try All Again")) {
                Task { await controller.retryAllNotCovered() }
            }
            .buttonStyle(OButtonStyle(.warn))
            .disabled(!controller.model.status.uncovered.contains { controller.sourceExists($0) })
        }
    }
}

/// One file: a plain tile, its name, folder and when, why it is not covered, and the three verbs.
struct NotCoveredRow: View {
    let controller: JournalController
    let file: UncoveredFile

    var body: some View {
        let exists = controller.sourceExists(file)
        let reason = JournalFormat.notCoveredReason(cleanCopy: file.isCleanCopy, attempts: file.attempts)
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
            Button(String(localized: "Try Again")) { Task { await controller.retry(file) } }.disabled(!exists)
            Button(String(localized: "Show in Finder")) { controller.showInFinder(file) }.disabled(!exists)
            Divider()
            Button(String(localized: "Dismiss")) { Task { await controller.dismiss(file) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(file.displayName), \(exists ? reason : String(localized: "moved or deleted"))"))
    }

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
                Image(systemName: "folder").font(.system(size: 10))
                Text(JournalFormat.uncheckedMeta(folder: JournalFormat.folderName(of: file.fileURL), date: file.date,
                                                 attempts: 1, now: controller.now(), calendar: controller.calendar))
                    .lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(OColor.text3)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: exists ? JournalFormat.notCoveredSymbol : "questionmark.folder").font(.system(size: 10.5, weight: .semibold))
                Text(exists ? reason : String(localized: "The caught file was moved or deleted, so there is nothing to cover here."))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(exists ? OColor.needsText : OColor.text2)
        }
        .layoutPriority(1)
    }

    private func buttons(exists: Bool) -> some View {
        HStack(spacing: OMetric.Space.s) {
            Button(String(localized: "Try Again")) { Task { await controller.retry(file) } }
                .buttonStyle(OButtonStyle(.quiet, size: .small))
                .disabled(!exists)
            Button(String(localized: "Show in Finder")) { controller.showInFinder(file) }
                .buttonStyle(OButtonStyle(.quiet, size: .small))
                .disabled(!exists)
            Button(String(localized: "Dismiss")) { Task { await controller.dismiss(file) } }
                .buttonStyle(OButtonStyle(.quiet, size: .small))
                .help(String(localized: "Remove it from this list and leave the file as it is"))
        }
        .fixedSize()
    }
}

/// The quiet empty state, shown while the section is on screen and its last file just left.
struct JournalNotCoveredEmpty: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 24)).foregroundStyle(OColor.text3)
                .accessibilityHidden(true)
            Text("Every caught file is covered").font(.system(size: 13, weight: .semibold)).foregroundStyle(OColor.text1)
            Text("Files Obscura couldn't write the covered picture to are listed here until a write succeeds or you dismiss them.")
                .font(.system(size: 12)).foregroundStyle(OColor.text2)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
