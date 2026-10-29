// Ink on a line's row, measured from the pixels (G-12 cover geometry). Vision's word boxes are padded and its
// text-rectangle character boxes miss thin glyphs (measured: no box for the `"` before a JSON value, none for a `:`),
// so the cells a cover snaps to are measured directly: which columns of the row carry ink, the monospace grid the
// glyphs sit on, and the ink bounding box inside each cell. Only lines that carry a finding are measured.
public import Foundation
public import CoreGraphics

public enum InkCells {
    /// One ink bounding box per inked cell on `line`'s row, left to right, measured over the line rect widened by
    /// `reach` line heights on each side (so glyphs Vision dropped at either end are seen). Empty when the row fits no
    /// monospace grid (proportional text keeps the word-box placement).
    public static func measure(_ image: CGImage, line: OCRLine, reach: CGFloat = 6) -> [CGRect] {
        let h = line.rect.height
        guard h >= 4 else { return [] }
        let band = CGRect(x: line.rect.minX - reach * h, y: line.rect.minY, width: line.rect.width + 2 * reach * h, height: h)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard !band.isNull, band.width >= 8, band.height >= 4, let columns = inkColumns(image, band: band) else { return [] }
        // The grid comes from the text-rectangle glyph boxes when the row has them (one box per glyph; the pixel runs
        // split a `"` into two ticks and merge `__` into one), else from the pixel runs at least 0.4 line heights wide.
        let runBoxes = runs(columns).map { CGRect(x: band.minX + CGFloat($0.lowerBound), y: band.minY, width: CGFloat($0.count), height: band.height) }
        guard let grid = GlyphGrid.fit(line.glyphBoxes, lineHeight: h) ?? GlyphGrid.fit(runBoxes.filter { $0.width >= 0.4 * h }, lineHeight: h)
        else { return [] }
        return cells(columns: columns, originX: band.minX, originY: band.minY, grid: grid)
    }

    /// The ink of a whole re-read band (G-22): one box per inked grid cell when the row fits a monospace grid, else one
    /// box per run of inked columns (proportional text: runs are words, not glyphs, so only coverage can be judged).
    /// `rect` is the band's text (its core); `glyphs` its text-rectangle glyph boxes. Nil when the band cannot be drawn.
    public static func profile(_ image: CGImage, rect: CGRect, glyphs: [CGRect]) -> InkProfile? {
        let h = rect.height
        guard h >= 4 else { return nil }
        let band = rect.insetBy(dx: -h, dy: 0).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard !band.isNull, band.width >= 8, band.height >= 4, let columns = inkColumns(image, band: band) else { return nil }
        let runBoxes = runs(columns).map { CGRect(x: band.minX + CGFloat($0.lowerBound), y: band.minY, width: CGFloat($0.count), height: band.height) }
        if let grid = GlyphGrid.fit(glyphs, lineHeight: h) ?? GlyphGrid.fit(runBoxes.filter { $0.width >= 0.4 * h }, lineHeight: h) {
            return InkProfile(boxes: cells(columns: columns, originX: band.minX, originY: band.minY, grid: grid), advance: grid.advance, isGrid: true)
        }
        return InkProfile(boxes: runBoxes, advance: max(1, 0.6 * h), isGrid: false)
    }

    /// Per column of `band`, the topmost and bottommost rows (band coordinates) with ink, or nil for a blank column.
    /// Ink is a pixel differing from the band's most common colour by more than 48 in any channel. Nil when the band
    /// cannot be drawn.
    static func inkColumns(_ image: CGImage, band: CGRect) -> [ClosedRange<Int>?]? {
        let width = Int(band.width), height = Int(band.height)
        guard let crop = image.cropping(to: band), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data
        else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        func bucket(_ i: Int) -> UInt32 {
            UInt32(bytes[i * 4] >> 3) << 10 | UInt32(bytes[i * 4 + 1] >> 3) << 5 | UInt32(bytes[i * 4 + 2] >> 3)
        }
        var counts: [UInt32: Int] = [:]
        for i in 0..<(width * height) { counts[bucket(i), default: 0] += 1 }
        guard let backgroundKey = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        var sum = (0, 0, 0), n = 0
        for i in 0..<(width * height) where bucket(i) == backgroundKey {
            sum.0 += Int(bytes[i * 4]); sum.1 += Int(bytes[i * 4 + 1]); sum.2 += Int(bytes[i * 4 + 2]); n += 1
        }
        let bg = (sum.0 / max(n, 1), sum.1 / max(n, 1), sum.2 / max(n, 1))
        // A bitmap context keeps its top row first in memory, so y counts down from the band's top.
        var columns = [ClosedRange<Int>?](repeating: nil, count: width)
        for x in 0..<width {
            var top: Int?, bottom: Int?
            for y in 0..<height {
                let p = (y * width + x) * 4
                if max(abs(Int(bytes[p]) - bg.0), abs(Int(bytes[p + 1]) - bg.1), abs(Int(bytes[p + 2]) - bg.2)) > 48 {
                    if top == nil { top = y }
                    bottom = y
                }
            }
            if let top, let bottom { columns[x] = top...bottom }
        }
        return columns
    }

    /// Maximal runs of inked columns.
    static func runs(_ columns: [ClosedRange<Int>?]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        for (x, ink) in columns.enumerated() {
            if ink != nil, start == nil { start = x }
            if ink == nil, let s = start { result.append(s..<x); start = nil }
        }
        if let s = start { result.append(s..<columns.count) }
        return result
    }

    /// One box per grid cell with ink: the bounding box of the ink inside the cell (image coordinates).
    static func cells(columns: [ClosedRange<Int>?], originX: CGFloat, originY: CGFloat, grid: GlyphGrid) -> [CGRect] {
        var boxes: [CGRect] = []
        let first = grid.cell(nearest: originX), last = grid.cell(nearest: originX + CGFloat(columns.count))
        for cell in first...max(first, last) {
            let lo = max(0, Int((grid.left(of: cell) - originX).rounded()))
            let hi = min(columns.count, Int((grid.left(of: cell) + grid.advance - originX).rounded()))
            guard lo < hi else { continue }
            let inked = (lo..<hi).filter { columns[$0] != nil }
            guard let a = inked.first, let b = inked.last else { continue }
            let top = inked.compactMap { columns[$0]?.lowerBound }.min()!, bottom = inked.compactMap { columns[$0]?.upperBound }.max()!
            boxes.append(CGRect(x: originX + CGFloat(a), y: originY + CGFloat(top), width: CGFloat(b - a + 1), height: CGFloat(bottom - top + 1)))
        }
        return boxes
    }
}
