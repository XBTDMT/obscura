import AppKit
import Foundation
import SwiftUI
import Testing
import ObscuraPrefs
import ObscuraTestSupport
import ObscuraUIKit
@testable import ObscuraSetupUI

/// G-21: the "Pick your menu bar icon" step drawn the way the window server shows it (ViewSnapshot, so the segmented
/// style picker, an AppKit control, is drawn too), light and dark, with the Classic ring and with a coloured pick.
/// PNGs go to OBSCURA_UI_RENDER_DIR for the visual check.
@Suite(.serialized) @MainActor struct MenuBarIconStepRenderTests {
    @Test(arguments: [false, true])
    func theStepRendersWithItsGridAndStylePicker(dark: Bool) async throws {
        for (name, mark, style) in [("classic", MenuBarMarkID.classic, MenuBarMarkStyle.warm), ("pixelated-glass", .pixelatedHalf, .glass)] {
            let mac = FakeMac()
            var settings = Settings.default
            settings.menuBarMark = mark
            settings.menuBarMarkStyle = style
            let flow = try await makeFlow(mac, settings: settings)
            flow.preset(step: .menuBarIcon, seen: Set(SetupStep.allCases.prefix(while: { $0 != .menuBarIcon })))
            let host = NSHostingView(rootView: SetupWindow(flow: flow).environment(\.colorScheme, dark ? .dark : .light))
            host.frame = CGRect(origin: .zero, size: OMetric.setupSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let bitmap = try #require(ViewSnapshot.bitmap(host))
            #expect(bitmap.size == OMetric.setupSize)
            #expect(Self.distinctColours(bitmap) > 20, "\(name) drew the grid's colours")
            if let dir = ProcessInfo.processInfo.environment["OBSCURA_UI_RENDER_DIR"] {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: URL(filePath: dir).appending(path: "setup-menubar-icon-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    static func distinctColours(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                seen.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
            }
        }
        return seen.count
    }
}
