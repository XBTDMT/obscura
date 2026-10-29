// G-12 routes A and B: which parts of an image are read a second time, zoomed. Pure: lines + text regions in,
// bands and tiles out. Every value was measured against the image fixtures (G-12).
public import Foundation
import CoreGraphics

/// The knobs of the re-read passes, each with the measurement it rests on.
public struct RecallTuning: Sendable, Hashable {
    /// A line of at least this many UTF-16 units is re-read. Vision's accurate recognizer stopped a 302-char line after
    /// ~112 characters and split 180- and 195-char lines (2026-10-27); 96 leaves a margin under that.
    public var longLineUnits = 96
    /// Tile width and overlap in glyph advances. A cropped line band read whole up to 195 characters in the probes,
    /// while a tile that starts or ends inside a token misreads its edge (measured: a 56-glyph last tile read a
    /// closing `f",` as `fiồại`, the whole band read it right at 1×–3×). So a band is cut only when it is long:
    /// 120 glyphs per tile, with a 20-glyph overlap to seam on.
    public var tileGlyphs: CGFloat = 120
    public var overlapGlyphs: CGFloat = 20
    /// Two observations on one row closer than this many advances are one line Vision split.
    public var splitGapGlyphs: CGFloat = 1.5
    /// A text region reaching this many advances past a line's end (or start) means the read ended early.
    public var endsEarlyGlyphs: CGFloat = 2
    /// A text region whose area is less than this fraction covered by recognized lines was skipped (route B).
    public var unreadCoverage: CGFloat = 0.5
    /// Route B ignores regions narrower than this many heights (about six glyphs): shorter than any secret format.
    public var minUnreadAspect: CGFloat = 4
    /// Unread regions on one row within this many heights of each other are read as one band.
    public var unreadJoinHeights: CGFloat = 3
    /// Strips are scaled so the line is about this tall: 24 px lines read at 2×, which fixed the probe's misreads.
    public var targetLineHeight: CGFloat = 48
    public var maxScale: CGFloat = 3
    /// Vertical padding of a band, in line heights, above and below.
    public var bandPadding: CGFloat = 0.35
    /// Scale factors (× the strip's scale, never below 1×) for strips a sheet returned no text for, tried in order.
    public var retryScales: [CGFloat] = [1.25, 0.8]
    /// A re-read sheet is at most this tall and wide (Vision's working size; nothing is downscaled).
    public var sheetMaxSide = 4096
    /// No re-read sheet, and no last-attempt crop read at full size, holds more pixels than this: twice `sheetMaxSide`
    /// squared (`RereadSheet.maxPixels`), 32 MP at the defaults (128 MB drawn). Security scan F13: a band's height
    /// comes from the picture's text, which whoever made the picture chose.
    public var sheetMaxPixels: Int { Int(RereadSheet.maxPixels(maxSide: sheetMaxSide)) }
    /// The re-read is skipped when less than this is left of the image's OCR deadline (pass 1 keeps its result).
    public var minimumRereadBudget: Duration = .milliseconds(500)
    /// The re-read's recognition languages (see `OCROptions.languages`).
    public var rereadLanguages = ["en-US"]
    /// G-22: a strip or band reading is short when it falls behind its ink by more than `shortReadTolerance(ink:)`
    /// glyphs (`ReadCount.isShort`): at least `shortReadMinimum`, or `shortReadFraction` of the ink when that is more.
    /// The floor absorbs a read that drops or merges a glyph or two (measured: a dropped `f` plus its `",`); a short
    /// read under load lost 86 of 322 (27 %).
    public var shortReadMinimum: CGFloat = 3
    public var shortReadFraction: CGFloat = 0.03

    public func shortReadTolerance(ink: Int) -> CGFloat { max(shortReadMinimum, shortReadFraction * CGFloat(ink)) }

    public init() {}
}

public enum RereadReason: String, Sendable, Hashable, CaseIterable {
    /// The line is at least `longLineUnits` long.
    case long
    /// Two observations on one row nearly touch.
    case split
    /// A text region continues past the observation's end (or before its start).
    case endsEarly
    /// The caller flagged the line: a secret-looking label whose value no vendor detector recognized.
    case label
    /// Route B: a text region with no recognized text.
    case unread
}

/// One horizontal band of the image to read again, already cut into overlapping tiles.
public struct RereadBand: Sendable, Hashable {
    /// Full-resolution band, padded and clipped to the image.
    public let rect: CGRect
    /// Positions in the pass-1 lines this band reads again (empty when the band holds only unread text).
    public let replaces: [Int]
    public let reasons: Set<RereadReason>
    /// Estimated glyph advance (px, full resolution) and line height of the band's text.
    public let advance: CGFloat
    public let lineHeight: CGFloat
    /// The text the band was planned around (the lines' and regions' union, before padding).
    public let core: CGRect
    /// Left-to-right, overlapping by `overlapGlyphs` advances; each spans the band's full height.
    public let tiles: [CGRect]
    /// The factor each tile is enlarged by on the sheet.
    public let scale: CGFloat
}

public enum RereadPlanner {
    /// Bands to re-read for these pass-1 `lines` (positions are indexes into the array) and `regions`.
    /// `labelLines` are the positions the caller flagged (route A's label trigger).
    public static func plan(lines: [OCRLine], regions: [TextRegion], imageSize: CGSize, labelLines: Set<Int>,
                            tuning: RecallTuning = RecallTuning()) -> [RereadBand] {
        let bounds = CGRect(origin: .zero, size: imageSize)
        var drafts: [Draft] = []

        // Route A: flagged lines, each grown over its split partners and the text regions it runs into.
        let triggers = lineTriggers(lines: lines, regions: regions, labelLines: labelLines, tuning: tuning)
        for (position, reasons) in triggers.sorted(by: { $0.key < $1.key }) {
            let line = lines[position]
            let advance = advance(of: line)
            var members: Set<Int> = [position]
            var extent = line.rect
            var grew = true
            while grew {
                grew = false
                for (other, candidate) in lines.enumerated() where !members.contains(other) {
                    guard sameRow(candidate.rect, extent), horizontalGap(candidate.rect, extent) <= tuning.splitGapGlyphs * advance else { continue }
                    members.insert(other); extent = extent.union(candidate.rect); grew = true
                }
                for region in regions where sameRow(region.rect, extent) && horizontalGap(region.rect, extent) <= advance {
                    let union = extent.union(region.rect)
                    if union != extent { extent = union; grew = true }
                }
            }
            drafts.append(Draft(extent: extent, replaces: members, reasons: reasons, advance: advance, lineHeight: line.rect.height))
        }

        // Route B: regions nobody read, joined per row.
        let unread = regions.filter { region in
            region.rect.height > 0 && region.rect.width >= tuning.minUnreadAspect * region.rect.height
                && coveredFraction(region.rect, by: lines) < tuning.unreadCoverage
                && !drafts.contains(where: { $0.extent.intersects(region.rect) })
        }.sorted { $0.rect.minX < $1.rect.minX }
        var groups: [[TextRegion]] = []
        for region in unread {
            if let i = groups.firstIndex(where: { group in group.contains { sameRow($0.rect, region.rect)
                && horizontalGap($0.rect, region.rect) <= tuning.unreadJoinHeights * region.rect.height } }) {
                groups[i].append(region)
            } else {
                groups.append([region])
            }
        }
        for group in groups {
            let extent = group.dropFirst().reduce(group[0].rect) { $0.union($1.rect) }
            let glyphs = group.flatMap(\.glyphs)
            let advance = glyphs.count >= 2
                ? max(1, (glyphs.map(\.maxX).max()! - glyphs.map(\.minX).min()!) / CGFloat(glyphs.count))
                : extent.height * 0.6
            // A band over a row that pass 1 partly read replaces those lines: its reading is the fuller one.
            let replaces = Set(lines.enumerated().filter { sameRow($0.element.rect, extent) && $0.element.rect.intersects(extent.insetBy(dx: -advance, dy: 0)) }.map(\.offset))
            drafts.append(Draft(extent: extent, replaces: replaces, reasons: [.unread], advance: advance, lineHeight: extent.height))
        }

        // One band per row span: drafts that overlap on a row become one.
        var merged: [Draft] = []
        for draft in drafts {
            if let i = merged.firstIndex(where: { sameRow($0.extent, draft.extent) && horizontalGap($0.extent, draft.extent) <= 0 }) {
                merged[i] = merged[i].merging(draft)
            } else {
                merged.append(draft)
            }
        }

        return merged.compactMap { draft in
            let pad = tuning.bandPadding * draft.lineHeight
            let rect = draft.extent.insetBy(dx: -draft.advance, dy: -pad).intersection(bounds).integral.intersection(bounds)
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
            let scale = min(tuning.maxScale, max(1, tuning.targetLineHeight / max(draft.lineHeight, 1)))
            var tileWidth = tuning.tileGlyphs * draft.advance
            // A tile never grows past the sheet once enlarged.
            tileWidth = min(tileWidth, CGFloat(tuning.sheetMaxSide) / scale - 16)
            let overlap = min(tuning.overlapGlyphs * draft.advance, tileWidth / 3)
            return RereadBand(rect: rect, replaces: draft.replaces.sorted(), reasons: draft.reasons, advance: draft.advance,
                              lineHeight: draft.lineHeight, core: draft.extent,
                              tiles: tiles(across: rect, width: tileWidth, overlap: overlap), scale: scale)
        }
    }

    /// Why each line is re-read (route A), by position. Lines with no reason are absent.
    public static func lineTriggers(lines: [OCRLine], regions: [TextRegion], labelLines: Set<Int>,
                                    tuning: RecallTuning = RecallTuning()) -> [Int: Set<RereadReason>] {
        var reasons: [Int: Set<RereadReason>] = [:]
        for position in labelLines where lines.indices.contains(position) { reasons[position, default: []].insert(.label) }
        for (position, line) in lines.enumerated() {
            let advance = advance(of: line)
            if line.text.utf16.count >= tuning.longLineUnits { reasons[position, default: []].insert(.long) }
            for (other, neighbour) in lines.enumerated() where other != position && sameRow(neighbour.rect, line.rect)
                && horizontalGap(neighbour.rect, line.rect) <= tuning.splitGapGlyphs * advance {
                reasons[position, default: []].insert(.split)
            }
            let reach = tuning.endsEarlyGlyphs * advance
            for region in regions where sameRow(region.rect, line.rect) && horizontalGap(region.rect, line.rect) <= advance {
                let after = region.rect.maxX - line.rect.maxX, before = line.rect.minX - region.rect.minX
                let excessAfter = CGRect(x: line.rect.maxX, y: region.rect.minY, width: max(0, after), height: region.rect.height)
                let excessBefore = CGRect(x: region.rect.minX, y: region.rect.minY, width: max(0, before), height: region.rect.height)
                let others = lines.enumerated().filter { $0.offset != position }.map(\.element)
                if after > reach, coveredFraction(excessAfter, by: others) < tuning.unreadCoverage { reasons[position, default: []].insert(.endsEarly) }
                if before > reach, coveredFraction(excessBefore, by: others) < tuning.unreadCoverage { reasons[position, default: []].insert(.endsEarly) }
            }
        }
        return reasons
    }

    /// Overlapping tiles across `rect`: one when it fits (with 15 % slack), else steps of `width − overlap` with the
    /// last tile flush with the band's end.
    public static func tiles(across rect: CGRect, width: CGFloat, overlap: CGFloat) -> [CGRect] {
        guard width > 0, rect.width > width * 1.15 else { return [rect] }
        var result: [CGRect] = []
        var x = rect.minX
        let step = max(1, width - overlap)
        while true {
            if x + width >= rect.maxX {
                result.append(CGRect(x: max(rect.minX, rect.maxX - width), y: rect.minY, width: min(width, rect.width), height: rect.height).integral)
                break
            }
            result.append(CGRect(x: x, y: rect.minY, width: width, height: rect.height).integral)
            x += step
        }
        return result
    }

    /// The narrowest glyph advance a line of text is taken to have, as a fraction of its height: the lower bound every
    /// advance estimate here is clamped to (`advance(of:)`). G-40's capacity bound (route D) divides a spot's width by
    /// this advance, so a spot is credited with the most glyphs any text of its height could fit.
    public static let narrowestAdvanceRatio: CGFloat = 0.3

    /// The line's average glyph advance, bounded to [`narrowestAdvanceRatio`, 1.0] × its height.
    public static func advance(of line: OCRLine) -> CGFloat {
        let count = CGFloat(max(1, line.text.utf16.count))
        let h = max(1, line.rect.height)
        return min(max(line.rect.width / count, narrowestAdvanceRatio * h), h)
    }

    /// Two boxes share a row when their vertical overlap is at least half the shorter one's height.
    static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap >= 0.5 * min(a.height, b.height)
    }

    /// Horizontal distance between two boxes; negative when they overlap.
    static func horizontalGap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(a.minX, b.minX) - min(a.maxX, b.maxX)
    }

    /// The fraction of `rect`'s area that `lines` cover (their rects barely overlap one another, so areas add).
    static func coveredFraction(_ rect: CGRect, by lines: [OCRLine]) -> CGFloat {
        let area = rect.width * rect.height
        guard area > 0 else { return 1 }
        var covered: CGFloat = 0
        for line in lines {
            let i = line.rect.intersection(rect)
            if !i.isNull { covered += i.width * i.height }
        }
        return min(1, covered / area)
    }

    private struct Draft {
        var extent: CGRect
        var replaces: Set<Int>
        var reasons: Set<RereadReason>
        var advance: CGFloat
        var lineHeight: CGFloat

        func merging(_ other: Draft) -> Draft {
            Draft(extent: extent.union(other.extent), replaces: replaces.union(other.replaces), reasons: reasons.union(other.reasons),
                  advance: max(advance, other.advance), lineHeight: max(lineHeight, other.lineHeight))
        }
    }
}
