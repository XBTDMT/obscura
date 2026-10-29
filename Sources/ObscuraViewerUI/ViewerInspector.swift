// The on-demand inspector (236 pt): the finding box, the Black out list (same order as the badges), Details and the
// two copy verbs; and the first-run variant with the four-step story, Run Again and Continue Setup.
import SwiftUI
import ObscuraUIKit
import ObscuraPrefs
import ObscuraJournal

struct ViewerInspector: View {
    var keys: KeyBindings
    var entry: Entry
    var names: [UUID: String]
    var verdict: Verdict
    var retentionHours: Int
    var originalAvailable: Bool
    var toggle: (Finding) -> Void
    var blackOutAll: () -> Void
    /// The key-text field under a finding left visible (G-17): its state (nil = no field), the read and Copy.
    var keyText: (Finding) -> KeyTextState? = { _ in nil }
    var requestKeyText: (Finding) -> Void = { _ in }
    var copyKeyText: (Finding) -> Void = { _ in }
    var copyClean: () -> Void
    var copyOriginal: () -> Void

    var body: some View {
        InspectorColumn {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    StatusBox(verdict)
                    if !entry.findings.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel(String(localized: "Black out"))
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(entry.findings) { f in
                                    FindingToggleRow(name: names[f.id] ?? "", on: f.enabled,
                                                     stateText: ViewerCopy.findingState(enabled: f.enabled)) { toggle(f) }
                                    if let state = keyText(f) {
                                        // Under the row, aligned with its name (the row's 7 pt inset + checkbox 14 + 8 pt gap).
                                        UncoveredKeyField(state: state) { copyKeyText(f) }
                                            .padding(.leading, 29).padding(.trailing, 7).padding(.bottom, 6)
                                            .task(id: f.id) { requestKeyText(f) }
                                    }
                                }
                                if entry.findings.contains(where: { !$0.enabled }) {
                                    Button(ViewerCopy.blackOutAll, action: blackOutAll)
                                        .buttonStyle(OButtonStyle(.plain))
                                        .font(.system(size: 11.5, weight: .medium))
                                        .padding(.vertical, 4).padding(.horizontal, 7)
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(String(localized: "Details"))
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                            row(String(localized: "Source"), ViewerCopy.source(entry))
                            row(String(localized: "Date"), ViewerCopy.date(entry.createdAt))
                            row(String(localized: "Kind"), ViewerCopy.kind(entry))
                            row(String(localized: "Original"), ViewerCopy.originalExpiry(createdAt: entry.createdAt, retentionHours: retentionHours,
                                                                                        available: originalAvailable))
                            row(String(localized: "Left Mac"), ViewerCopy.leftMacNever)
                        }
                        .font(.system(size: 12))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            // Both verbs on one line when they fit (the icon goes first), else stacked.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { copyButtons(withIcon: true) }.fixedSize()
                HStack(spacing: 6) { copyButtons(withIcon: false) }.fixedSize()
                VStack(alignment: .leading, spacing: 6) { copyButtons(withIcon: true) }
            }
        }
    }

    @ViewBuilder private func copyButtons(withIcon: Bool) -> some View {
        Button(action: copyClean) {
            if withIcon { IconLabel(String(localized: "Copy Clean"), symbol: "doc.on.doc") }
            else { Text("Copy Clean").lineLimit(1).fixedSize() }
        }
        .buttonStyle(OButtonStyle(.quiet))
        .help(String(localized: "Copy the blacked-out image"))
        Button(action: copyOriginal) { Text("Copy Original").lineLimit(1).fixedSize() }
            .buttonStyle(OButtonStyle(.danger))
            .disabled(!originalAvailable)
            .help(ShortcutText.withChord(String(localized: "Copy the original. It contains every secret"), .viewerCopyOriginal, keys))
            .shortcut(.viewerCopyOriginal, keys)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(OColor.text3).frame(width: 62, alignment: .leading)
            Text(value).foregroundStyle(OColor.text1).lineLimit(2)
        }
    }
}

/// The first-run test shot's inspector.
struct TestShotInspector: View {
    var entry: Entry
    var names: [UUID: String]
    var durationMS: Int
    var retentionHours: Int
    var toggle: (Finding) -> Void
    var runAgain: () -> Void
    var continueSetup: () -> Void

    var body: some View {
        InspectorColumn {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    StatusBox(title: ViewerCopy.testShotHeadline(secrets: entry.findings.count, durationMS: durationMS),
                              detail: ViewerCopy.testShotDetail, tone: .ok, symbol: "checkmark.shield")
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(String(localized: "What just happened"))
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(steps.enumerated()), id: \.offset) { _, s in StepRow(text: s) }
                        }
                    }
                    if !entry.findings.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel(String(localized: "Black out"))
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(entry.findings) { f in
                                    FindingToggleRow(name: names[f.id] ?? "", on: f.enabled,
                                                     stateText: f.enabled ? String(localized: "on") : String(localized: "off")) { toggle(f) }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                Button(action: runAgain) { IconLabel(String(localized: "Run Again"), symbol: "arrow.clockwise") }
                .buttonStyle(OButtonStyle(.ghost))
                Button(String(localized: "Continue Setup"), action: continueSetup)
                    .buttonStyle(OButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var steps: [String] {
        let detectors = Set(entry.findings.compactMap(\.detectorIDs.first)).count
        return ViewerCopy.testShotSteps(detectors: detectors, secrets: entry.findings.count, retentionHours: retentionHours)
    }
}

/// `.vside`: 236 pt, window background, a hairline on its leading edge, 12 pt padding, the actions at the bottom.
struct InspectorColumn<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(12)
            .frame(width: OMetric.settingsSidebarWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(OColor.window)
            .overlay(alignment: .leading) { Rectangle().fill(OColor.separator).frame(width: OMetric.hairline) }
    }
}
