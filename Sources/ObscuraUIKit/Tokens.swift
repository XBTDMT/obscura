// Obscura design tokens, from design/mockups/unified/CHANGES.md "Token table" (G-6, accent from the Glass O icon pick).
// Every colour in the app comes from here; a theme change is a change to this file only.
public import SwiftUI
import AppKit

/// Colour tokens. Each resolves per appearance (light / dark) at draw time, so views never branch on the colour scheme.
public enum OColor {
    // Brand accent: Glass indigo (icon-30 r3-a). Buttons, links, selection, switches, focus, "working" and "waiting".
    public static let accent = dyn(0x5B5BD6, 1, 0x8383E0, 1)
    public static let accentText = dyn(0x4A4AC4, 1, 0x9D9DEA, 1)
    public static let accentSoft = dyn(0x5B5BD6, 0.12, 0x8383E0, 0.20)
    public static let selection = dyn(0x5B5BD6, 0.14, 0x8383E0, 0.30)

    // Semantic states. Red means only "original showing" or destructive; orange "needs you / left visible"; green "safe".
    public static let live = dyn(0xFF3B30, 1, 0xFF453A, 1)
    public static let liveText = dyn(0xD70015, 1, 0xFF6961, 1)
    public static let liveSoft = dyn(0xFF3B30, 0.13, 0xFF453A, 0.20)
    public static let needs = dyn(0xFF9500, 1, 0xFF9F0A, 1)
    public static let needsText = dyn(0xB86200, 1, 0xFFB340, 1)
    public static let needsSoft = dyn(0xFF9500, 0.15, 0xFF9F0A, 0.18)
    public static let ok = dyn(0x34C759, 1, 0x30D158, 1)
    public static let okText = dyn(0x1F8A3A, 1, 0x45D86A, 1)
    public static let okSoft = dyn(0x34C759, 0.14, 0x30D158, 0.17)

    // Text and lines.
    public static let text1 = dyn(0x1D1D1F, 1, 0xF5F5F7, 1)
    public static let text2 = dyn(0x3C3C43, 0.72, 0xEBEBF5, 0.68)
    public static let text3 = dyn(0x3C3C43, 0.45, 0xEBEBF5, 0.42)
    public static let hairline = dyn(0x000000, 0.12, 0xFFFFFF, 0.13)
    public static let separator = dyn(0x000000, 0.08, 0xFFFFFF, 0.08)

    // Fills and surfaces.
    public static let fill = dyn(0x787880, 0.10, 0x767680, 0.20)
    public static let fill2 = dyn(0x787880, 0.18, 0x767680, 0.32)
    public static let toggleOff = dyn(0x787880, 0.26, 0x767680, 0.40)
    public static let window = dyn(0xF6F6F8, 1, 0x242428, 1)
    public static let sidebar = dyn(0xECECF0, 0.78, 0x242428, 0.72)
    public static let card = dyn(0xFFFFFF, 1, 0x2C2C30, 1)
    public static let control = dyn(0xFFFFFF, 1, 0x3A3A3F, 1)
    public static let popover = dyn(0xF8F8FA, 0.94, 0x2C2C30, 0.92)
    public static let canvas = dyn(0xE4E4E8, 1, 0x1A1A1E, 1)
    public static let field = dyn(0xFFFFFF, 1, 0x1E1E21, 1)
    public static let segmentSelected = dyn(0xFFFFFF, 1, 0x56565C, 1)

    // The redaction cover itself: the same near-black in both appearances, never inverted.
    public static let mark = Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x13 / 255)
    public static let markText = Color.white

    // Sample terminals and thumbnails.
    public static let terminal = dyn(0x1E2430, 1, 0x15181F, 1)
    public static let terminalText = dyn(0xD6DBE6, 1, 0xC9CEDA, 1)
    /// The sample terminal's window chrome (title text, traffic-light dots, title bar), the same in both appearances.
    public static let terminalChrome = Color.white.opacity(0.55)
    public static let terminalChromeDot = Color.white.opacity(0.22)
    public static let terminalChromeBar = Color.white.opacity(0.06)

    // Drawn desks (setup's floating-thumbnail and login-item drawings).
    /// `--o-desk`: the desktop gradient's three stops, top-left to bottom-right.
    public static let deskStops: [Color] = [dyn(0xD4E0F1, 1, 0x19212F, 1), dyn(0xE2DEF0, 1, 0x251F34, 1), dyn(0xEFE5DD, 1, 0x2E2420, 1)]
    /// `--o-mb`: the menu bar strip on drawn desks.
    public static let deskMenuBar = dyn(0xF6F6F8, 0.66, 0x1C1C20, 0.58)

    // The floating thumbnail card (r3-a).
    /// `.timg` edge: a crisper hairline than `hairline`, since the card floats over any desktop.
    public static let imageEdge = dyn(0x000000, 0.22, 0xFFFFFF, 0.24)
    /// The cover bar's light outline on dark capsules (none in light).
    public static let coverBarEdge = dyn(0x000000, 0, 0xFFFFFF, 0.4)

    /// `--o-shadow-ctl`'s drop colour under a raised control: black at .06 in light, .3 in dark.
    public static let controlShadow = dyn(0x000000, 0.06, 0x000000, 0.30)
    /// `--o-shadow-pop`'s drop colour: rgba(24,28,48,.20) in light, black at .5 in dark.
    public static let popShadow = dyn(0x181C30, 0.20, 0x000000, 0.50)

    /// Detector category tile colours, by `Detector.Category` raw value.
    public static func category(_ raw: String) -> Color {
        switch raw {
        case "ai": return hex(0xAF52DE)
        case "cloud": return hex(0xFF9F0A)
        case "payments": return hex(0x30B265)
        case "scm": return hex(0x3C4049)
        case "messaging": return hex(0x5D8FD8)
        case "databases": return hex(0x2F7FB8)
        case "tokens": return hex(0x5B6CF0)
        case "config": return hex(0x8E8E93)
        case "personal": return hex(0xC9742A)
        case "network": return hex(0x6DAA4E)
        default: return hex(0x8E8E93)
        }
    }

    /// Settings sidebar tile colours.
    public enum SettingsTile {
        public static let protection = hex(0x34C759)
        public static let detectors = hex(0x007AFF)
        public static let style = hex(0xFF9500)
        public static let rules = hex(0xAF52DE)
        public static let journal = hex(0x5856D6)
        public static let shortcuts = hex(0x30B0C7)
        public static let about = hex(0x8E8E93)
    }

    // MARK: - Construction

    static func hex(_ rgb: UInt32, _ alpha: Double = 1) -> Color {
        Color(nsColor: nsColor(rgb, alpha))
    }

    static func nsColor(_ rgb: UInt32, _ alpha: Double) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: CGFloat(alpha))
    }

    /// A colour that resolves to `light` in light appearances and `dark` in dark ones.
    static func dyn(_ light: UInt32, _ lightAlpha: Double, _ dark: UInt32, _ darkAlpha: Double) -> Color {
        let l = nsColor(light, lightAlpha), d = nsColor(dark, darkAlpha)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil ? d : l
        })
    }
}

/// Non-colour constants from the unified pass (points).
public enum OMetric {
    public static let menuBarPanelWidth: CGFloat = 310
    public static let bannerWidth: CGFloat = 356
    public static let settingsSize = CGSize(width: 880, height: 620)
    public static let setupSize = CGSize(width: 880, height: 560)
    public static let journalSize = CGSize(width: 1040, height: 660)
    public static let journalSidebarWidth: CGFloat = 190
    public static let journalInspectorWidth: CGFloat = 300
    public static let viewerWidth: CGFloat = 720
    public static let viewerWidthWithInspector: CGFloat = 880
    public static let settingsSidebarWidth: CGFloat = 236
    public static let setupRailWidth: CGFloat = 206
    public static let thumbSmall = CGSize(width: 64, height: 44)
    public static let thumbLarge = CGSize(width: 120, height: 80)
    public static let hairline: CGFloat = 0.5
    public static let iconLine: CGFloat = 1.5

    /// Control sizes (system.html `.btn`, `.btn.sm`, `.ibtn`, `.pill`, `.bdg`, `.kbd`, `.ck`).
    public enum Control {
        public static let buttonHeight: CGFloat = 24
        public static let smallButtonHeight: CGFloat = 21
        public static let iconButton = CGSize(width: 28, height: 24)
        public static let pillHeight: CGFloat = 22
        public static let badgeHeight: CGFloat = 18
        public static let keyCapHeight: CGFloat = 17
        public static let checkbox: CGFloat = 14
        /// `.btn.dis`: every disabled control dims to this.
        public static let disabledOpacity: Double = 0.45
        public static let pressedOpacity: Double = 0.75
    }

    /// The floating thumbnail card (r3-a): its corner, the 19 pt capsule, the Obscura tile and the burst edges.
    public enum FloatingCard {
        public static let corner: CGFloat = 8
        public static let capsuleHeight: CGFloat = 19
        public static let capsuleInset: CGFloat = 6
        public static let tileSize: CGFloat = 13
        public static let edgeHeight: CGFloat = 6
    }

    /// The radius ladder. Banners alone use 14.
    public enum Radius {
        public static let xs: CGFloat = 4, s: CGFloat = 5, m: CGFloat = 6, ml: CGFloat = 7
        public static let l: CGFloat = 9, xl: CGFloat = 10, xxl: CGFloat = 12, banner: CGFloat = 14
    }

    /// Spacing scale.
    public enum Space {
        public static let xxs: CGFloat = 2, xs: CGFloat = 4, s: CGFloat = 6, m: CGFloat = 8
        public static let l: CGFloat = 12, xl: CGFloat = 16, xxl: CGFloat = 20, xxxl: CGFloat = 28
    }
}

/// Shadow tokens from system.html. A CSS blur of `b` px is a SwiftUI radius of `b / 2`.
public struct OShadow: Sendable, Hashable {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat

    public init(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat) {
        self.color = color; self.radius = radius; self.x = x; self.y = y
    }

    /// `--o-shadow-ctl`'s drop, `0 1px 1.5px` in `OColor.controlShadow`, under `.btn` and the other raised controls.
    /// The token's `.5px` hairline ring is the control's own `OColor.hairline` stroke.
    public static let control = OShadow(color: OColor.controlShadow, radius: 0.75, y: 1)
    /// `box-shadow: none`.
    public static let none = OShadow(color: .clear, radius: 0, y: 0)
    /// `--o-shadow-pop`'s drop, `0 12px 34px`, under a pop drawn inside a window or the panel (the duration pop). The
    /// token's `.5px` ring is the pop's own `OColor.hairline` stroke.
    public static let pop = OShadow(color: OColor.popShadow, radius: 17, y: 12)
}

public extension View {
    /// Casts a shadow token.
    func shadow(_ token: OShadow) -> some View {
        shadow(color: token.color, radius: token.radius, x: token.x, y: token.y)
    }
}

/// Type scale (system font, as the house style requires).
public enum OFont {
    public static let largeTitle = Font.system(size: 22, weight: .bold)
    public static let title = Font.system(size: 15, weight: .semibold)
    public static let headline = Font.system(size: 13, weight: .semibold)
    public static let body = Font.system(size: 13)
    public static let callout = Font.system(size: 12)
    public static let caption = Font.system(size: 11)
    public static let groupHeader = Font.system(size: 11.5, weight: .semibold)
    public static let mono = Font.system(size: 12, design: .monospaced)
    public static let number = Font.system(size: 20, weight: .semibold).monospacedDigit()
    /// `.btn` and `.btn.sm` labels.
    public static let button = Font.system(size: 12.5, weight: .medium)
    public static let smallButton = Font.system(size: 11.5, weight: .medium)
    /// `.pill`, `.bdg` and `.kbd` words.
    public static let pill = Font.system(size: 11.5, weight: .semibold)
    public static let badge = Font.system(size: 11, weight: .medium)
    public static let keyCap = Font.system(size: 11, weight: .medium)
    /// The floating thumbnail's capsule words (`.cap1`).
    public static let capsule = Font.system(size: 10.5, weight: .semibold)
}
