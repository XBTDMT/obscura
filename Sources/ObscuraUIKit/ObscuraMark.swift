// The Obscura mark: the ring of the Glass O (design/mockups/icon-30/r3-a.html), drawn natively at any size.
// Geometry is taken from the 16 px template drawings on that page and scaled: radius 5.51/16, stroke 2.31/16.
public import SwiftUI
public import ObscuraPrefs
import AppKit

/// Every state the menu bar mark can show. States are shape changes first, colour second, so they read in a template image.
public enum MarkState: String, CaseIterable, Sendable, Hashable {
    /// Full ring.
    case protected
    /// Left half solid, right half faint: some source is not covered.
    case partlyProtected
    /// Thin ring.
    case paused
    /// Faint ring with a sweeping arc outside it.
    case checking
    /// Full ring with a green dot at the lower right, shown briefly after a catch.
    case caught
    /// Full ring with an orange dot at the lower right.
    case needsAttention
    /// Full ring with an accent dot at the upper right: an update is ready.
    case waiting
    /// Full ring with an accent crescent moon at the upper right, drawn heavier than the update's dot so it reads at
    /// menu bar size: Focus (or quiet delivery) is holding catch notifications (G-19 #18: two distinct marks).
    case focusHolding
}

/// The mark's timing (menubar.html "The menu bar item, in every state"; G-15).
public enum MarkTiming {
    /// The checking state shows only for a check that outlasts this. A warm scan takes about 0.1 s (G-8 evidence), so
    /// every image copied or captured would otherwise blink the mark; the thumbnail reveals its checking card after the
    /// same 0.3 s (design/mockups/thumbnail/NOTES.md, "if the check passes 0.3 s").
    public static let checkingReveal: TimeInterval = 0.3
    /// Once shown, checking stays at least this long: half a turn of the 1.1 s sweep, so the arc is seen to travel and
    /// never reads as a blink.
    public static let checkingMinimum: TimeInterval = 0.55
    /// "Green dot for about 4 s after a catch, then gone" (menubar.html).
    public static let caughtSeconds: TimeInterval = 4
    /// One turn of the checking arc (`o-sp 1.1s linear`, system.html).
    public static let sweepPeriod: TimeInterval = 1.1
    /// Frames per turn: 60 fps, so the arc turns smoothly; each frame is drawn once and reused.
    public static let sweepFrames = 66
}

/// When the mark shows "checking", from the moments the engine starts and stops being busy. Pure; the caller supplies
/// the time and wakes at `nextWakeup`.
public struct MarkCheckingGate: Sendable, Hashable {
    /// When the current busy run began; nil while idle.
    public private(set) var busySince: TimeInterval?
    /// When checking began to show; nil while it does not.
    public private(set) var shownSince: TimeInterval?

    /// Wall-clock seconds since 2001 are not exact in binary: a wake at exactly the boundary must count as reaching it.
    private static let slack: TimeInterval = 1e-6

    public init() {}

    /// Feeds the engine's state at `now` and returns whether the mark shows checking.
    @discardableResult
    public mutating func update(busy: Bool, at now: TimeInterval) -> Bool {
        if busy {
            if busySince == nil { busySince = now }
            if shownSince == nil, let since = busySince, now - since >= MarkTiming.checkingReveal - Self.slack { shownSince = now }
        } else {
            busySince = nil
            if let shown = shownSince, now - shown >= MarkTiming.checkingMinimum - Self.slack { shownSince = nil }
        }
        return shownSince != nil
    }

    public var showsChecking: Bool { shownSince != nil }

    /// The next moment `update` may change the answer without the engine changing.
    public func nextWakeup() -> TimeInterval? {
        if shownSince == nil, let since = busySince { return since + MarkTiming.checkingReveal }
        if busySince == nil, let shown = shownSince { return shown + MarkTiming.checkingMinimum }
        return nil
    }
}

/// The mark as a SwiftUI view. `sweep` (0…1) rotates the checking arc; pass a changing value to animate it.
public struct ObscuraMark: View {
    public var state: MarkState
    public var sweep: Double
    /// The colour behind the mark, used to cut a clean gap around a badge dot.
    public var background: Color
    /// The ring's colour while paused (`PausedColor.markTint`); nil draws it in the ink like every other state.
    public var pausedTint: Color?

    public init(_ state: MarkState, sweep: Double = 0, background: Color = .clear, pausedTint: Color? = nil) {
        self.state = state
        self.sweep = sweep
        self.background = background
        self.pausedTint = pausedTint
    }

    public var body: some View {
        Canvas { ctx, size in
            let ink: Color = state == .paused ? (pausedTint ?? .primary) : .primary
            ObscuraMarkDrawing.draw(state: state, sweep: sweep, in: &ctx, size: size, ink: ink, background: background)
        }
        .accessibilityLabel(Text(MarkCopy.accessibilityLabel(state)))
    }
}

/// Drawing shared by the SwiftUI view and the menu bar template image.
public enum ObscuraMarkDrawing {
    static let radiusFraction: CGFloat = 5.51 / 16
    static let strokeFraction: CGFloat = 2.31 / 16
    static let thinStrokeFraction: CGFloat = 1.24 / 16

    /// `dotOpacity` (0…1) fades a state's dot in or out (the caught dot "appears and fades, never pulses").
    public static func draw(state: MarkState, sweep: Double, in ctx: inout GraphicsContext, size: CGSize,
                            ink: Color, background: Color, dotOpacity: Double = 1) {
        let s = min(size.width, size.height)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = s * radiusFraction, w = s * strokeFraction, thin = s * thinStrokeFraction
        let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))

        switch state {
        case .protected, .caught, .needsAttention, .waiting, .focusHolding:
            ctx.stroke(ring, with: .color(ink), lineWidth: w)
        case .paused:
            ctx.stroke(ring, with: .color(ink), lineWidth: thin)
        case .partlyProtected:
            var left = Path(); left.addArc(center: c, radius: r, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
            var right = Path(); right.addArc(center: c, radius: r, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            ctx.stroke(left, with: .color(ink), lineWidth: w)
            ctx.stroke(right, with: .color(ink.opacity(0.35)), lineWidth: w)
        case .checking:
            ctx.stroke(ring, with: .color(ink.opacity(0.5)), lineWidth: w)
            let outer = s * 6.93 / 16
            let start = Angle.degrees(-90 + 360 * sweep)
            var arc = Path(); arc.addArc(center: c, radius: outer, startAngle: start, endAngle: start + .degrees(101), clockwise: false)
            ctx.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: thin, lineCap: .round))
        }

        func dot(at p: CGPoint, radius: CGFloat, color: Color) {
            guard dotOpacity > 0 else { return }
            let gap = radius + s * 0.8 / 16
            ctx.blendMode = background == .clear ? .clear : .normal
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - gap, y: p.y - gap, width: 2 * gap, height: 2 * gap)),
                     with: .color((background == .clear ? .black : background).opacity(dotOpacity)))
            ctx.blendMode = .normal
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius)),
                     with: .color(color.opacity(dotOpacity)))
        }
        let lowerRight = CGPoint(x: size.width / 2 + s * 4.8 / 16, y: size.height / 2 + s * 4.8 / 16)
        let upperRight = CGPoint(x: size.width / 2 + s * 5.51 / 16, y: size.height / 2 - s * 5.51 / 16)
        /// A crescent: the disc of `radius` at `p` shifted toward the lower left, less the disc itself
        /// (open-calls.html #18, the `.moon` sketch), with the same clean gap a dot gets.
        func moon(at p: CGPoint, radius: CGFloat, color: Color) {
            guard dotOpacity > 0 else { return }
            let shift = CGPoint(x: p.x - radius * Self.moonShiftX, y: p.y + radius * Self.moonShiftY)
            func disc(_ c: CGPoint, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }
            let gap = radius + s * 0.8 / 16
            ctx.blendMode = background == .clear ? .clear : .normal
            ctx.fill(disc(shift, gap), with: .color((background == .clear ? .black : background).opacity(dotOpacity)))
            ctx.blendMode = .normal
            var body = ctx
            body.clip(to: disc(p, radius), options: .inverse)
            body.fill(disc(shift, radius), with: .color(color.opacity(dotOpacity)))
        }
        switch state {
        case .caught: dot(at: lowerRight, radius: s * 2.13 / 16, color: OColor.ok)
        case .needsAttention: dot(at: lowerRight, radius: s * 2.13 / 16, color: OColor.needs)
        case .waiting: dot(at: upperRight, radius: s * Self.updateDotRadius / 16, color: OColor.accent)
        case .focusHolding:
            // The cut-out disc sits half a shift up and right of the update dot's spot, so the crescent's body lands on it.
            let r: CGFloat = s * Self.moonRadius / 16
            let at = CGPoint(x: upperRight.x + r * Self.moonShiftX / 2, y: upperRight.y - r * Self.moonShiftY / 2)
            moon(at: at, radius: r, color: OColor.accent)
        default: break
        }
    }

    /// The update dot's radius, in sixteenths of the mark.
    public static let updateDotRadius: CGFloat = 1.60
    /// The Focus moon's disc radius, in sixteenths: larger than the update dot so the crescent's body is heavier
    /// (G-19 #18, 2026-10-27: "Focus holding might need to be a bit thicker to see it").
    public static let moonRadius: CGFloat = 2.8
    /// How far the crescent's disc is shifted from the cut-out disc, as fractions of its radius. The sketch's
    /// `box-shadow: -3px 1px` on a 10 px disc is 0.6 left and 0.2 down; this is a quarter deeper, so the crescent's body
    /// is thick enough to read at 18 pt.
    static let moonShiftX: CGFloat = 0.75
    static let moonShiftY: CGFloat = 0.25

    /// The menu bar image's width with a one-figure count badge: the 18 pt square mark, the gap, then the badge BESIDE
    /// it, so the badge never covers the lower-right state dot (redman 2026-10-27: the old 26 pt image pinned the
    /// badge over the mark's right edge). `MenuBarBadgeLayout` owns the geometry.
    public static var badgedWidth: CGFloat { MenuBarBadgeLayout.width(pointSize: 18, count: 1, reservesBadgeSpace: false) }

    /// The menu bar image's width: the square mark, or with the badge beside it when a count shows (wider for more
    /// figures) or its space is reserved (S-12: `Settings.reservesBadgeSpace` while panel-only mode is on), so the items
    /// beside it never move.
    public static func menuBarWidth(pointSize: CGFloat = 18, count: Int, reservesBadgeSpace: Bool) -> CGFloat {
        MenuBarBadgeLayout.width(pointSize: pointSize, count: count, reservesBadgeSpace: reservesBadgeSpace)
    }

    /// The menu bar image. Ring-only states are template images (macOS tints them for the bar); badge states are not,
    /// so their dots keep their colour, with the ring drawn in the bar's label colour for the given appearance.
    /// A `count` above zero adds the accent count badge (panel-only mode: catches not yet seen in the panel), which
    /// widens the image to `badgedWidth` and keeps it in colour.
    /// `dotOpacity` below 1 draws a frame of the dot's fade; `scale` defaults to the main screen's.
    /// `pausedTint` colours the paused ring (G-19 #17), which makes that image a colour image; nil keeps the template.
    /// `reservesBadgeSpace` keeps the badged width with no badge drawn (S-12).
    /// `ink` is the menu bar's label colour for a colour image (`MarkPalette.ink` for the bar's appearance); nil uses
    /// `NSColor.labelColor` as resolved where the image is drawn. `badgeAccent` colours the badge; nil is `OColor.accent`.
    @MainActor
    public static func menuBarImage(_ state: MarkState, sweep: Double = 0, pointSize: CGFloat = 18, count: Int = 0,
                                    dotOpacity: Double = 1, scale: CGFloat? = nil, pausedTint: Color? = nil,
                                    reservesBadgeSpace: Bool = false, ink labelInk: Color? = nil,
                                    badgeAccent: MarkRGBA? = nil) -> NSImage {
        let tint = state == .paused ? pausedTint : nil
        if count > 0 {
            return badgedMenuBarImage(state, sweep: sweep, pointSize: pointSize, count: count, dotOpacity: dotOpacity, scale: scale, tint: tint,
                                      ink: labelInk, accent: badgeAccent)
        }
        let size = CGSize(width: menuBarWidth(pointSize: pointSize, count: 0, reservesBadgeSpace: reservesBadgeSpace), height: pointSize)
        let hasColour = state.hasDot || tint != nil
        let ink: Color = tint ?? (hasColour ? (labelInk ?? Color(nsColor: .labelColor)) : .black)
        let renderer = ImageRenderer(content:
            Canvas { ctx, sz in
                draw(state: state, sweep: sweep, in: &ctx, size: sz, ink: ink, background: .clear, dotOpacity: dotOpacity)
            }
            .frame(width: pointSize, height: pointSize)
            .frame(width: size.width, height: size.height, alignment: .leading))
        renderer.scale = scale ?? NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(size: size)
        image.isTemplate = !hasColour
        image.accessibilityDescription = MarkCopy.accessibilityLabel(state)
        return image
    }

    @MainActor
    private static func badgedMenuBarImage(_ state: MarkState, sweep: Double, pointSize: CGFloat, count: Int, dotOpacity: Double,
                                           scale: CGFloat?, tint: Color?, ink: Color?, accent: MarkRGBA?) -> NSImage {
        let size = CGSize(width: menuBarWidth(pointSize: pointSize, count: count, reservesBadgeSpace: false), height: pointSize)
        let badge = MenuBarBadgeLayout.badgeRect(pointSize: pointSize, count: count) ?? .zero
        // The badge beside the mark's square, top-aligned, never over its lower-right dot (MenuBarBadgeLayout).
        let content = ZStack(alignment: .topLeading) {
            Canvas { ctx, sz in
                draw(state: state, sweep: sweep, in: &ctx, size: sz, ink: tint ?? ink ?? Color(nsColor: .labelColor), background: .clear,
                     dotOpacity: dotOpacity)
            }
            .frame(width: pointSize, height: pointSize)
            CountBadge(count: count, fill: accent.map { Color(cgColor: $0.cgColor) })
                .scaleEffect(pointSize / 18, anchor: .topLeading)
                .frame(width: badge.width, height: badge.height, alignment: .topLeading)
                .offset(x: badge.minX, y: badge.minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale ?? NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(size: size)
        image.isTemplate = false
        image.accessibilityDescription = MarkCopy.accessibilityLabel(state, count: count)
        return image
    }
}

public extension MarkState {
    /// The states drawn with a coloured dot (and so as a colour image, not a template).
    var hasDot: Bool { self == .caught || self == .needsAttention || self == .waiting || self == .focusHolding }
    /// The states whose ring is the full ring: between two of them only the dot changes, so the change can fade.
    var hasFullRing: Bool { self == .protected || hasDot }
}

/// The accent count badge on the menu bar mark: white figures on an accent capsule, at least 13 pt round, "99+" past 99.
public struct CountBadge: View {
    public var count: Int
    /// The capsule's colour; nil is `OColor.accent`.
    public var fill: Color?
    public init(count: Int, fill: Color? = nil) { self.count = count; self.fill = fill }
    public nonisolated static func text(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }
    public var body: some View {
        Text(Self.text(count))
            .font(.system(size: MenuBarBadgeLayout.fontSize, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, MenuBarBadgeLayout.padding)
            .frame(minWidth: MenuBarBadgeLayout.minimumWidth, minHeight: MenuBarBadgeLayout.height)
            .frame(width: MenuBarBadgeLayout.badgeWidth(count), height: MenuBarBadgeLayout.height)
            .background(Capsule().fill(fill ?? OColor.accent))
    }
}

/// Words for the mark's states (English source strings; the String Catalog localizes them).
public enum MarkCopy {
    public static func accessibilityLabel(_ state: MarkState) -> String {
        switch state {
        case .protected: return String(localized: "Obscura: protected")
        case .partlyProtected: return String(localized: "Obscura: partly protected")
        case .paused: return String(localized: "Obscura: paused")
        case .checking: return String(localized: "Obscura: checking an image")
        case .caught: return String(localized: "Obscura: a secret was just blacked out")
        case .needsAttention: return String(localized: "Obscura: needs attention")
        case .waiting: return String(localized: "Obscura: an update is ready")
        case .focusHolding: return String(localized: "Obscura: Focus is holding catch notifications")
        }
    }

    /// The state's words, then the catches the count badge stands for.
    public static func accessibilityLabel(_ state: MarkState, count: Int) -> String {
        let base = accessibilityLabel(state)
        guard count > 0 else { return base }
        let catches = count == 1 ? String(localized: "1 catch to review") : String(localized: "\(count) catches to review")
        return base + ", " + catches
    }
}

// MARK: - The paused colour (G-19 #17)

public extension PausedColor {
    /// The tone "Paused" is drawn in: its dot, its title and the Settings lead.
    var tone: Tone {
        switch self {
        case .red: return .live
        case .orange: return .needs
        case .grey: return .quiet
        }
    }

    /// The paused ring's colour on the menu bar mark; nil for grey, which stays the template image macOS tints.
    var markTint: Color? {
        switch self {
        case .red: return OColor.live
        case .orange: return OColor.needs
        case .grey: return nil
        }
    }

    /// The choice's name in Settings.
    var title: String {
        switch self {
        case .red: return String(localized: "Red")
        case .orange: return String(localized: "Orange")
        case .grey: return String(localized: "Grey")
        }
    }
}
