import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ObscuraSettingsUI
import ObscuraPrefs
import ObscuraUIKit
import ObscuraTestSupport

/// G-21: Settings → About → Menu bar icon. The sixteen marks and the colour style, drawn the way the window server shows
/// them (ViewSnapshot), light and dark; picking writes the setting the menu bar reads, at once.
@Suite(.serialized) @MainActor struct MenuBarIconPickerTests {
    static func render(_ view: some View, size: CGSize, dark: Bool) async throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(OColor.window)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        return try #require(ViewSnapshot.bitmap(host))
    }

    static func write(_ rep: NSBitmapImageRep, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["OBSCURA_SETTINGS_SNAPSHOT_DIR"] ?? ProcessInfo.processInfo.environment["OBSCURA_UI_RENDER_DIR"]
        else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: dir).appending(path: "\(name).png"))
    }

    @Test(arguments: [false, true])
    func thePickerRendersEveryMarkInBothAppearances(dark: Bool) async throws {
        for (name, mark, style) in [("classic", MenuBarMarkID.classic, MenuBarMarkStyle.warm), ("checker-warm", .checkerBand, .warm),
                                    ("shield-one-colour", .shield, .oneColor)] {
            var settings = ObscuraPrefs.Settings.default
            settings.menuBarMark = mark
            settings.menuBarMarkStyle = style
            let model = try await SampleData.model(entries: 0, settings: settings)
            let rep = try await Self.render(MenuBarIconPicker(model: model).padding(12), size: CGSize(width: 620, height: 340), dark: dark)
            #expect(rep.size == CGSize(width: 620, height: 340))
            // The grid draws sixteen chips in the bar's colour: count chip-coloured pixels on a coarse grid. The snapshot
            // is in the window's colour space, so the chip colour is read from a swatch drawn the same way.
            let swatch = try await Self.render(Rectangle().fill(MarkPreview.barColor(dark: dark)), size: CGSize(width: 20, height: 20), dark: dark)
            let bar = try #require(swatch.colorAt(x: 20, y: 20))
            var chips = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    if abs(c.redComponent - bar.redComponent) < 0.01, abs(c.greenComponent - bar.greenComponent) < 0.01,
                       abs(c.blueComponent - bar.blueComponent) < 0.01 { chips += 1 }
                }
            }
            #expect(chips > 16 * 100, "\(name): sixteen preview chips (\(chips) chip pixels)")
            try Self.write(rep, "menubar-icon-picker-\(name)-\(dark ? "dark" : "light")")
        }
    }

    @Test func theAboutPaneCarriesThePicker() async throws {
        let model = try await SampleData.model(entries: 0)
        for dark in [false, true] {
            let view = SettingsWindow(model: model, pane: .constant(.about), services: .fixed(SettingsWindowRenderTests.snapshot),
                                      snapshot: SettingsWindowRenderTests.snapshot)
            let rep = try await Self.render(view, size: OMetric.settingsSize, dark: dark)
            #expect(rep.size == OMetric.settingsSize)
            try Self.write(rep, "about-with-menubar-icon-\(dark ? "dark" : "light")")
        }
    }

    @Test func pickingWritesTheSettingTheMenuBarReads() async throws {
        let model = try await SampleData.model(entries: 0)
        #expect(model.settings.menuBarMark == .classic && model.settings.menuBarMarkStyle == .warm)
        // The picker's own actions, as the cells and the segmented control call them.
        let picker = MarkPicker(selection: model.settings.menuBarMark, style: model.settings.menuBarMarkStyle, state: model.markState,
                                pausedColor: model.settings.pausedColor,
                                onPick: { m in model.updateSettings { $0.menuBarMark = m } },
                                onStyle: { s in model.updateSettings { $0.menuBarMarkStyle = s } })
        picker.onPick(.yinYang)
        picker.onStyle(.indigo)
        #expect(model.settings.menuBarMark == .yinYang && model.settings.menuBarMarkStyle == .indigo)
        #expect(SidebarCopy.keywords(.about).joined(separator: " ").contains("menu bar"), "search finds the picker")
    }
}
