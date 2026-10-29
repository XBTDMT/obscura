// The menu bar marks a person can pick (G-21, ruled 2026-10-27): the Classic ring plus the fifteen picked from
// the mark gallery. Each mark's geometry is ported from the gallery's SVG generator, on the same
// 16-unit grid as `ObscuraMarkDrawing` (ring radius 5.51, stroke 2.31, thin 1.24), with y growing downwards as in SVG.
// A mark has two parts: the plain part, drawn in the menu bar's label colour, and the designed part, which takes the
// colour style. The designed part is a list of pieces (the gallery's top-level children of `.ds`), so the snap shut can
// close them one after another. "Knock-out" paint is the gallery's `K`: it cuts a clean gap in what is under it.
public import ObscuraPrefs
import CoreGraphics
import Foundation

public extension MenuBarMarkID {
    /// The mark's name in the picker and for VoiceOver (the gallery's names; its numbering is in `galleryNumber`).
    var title: String {
        switch self {
        case .classic: return String(localized: "Classic ring")
        case .twoTone: return String(localized: "Two-tone")
        case .pixelatedHalf: return String(localized: "Pixelated half")
        case .dissolving: return String(localized: "Dissolving")
        case .halfBar: return String(localized: "Half bar")
        case .redactedLines: return String(localized: "Redacted lines")
        case .patched: return String(localized: "Patched")
        case .scanlines: return String(localized: "Scanlines")
        case .checkerBand: return String(localized: "Checker band")
        case .keyholeSplit: return String(localized: "Keyhole split")
        case .shutter: return String(localized: "Shutter")
        case .orbit: return String(localized: "Orbit")
        case .segments: return String(localized: "Segments")
        case .viewfinder: return String(localized: "Viewfinder")
        case .yinYang: return String(localized: "Yin-yang")
        case .shield: return String(localized: "Shield")
        }
    }

    /// The mark's number on the gallery page the marks were picked from; nil for the Classic ring, which predates it.
    var galleryNumber: Int? {
        switch self {
        case .classic: return nil
        case .twoTone: return 1
        case .pixelatedHalf: return 6
        case .dissolving: return 11
        case .halfBar: return 15
        case .redactedLines: return 17
        case .patched: return 18
        case .scanlines: return 23
        case .checkerBand: return 26
        case .keyholeSplit: return 33
        case .shutter: return 35
        case .orbit: return 40
        case .segments: return 42
        case .viewfinder: return 45
        case .yinYang: return 46
        case .shield: return 49
        }
    }

    /// Whether the mark has a designed part that takes a colour style (every mark but the Classic ring).
    var takesColourStyle: Bool { self != .classic }

    /// How many pieces the designed part has: the snap shut closes them one after another, so its length depends on it.
    var designedPieceCount: Int { MarkGeometry.pieceCounts[self] ?? 0 }
}

public extension MenuBarMarkStyle {
    /// The style's name in the picker.
    var title: String {
        switch self {
        case .warm: return String(localized: "Warm")
        case .glass: return String(localized: "Glass")
        case .indigo: return String(localized: "Indigo")
        case .oneColor: return String(localized: "One colour")
        }
    }
}

// MARK: - Geometry

/// What an op is painted with.
enum MarkPaint: Sendable, Hashable {
    /// The menu bar's label colour (or the paused colour).
    case plain
    /// The colour style (or the paused colour, or the label colour in One colour).
    case designed
    /// The gallery's `K`: cuts a gap in everything drawn under it.
    case knock
}

/// One filled or stroked path on the 16-unit grid.
struct MarkOp {
    enum Kind {
        case fill(evenOdd: Bool)
        case stroke(width: CGFloat, cap: CGLineCap, join: CGLineJoin)
    }
    var path: CGPath
    var kind: Kind
    var paint: MarkPaint
    var opacity: CGFloat = 1

    static func fill(_ path: CGPath, _ paint: MarkPaint, opacity: CGFloat = 1, evenOdd: Bool = false) -> MarkOp {
        MarkOp(path: path, kind: .fill(evenOdd: evenOdd), paint: paint, opacity: opacity)
    }

    static func stroke(_ path: CGPath, _ paint: MarkPaint, width: CGFloat, cap: CGLineCap = .butt, join: CGLineJoin = .miter,
                       opacity: CGFloat = 1) -> MarkOp {
        MarkOp(path: path, kind: .stroke(width: width, cap: cap, join: join), paint: paint, opacity: opacity)
    }
}

/// One piece: its ops, optionally clipped. The snap scales a piece about the centre of its bounding box.
struct MarkPiece {
    var ops: [MarkOp]
    var clip: CGPath?

    init(_ ops: [MarkOp], clip: CGPath? = nil) {
        self.ops = ops
        self.clip = clip
    }

    init(_ op: MarkOp) { self.init([op]) }

    /// The bounding box of the piece's geometry, stroke width left out (SVG's fill-box).
    var box: CGRect {
        ops.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
    }
}

/// A mark's two parts and the line its gradient runs along.
struct MarkDesign {
    var plain: [MarkPiece]
    var designed: [MarkPiece]
    /// The gradient's start and end on the 16-unit grid (the gallery's `gd`).
    var gradient: (CGPoint, CGPoint)
}

/// The geometry of every mark but the Classic ring (which `ObscuraMarkDrawing` draws, unchanged).
enum MarkGeometry {
    static let radius: CGFloat = 5.51
    static let stroke: CGFloat = 2.31
    static let thin: CGFloat = 1.24
    static let centre = CGPoint(x: 8, y: 8)

    /// A point on the circle of radius `r` at `degrees` (0 = 3 o'clock, growing clockwise on screen).
    static func pt(_ degrees: CGFloat, _ r: CGFloat = radius) -> CGPoint {
        let t = degrees * .pi / 180
        return CGPoint(x: 8 + r * cos(t), y: 8 + r * sin(t))
    }

    /// The ring from `a0` to `a1` degrees, clockwise on screen (the gallery's `arcD`).
    static func arc(_ a0: CGFloat, _ a1: CGFloat, _ r: CGFloat = radius) -> CGPath {
        let p = CGMutablePath()
        p.move(to: pt(a0, r))
        p.addArc(center: centre, radius: r, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: false)
        return p
    }

    static func ring(_ r: CGFloat = radius) -> CGPath {
        CGPath(ellipseIn: CGRect(x: 8 - r, y: 8 - r, width: 2 * r, height: 2 * r), transform: nil)
    }

    static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), transform: nil)
    }

    static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, rx: CGFloat = 0) -> CGPath {
        let r = CGRect(x: x, y: y, width: w, height: h)
        guard rx > 0 else { return CGPath(rect: r, transform: nil) }
        let c = min(rx, w / 2, h / 2)
        return CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil)
    }

    static func line(_ a: CGPoint, _ b: CGPoint) -> CGPath {
        let p = CGMutablePath()
        p.move(to: a)
        p.addLine(to: b)
        return p
    }

    /// The right half of the ring's band as a closed region, for clipping textures to the ring (the gallery's `bandRight`).
    static func bandRight(_ w: CGFloat) -> CGPath {
        let o = radius + w / 2, i = radius - w / 2
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 8, y: 8 - o))
        p.addArc(center: centre, radius: o, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: 8, y: 8 + i))
        p.addArc(center: centre, radius: i, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
        p.closeSubpath()
        return p
    }

    /// The keyhole of 33: a disc and a tapered slot under it.
    static func keyhole(_ paint: MarkPaint) -> [MarkOp] {
        let slot = CGMutablePath()
        slot.move(to: CGPoint(x: 7.25, y: 7.9))
        slot.addLine(to: CGPoint(x: 6.6, y: 11.1))
        slot.addLine(to: CGPoint(x: 9.4, y: 11.1))
        slot.addLine(to: CGPoint(x: 8.75, y: 7.9))
        slot.closeSubpath()
        return [.fill(circle(8, 6.9, 1.75), paint), .fill(slot, paint), .stroke(slot, paint, width: 0.3, join: .round)]
    }

    /// The left or right half of the grid, for marks split down the middle.
    static func half(left: Bool) -> CGPath {
        CGPath(rect: CGRect(x: left ? -1 : 8, y: -1, width: 9, height: 18), transform: nil)
    }

    /// The default gradient line (`gd || [3, 2, 13, 14]`).
    static let defaultGradient = (CGPoint(x: 3, y: 2), CGPoint(x: 13, y: 14))

    /// Shutter blade stroke width (35). The gallery drew 1.0 and its review found the blades mush at 16 pt; see
    /// `MarkTuning`.
    static var shutterBlade: CGFloat { MarkTuning.shutterBladeWidth }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    /// The mark's two parts. `paused` draws the thin paused variant (the whole mark then takes the paused colour).
    static func design(_ mark: MenuBarMarkID, paused: Bool) -> MarkDesign {
        let w = paused ? thin : stroke
        func g(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> (CGPoint, CGPoint) {
            (CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2))
        }
        let ringPiece = MarkPiece(.stroke(ring(), .plain, width: w))
        let leftHalf = MarkPiece(.stroke(arc(90, 270), .plain, width: w))
        switch mark {
        case .classic:
            // Never drawn here; the Classic ring keeps `ObscuraMarkDrawing`. A plain ring keeps this total.
            return MarkDesign(plain: [ringPiece], designed: [], gradient: defaultGradient)

        case .twoTone:
            return MarkDesign(plain: [leftHalf], designed: [MarkPiece(.stroke(arc(-90, 90), .designed, width: w))],
                              gradient: g(8, 1.3, 8, 14.7))

        case .pixelatedHalf:
            if paused { return MarkDesign(plain: [MarkPiece(.stroke(ring(), .plain, width: thin))], designed: [], gradient: g(8, 2, 14, 14)) }
            let cells: [(CGFloat, CGFloat)] = [(8, 2), (10, 2), (10, 4), (12, 4), (12, 6), (12, 8), (12, 10), (10, 10), (10, 12), (8, 12)]
            let pieces = cells.map { c in
                MarkPiece(.fill(rect(c.0, c.1, 2, 2), .designed, opacity: (Int(c.0 / 2) + Int(c.1 / 2)) % 2 == 1 ? 0.55 : 1))
            }
            return MarkDesign(plain: [leftHalf], designed: pieces, gradient: g(8, 2, 14, 14))

        case .dissolving:
            let keep: [(CGFloat, CGFloat)] = [(8, 2), (10, 2), (10, 4), (12, 4), (12, 8), (10, 10), (8, 12)]
            var pieces = keep.enumerated().map { i, c in
                MarkPiece(.fill(rect(c.0, c.1, 2, 2), .designed, opacity: i % 2 == 1 ? 0.6 : 1))
            }
            pieces.append(MarkPiece(.fill(rect(14.3, 6.1, 1.5, 1.5), .designed, opacity: 0.75)))
            pieces.append(MarkPiece(.fill(rect(12.9, 12.3, 1.4, 1.4), .designed, opacity: 0.5)))
            return MarkDesign(plain: [leftHalf], designed: pieces, gradient: g(8, 2, 15, 14))

        case .halfBar:
            return MarkDesign(plain: [ringPiece],
                              designed: [MarkPiece(.fill(rect(7, 5.4, 9.4, 5.2), .knock)),
                                         MarkPiece(.fill(rect(7.8, 6.3, 7.7, 3.4, rx: 0.7), .designed))],
                              gradient: g(7.8, 8, 15.5, 8))

        case .redactedLines:
            return MarkDesign(plain: [ringPiece],
                              designed: [MarkPiece(.fill(rect(5, 5.6, 6, 1.7, rx: 0.5), .designed)),
                                         MarkPiece(.fill(rect(5, 8.8, 4, 1.7, rx: 0.5), .designed))],
                              gradient: g(5, 6, 11, 10))

        case .patched:
            return MarkDesign(plain: [ringPiece],
                              designed: [MarkPiece(.fill(rect(10.9, 5.2, 5.6, 5.6, rx: 1.2), .knock)),
                                         MarkPiece(.fill(rect(11.7, 6, 4, 4, rx: 0.7), .designed))],
                              gradient: g(11.7, 6, 15.7, 10))

        case .scanlines:
            var lines: [MarkOp] = []
            var y: CGFloat = 1.3
            while y < 15 { lines.append(.fill(rect(8, y, 7.5, MarkTuning.scanlineHeight), .designed)); y += 2.6 }
            return MarkDesign(plain: [leftHalf], designed: [MarkPiece(lines, clip: bandRight(w))], gradient: g(8, 1.3, 8, 14.7))

        case .checkerBand:
            let z = MarkTuning.checkerCell
            var cells: [MarkOp] = []
            let columns = Int((8 / z).rounded(.up)), rows = Int((16 / z).rounded(.up))
            for j in 0..<rows {
                for i in 0..<columns where (Int((8 / z).rounded()) + i + j) % 2 == 0 {
                    cells.append(.fill(rect(8 + CGFloat(i) * z, CGFloat(j) * z, z, z), .designed))
                }
            }
            return MarkDesign(plain: [leftHalf], designed: [MarkPiece(cells, clip: bandRight(w))], gradient: g(8, 1.3, 8, 14.7))

        case .keyholeSplit:
            return MarkDesign(plain: [MarkPiece([.stroke(arc(90, 270), .plain, width: w)] + keyhole(.plain))],
                              designed: [MarkPiece(.stroke(arc(-90, 90), .designed, width: w))],
                              gradient: g(8, 1.3, 8, 14.7))

        case .shutter:
            var pieces = [MarkPiece(.fill(circle(8, 8, MarkTuning.shutterDiscRadius), .designed))]
            for i in 0..<6 {
                let a = CGFloat(i * 60 + 15)
                let v = pt(a, 1.0)
                let b = (a + 70) * .pi / 180
                let e = CGPoint(x: v.x + 4 * cos(b), y: v.y + 4 * sin(b))
                pieces.append(MarkPiece(.stroke(line(v, e), .knock, width: shutterBlade, cap: .round)))
            }
            pieces.append(MarkPiece(.fill(circle(8, 8, MarkTuning.shutterCentreRadius), .knock)))
            return MarkDesign(plain: [ringPiece], designed: pieces, gradient: defaultGradient)

        case .orbit:
            let p = pt(135)
            return MarkDesign(plain: [ringPiece],
                              designed: [MarkPiece(.fill(circle(p.x, p.y, 2.55), .knock)),
                                         MarkPiece(.fill(circle(p.x, p.y, 1.8), .designed))],
                              gradient: g(2.4, 10.2, 5.8, 13.6))

        case .segments:
            return MarkDesign(plain: [MarkPiece([.stroke(arc(-83, 23), .plain, width: w), .stroke(arc(157, 263), .plain, width: w)])],
                              designed: [MarkPiece(.stroke(arc(37, 143), .designed, width: w))],
                              gradient: g(13, 10, 3, 10))

        case .viewfinder:
            let corners = CGMutablePath()
            corners.move(to: CGPoint(x: 1.6, y: 5.4)); corners.addLine(to: CGPoint(x: 1.6, y: 1.6)); corners.addLine(to: CGPoint(x: 5.4, y: 1.6))
            corners.move(to: CGPoint(x: 10.6, y: 1.6)); corners.addLine(to: CGPoint(x: 14.4, y: 1.6)); corners.addLine(to: CGPoint(x: 14.4, y: 5.4))
            corners.move(to: CGPoint(x: 14.4, y: 10.6)); corners.addLine(to: CGPoint(x: 14.4, y: 14.4)); corners.addLine(to: CGPoint(x: 10.6, y: 14.4))
            corners.move(to: CGPoint(x: 5.4, y: 14.4)); corners.addLine(to: CGPoint(x: 1.6, y: 14.4)); corners.addLine(to: CGPoint(x: 1.6, y: 10.6))
            return MarkDesign(plain: [MarkPiece(.stroke(corners, .plain, width: paused ? thin : 1.6))],
                              designed: [MarkPiece(.fill(rect(3.8, 6.5, 8.4, 3, rx: 0.6), .designed))],
                              gradient: g(3.8, 8, 12.2, 8))

        case .yinYang:
            let swirl = CGMutablePath()
            swirl.move(to: CGPoint(x: 8, y: 4.3))
            // A3.7 0 0,1 8,11.7: the right half of the r 3.7 circle, top to bottom.
            swirl.addArc(center: CGPoint(x: 8, y: 8), radius: 3.7, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
            // A1.85 0 0,1 8,8: bottom to centre round the left (clockwise on screen from 90° to 270°).
            swirl.addArc(center: CGPoint(x: 8, y: 9.85), radius: 1.85, startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
            // A1.85 0 0,0 8,4.3: centre back to the top round the right (counter-clockwise on screen).
            swirl.addArc(center: CGPoint(x: 8, y: 6.15), radius: 1.85, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
            swirl.closeSubpath()
            return MarkDesign(plain: [ringPiece], designed: [MarkPiece(.fill(swirl, .designed))], gradient: g(8, 4.3, 8, 11.7))

        case .shield:
            let shield = CGMutablePath()
            shield.move(to: CGPoint(x: 8, y: 1.6))
            shield.addLine(to: CGPoint(x: 13.5, y: 3.6))
            shield.addLine(to: CGPoint(x: 13.5, y: 8))
            shield.addCurve(to: CGPoint(x: 8, y: 14.5), control1: CGPoint(x: 13.5, y: 11.2), control2: CGPoint(x: 11.2, y: 13.4))
            shield.addCurve(to: CGPoint(x: 2.5, y: 8), control1: CGPoint(x: 4.8, y: 13.4), control2: CGPoint(x: 2.5, y: 11.2))
            shield.addLine(to: CGPoint(x: 2.5, y: 3.6))
            shield.closeSubpath()
            let sw: CGFloat = paused ? thin : 2.0
            return MarkDesign(plain: [MarkPiece([.stroke(shield, .plain, width: sw, join: .round)], clip: half(left: true))],
                              designed: [MarkPiece([.stroke(shield, .designed, width: sw, join: .round)], clip: half(left: false))],
                              gradient: g(8, 1.5, 8, 14.7))
        }
    }

    /// How many pieces each mark's designed part has, counted once.
    static let pieceCounts: [MenuBarMarkID: Int] = Dictionary(uniqueKeysWithValues: MenuBarMarkID.allCases.map {
        ($0, $0 == .classic ? 0 : design($0, paused: false).designed.count)
    })
}

/// The two marks the gallery flagged as soft at 16 pt (26 Checker band, 35 Shutter), tuned in the real menu bar rather
/// than dropped (G-21 "legibility"), and the one texture value they share with 23. The gallery's values are kept as
/// `gallery*` so the change is visible; see the G-21 "built:" line for what was measured.
enum MarkTuning {
    /// 26's checker square. The gallery's 1.4 units is 1.6 pt at 18 pt: below two device pixels at 1×, so the cells
    /// blur into a grey band. 2.0 units (2.25 pt) keeps every cell at least two pixels at 1×.
    static let galleryCheckerCell: CGFloat = 1.4
    static let checkerCell: CGFloat = 16.0 / 9
    /// 35's blades: the gallery's 1-unit knock-out lines over a 3.35 disc left a smudge at 1×. Wider blades and a larger
    /// disc keep six distinct gaps.
    static let galleryShutterBladeWidth: CGFloat = 1.0
    static let shutterBladeWidth: CGFloat = 1.1
    static let galleryShutterDiscRadius: CGFloat = 3.35
    static let shutterDiscRadius: CGFloat = 3.6
    static let galleryShutterCentreRadius: CGFloat = 0.9
    static let shutterCentreRadius: CGFloat = 1.3
    /// 23's scan line height (unchanged from the gallery).
    static let scanlineHeight: CGFloat = 1.45
}
