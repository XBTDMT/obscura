// G-22: does a re-read account for the ink it was read from? A strip or a band whose reading falls short of its ink is
// read again; a band still short after that is marked (`ShortRead`) so the engine covers it conservatively. Pure.
//
// Measured 2026-10-27 (cloud.aws.sessiontoken, ANE saturated by other Vision work): one re-read sheet of five strips came
// back with 3 observations instead of 7: the full readings of four strips were missing and two strips held only short
// duplicate fragments (23 and 28 units). The empty-strip retry re-read the two empty strips, the two fragment strips were
// trusted, the stitch joined across 1,132 px nobody had read, and the line came back 236 units for 322 glyphs of ink.
// The cover counts one grid cell per character from the token's start, so it stopped 86 glyphs short. Nothing measured
// the reading against the ink, so nothing noticed.
public import Foundation
import CoreGraphics

/// A band's ink: one box per inked grid cell (`isGrid`), else one box per run of inked columns.
public struct InkProfile: Sendable, Hashable {
    public let boxes: [CGRect]
    /// The grid's advance (px, full resolution), or an estimate (0.6 × height) without a grid.
    public let advance: CGFloat
    /// True when `boxes` are glyph cells, so a unit count can be compared with them.
    public let isGrid: Bool

    public init(boxes: [CGRect], advance: CGFloat, isGrid: Bool) {
        self.boxes = boxes.sorted { $0.minX < $1.minX }
        self.advance = advance
        self.isGrid = isGrid
    }
}

/// How much of the ink in a span a reading accounts for. Counts only: no text.
public struct ReadCount: Sendable, Hashable {
    /// Non-space UTF-16 units read whose box centre lies in the span.
    public let units: Int
    /// Ink boxes whose centre lies in the span (glyph cells on a grid, else column runs).
    public let ink: Int
    /// Ink boxes in the span that no read unit lies over.
    public let uncovered: Int
    /// True when `ink` counts glyphs (a grid), so `units` is comparable with it.
    public let isGrid: Bool

    public init(units: Int, ink: Int, uncovered: Int, isGrid: Bool) {
        self.units = units
        self.ink = ink
        self.uncovered = uncovered
        self.isGrid = isGrid
    }

    /// Short: on a grid, fewer units than ink cells by more than the tolerance, or (grid or not) more uncovered ink
    /// than the tolerance. The tolerance (`RecallTuning.shortReadTolerance`) absorbs single dropped or merged glyphs.
    public func isShort(_ tuning: RecallTuning) -> Bool {
        let tolerance = tuning.shortReadTolerance(ink: ink)
        if isGrid, CGFloat(ink - units) > tolerance { return true }
        return CGFloat(uncovered) > tolerance
    }
}

/// A band whose reading stayed short of its ink after the bounded re-reads: the engine covers each finding on it from
/// the finding's start to the end of the line's ink (RecallPipeline). Counts and geometry only.
public struct ShortRead: Sendable, Hashable {
    /// Why the band's reading cannot be trusted to reach the end of its ink.
    public enum Cause: String, Sendable, Hashable {
        /// G-22: every strip was read, and the reading still falls short of the band's ink after the bounded retries.
        case short
        /// Fail-open #1: part or all of the band was never read (`ReadCompleteness.Gap`). The engine also ends the image
        /// "not checked".
        case unread
        /// G-32: no re-read could read the band; the last attempt read it only at Vision's `.fast` level, a weaker model
        /// whose text may be misread. Read (the image can be checked), but covered conservatively like a short band.
        case fast
    }

    /// The band's position in the plan.
    public let band: Int
    public let count: ReadCount
    /// The band's ink boxes (full resolution, left to right) and their advance: where "the end of the line's ink" is.
    /// For a band whose ink could not be measured, its text's box (the end of the band).
    public let ink: [CGRect]
    public let advance: CGFloat
    public let cause: Cause

    public init(band: Int, count: ReadCount, ink: [CGRect], advance: CGFloat, cause: Cause = .short) {
        self.band = band
        self.count = count
        self.ink = ink
        self.advance = advance
        self.cause = cause
    }

    /// The right edge of the ink that continues the row from `x` (exclusive of ink left of `start`): ink boxes are
    /// chained while each gap is at most `ReadCoverage.chainGapAdvances` advances (a space is about one; a column gap is
    /// more), so the end is that of the text run the cover is on, not of a far column. `x` when nothing continues it.
    public func inkEnd(from x: CGFloat, start: CGFloat) -> CGFloat {
        ReadCoverage.inkEnd(from: x, start: start, ink: ink, advance: advance)
    }
}

public enum ReadCoverage {
    /// Two ink boxes belong to one run of text when the gap between them is at most this many advances (the rule
    /// `BoxMapper.lineExtent` uses for "the line's ink").
    public static let chainGapAdvances: CGFloat = 2

    /// Counts `run` against the `profile` boxes whose centres lie in `span` (x, full resolution).
    public static func count(_ run: TileStitcher.Run, profile: InkProfile, span: ClosedRange<CGFloat>) -> ReadCount {
        // A read unit accounts for the ink centred within a quarter advance of its box (geometry noise, not a neighbour).
        let reach = profile.advance / 4
        var read: [ClosedRange<CGFloat>] = []
        var units = 0
        for (unit, box) in zip(run.units, run.boxes) where !box.isNull && !UnitBoxes.isSpace(unit) {
            read.append((box.minX - reach)...(box.maxX + reach))
            if span.contains(box.midX) { units += 1 }
        }
        let ink = profile.boxes.filter { span.contains($0.midX) }
        let uncovered = ink.filter { cell in !read.contains { $0.contains(cell.midX) } }.count
        return ReadCount(units: units, ink: ink.count, uncovered: uncovered, isGrid: profile.isGrid)
    }

    /// The part of `tile` (x) whose ink a tile's reading is judged on: an inner edge (one shared with a neighbouring
    /// tile) loses one advance, since the glyph it cuts is read by the neighbour; a band edge keeps all.
    public static func judgedSpan(tile: CGRect, band: CGRect, advance: CGFloat) -> ClosedRange<CGFloat> {
        let lower = tile.minX > band.minX + 0.5 ? tile.minX + advance : -CGFloat.infinity
        let upper = tile.maxX < band.maxX - 0.5 ? tile.maxX - advance : CGFloat.infinity
        return lower <= upper ? lower...upper : tile.midX...tile.midX
    }

    static func inkEnd(from x: CGFloat, start: CGFloat, ink: [CGRect], advance: CGFloat) -> CGFloat {
        var end = x
        let gap = chainGapAdvances * max(advance, 1)
        for box in ink where box.midX > start && box.maxX > end {
            guard box.minX - end <= gap else { break }
            end = box.maxX
        }
        return end
    }
}
