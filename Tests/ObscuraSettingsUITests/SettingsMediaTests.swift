// README media (docs/media/settings.png, settings-dark.png): Settings → Detectors with the AI providers tile picked, the
// Anthropic API key detector open and a made-up key in the test line, drawn by the window's own code through
// ViewSnapshot on a system snapshot where every source is allowed. Skipped unless OBSCURA_RENDER_MEDIA=1
// (docs/media/README.md). The test line's key is made up (an EXAMPLE body).
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ObscuraSettingsUI
import ObscuraPrefs
import ObscuraUIKit
import ObscuraTestSupport

@Suite(.serialized) @MainActor struct SettingsMediaTests {
    /// Every source allowed, nothing waiting on the person: the window as a settled install shows it. Paths carry no
    /// person's name.
    static let snapshot = SystemSnapshot(
        screenshotFolder: URL(filePath: "/Users/example/Desktop"), screenshotAccess: .granted,
        downloads: URL(filePath: "/Users/example/Downloads"), downloadsAccess: .granted,
        folderAccess: [:], floatingThumbnail: false, notificationsDenied: false, loginItem: .enabled)

    static let size = CGSize(width: 880, height: 620)

    @Test(.enabled(if: MediaOutput.enabled), arguments: [false, true])
    func detectorsPane(dark: Bool) async throws {
        var settings = ObscuraPrefs.Settings.default
        settings.hasFinishedSetup = true
        let model = try await SampleData.model(entries: 3, settings: settings)
        let initial = SettingsInitialState(tile: .ai, expanded: ["ai.anthropic.apikey"],
                                           testLine: "ANTHROPIC_API_KEY=sk-ant-api03-EXAMPLE000000000000000000")
        let view = SettingsWindow(model: model, pane: .constant(.detectors), services: .fixed(Self.snapshot), snapshot: Self.snapshot)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.settingsInitialState, initial)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(800))   // the session loads and the test line is checked
        host.layoutSubtreeIfNeeded()
        // The window is left to the test process (as the other Settings renders do): closing a borderless window made
        // here releases it under AppKit's feet.
        let rep = try #require(ViewSnapshot.bitmap(host))
        let content = try #require(rep.cgImage)
        let framed = try #require(MediaOutput.framedWindow(content, pointSize: Self.size, dark: dark))
        try MediaOutput.writePNG(framed, name: dark ? "settings-dark" : "settings")
    }
}
