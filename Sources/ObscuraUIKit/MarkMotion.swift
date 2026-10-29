// The menu bar mark's motion (G-21 "motion", ruled 2026-10-27: "do recommend for all animations"). The menu bar
// mark is the one ruled exception to G-15: small movements are allowed for it alone; every other surface keeps
// instant-or-fade. Each action is a pure timeline from time to a `MarkPose`, ported from the gallery's Web Animations
// (design/mockups/menubar-mark/gallery.html, `PLAY`): the same durations, keyframes and easing. Rules: each ≤ 0.6 s except
// the checking loop, never more than two repeats, instant (one final frame) under Reduce Motion, and the end state reads
// in one colour. Apple's symbol effects do not run on an NSStatusBarButton, so the presenter draws frames from these.
public import Foundation

/// One action the mark plays.
public enum MarkMotion: Sendable, Hashable, CaseIterable {
    /// A catch from a file: the designed pieces snap shut one after another, then the green dot fades in.
    case caught
    /// A catch from the clipboard: a thin line wipes across and the designed part comes back fresh, then the green dot.
    case clipboardCleaned
    /// Copy Clean: the mark swells slightly and settles, once.
    case copyClean
    /// Undo, the original showing: the cover lifts up and to the right, half see-through, and stays lifted.
    case coverLifts
    /// The original no longer showing: the cover settles back.
    case coverReturns
    /// Paused or resumed: the mark cross-fades into the other.
    case pauseCrossFade
    /// Needs you: the orange dot pops in, slightly too big, and settles.
    case needsYouPop
    /// Update ready (and Focus holding): the dot fades in.
    case updateFade
    /// A dot leaving the mark fades out (the caught dot after its 4 s, a cleared problem).
    case dotFadeOut
}

/// One snap piece's look: scale about its own centre and opacity.
public struct MarkPiecePose: Sendable, Hashable {
    public var opacity: Double
    public var scale: Double
    public init(opacity: Double, scale: Double) { self.opacity = opacity; self.scale = scale }
}

/// Everything a frame of motion changes about the drawn mark. The default is the mark at rest.
public struct MarkPose: Sendable, Hashable {
    /// The whole mark's scale about its centre (Copy Clean's pulse). Dots are not scaled.
    public var markScale: Double = 1
    /// The designed part's opacity (the lifted cover, the wipe's fresh return).
    public var designedOpacity: Double = 1
    /// The designed part's offset on the 16-unit grid, y downwards (the lifted cover).
    public var designedDX: Double = 0
    public var designedDY: Double = 0
    /// Each designed piece's own look while snapping; nil when every piece is at rest.
    public var pieces: [MarkPiecePose]?
    /// The wiping line's offset across the mark, 0…18 units; nil when no line shows.
    public var wipeX: Double?
    /// The state dot's opacity and scale (fades, the pop).
    public var dotOpacity: Double = 1
    public var dotScale: Double = 1
    /// Progress of a cross-fade into the frame's state from `MarkFrame.crossFrom` (0…1); nil when not cross-fading.
    public var crossFade: Double?
    /// The checking scan line's centre on the grid (2.4…13.6); nil draws it at the centre (Reduce Motion).
    public var scanY: Double?

    public init() {}

    /// The cover lifted while an original shows (G-21: "stays lifted while the original shows").
    public static let lifted: MarkPose = {
        var p = MarkPose()
        p.designedDX = MarkTimeline.liftOffset
        p.designedDY = -MarkTimeline.liftOffset
        p.designedOpacity = MarkTimeline.liftedOpacity
        return p
    }()

    /// The rest pose with the cover lifted or not.
    public static func rest(lifted: Bool) -> MarkPose { lifted ? .lifted : MarkPose() }
}

/// The timelines, as pure functions of time.
public enum MarkTimeline {
    /// Frames per second the presenter draws motion at.
    public static let fps: Double = 60
    /// The longest one-shot action may take (G-21: "each ≤ 0.6 s except the checking loop").
    public static let maximumDuration: TimeInterval = 0.6

    // Durations and keyframes, from the gallery's `PLAY`.
    static let snapPiece: TimeInterval = 0.18
    static let snapStaggerMax: TimeInterval = 0.03
    static let snapStaggerBudget: TimeInterval = 0.27
    static let snapFromScale: Double = 1.9
    static let dotFade: TimeInterval = 0.15
    static let wipe: TimeInterval = 0.4
    static let wipeFromOpacity: Double = 0.2
    static let wipeDistance: Double = 18
    static let pulse: TimeInterval = 0.3
    static let pulseScale: Double = 1.1
    static let lift: TimeInterval = 0.25
    public static let liftOffset: Double = 1.3
    public static let liftedOpacity: Double = 0.5
    static let crossFade: TimeInterval = 0.3
    static let pop: TimeInterval = 0.3
    static let popPeak: Double = 1.25
    static let popPeakAt: Double = 0.65
    /// The checking scan line: down then up, 0.55 s each way (ease-in-out, alternating), looping while checking.
    public static let scanLeg: TimeInterval = 0.55
    public static var scanPeriod: TimeInterval { 2 * scanLeg }
    /// Frames per scan loop at 60 fps; each is drawn once and reused, as the Classic ring's sweep is.
    public static var scanFrames: Int { Int((scanPeriod * fps).rounded()) }
    static let scanTop: Double = 2.4
    static let scanBottom: Double = 13.6

    /// The snap's stagger between pieces (the gallery's `Math.min(30, 270 / kids.length)` ms).
    static func snapStep(pieces: Int) -> TimeInterval { min(snapStaggerMax, snapStaggerBudget / Double(max(1, pieces))) }

    /// When the snap's last piece has settled (`180 + kids.length * step` ms), the moment the green dot starts.
    static func snapLead(pieces: Int) -> TimeInterval { snapPiece + Double(max(1, pieces)) * snapStep(pieces: pieces) }

    /// How long the action runs.
    public static func duration(_ motion: MarkMotion, pieces: Int) -> TimeInterval {
        switch motion {
        case .caught: return snapLead(pieces: pieces) + dotFade
        case .clipboardCleaned: return wipe + dotFade
        case .copyClean: return pulse
        case .coverLifts, .coverReturns: return lift
        case .pauseCrossFade: return crossFade
        case .needsYouPop: return pop
        case .updateFade, .dotFadeOut: return dotFade
        }
    }

    /// The moments a frame is drawn: every 1/60 s up to the end, the end itself last. Under Reduce Motion, only the end.
    public static func frameTimes(_ motion: MarkMotion, pieces: Int, reduceMotion: Bool) -> [TimeInterval] {
        let d = duration(motion, pieces: pieces)
        if reduceMotion { return [d] }
        // 0.3 s × 60 is 18.000000000000004 in binary; it is 18 frames, not 19.
        let n = Int((d * fps - 1e-6).rounded(.up))
        return (1...max(1, n)).map { min(d, Double($0) / fps) }
    }

    /// The pose at `t` seconds into `motion`. `lifted` is the rest pose's cover (an Undo's original showing), which every
    /// action but the lift itself plays on top of.
    public static func pose(_ motion: MarkMotion, pieces: Int, at t: TimeInterval, lifted: Bool = false) -> MarkPose {
        let d = duration(motion, pieces: pieces)
        let t = min(max(0, t), d)
        var p = MarkPose.rest(lifted: lifted)
        switch motion {
        case .caught:
            let step = snapStep(pieces: pieces)
            p.pieces = (0..<max(0, pieces)).map { i in
                let local = (t - Double(i) * step) / snapPiece
                // `fill: backwards`: before its turn a piece waits at the first keyframe, invisible and large.
                guard local < 1 else { return MarkPiecePose(opacity: 1, scale: 1) }
                let e = Easing.snap(max(0, local))
                return MarkPiecePose(opacity: min(1, max(0, e)), scale: snapFromScale + (1 - snapFromScale) * e)
            }
            if p.pieces?.allSatisfy({ $0 == MarkPiecePose(opacity: 1, scale: 1) }) == true { p.pieces = nil }
            let lead = snapLead(pieces: pieces)
            p.dotOpacity = t <= lead ? 0 : Easing.easeOut((t - lead) / dotFade)
        case .clipboardCleaned:
            if t < wipe {
                let e = Easing.easeInOut(t / wipe)
                p.wipeX = wipeDistance * e
                p.designedOpacity *= wipeFromOpacity + (1 - wipeFromOpacity) * Easing.easeIn(t / wipe)
                p.dotOpacity = 0
            } else {
                p.dotOpacity = Easing.easeOut((t - wipe) / dotFade)
            }
        case .copyClean:
            let e = Easing.easeInOut(t / pulse)
            p.markScale = 1 + (pulseScale - 1) * (e < 0.5 ? e * 2 : (1 - e) * 2)
        case .coverLifts, .coverReturns:
            let e = Easing.easeOut(t / lift)
            let up = motion == .coverLifts ? e : 1 - e
            p.designedDX = liftOffset * up
            p.designedDY = -liftOffset * up
            p.designedOpacity = 1 + (liftedOpacity - 1) * up
        case .pauseCrossFade:
            p.crossFade = Easing.easeOut(t / crossFade)
            if p.crossFade == 1 { p.crossFade = nil }
        case .needsYouPop:
            let e = Easing.easeOut(t / pop)
            if e < popPeakAt {
                let k = e / popPeakAt
                p.dotScale = popPeak * k
                p.dotOpacity = k
            } else {
                p.dotScale = popPeak + (1 - popPeak) * (e - popPeakAt) / (1 - popPeakAt)
                p.dotOpacity = 1
            }
        case .updateFade:
            p.dotOpacity = Easing.easeOut(t / dotFade)
        case .dotFadeOut:
            p.dotOpacity = 1 - Easing.easeOut(t / dotFade)
        }
        return p
    }

    /// The pose the action ends on: what Reduce Motion shows at once.
    public static func finalPose(_ motion: MarkMotion, pieces: Int, lifted: Bool = false) -> MarkPose {
        pose(motion, pieces: pieces, at: duration(motion, pieces: pieces), lifted: lifted)
    }

    /// The checking scan line's centre at `t` seconds into the loop: down for 0.55 s, then back up (ease-in-out each way).
    public static func scanY(at t: TimeInterval) -> Double {
        let phase = t.truncatingRemainder(dividingBy: scanPeriod)
        let leg = phase < scanLeg ? phase / scanLeg : 1 - (phase - scanLeg) / scanLeg
        return scanTop + (scanBottom - scanTop) * Easing.easeInOut(leg)
    }

    /// The scan line for loop frame `index` of `scanFrames`.
    public static func scanY(frame index: Int) -> Double { scanY(at: Double(index) / fps) }

    /// Where the scan line rests under Reduce Motion: the middle of the mark, still (the gallery's `translateY(8px)`).
    public static let scanRest: Double = 8
}

/// The CSS timing functions the gallery uses, solved exactly (cubic Bézier with x(t) inverted by Newton steps).
enum Easing {
    static func easeOut(_ x: Double) -> Double { bezier(0, 0, 0.58, 1, x) }
    static func easeIn(_ x: Double) -> Double { bezier(0.42, 0, 1, 1, x) }
    static func easeInOut(_ x: Double) -> Double { bezier(0.42, 0, 0.58, 1, x) }
    /// The snap's overshoot: `cubic-bezier(.2,.9,.3,1.25)`.
    static func snap(_ x: Double) -> Double { bezier(0.2, 0.9, 0.3, 1.25, x) }

    static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        let x = min(1, max(0, x))
        if x == 0 || x == 1 { return x }
        func sample(_ a: Double, _ b: Double, _ t: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        func slope(_ a: Double, _ b: Double, _ t: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b)
        }
        var t = x
        for _ in 0..<8 {
            let err = sample(x1, x2, t) - x
            let d = slope(x1, x2, t)
            if abs(err) < 1e-7 { break }
            if abs(d) < 1e-6 { break }
            t -= err / d
        }
        // Bisection fallback when Newton strays.
        if t < 0 || t > 1 || abs(sample(x1, x2, t) - x) > 1e-5 {
            var lo = 0.0, hi = 1.0
            t = x
            for _ in 0..<40 {
                let v = sample(x1, x2, t)
                if abs(v - x) < 1e-7 { break }
                if v < x { lo = t } else { hi = t }
                t = (lo + hi) / 2
            }
        }
        return sample(y1, y2, t)
    }
}
