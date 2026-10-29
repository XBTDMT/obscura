// The kit's buttons as system.html draws `.btn`: every role in both sizes, light and dark, on the window colour. With
// OBSCURA_UI_RENDER_DIR set the PNGs are written there for a visual check against system.html (redman: the control
// shadow, `--o-shadow-ctl`).
import Testing
import AppKit
import SwiftUI
@testable import ObscuraUIKit

@MainActor
@Suite struct ButtonRenderTests {
    static let roles: [(String, OButtonStyle.Role)] = [("Primary", .primary), ("Quiet", .quiet), ("Warn", .warn), ("Danger", .danger),
                                                       ("Ghost", .ghost), ("Plain", .plain)]

    /// Draws a view at 2× with SwiftUI's own renderer. Not `NSView.cacheDisplay`: that path draws layer shadows with the
    /// y offset inverted (a `y: 1` drop lands above the shape), so it cannot show or measure this one.
    static func render(_ view: some View, size: CGSize, dark: Bool) -> NSBitmapImageRep? {
        var rep: NSBitmapImageRep?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
                .environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 2
            rep = renderer.cgImage.map { NSBitmapImageRep(cgImage: $0) }
        }
        return rep
    }

    static func save(_ rep: NSBitmapImageRep, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["OBSCURA_UI_RENDER_DIR"], let data = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    static var sheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach([OButtonStyle.Size.regular, .small], id: \.self) { size in
                HStack(spacing: 10) {
                    ForEach(roles, id: \.0) { title, role in
                        Button(title) {}.buttonStyle(OButtonStyle(role, size: size))
                    }
                    Button("Disabled") {}.buttonStyle(OButtonStyle(.quiet, size: size)).disabled(true)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OColor.window)
    }

    @Test(arguments: [false, true])
    func everyRoleInBothSizesRenders(dark: Bool) throws {
        let rep = try #require(Self.render(Self.sheet, size: CGSize(width: 620, height: 110), dark: dark))
        #expect(rep.pixelsWide >= 620)
        Self.save(rep, "buttons-\(dark ? "dark" : "light")")
    }

    /// The luminance just under a lone button's bottom edge, against the window colour beside it. A button with the
    /// control shadow darkens the row of pixels under it; one without leaves the window colour.
    static func shadowDarkening(role: OButtonStyle.Role, size: OButtonStyle.Size, dark: Bool) throws -> Double {
        let canvas = CGSize(width: 120, height: 60)
        let view = ZStack {
            OColor.window
            Button("Button") {}.buttonStyle(OButtonStyle(role, size: size))
        }
        let rep = try #require(render(view, size: canvas, dark: dark))
        let scale = Double(rep.pixelsWide) / canvas.width
        let height = size == .regular ? OMetric.Control.buttonHeight : OMetric.Control.smallButtonHeight
        // Centre column; the first pixel row below the button's bottom edge (the hairline sits inside the edge).
        let x = rep.pixelsWide / 2
        let below = Int(((canvas.height + height) / 2 + 0.5) * scale)
        func luminance(_ px: Int, _ py: Int) -> Double {
            guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { return 0 }
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }
        return luminance(4, below) - luminance(x, below)
    }

    @Test func quietAndDangerButtonsCastTheControlShadowInBothAppearances() throws {
        for dark in [false, true] {
            for size in [OButtonStyle.Size.regular, .small] {
                for role in [OButtonStyle.Role.quiet, .danger] {
                    #expect(try Self.shadowDarkening(role: role, size: size, dark: dark) > 0.004,
                            "\(role) \(size) \(dark ? "dark" : "light") sits on a shadow")
                }
            }
        }
    }

    @Test func filledAndBareButtonsCastNone() throws {
        for dark in [false, true] {
            for role in [OButtonStyle.Role.primary, .warn, .ghost, .plain] {
                #expect(abs(try Self.shadowDarkening(role: role, size: .regular, dark: dark)) < 0.002,
                        "system.html gives .\(role) box-shadow: none")
            }
        }
    }

    @Test func theControlShadowTokenIsSystemHtmls() {
        // --o-shadow-ctl: 0 0 0 .5px var(--o-hair), 0 1px 1.5px rgba(0,0,0,.06) light / .3 dark. CSS blur b is radius b/2.
        #expect(OShadow.control.x == 0)
        #expect(OShadow.control.y == 1)
        #expect(OShadow.control.radius == 0.75)
        let light = NSColor(OShadow.control.color).resolved(dark: false)
        let dark = NSColor(OShadow.control.color).resolved(dark: true)
        #expect(abs(light.alphaComponent - 0.06) < 0.001 && light.redComponent == 0 && light.greenComponent == 0 && light.blueComponent == 0)
        #expect(abs(dark.alphaComponent - 0.30) < 0.001 && dark.redComponent == 0)
        #expect(OButtonStyle(.quiet).castsControlShadow && OButtonStyle(.danger, size: .small).castsControlShadow)
        #expect(![OButtonStyle.Role.primary, .warn, .ghost, .plain].contains { OButtonStyle($0).castsControlShadow })
    }
}

private extension NSColor {
    /// This colour as drawn in a light or dark appearance, in sRGB.
    func resolved(dark: Bool) -> NSColor {
        var out = self
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            out = self.usingColorSpace(.sRGB) ?? self
        }
        return out
    }
}
