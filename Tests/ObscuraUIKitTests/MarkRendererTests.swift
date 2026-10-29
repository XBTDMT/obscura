import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import ObscuraPrefs
@testable import ObscuraUIKit

/// G-21: every mark in every colour style and key state, drawn natively: present, inside its bounds, the plain part in
/// the menu bar's label colour (light, dark, highlighted), a template only for One colour, the Focus moon heavier than
/// the update dot, Paused in the paused colour, and the count badge beside the mark, never on its dot.
@Suite @MainActor struct MarkRendererTests {
    static let keyStates: [MarkState] = MarkState.allCases
    static let designed = MenuBarMarkID.allCases.filter { $0 != .classic }

    /// The image's pixels as RGBA bytes (premultiplied, sRGB), row 0 at the top.
    struct Pixels {
        let width: Int, height: Int
        let bytes: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            var b = [UInt8](repeating: 0, count: width * height * 4)
            b.withUnsafeMutableBytes { buf in
                let ctx = CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            bytes = b
        }

        /// The pixel at (x, y), y counted from the top, un-premultiplied.
        func rgba(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
            let i = (y * width + x) * 4
            let a = Double(bytes[i + 3]) / 255
            guard a > 0 else { return (0, 0, 0, 0) }
            return (Double(bytes[i]) / 255 / a, Double(bytes[i + 1]) / 255 / a, Double(bytes[i + 2]) / 255 / a, a)
        }

        func count(where test: (Double, Double, Double, Double) -> Bool) -> Int {
            var n = 0
            for y in 0..<height { for x in 0..<width { let p = rgba(x, y); if test(p.r, p.g, p.b, p.a) { n += 1 } } }
            return n
        }

        /// The bounding box of pixels passing `test`, in pixels (y from the top).
        func box(where test: (Double, Double, Double, Double) -> Bool) -> CGRect {
            var r = CGRect.null
            for y in 0..<height { for x in 0..<width { let p = rgba(x, y); if test(p.r, p.g, p.b, p.a) { r = r.union(CGRect(x: x, y: y, width: 1, height: 1)) } } }
            return r
        }

        var opaque: Int { count { _, _, _, a in a > 0.2 } }
    }

    static func render(_ mark: MenuBarMarkID, _ style: MenuBarMarkStyle = .warm, _ state: MarkState = .protected,
                       appearance: MarkAppearance = .light, paused: PausedColor = .red, count: Int = 0, scale: CGFloat = 2,
                       pose: MarkPose = MarkPose()) throws -> (Pixels, NSImage) {
        let frame = MarkFrame(mark: mark, style: style, state: state, pose: pose)
        let look = MarkLook(count: count, appearance: appearance, pausedColor: paused)
        let image = MenuBarMarkImage.image(frame, look, scales: [scale])
        var rect = CGRect(origin: .zero, size: image.size)
        let cg = try #require(image.cgImage(forProposedRect: &rect, context: nil,
                                            hints: [.ctm: NSAffineTransform(transform: AffineTransform(scale: scale))]))
        return (Pixels(cg), image)
    }

    // MARK: Every mark, style and state

    @Test(arguments: MenuBarMarkID.allCases)
    func everyStyleAndStateDrawsInsideTheSquare(mark: MenuBarMarkID) throws {
        for style in MenuBarMarkStyle.allCases {
            for state in Self.keyStates {
                for scale in [CGFloat(1), 2] {
                    let (px, image) = try Self.render(mark, style, state, scale: scale)
                    let side = Int(18 * scale)
                    #expect(image.size == CGSize(width: 18, height: 18), "\(mark) \(style) \(state)")
                    #expect(px.width == side && px.height == side, "\(mark) \(style) \(state) @\(scale)x is \(px.width)×\(px.height)")
                    // Present: a mark covers a real share of its square (the thin paused shield is the lightest, ~6 %).
                    #expect(px.opaque > side * side / 25, "\(mark) \(style) \(state) @\(scale)x drew \(px.opaque) px")
                }
            }
        }
    }

    /// Inside its bounds: every painted shape, stroke width included and clipped as drawn, lies on the 16-unit grid, so
    /// nothing is cut off by the image's edge at any size.
    @Test func everyMarkFitsItsGrid() {
        for mark in Self.designed {
            for paused in [false, true] {
                let design = MarkGeometry.design(mark, paused: paused)
                var box = CGRect.null
                for piece in design.plain + design.designed {
                    for op in piece.ops where op.paint != .knock {
                        var b: CGRect
                        switch op.kind {
                        case .fill: b = op.path.boundingBoxOfPath
                        case .stroke(let w, let cap, let join):
                            b = op.path.copy(strokingWithWidth: w, lineCap: cap, lineJoin: join, miterLimit: 10).boundingBoxOfPath
                        }
                        if let clip = piece.clip { b = b.intersection(clip.boundingBoxOfPath) }
                        box = box.union(b)
                    }
                }
                #expect(box.minX >= -0.001 && box.minY >= -0.001 && box.maxX <= 16.001 && box.maxY <= 16.001,
                        "\(mark)\(paused ? " paused" : "") spans \(box)")
                #expect(box.width > 8 && box.height > 8, "\(mark) fills its grid: \(box)")
            }
        }
    }

    @Test func everyMarkHasANameAndTheGalleryNumbersAreThePickedFifteen() {
        #expect(MenuBarMarkID.allCases.count == 16)
        #expect(Set(MenuBarMarkID.allCases.map(\.title)).count == 16, "every mark has its own name")
        #expect(MenuBarMarkID.classic.title == "Classic ring")
        #expect(MenuBarMarkID.allCases.compactMap(\.galleryNumber) == [1, 6, 11, 15, 17, 18, 23, 26, 33, 35, 40, 42, 45, 46, 49])
        #expect(MenuBarMarkStyle.allCases.map(\.title) == ["Warm", "Glass", "Indigo", "One colour"])
        for mark in Self.designed { #expect(mark.designedPieceCount > 0, "\(mark) has a designed part") }
    }

    // MARK: Light, dark, highlighted

    /// A point on each mark's plain part (16-unit grid), where only the plain stroke is drawn.
    static func plainPoint(_ mark: MenuBarMarkID) -> CGPoint {
        switch mark {
        case .viewfinder: return CGPoint(x: 1.6, y: 3.5)
        case .shield: return CGPoint(x: 2.5, y: 6)
        default: return CGPoint(x: 2.49, y: 8)
        }
    }

    @Test(arguments: [MarkAppearance.light, .dark, MarkAppearance(isDark: false, isEmphasized: true), MarkAppearance(isDark: true, isEmphasized: true)])
    func thePlainPartFollowsTheLabelColour(appearance: MarkAppearance) throws {
        let ink = MarkPalette.ink(appearance)
        for mark in Self.designed {
            for style in [MenuBarMarkStyle.warm, .glass, .indigo] {
                let (px, image) = try Self.render(mark, style, .protected, appearance: appearance, scale: 2)
                #expect(!image.isTemplate)
                let p = Self.plainPoint(mark)
                let c = px.rgba(Int(p.x * 18 / 16 * 2), Int(p.y * 18 / 16 * 2))
                #expect(abs(c.r - ink.r) < 0.06 && abs(c.g - ink.g) < 0.06 && abs(c.b - ink.b) < 0.06,
                        "\(mark) \(style) plain part is \(c), the bar's ink is \(ink)")
                #expect(c.a > 0.6, "\(mark) plain part is drawn at \(p)")
            }
        }
    }

    @Test func theDesignedPartTakesTheStyleNotTheInk() throws {
        // Two-tone's right half at 3 o'clock.
        let at = (x: Int(13.51 * 18 / 16 * 2), y: Int(8 * 18 / 16 * 2))
        var seen: [MarkRGBA] = []
        for style in [MenuBarMarkStyle.warm, .glass, .indigo] {
            for appearance in [MarkAppearance.light, .dark] {
                let (px, _) = try Self.render(.twoTone, style, .protected, appearance: appearance)
                let c = px.rgba(at.x, at.y)
                #expect(max(abs(c.r - c.g), abs(c.r - c.b), abs(c.g - c.b)) > 0.15, "\(style) is coloured, not grey: \(c)")
                seen.append(MarkRGBA(c.r, c.g, c.b))
            }
        }
        // At 3 o'clock the vertical gradient is at its middle stop: Warm's pink, and Glass's middle stop is the brand
        // indigo (Indigo's only colour), so light and dark give four distinct colours.
        #expect(Set(seen.map { "\(Int($0.r * 20)),\(Int($0.g * 20)),\(Int($0.b * 20))" }).count == 4, "styles and appearances differ")
        // One colour: the designed half is the ink too.
        let (mono, image) = try Self.render(.twoTone, .oneColor, .protected)
        #expect(image.isTemplate)
        let c = mono.rgba(at.x, at.y)
        #expect(c.a > 0.6 && c.r < 0.05 && c.g < 0.05 && c.b < 0.05, "a template draws in black, for macOS to tint: \(c)")
    }

    /// The ink is the system's own label colour (so a coloured mark's plain part matches the template icons beside it).
    @Test func theInkIsTheSystemLabelColour() throws {
        for (name, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            let appearance = try #require(NSAppearance(named: name))
            var system = NSColor.black
            appearance.performAsCurrentDrawingAppearance { system = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black }
            let ink = MarkPalette.ink(MarkAppearance(isDark: dark))
            #expect(abs(system.redComponent - ink.r) < 0.01 && abs(system.alphaComponent - ink.a) < 0.01, "\(name.rawValue)")
            #expect(MarkAppearance(appearance).isDark == dark)
        }
        #expect(MarkPalette.ink(MarkAppearance(isDark: false, isEmphasized: true)) == MarkRGBA(1, 1, 1, 1))
    }

    // MARK: Template

    @Test(arguments: MenuBarMarkID.allCases)
    func onlyOneColourIsATemplate(mark: MenuBarMarkID) throws {
        for style in MenuBarMarkStyle.allCases {
            let (_, image) = try Self.render(mark, style, .protected)
            if mark == .classic {
                #expect(image.isTemplate, "the Classic ring keeps its template in every style")
            } else {
                #expect(image.isTemplate == (style == .oneColor), "\(mark) \(style)")
            }
            // A coloured dot or badge always makes a colour image.
            #expect(!(try Self.render(mark, style, .caught).1.isTemplate))
            #expect(!(try Self.render(mark, style, .protected, count: 2).1.isTemplate))
        }
        if mark != .classic {
            #expect(!(try Self.render(mark, .oneColor, .paused, paused: .red).1.isTemplate), "a red pause keeps its colour")
            #expect(try Self.render(mark, .oneColor, .paused, paused: .grey).1.isTemplate, "a grey pause is the template")
        }
    }

    // MARK: Focus moon and Paused colour

    static func accent(_ px: Pixels) -> Int {
        px.count { r, g, b, a in a > 0.5 && b > r + 0.23 && b > g + 0.23 }
    }

    @Test(arguments: MenuBarMarkID.allCases)
    func theFocusMoonIsHeavierThanTheUpdateDot(mark: MenuBarMarkID) throws {
        for appearance in [MarkAppearance.light, .dark] {
            // One colour, so only the dot and the moon are accent.
            let dot = Self.accent(try Self.render(mark, .oneColor, .waiting, appearance: appearance).0)
            let moon = Self.accent(try Self.render(mark, .oneColor, .focusHolding, appearance: appearance).0)
            #expect(dot > 0 && moon > dot, "\(mark): moon \(moon) vs dot \(dot) pixels")
        }
    }

    @Test(arguments: MenuBarMarkID.allCases)
    func pausedUsesThePausedColour(mark: MenuBarMarkID) throws {
        func red(_ px: Pixels) -> Int { px.count { r, g, b, a in a > 0.5 && r > 0.85 && g < 0.4 && b < 0.4 } }
        func orange(_ px: Pixels) -> Int { px.count { r, g, b, a in a > 0.5 && r > 0.85 && g > 0.45 && g < 0.75 && b < 0.2 } }
        for style in MenuBarMarkStyle.allCases {
            let r = try Self.render(mark, style, .paused, paused: .red).0
            let o = try Self.render(mark, style, .paused, paused: .orange).0
            let g = try Self.render(mark, style, .paused, paused: .grey).0
            #expect(red(r) > 20, "\(mark) \(style) paused red")
            #expect(orange(o) > 20 && red(o) == 0, "\(mark) \(style) paused orange")
            #expect(red(g) == 0 && orange(g) == 0, "\(mark) \(style) paused grey has no colour")
            // The whole mark takes the paused colour: no gradient left.
            #expect(Self.accent(r) == 0, "\(mark) \(style) keeps no style colour while paused")
        }
    }

    // MARK: The count badge (redman 2026-10-27)

    @Test func theBadgeNeverOverlapsTheStateDot() {
        for pointSize in [CGFloat(16), 18, 22, 36] {
            let dot = MenuBarBadgeLayout.dotRect(pointSize: pointSize)
            for count in [1, 9, 10, 42, 99, 100, 5000] {
                let badge = MenuBarBadgeLayout.badgeRect(pointSize: pointSize, count: count)!
                #expect(!badge.intersects(dot), "\(count) at \(pointSize) pt: badge \(badge) dot \(dot)")
                #expect(badge.minX >= pointSize, "the badge starts beside the mark's square")
                #expect(badge.maxX <= MenuBarBadgeLayout.width(pointSize: pointSize, count: count, reservesBadgeSpace: false) + 0.001)
            }
        }
        #expect(MenuBarBadgeLayout.badgeRect(pointSize: 18, count: 0) == nil)
        // S-12: the reserved width is the one-figure badge's, and a one-figure count fills it exactly.
        #expect(MenuBarBadgeLayout.width(pointSize: 18, count: 0, reservesBadgeSpace: true)
                == MenuBarBadgeLayout.width(pointSize: 18, count: 3, reservesBadgeSpace: false))
        #expect(ObscuraMarkDrawing.badgedWidth == 18 + MenuBarBadgeLayout.gap + MenuBarBadgeLayout.minimumWidth)
        #expect(MenuBarBadgeLayout.width(pointSize: 18, count: 100, reservesBadgeSpace: true) > ObscuraMarkDrawing.badgedWidth,
                "99+ grows past the reservation rather than covering the mark")
    }

    @Test(arguments: MenuBarMarkID.allCases)
    func theDrawnBadgeSitsBesideTheDrawnDot(mark: MenuBarMarkID) throws {
        let scale: CGFloat = 2
        for count in [3, 27] {
            let (px, image) = try Self.render(mark, .warm, .caught, count: count, scale: scale)
            #expect(image.size.width == MenuBarBadgeLayout.width(pointSize: 18, count: count, reservesBadgeSpace: false))
            let badge = MenuBarBadgeLayout.badgeRect(pointSize: 18, count: count)!
            let green = px.box { r, g, b, a in a > 0.5 && g > 0.6 && r < 0.4 && b < 0.5 }
            let badgePixels = px.box { r, g, b, a in a > 0.5 && b > r + 0.2 && b > g + 0.2 }
                .intersection(CGRect(x: badge.minX * scale, y: 0, width: 1000, height: 1000))
            #expect(!green.isNull && !badgePixels.isNull, "\(mark): both the dot and the badge are drawn")
            #expect(green.maxX <= badge.minX * scale, "\(mark) \(count): the green dot ends at \(green.maxX), the badge starts at \(badge.minX * scale)")
        }
    }

    // MARK: 1× and 2×

    @Test func everyImageCarriesA1xAnd2xBitmap() {
        for mark in [MenuBarMarkID.classic, .pixelatedHalf, .checkerBand, .shutter] {
            let image = MenuBarMarkImage.image(MarkFrame(mark: mark, state: .protected), MarkLook())
            let widths = image.representations.map(\.pixelsWide).sorted()
            if mark == .classic {
                #expect(!widths.isEmpty)
            } else {
                #expect(widths == [18, 36], "\(mark): \(widths)")
            }
        }
    }

    @Test func theAccessibilityWordsStayTheStates() {
        for mark in MenuBarMarkID.allCases {
            for state in MarkState.allCases {
                let image = MenuBarMarkImage.image(MarkFrame(mark: mark, state: state), MarkLook(count: 2))
                #expect(image.accessibilityDescription == MarkCopy.accessibilityLabel(state, count: 2), "\(mark) \(state)")
            }
        }
    }

    // MARK: Legibility tuning (G-21: 26 and 35 at 16 pt)

    @Test func theTwoSoftMarksAreTunedAndCrispAt1x() throws {
        // 26: each checker cell is a whole number of device pixels at 18 pt (2 px at 1×, 4 at 2×).
        #expect(abs(MarkTuning.checkerCell * 18 / 16 - 2) < 0.0001)
        #expect(MarkTuning.checkerCell > MarkTuning.galleryCheckerCell)
        // 35: larger disc and aperture, so six gaps survive at 1×.
        #expect(MarkTuning.shutterDiscRadius > MarkTuning.galleryShutterDiscRadius)
        #expect(MarkTuning.shutterCentreRadius > MarkTuning.galleryShutterCentreRadius)
        // The disc still clears the ring's inner edge by at least one device pixel at 1× (18 pt).
        #expect((MarkGeometry.radius - MarkGeometry.stroke / 2 - MarkTuning.shutterDiscRadius) * 18 / 16 >= 0.8)
        // Checker: at 1× the band has fully opaque cells and fully empty ones, not a grey blur.
        let (px, _) = try Self.render(.checkerBand, .indigo, .protected, scale: 1)
        let strong = px.count { _, _, b, a in a > 0.9 && b > 0.6 }
        #expect(strong >= 6, "\(strong) solid checker pixels at 1×")
    }
}
