// G-17 in the viewer's inspector: the key-text field under a finding left visible fits the 236 pt column and keeps the
// window at its 880 pt width. Every key here is made up.
import Testing
import Foundation
import AppKit
import SwiftUI
@testable import ObscuraViewerUI
import ObscuraUIKit
import ObscuraJournal
import ObscuraPrefs

@Suite(.serialized) @MainActor struct ViewerKeyTextTests {
    @Test func theFieldFitsTheInspectorInEveryState() async throws {
        let model = try await SampleData.model(entries: 2)
        let entry = try #require(model.entries.first { $0.findings.contains { !$0.enabled } })
        let names = ViewerScene.names(for: entry)
        let long = "sk-ant-api03-OdR-zLBztqrYi_rvGbv_a_Qx0nby3pkIrvS2pn9v7rZHTaTc8eH2yOynBcI5AA"   // SampleData's made-up value
        for (label, state) in [("reading", KeyTextState.reading), ("text", .text(long)), ("unreadable", .unreadable)] {
            for dark in [false, true] {
                let view = ViewerInspector(keys: .defaults, entry: entry, names: names, verdict: model.verdict(for: entry), retentionHours: 24,
                                           originalAvailable: true, toggle: { _ in }, blackOutAll: {},
                                           keyText: { $0.enabled ? nil : state }, copyClean: {}, copyOriginal: {})
                let (window, host) = await Snapshot.host(view, width: OMetric.settingsSidebarWidth, dark: dark)
                #expect(host.fittingSize.width <= OMetric.settingsSidebarWidth + 0.5, "the field widened the inspector")
                let rep = try #require(Snapshot.bitmap(host))
                Snapshot.write(rep, "inspector-keytext-\(label)-\(dark ? "dark" : "light")")
                window.close()
            }
        }
    }

    @Test func theWindowKeepsItsWidthWithTheSwitchOn() async throws {
        var settings = Settings.default
        settings.showsUncoveredKeyText = true
        // No engine in the sample model: the read fails and the field says "Couldn't read this one."
        let model = try await SampleData.model(entries: 2, settings: settings)
        let entry = try #require(model.entries.first { $0.findings.contains { !$0.enabled } })
        let (window, host) = await Snapshot.host(ViewerWindow(model: model, entryID: entry.id), width: 880)
        #expect(host.fittingSize.width == OMetric.viewerWidthWithInspector)
        let rep = try #require(Snapshot.bitmap(host))
        Snapshot.write(rep, "left-visible-keytext-light")
        window.close()
    }
}
