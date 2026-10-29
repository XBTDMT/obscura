// Draws the picked menu bar mark (G-21) natively with Core Graphics: vector paths on the 16-unit grid scaled to the
// point size, rendered into one bitmap per display scale (1× and 2×), so the mark is crisp on every screen. Pure: no
// view, no main actor. The Classic ring is not drawn here; `MenuBarMarkImage` sends it to `ObscuraMarkDrawing`, unchanged.
//
// How the parts follow the menu bar (G-21: "the plain part drawn in the menu bar's label colour for the current
// appearance"): `MarkAppearance` says whether the bar is dark and whether the item is highlighted on an emphasized
// background (AppKit's own signal for drawing template content white). The plain part takes `MarkPalette.ink`, which is
// `NSColor.labelColor` for aqua and darkAqua (pinned by a test) and white when emphasized; the designed part takes the
// style's colours for light or dark. One colour with no coloured dot is a template image, so macOS tints it itself.
//
// The gallery's knock-out (`K`) paints the menu bar's own colour to cut a gap. Here a gap is real transparency: the
// designed part is drawn into its own layer, its coverage is cut out of the plain part (`destinationOut`) and its
// content added back (`plusLighter`), which is exactly the browser's result for an opaque background, at any opacity.
public import CoreGraphics
public import ObscuraPrefs
import CoreText
public import AppKit
import SwiftUI

/// A colour as four sRGB components, so drawing stays a pure value computation.
public struct MarkRGBA: Sendable, Hashable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }
    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// The menu bar the mark sits in.
public struct MarkAppearance: Sendable, Hashable {
    /// The bar is dark (darkAqua or a dark wallpaper's bar).
    public var isDark: Bool
    /// The item is highlighted on an emphasized background (the panel open, where AppKit draws template content white).
    public var isEmphasized: Bool

    public init(isDark: Bool, isEmphasized: Bool = false) { self.isDark = isDark; self.isEmphasized = isEmphasized }

    public static let light = MarkAppearance(isDark: false)
    public static let dark = MarkAppearance(isDark: true)

    /// The appearance an AppKit view draws in: dark or light from its effective appearance, emphasized from its cell.
    @MainActor public init(_ appearance: NSAppearance, emphasized: Bool = false) {
        self.init(isDark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, isEmphasized: emphasized)
    }
}

/// The colours, from the gallery's strips (`.lt` / `.dk`) and Tokens.swift.
public enum MarkPalette {
    /// `NSColor.labelColor` in aqua and darkAqua (MarkRendererTests pins these to the system's own values), and white
    /// on an emphasized highlight.
    public static func ink(_ a: MarkAppearance) -> MarkRGBA {
        if a.isEmphasized { return MarkRGBA(1, 1, 1, 1) }
        return a.isDark ? MarkRGBA(1, 1, 1, 0.847) : MarkRGBA(0, 0, 0, 0.847)
    }

    /// The style's three gradient stops (start, middle, end); nil for One colour, which paints with the ink.
    public static func gradient(_ style: MenuBarMarkStyle, dark: Bool) -> [MarkRGBA]? {
        switch (style, dark) {
        case (.warm, false): return [MarkRGBA(hex: 0x5B5BD6), MarkRGBA(hex: 0xD6449B), MarkRGBA(hex: 0xE8742A)]
        case (.warm, true): return [MarkRGBA(hex: 0x8383E0), MarkRGBA(hex: 0xF07CC0), MarkRGBA(hex: 0xFFA060)]
        case (.glass, false): return [MarkRGBA(hex: 0x0A84FF), MarkRGBA(hex: 0x5B5BD6), MarkRGBA(hex: 0x8E44D6)]
        case (.glass, true): return [MarkRGBA(hex: 0x64B5FF), MarkRGBA(hex: 0x8383E0), MarkRGBA(hex: 0xB98AF0)]
        case (.indigo, false): return Array(repeating: MarkRGBA(hex: 0x5B5BD6), count: 3)
        case (.indigo, true): return Array(repeating: MarkRGBA(hex: 0x8383E0), count: 3)
        case (.oneColor, _): return nil
        }
    }

    public static func ok(dark: Bool) -> MarkRGBA { MarkRGBA(hex: dark ? 0x30D158 : 0x34C759) }
    public static func needs(dark: Bool) -> MarkRGBA { MarkRGBA(hex: dark ? 0xFF9F0A : 0xFF9500) }
    public static func accent(dark: Bool) -> MarkRGBA { MarkRGBA(hex: dark ? 0x8383E0 : 0x5B5BD6) }
    public static func live(dark: Bool) -> MarkRGBA { MarkRGBA(hex: dark ? 0xFF453A : 0xFF3B30) }

    /// The paused mark's colour (G-19 #17): red, orange, or grey (the ink, as the Classic ring's template).
    public static func paused(_ color: PausedColor, _ a: MarkAppearance) -> MarkRGBA {
        switch color {
        case .red: return live(dark: a.isDark)
        case .orange: return needs(dark: a.isDark)
        case .grey: return ink(a)
        }
    }
}

/// Where the count badge sits: beside the mark, never on its state dot (redman 2026-10-27; the gallery draws it so).
/// All values are in points for an 18 pt mark and scale with the point size.
public enum MenuBarBadgeLayout {
    /// The space between the mark's square and the badge.
    public static let gap: CGFloat = 1
    public static let height: CGFloat = 13
    public static let minimumWidth: CGFloat = 13
    public static let padding: CGFloat = 3
    public static let fontSize: CGFloat = 9

    /// The badge's width for `count` at 18 pt: its figures plus padding, at least round.
    public static func badgeWidth(_ count: Int) -> CGFloat {
        max(minimumWidth, (textWidth(CountBadge.text(count)) + 2 * padding).rounded(.up))
    }

    /// The image's width: the square mark; with a count, the mark, the gap and the badge; with the space reserved
    /// (S-12) and no count, the one-figure badge's width, so the items beside it never move when a count comes.
    public static func width(pointSize: CGFloat, count: Int, reservesBadgeSpace: Bool) -> CGFloat {
        let k = pointSize / 18
        if count > 0 { return pointSize + (gap + badgeWidth(count)) * k }
        if reservesBadgeSpace { return pointSize + (gap + minimumWidth) * k }
        return pointSize
    }

    /// The badge's rectangle in the image (y downwards), or nil with no count.
    public static func badgeRect(pointSize: CGFloat, count: Int) -> CGRect? {
        guard count > 0 else { return nil }
        let k = pointSize / 18
        return CGRect(x: pointSize + gap * k, y: 0, width: badgeWidth(count) * k, height: height * k)
    }

    /// The lower-right state dot with its clean gap (caught green, needs-you orange), in the image (y downwards). The
    /// Classic ring and every new mark put it at the same spot: centre 12.8/16, gap radius 2.93/16.
    public static func dotRect(pointSize: CGFloat) -> CGRect {
        let u = pointSize / 16
        return CGRect(x: (12.8 - 2.93) * u, y: (12.8 - 2.93) * u, width: 2 * 2.93 * u, height: 2 * 2.93 * u)
    }

    static func font(size: CGFloat) -> CTFont {
        NSFont.systemFont(ofSize: size, weight: .bold) as CTFont
    }

    static func line(_ text: String, size: CGFloat, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: size),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    static func textWidth(_ text: String) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, size: fontSize, color: CGColor(gray: 1, alpha: 1)), nil, nil, nil))
    }
}

/// One frame of a mark: which mark, how it is coloured, its state and the pose of any motion.
public struct MarkFrame: Sendable, Hashable {
    public var mark: MenuBarMarkID
    public var style: MenuBarMarkStyle
    public var state: MarkState
    public var pose: MarkPose
    /// The state a cross-fade comes from (`pose.crossFade` is the progress into `state`).
    public var crossFrom: MarkState?
    /// The Classic ring's checking sweep (0…1).
    public var sweep: Double

    public init(mark: MenuBarMarkID, style: MenuBarMarkStyle = .warm, state: MarkState, pose: MarkPose = MarkPose(),
                crossFrom: MarkState? = nil, sweep: Double = 0) {
        self.mark = mark
        self.style = style
        self.state = state
        self.pose = pose
        self.crossFrom = crossFrom
        self.sweep = sweep
    }
}

/// Where and how big the frame is drawn, and the colours it depends on.
public struct MarkLook: Sendable, Hashable {
    public var pointSize: CGFloat
    /// Catches the count badge stands for; 0 = no badge.
    public var count: Int
    /// S-12: keep the badge's width with no badge.
    public var reservesBadgeSpace: Bool
    public var appearance: MarkAppearance
    public var pausedColor: PausedColor

    public init(pointSize: CGFloat = 18, count: Int = 0, reservesBadgeSpace: Bool = false, appearance: MarkAppearance = .light,
                pausedColor: PausedColor = .red) {
        self.pointSize = pointSize
        self.count = count
        self.reservesBadgeSpace = reservesBadgeSpace
        self.appearance = appearance
        self.pausedColor = pausedColor
    }

    public var width: CGFloat { MenuBarBadgeLayout.width(pointSize: pointSize, count: count, reservesBadgeSpace: reservesBadgeSpace) }
}

public enum MarkRenderer {
    /// Whether the frame is a template image: One colour, no badge, and nothing coloured (no state dot, no tinted pause).
    public static func isTemplate(_ frame: MarkFrame, _ look: MarkLook) -> Bool {
        guard frame.mark != .classic, frame.style == .oneColor, look.count == 0 else { return false }
        func coloured(_ s: MarkState) -> Bool { s.hasDot || (s == .paused && look.pausedColor != .grey) }
        if coloured(frame.state) { return false }
        if frame.pose.crossFade != nil, let from = frame.crossFrom, coloured(from) { return false }
        return true
    }

    /// The frame drawn at `scale` pixels per point, or nil for the Classic ring (drawn by `ObscuraMarkDrawing`).
    public static func render(_ frame: MarkFrame, _ look: MarkLook, scale: CGFloat) -> CGImage? {
        guard frame.mark != .classic else { return nil }
        let w = Int((look.width * scale).rounded(.up)), h = Int((look.pointSize * scale).rounded(.up))
        guard let ctx = bitmap(w, h) else { return nil }
        let template = isTemplate(frame, look)
        let colours = Colours(frame: frame, look: look, template: template)
        let square = Int((look.pointSize * scale).rounded(.up))
        let markImage: CGImage?
        if let p = frame.pose.crossFade, let from = frame.crossFrom {
            var fromFrame = frame
            fromFrame.state = from
            let a = stateImage(fromFrame, colours, side: square)
            let b = stateImage(frame, colours, side: square)
            guard let mixed = bitmap(square, square) else { return nil }
            if let a { mixed.setAlpha(1 - p); mixed.draw(a, in: CGRect(x: 0, y: 0, width: square, height: square)) }
            if let b { mixed.setAlpha(p); mixed.draw(b, in: CGRect(x: 0, y: 0, width: square, height: square)) }
            markImage = mixed.makeImage()
        } else {
            markImage = stateImage(frame, colours, side: square)
        }
        // Pixel space, y up: the square sits at the left, full height.
        if let markImage { ctx.draw(markImage, in: CGRect(x: 0, y: h - square, width: square, height: square)) }
        if let rect = MenuBarBadgeLayout.badgeRect(pointSize: look.pointSize, count: look.count) {
            drawBadge(look.count, in: rect, imageHeight: CGFloat(h), scale: scale, ctx: ctx,
                      accent: MarkPalette.accent(dark: look.appearance.isDark), k: look.pointSize / 18)
        }
        return ctx.makeImage()
    }

    // MARK: Drawing

    /// The resolved paints for one frame.
    struct Colours {
        var ink: MarkRGBA
        var gradient: [MarkRGBA]?
        var pausedInk: MarkRGBA
        var ok: MarkRGBA, needs: MarkRGBA, accent: MarkRGBA

        init(frame: MarkFrame, look: MarkLook, template: Bool) {
            let a = look.appearance
            ink = template ? MarkRGBA(0, 0, 0, 1) : MarkPalette.ink(a)
            gradient = MarkPalette.gradient(frame.style, dark: a.isDark)
            pausedInk = template ? ink : MarkPalette.paused(look.pausedColor, a)
            ok = MarkPalette.ok(dark: a.isDark)
            needs = MarkPalette.needs(dark: a.isDark)
            accent = MarkPalette.accent(dark: a.isDark)
        }
    }

    static func bitmap(_ w: Int, _ h: Int) -> CGContext? {
        guard w > 0, h > 0 else { return nil }
        return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// A square layer whose user space is the 16-unit grid, y downwards.
    static func gridLayer(_ side: Int) -> CGContext? {
        guard let c = bitmap(side, side) else { return nil }
        c.translateBy(x: 0, y: CGFloat(side))
        c.scaleBy(x: CGFloat(side) / 16, y: -CGFloat(side) / 16)
        c.setShouldAntialias(true)
        c.interpolationQuality = .high
        return c
    }

    /// Draws a layer's image over `ctx` pixel for pixel (both layers share a size), whatever the current transform.
    static func composite(_ image: CGImage, onto ctx: CGContext, blend: CGBlendMode = .normal, alpha: CGFloat = 1,
                          transform: CGAffineTransform = .identity) {
        ctx.saveGState()
        ctx.concatenate(ctx.ctm.inverted())
        ctx.concatenate(transform)
        ctx.setBlendMode(blend)
        ctx.setAlpha(alpha)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.restoreGState()
    }

    /// One state of the mark, with its overlays and dot, in a square of `side` pixels.
    static func stateImage(_ frame: MarkFrame, _ colours: Colours, side: Int) -> CGImage? {
        guard let m = gridLayer(side) else { return nil }
        let state = frame.state
        let paused = state == .paused
        let design = MarkGeometry.design(frame.mark, paused: paused)
        let plainInk = paused ? colours.pausedInk : colours.ink
        let designedPaint: DesignedPaint = paused ? .flat(colours.pausedInk)
            : (colours.gradient.map { .gradient($0, design.gradient) } ?? .flat(colours.ink))
        let pose = frame.pose

        // The mark itself: plain, then the designed part cut in and added back.
        if let body = markBody(design, plainInk: plainInk, designed: designedPaint, pose: pose, side: side) {
            let s = CGFloat(side)
            let k = CGFloat(pose.markScale)
            let scale = CGAffineTransform(translationX: s / 2, y: s / 2).scaledBy(x: k, y: k).translatedBy(x: -s / 2, y: -s / 2)
            let alpha: CGFloat = state == .checking ? 0.5 : 1
            if state == .partlyProtected {
                m.saveGState(); m.clip(to: CGRect(x: -1, y: -1, width: 9, height: 18))
                composite(body, onto: m, alpha: alpha, transform: scale)
                m.restoreGState()
                m.saveGState(); m.clip(to: CGRect(x: 8, y: -1, width: 9, height: 18))
                composite(body, onto: m, alpha: alpha * 0.35, transform: scale)
                m.restoreGState()
            } else {
                composite(body, onto: m, alpha: alpha, transform: scale)
            }
        }

        // Overlays, outside the mark's opacity (the gallery's `.ov`): the checking scan line and the wipe.
        if state == .checking {
            let y = CGFloat(pose.scanY ?? MarkTimeline.scanRest)
            fill(MarkGeometry.rect(1.6, y - 0.62, 12.8, 1.24, rx: 0.62), with: paused ? .flat(colours.pausedInk) : designedPaint, in: m)
        }
        if let x = pose.wipeX {
            fill(MarkGeometry.rect(-1.3 + CGFloat(x), 0.6, 1.24, 14.8, rx: 0.62), with: designedPaint, in: m)
        }

        // The state dot, with its clean gap.
        dot(for: state, colours: colours, pose: pose, in: m)
        return m.makeImage()
    }

    enum DesignedPaint {
        case flat(MarkRGBA)
        case gradient([MarkRGBA], (CGPoint, CGPoint))
    }

    /// Plain part, then the designed part's coverage cut out and its content added: the browser's result for the
    /// gallery's knock-outs on an opaque bar, at any opacity.
    static func markBody(_ design: MarkDesign, plainInk: MarkRGBA, designed: DesignedPaint, pose: MarkPose, side: Int) -> CGImage? {
        guard let body = gridLayer(side) else { return nil }
        for piece in design.plain { draw(piece, in: body, paint: { op, ctx in
            switch op.paint {
            case .plain, .designed: paint(op, .flat(plainInk), in: ctx)
            case .knock: knock(op, in: ctx)
            }
        }) }
        guard !design.designed.isEmpty, let content = gridLayer(side), let coverage = gridLayer(side) else { return body.makeImage() }
        let offset = CGAffineTransform(translationX: CGFloat(pose.designedDX), y: CGFloat(pose.designedDY))
        for (i, piece) in design.designed.enumerated() {
            let piecePose = pose.pieces.flatMap { i < $0.count ? $0[i] : nil } ?? MarkPiecePose(opacity: 1, scale: 1)
            guard piecePose.opacity > 0 else { continue }
            let box = piece.box
            let c = CGPoint(x: box.midX, y: box.midY)
            let k = CGFloat(piecePose.scale)
            let t = offset.translatedBy(x: c.x, y: c.y).scaledBy(x: k, y: k).translatedBy(x: -c.x, y: -c.y)
            // A piece's opacity multiplies each of its ops (no piece layer), so a knock-out piece still cuts the pieces
            // drawn before it, as the gallery's background-coloured shapes do.
            let m = CGFloat(piecePose.opacity)
            for layer in [content, coverage] { layer.saveGState(); layer.concatenate(t) }
            draw(piece, in: content, paint: { op, ctx in
                switch op.paint {
                case .designed: paint(op, designed, in: ctx, multiplier: m)
                case .plain: paint(op, .flat(plainInk), in: ctx, multiplier: m)
                case .knock: knock(op, in: ctx, multiplier: m)
                }
            })
            draw(piece, in: coverage, paint: { op, ctx in paint(op, .flat(MarkRGBA(0, 0, 0, 1)), in: ctx, multiplier: m) })
            for layer in [content, coverage] { layer.restoreGState() }
        }
        let alpha = CGFloat(pose.designedOpacity)
        if let cover = coverage.makeImage() { composite(cover, onto: body, blend: .destinationOut, alpha: alpha) }
        if let added = content.makeImage() { composite(added, onto: body, blend: .plusLighter, alpha: alpha) }
        return body.makeImage()
    }

    static func draw(_ piece: MarkPiece, in ctx: CGContext, paint: (MarkOp, CGContext) -> Void) {
        ctx.saveGState()
        if let clip = piece.clip { ctx.addPath(clip); ctx.clip() }
        for op in piece.ops { paint(op, ctx) }
        ctx.restoreGState()
    }

    /// Clips to the op's shape (its fill, or its stroke outline).
    static func clip(to op: MarkOp, in ctx: CGContext) {
        ctx.addPath(op.path)
        switch op.kind {
        case .fill(let evenOdd):
            ctx.clip(using: evenOdd ? .evenOdd : .winding)
        case .stroke(let width, let cap, let join):
            ctx.setLineWidth(width)
            ctx.setLineCap(cap)
            ctx.setLineJoin(join)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
        }
    }

    static func paint(_ op: MarkOp, _ paint: DesignedPaint, in ctx: CGContext, multiplier: CGFloat = 1) {
        ctx.saveGState()
        clip(to: op, in: ctx)
        ctx.setAlpha(op.opacity * multiplier)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        switch paint {
        case .flat(let c):
            ctx.setFillColor(c.cgColor)
            ctx.fill(CGRect(x: -4, y: -4, width: 24, height: 24))
        case .gradient(let stops, let line):
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.cgColor) as CFArray,
                                  locations: [0, 0.5, 1]) {
                ctx.drawLinearGradient(g, start: line.0, end: line.1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// Cuts the op's shape out of everything already drawn in this layer.
    static func knock(_ op: MarkOp, in ctx: CGContext, multiplier: CGFloat = 1) {
        ctx.saveGState()
        clip(to: op, in: ctx)
        ctx.setBlendMode(.destinationOut)
        ctx.setFillColor(CGColor(gray: 0, alpha: op.opacity * multiplier))
        ctx.fill(CGRect(x: -4, y: -4, width: 24, height: 24))
        ctx.restoreGState()
    }

    static func fill(_ path: CGPath, with paint: DesignedPaint, in ctx: CGContext) {
        Self.paint(.fill(path, .designed), paint, in: ctx)
    }

    /// The dot spots, as the gallery draws them (`dotLR`, `dotUR`, `moon`).
    static func dot(for state: MarkState, colours: Colours, pose: MarkPose, in ctx: CGContext) {
        guard pose.dotOpacity > 0 else { return }
        let centre: CGPoint, gap: CGFloat, radius: CGFloat, color: MarkRGBA
        var cut: (CGPoint, CGFloat)?
        switch state {
        case .caught: (centre, gap, radius, color) = (CGPoint(x: 12.8, y: 12.8), 2.93, 2.13, colours.ok)
        case .needsAttention: (centre, gap, radius, color) = (CGPoint(x: 12.8, y: 12.8), 2.93, 2.13, colours.needs)
        case .waiting: (centre, gap, radius, color) = (CGPoint(x: 13.51, y: 2.49), 2.31, 1.6, colours.accent)
        case .focusHolding:
            (centre, gap, radius, color) = (CGPoint(x: 13.2, y: 2.8), 3.05, 2.35, colours.accent)
            cut = (CGPoint(x: 14.5, y: 1.7), 1.85)
        default: return
        }
        ctx.saveGState()
        let k = CGFloat(pose.dotScale)
        ctx.translateBy(x: centre.x, y: centre.y)
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -centre.x, y: -centre.y)
        let alpha = CGFloat(pose.dotOpacity)
        ctx.setBlendMode(.destinationOut)
        ctx.setFillColor(CGColor(gray: 0, alpha: alpha))
        ctx.addPath(MarkGeometry.circle(centre.x, centre.y, gap)); ctx.fillPath()
        ctx.setBlendMode(.normal)
        var c = color
        c.a *= Double(alpha)
        ctx.setFillColor(c.cgColor)
        ctx.addPath(MarkGeometry.circle(centre.x, centre.y, radius)); ctx.fillPath()
        if let cut {
            ctx.setBlendMode(.destinationOut)
            ctx.setFillColor(CGColor(gray: 0, alpha: alpha))
            ctx.addPath(MarkGeometry.circle(cut.0.x, cut.0.y, cut.1)); ctx.fillPath()
        }
        ctx.restoreGState()
    }

    /// The accent count badge: white bold figures on an accent capsule (`CountBadge`'s look), drawn in pixel space.
    static func drawBadge(_ count: Int, in rect: CGRect, imageHeight: CGFloat, scale: CGFloat, ctx: CGContext, accent: MarkRGBA,
                          k: CGFloat) {
        ctx.saveGState()
        // y-up pixels.
        let r = CGRect(x: rect.minX * scale, y: imageHeight - rect.maxY * scale, width: rect.width * scale, height: rect.height * scale)
        ctx.setFillColor(accent.cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
        ctx.fillPath()
        let line = MenuBarBadgeLayout.line(CountBadge.text(count), size: MenuBarBadgeLayout.fontSize * k * scale,
                                           color: CGColor(gray: 1, alpha: 1))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        ctx.textPosition = CGPoint(x: r.midX - width / 2, y: r.midY - (ascent - descent) / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

// MARK: - Images for AppKit and SwiftUI

@MainActor
public enum MenuBarMarkImage {
    /// The scales every image carries a bitmap for: 1× and 2× displays.
    public static let scales: [CGFloat] = [1, 2]

    /// The frame as an image for the status item or a preview: one bitmap per scale, so it is crisp on 1× and 2×
    /// screens alike. The Classic ring goes to `ObscuraMarkDrawing` exactly as before (with the badge beside it).
    public static func image(_ frame: MarkFrame, _ look: MarkLook, scales: [CGFloat] = scales) -> NSImage {
        let label = MarkCopy.accessibilityLabel(frame.state, count: look.count)
        if frame.mark == .classic {
            let ink = MarkPalette.ink(look.appearance)
            let image = ObscuraMarkDrawing.menuBarImage(frame.state, sweep: frame.sweep, pointSize: look.pointSize, count: look.count,
                                                        dotOpacity: frame.pose.dotOpacity, scale: scales.max(),
                                                        pausedTint: look.pausedColor.markTint, reservesBadgeSpace: look.reservesBadgeSpace,
                                                        ink: Color(cgColor: ink.cgColor), badgeAccent: MarkPalette.accent(dark: look.appearance.isDark))
            image.accessibilityDescription = label
            return image
        }
        let size = CGSize(width: look.width, height: look.pointSize)
        let image = NSImage(size: size)
        for scale in scales {
            guard let cg = MarkRenderer.render(frame, look, scale: scale) else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = size
            image.addRepresentation(rep)
        }
        image.isTemplate = MarkRenderer.isTemplate(frame, look)
        image.accessibilityDescription = label
        return image
    }
}
