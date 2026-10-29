// Where each finding's numbered badge goes on the canvas. The viewer design (r3-a, unified/viewer.html) puts the badge
// "on the bars"; its mockup hangs it in the leading gutter, which is empty on a form but is the key name on a `KEY=value`
// line, so the badge covered the readable text next to the secret. The viewer only knows where the bars are, not where
// the rest of the text is, so the one area it can prove holds nothing readable is a bar that covers its secret. The
// order of preference follows from that: on its own covered bar, then just past the bar's trailing edge (the end of a
// value is usually the end of the text), then above and below it, then centred on a covered bar too small to hold it,
// then a short slide further along its row, and only then the leading edge. A badge never overlaps another bar or
// another badge and stays inside the image; when nothing near is clear it slides further along the bar's row and the
// rows above and below, and as a last resort takes the spot that hides the least.
// Pure, so it is tested without a window.
import CoreGraphics

enum BadgeLayout {
    /// One finding as the layout sees it: its rect and its badge's size in the same coordinates (document points,
    /// top-left origin), and whether a bar covers it (an enabled finding) or its text shows (left visible).
    struct Item: Equatable, Sendable {
        var rect: CGRect
        var badgeSize: CGSize
        var covered: Bool
    }

    /// Which spot a badge took, in order of preference.
    enum Anchor: Equatable, Sendable {
        case onBar, trailing, above, below, centredOnBar, leading, slid, leastHidden
    }

    struct Placement: Equatable, Sendable {
        var frame: CGRect
        var anchor: Anchor
        /// False only for `.leastHidden`: no clear spot existed and this one overlaps the least.
        var isClear: Bool { anchor != .leastHidden }
    }

    /// Places one badge per item, in item order (the badge numbers), so badge 1 gets first pick.
    /// - Parameters:
    ///   - imageSize: the image's size in the items' coordinates; every badge stays inside it when it fits.
    ///   - gap: the space kept between a badge and any bar or other badge (clears the left-visible outlines).
    ///   - inset: the space kept between a badge sitting on its bar and the bar's ends.
    static func place(imageSize: CGSize, items: [Item], gap: CGFloat, inset: CGFloat) -> [Placement] {
        let bounds = CGRect(origin: .zero, size: imageSize)
        var placed: [CGRect] = []
        var result: [Placement] = []
        result.reserveCapacity(items.count)
        for (i, item) in items.enumerated() {
            // Every other finding's rect is off limits: a covered one is someone else's bar, an uncovered one is text.
            let bars = items.indices.filter { $0 != i }.map { items[$0].rect }
            let badges = placed.map { $0.insetBy(dx: -gap, dy: -gap) }
            // Rect arithmetic leaves rounding dust (an intersection's width is maxX − minX, not the width), so an
            // overlap smaller than a millionth of the badge counts as none.
            let tolerance = max(item.badgeSize.width * item.badgeSize.height * 1e-6, .ulpOfOne)
            func hidden(_ frame: CGRect) -> CGFloat {
                var area: CGFloat = 0
                for r in bars { area += overlap(frame, r) }
                for r in badges { area += overlap(frame, r) }
                // Off the image counts as hidden, and an uncovered finding's own text must stay readable.
                if !bounds.contains(frame) { area += max(frame.width * frame.height - overlap(frame, bounds), tolerance) }
                if !item.covered { area += overlap(frame, item.rect.insetBy(dx: -gap / 2, dy: -gap / 2)) }
                return area
            }
            let candidates = Self.candidates(for: item, bounds: bounds, gap: gap, inset: inset)
            if let clear = candidates.first(where: { hidden($0.frame) < tolerance }) {
                result.append(clear)
            } else {
                // Least hidden among every candidate, each pulled inside the image.
                let clamped = candidates.map { Placement(frame: clamp($0.frame, into: bounds), anchor: .leastHidden) }
                var best = clamped[0], bestArea = hidden(best.frame)
                for c in clamped.dropFirst() {
                    let a = hidden(c.frame)
                    if a < bestArea { best = c; bestArea = a }
                }
                result.append(best)
            }
            placed.append(result[result.count - 1].frame)
        }
        return result
    }

    /// How many badge-widths a badge may slide along its own row before the leading edge is tried.
    static let nearSlides = 4

    /// The spots for one badge, best first. The slid spots walk away from the bar along its row (trailing; the first
    /// `nearSlides` before the leading edge, the rest after it) and then along the rows above and below, one badge-width
    /// at a time, until they leave the image.
    static func candidates(for item: Item, bounds: CGRect, gap: CGFloat, inset: CGFloat) -> [Placement] {
        let r = item.rect, b = item.badgeSize
        let midY = r.midY - b.height / 2
        var out: [Placement] = []
        func add(_ x: CGFloat, _ y: CGFloat, _ anchor: Anchor) {
            out.append(Placement(frame: CGRect(x: x, y: y, width: b.width, height: b.height), anchor: anchor))
        }
        if item.covered, r.width >= b.width + inset * 2, r.height >= b.height {
            // On the bar at its leading end: centred in a thin bar, tucked into the top corner of a tall one.
            let y = r.height >= b.height + inset * 2 ? r.minY + inset : midY
            add(r.minX + inset, y, .onBar)
        }
        add(r.maxX + gap, midY, .trailing)
        let aboveY = r.minY - gap - b.height, belowY = r.maxY + gap
        let endX = max(r.maxX - b.width, r.minX)
        add(endX, aboveY, .above)
        add(endX, belowY, .below)
        if item.covered { add(r.midX - b.width / 2, midY, .centredOnBar) }
        let step = b.width + gap
        let leading = { add(r.minX - gap - b.width, midY, .leading) }
        guard step > 0, bounds.width > 0 else { leading(); return out }
        var x = r.maxX + gap + step, slides = 0
        while x + b.width <= bounds.maxX {
            if slides == Self.nearSlides { leading() }
            add(x, midY, .slid)
            x += step
            slides += 1
        }
        if slides <= Self.nearSlides { leading() }
        for y in [aboveY, belowY] {
            var x = endX + step
            while x + b.width <= bounds.maxX {
                add(x, y, .slid)
                x += step
            }
            x = endX - step
            while x >= bounds.minX {
                add(x, y, .slid)
                x -= step
            }
        }
        return out
    }

    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    /// `frame` moved (not resized) to lie inside `bounds`; pinned to the top-left when it is bigger than `bounds`.
    static func clamp(_ frame: CGRect, into bounds: CGRect) -> CGRect {
        var f = frame
        f.origin.x = max(bounds.minX, min(f.minX, bounds.maxX - f.width))
        f.origin.y = max(bounds.minY, min(f.minY, bounds.maxY - f.height))
        return f
    }
}
