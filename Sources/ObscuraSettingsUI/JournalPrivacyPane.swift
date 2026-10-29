// Journal & Privacy: how long originals are kept (1 h / 24 h / 7 d / 30 d), what is stored now with Delete All
// Originals confirmed in the page, where originals live (kept out of Time Machine and Spotlight, G-23), the two search
// switches (Spotlight entries and Finder tags for covered files, G-24) and the privacy statement (update checks are the
// only network use).
import Foundation
import SwiftUI
import ObscuraUIKit
import ObscuraJournal
import ObscuraPrefs

struct JournalPrivacyPane: View {
    let model: AppModel
    let session: SettingsSession
    let services: SystemServices
    @State private var storedBytes: Int64?
    @State private var confirmingDelete = false
    @State private var deleting = false

    private var retention: JournalRetention { model.settings.journalRetention }

    var body: some View {
        PaneScaffold(String(localized: "Journal & Privacy")) {
            Lead(tone: .ok, title: String(localized: "Originals are deleted after \(RetentionCopy.duration(retention))"),
                 detail: String(localized: "Kept privately on this Mac so you can undo; then gone for good. Nothing leaves this Mac."))
            GroupHeading(title: String(localized: "Originals"))
            Card { originals }
            GroupHeading(title: String(localized: "Journal and Viewer"))
            Card { windows }
            GroupHeading(title: String(localized: "Search"))
            Card { search }
            GroupHeading(title: String(localized: "Privacy"))
            Card { privacy }
        }
        .task(id: model.entries.map(\.id)) { storedBytes = await originalsSize() }
    }

    // MARK: Originals

    @ViewBuilder private var originals: some View {
        SettingRow(title: String(localized: "Keep originals for"),
                   help: String(localized: "The original is kept privately so you can undo, then deleted for good")) {
            Picker(String(localized: "Keep originals for"), selection: Binding(get: { retention },
                                                                            set: { r in model.updateSettings { $0.journalRetention = r } })) {
                ForEach(JournalRetention.allCases, id: \.self) { Text(RetentionCopy.duration($0)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        RowDivider()
        if confirmingDelete {
            SettingRow(title: confirmTitle,
                       help: String(localized: "Undo and Restore Original stop working for these screenshots. The clean files you shared are not touched. This can’t be undone.")) {
                Button(String(localized: "Cancel")) { confirmingDelete = false }
                    .buttonStyle(OButtonStyle(.quiet, size: .small)).keyboardShortcut(.cancelAction)
                Button(String(localized: "Delete All")) { deleteAll() }
                    .buttonStyle(OButtonStyle(.danger, size: .small)).disabled(deleting)
            }
            .background(OColor.liveSoft.opacity(0.5))
        } else {
            SettingRow(title: String(localized: "Stored now"), help: storedLine) {
                Button { confirmingDelete = true } label: { Label(String(localized: "Delete All Originals…"), systemImage: "trash") }
                    .buttonStyle(OButtonStyle(.danger, size: .small))
                    .disabled(model.entries.isEmpty)
            }
        }
        RowDivider()
        SettingRow(title: String(localized: "Ask before Undo shows an original"),
                   help: String(localized: "Off, Undo acts at once and the red Original showing marking is the warning")) {
            AsyncSwitch(label: String(localized: "Ask before Undo shows an original"), isOn: model.settings.confirmsUndo) { on in
                model.updateSettings { $0.confirmsUndo = on }
            }
        }
        RowDivider()
        SettingRow(title: String(localized: "Where originals live"),
                   help: JournalPrivacyCopy.originalsHelp(PathCopy.abbreviated(originalsFolder))) {
            Button { services.reveal(originalsFolder) } label: { Label(String(localized: "Open folder"), systemImage: "folder") }
                .buttonStyle(OButtonStyle(.quiet, size: .small))
        }
    }

    // MARK: Journal and Viewer (G-19)

    @ViewBuilder private var windows: some View {
        SettingRow(title: String(localized: "Compare in the Viewer"),
                   help: String(localized: "Space shows the redacted image and the original side by side, or as one picture with a divider you drag")) {
            Picker(String(localized: "Compare in the Viewer"),
                   selection: Binding(get: { model.settings.compareStyle }, set: { c in model.updateSettings { $0.compareStyle = c } })) {
                Text("Side by side").tag(CompareStyle.sideBySide)
                Text("Wipe").tag(CompareStyle.wipe)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        RowDivider()
        // The pane's shortcut is read from the bindings, so the text follows a person's change (G-20).
        let detailsChord = model.settings.keyBindings.chord(for: .journalShowDetails).map { " (\($0.display))" } ?? ""
        SettingRow(title: String(localized: "Journal details pane"),
                   help: String(localized: "How the details pane\(detailsChord) shows and hides. With Reduce Motion it is always instant")) {
            Picker(String(localized: "Journal details pane"),
                   selection: Binding(get: { model.settings.journalInspectorMotion },
                                      set: { m in model.updateSettings { $0.journalInspectorMotion = m } })) {
                Text("Instant").tag(InspectorMotion.instant)
                Text("Slide").tag(InspectorMotion.slide)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }

    private var confirmTitle: String {
        let n = model.entries.count
        return n == 1 ? String(localized: "Delete the 1 stored original?") : String(localized: "Delete all \(n) stored originals?")
    }

    /// "14 originals · 38 MB · oldest deleted in 6 h"
    private var storedLine: String {
        let n = model.entries.count
        guard n > 0 else { return String(localized: "No originals are stored right now") }
        var parts = [n == 1 ? String(localized: "1 original") : String(localized: "\(n) originals")]
        if let storedBytes { parts.append(ByteCopy.size(storedBytes)) }
        if let oldest = model.entries.map(\.createdAt).min() {
            let left = oldest.addingTimeInterval(TimeInterval(retention.hours * 3600)).timeIntervalSinceNow
            parts.append(String(localized: "oldest deleted \(RetentionCopy.remaining(max(0, left)))"))
        }
        return parts.joined(separator: " · ")
    }

    private var originalsFolder: URL {
        if let store = model.journal as? SQLiteJournalStore { return store.journalRoot }
        return JournalLocations.images(in: JournalLocations.defaultRoot())
    }

    // MARK: Search (G-24)

    @ViewBuilder private var search: some View {
        SettingRow(title: JournalPrivacyCopy.spotlightTitle, help: JournalPrivacyCopy.spotlightHelp) {
            AsyncSwitch(label: JournalPrivacyCopy.spotlightTitle, isOn: model.settings.indexesCatchesInSpotlight) { on in
                model.updateSettings { $0.indexesCatchesInSpotlight = on }
            }
        }
        RowDivider()
        SettingRow(title: JournalPrivacyCopy.tagsTitle, help: JournalPrivacyCopy.tagsHelp) {
            AsyncSwitch(label: JournalPrivacyCopy.tagsTitle, isOn: model.settings.tagsCoveredFiles) { on in
                model.updateSettings { $0.tagsCoveredFiles = on }
            }
        }
    }

    private func originalsSize() async -> Int64 {
        var total: Int64 = 0
        for entry in model.entries {
            guard let url = try? await model.journal.originalURL(entry.id),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    private func deleteAll() {
        deleting = true
        Task {
            do {
                try await model.journal.deleteAll()
            } catch {
                session.notice = String(localized: "Couldn’t delete the originals.")
            }
            await model.reloadEntries()
            deleting = false
            confirmingDelete = false
        }
    }

    // MARK: Privacy

    @ViewBuilder private var privacy: some View {
        SettingRow(title: JournalPrivacyCopy.keyTextTitle, help: JournalPrivacyCopy.keyTextHelp) {
            AsyncSwitch(label: JournalPrivacyCopy.keyTextTitle, isOn: model.settings.showsUncoveredKeyText) { on in
                model.updateSettings { $0.showsUncoveredKeyText = on }
            }
        }
        RowDivider()
        SettingRow(title: String(localized: "Screenshots stay on this Mac"),
                   help: String(localized: "OCR and detection run on the Mac. No account, no analytics, no crash reports")) {
            Badge(String(localized: "Nothing leaves"), tone: .ok, symbol: "lock")
        }
        RowDivider()
        SettingRow(title: String(localized: "What goes online"),
                   help: String(localized: "Update checks only, at most once a day, and only when you allow them in About")) {
            Badge(String(localized: "Updates only"), tone: .accent, symbol: "globe")
        }
        RowDivider()
        SettingRow(title: String(localized: "Counts kept \(SQLiteJournalStore.statsRetentionDays) days"),
                   help: String(localized: "Daily catch counts for the week view: numbers only, never image content")) {
            Badge(String(localized: "Numbers only"), tone: .quiet, symbol: "number")
        }
    }
}
