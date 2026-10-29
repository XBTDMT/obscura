// G-40: Protection ▸ "When a spot can't be read" carries the two opt-in switches, both off by default, each with its
// one-line explanation; flipping one changes the setting the engine reads at the next check. Drawn by the pane itself.
import AppKit
import SwiftUI
import Testing
import ObscuraPrefs
import ObscuraTestSupport
import ObscuraUIKit
@testable import ObscuraSettingsUI

@MainActor
@Suite(.serialized) struct UnreadSpotSwitchesTests {
    @Test func theWordsSayWhatEachSwitchDoes() {
        #expect(SpotCopy.settingsGroup == "When a spot can't be read")
        #expect(SpotCopy.coverSwitch == "Cover spots Obscura can't read")
        #expect(SpotCopy.coverSwitchDetail == "A small mark that looks like text but can't be read is covered a little past its edges, instead of waiting for you. The notice says how many were covered")
        #expect(SpotCopy.skipSwitch == "Skip spots too small to hold a secret")
        #expect(SpotCopy.skipSwitchDetail == "A spot too narrow to fit the shortest secret your detectors and rules look for is skipped. Skipped spots are still recorded and outlined")
    }

    @Test func bothStartOffAndEachFlipsOnItsOwn() async throws {
        let model = try await SampleData.model(entries: 0, settings: .default)
        #expect(!model.settings.coversUnreadableSpots && !model.settings.skipsTinySpots)
        model.updateSettings { $0.coversUnreadableSpots = true }
        #expect(model.settings.coversUnreadableSpots && !model.settings.skipsTinySpots)
        model.updateSettings { $0.skipsTinySpots = true }
        #expect(model.settings.skipsTinySpots)
    }

    @Test func theProtectionPaneDrawsWithBothSwitchesOn() async throws {
        var settings = ObscuraPrefs.Settings.default
        settings.coversUnreadableSpots = true
        settings.skipsTinySpots = true
        let model = try await SampleData.model(entries: 0, settings: settings)
        let snapshot = SettingsWindowRenderTests.snapshot
        let view = SettingsWindow(model: model, pane: .constant(.protection), services: .fixed(snapshot), snapshot: snapshot)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 880, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        #expect(ViewSnapshot.bitmap(host) != nil)
    }
}
