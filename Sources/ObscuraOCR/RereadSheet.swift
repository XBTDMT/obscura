// G-12 routes A and B: every tile of every band is enlarged and stacked on one "sheet" so the whole re-read is one
// Vision request (measured 2026-10-27: five tiles as one sheet 90 ms, as five requests ~280 ms). Layout and the
// mapping back are pure; only `render` draws.
public import Foundation
public import CoreGraphics

/// One tile to re-read: which band it belongs to, where it is on the image and how much it is enlarged.
public struct RereadStrip: Sendable, Hashable {
    public let band: Int
    public let tile: CGRect
    public let scale: CGFloat
    public init(band: Int, tile: CGRect, scale: CGFloat) {
        self.band = band
        self.tile = tile
        self.scale = scale
    }
}

/// Where each strip sits on one sheet (top-left origin, sheet pixels).
public struct SheetLayout: Sendable, Hashable {
    public struct Slot: Sendable, Hashable {
        public let strip: Int
        public let rect: CGRect
    }
    public let size: CGSize
    public let slots: [Slot]
}

public enum RereadSheet {
    /// Stacks strips top to bottom with a gap of half a strip's height (at least 8 px) around each, starting a new sheet
    /// when the next strip would pass `maxSide` or the sheet would hold more than `maxPixels(maxSide:)`. Strip indexes
    /// refer to `strips`.
    ///
    /// A strip that does not fit a sheet on its own (`fits`) is on no sheet: the caller finds it missing from every
    /// layout and must treat it as unread (security scan F13: a first strip used to be admitted whatever its size, so a
    /// band of very tall text became a sheet of hundreds of megapixels). So no sheet is taller than `maxSide` or holds
    /// more than `maxPixels(maxSide:)` pixels.
    public static func layout(_ strips: [RereadStrip], maxSide: Int) -> [SheetLayout] {
        var sheets: [SheetLayout] = []
        var slots: [SheetLayout.Slot] = []
        var top: CGFloat = 0, width: CGFloat = 0
        func close() {
            guard !slots.isEmpty else { return }
            sheets.append(SheetLayout(size: CGSize(width: width, height: top), slots: slots))
            slots = []; top = 0; width = 0
        }
        for (index, strip) in strips.enumerated() {
            guard fits(strip, maxSide: maxSide) else { continue }
            let size = slotSize(strip)
            let gap = max(8, (size.height / 2).rounded())
            if !slots.isEmpty, top + gap + size.height + gap > CGFloat(maxSide)
                || max(width, gap + size.width + gap) * (top + gap + size.height + gap) > maxPixels(maxSide: maxSide) { close() }
            if slots.isEmpty { top = gap }
            slots.append(.init(strip: index, rect: CGRect(x: gap, y: top, width: size.width, height: size.height)))
            top += size.height + gap
            width = max(width, gap + size.width + gap)
        }
        close()
        return sheets
    }

    /// A strip's size on a sheet: its tile enlarged by its scale.
    static func slotSize(_ strip: RereadStrip) -> CGSize {
        CGSize(width: (strip.tile.width * strip.scale).rounded(), height: (strip.tile.height * strip.scale).rounded())
    }

    /// The most pixels one sheet may hold: twice `maxSide` squared (`RecallTuning.sheetMaxPixels`).
    public static func maxPixels(maxSide: Int) -> CGFloat { 2 * CGFloat(maxSide) * CGFloat(maxSide) }

    /// Whether `strip`, with its gaps, fits a sheet on its own: at most `maxSide` tall (the rule every later strip on a
    /// sheet already met) and at most `maxPixels(maxSide:)` in all. No band the planner makes comes near the area: a
    /// tile is at most `maxSide` wide once enlarged, 1.15 × that when a band is left whole, 1.25 × that again on a
    /// retry, plus gaps of at most half of `maxSide`, so under 1.95 × `maxSide` wide by at most `maxSide` tall. Not
    /// finite, or not positive: does not fit.
    public static func fits(_ strip: RereadStrip, maxSide: Int) -> Bool {
        let size = slotSize(strip)
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else { return false }
        let gap = max(8, (size.height / 2).rounded())
        let slot = CGSize(width: gap + size.width + gap, height: gap + size.height + gap)
        return slot.height <= CGFloat(maxSide) && slot.width * slot.height <= maxPixels(maxSide: maxSide)
    }

    /// Draws `layout` from `image`: each slot gets its strip's background (the tile's top-left pixel, inside the band's
    /// padding) over the slot and its gap, then the tile enlarged with high-quality interpolation. Public so a caller
    /// that re-reads one area on demand (the engine's key text, G-17) draws it exactly as the recall pass does.
    public static func render(_ image: CGImage, layout: SheetLayout, strips: [RereadStrip]) throws(OCRError) -> CGImage {
        let width = Int(layout.size.width), height = Int(layout.size.height)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw .badImage }
        context.interpolationQuality = .high
        var previousBottom: CGFloat = 0
        for (n, slot) in layout.slots.enumerated() {
            let strip = strips[slot.strip]
            guard let tile = image.cropping(to: strip.tile.integral) else { continue }
            // Background band: from the end of the previous slot's band to halfway into the next gap (or the sheet end).
            let nextTop = n + 1 < layout.slots.count ? layout.slots[n + 1].rect.minY : layout.size.height
            let bandBottom = n + 1 < layout.slots.count ? (slot.rect.maxY + nextTop) / 2 : layout.size.height
            if let corner = tile.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)) {
                context.interpolationQuality = .none
                context.draw(corner, in: flip(CGRect(x: 0, y: previousBottom, width: layout.size.width, height: bandBottom - previousBottom), height: layout.size.height))
                context.interpolationQuality = .high
            }
            previousBottom = bandBottom
            context.draw(tile, in: flip(slot.rect, height: layout.size.height))
        }
        guard let sheet = context.makeImage() else { throw .badImage }
        return sheet
    }

    /// Top-left rect → CoreGraphics' bottom-left drawing rect.
    static func flip(_ rect: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Sheet observations → per-strip lines in full-resolution image coordinates (index preserved). An observation
    /// belongs to the slot it overlaps most vertically, when that overlap is at least half its height; others are dropped.
    public static func mapBack(_ observations: [OCRLine], layout: SheetLayout, strips: [RereadStrip]) -> [Int: [OCRLine]] {
        var result: [Int: [OCRLine]] = [:]
        for observation in observations {
            var best: (slot: SheetLayout.Slot, overlap: CGFloat)?
            for slot in layout.slots {
                let overlap = min(slot.rect.maxY, observation.rect.maxY) - max(slot.rect.minY, observation.rect.minY)
                if overlap > (best?.overlap ?? 0) { best = (slot, overlap) }
            }
            guard let best, best.overlap >= 0.5 * observation.rect.height else { continue }
            let strip = strips[best.slot.strip]
            let transform = TransformedGlyphBoxes(base: observation.candidate ?? NoBoxes(), sheetOrigin: best.slot.rect.origin,
                                                  origin: strip.tile.origin, scale: strip.scale)
            let rect = transform.apply(observation.rect)
            result[best.slot.strip, default: []].append(OCRLine(index: observation.index, text: observation.text, rect: rect,
                                                                candidate: observation.candidate == nil ? nil : transform))
        }
        return result
    }

    private struct NoBoxes: GlyphBoxProvider {
        func boundingBox(forUTF16Range range: NSRange) -> CGRect? { nil }
    }
}
