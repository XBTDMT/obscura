// G-12 route A: the readings of a band's overlapping tiles joined into one line, with one box per UTF-16 unit.
// Pure. Adjacent tiles read the same characters in their overlap (a 16-character identical run in every probe,
// 2026-10-27), so the seam is placed in the middle of the longest common run there; with no such run it falls back
// to the middle of the overlap by position.
public import Foundation
import CoreGraphics

public enum TileStitcher {
    /// The shortest common run accepted as a seam. Shorter runs (one or two characters) recur by chance in base64.
    public static let minimumSeam = 4

    /// A unit sequence with its boxes.
    public struct Run: Sendable, Equatable {
        public var units: [UTF16.CodeUnit]
        public var boxes: [CGRect]
        /// Set by `stitch` (fail-open #22): the tiles, by position, that had no reading. Their glyphs are not in `units`,
        /// and when such a tile lies between two read ones the stitch joins the two across ink nobody read, so a band
        /// with any is not completely read (`ReadCompleteness`). Empty for a run of one tile's observations.
        public var unreadTiles: [Int]
        public init(units: [UTF16.CodeUnit], boxes: [CGRect], unreadTiles: [Int] = []) {
            self.units = units
            self.boxes = boxes
            self.unreadTiles = unreadTiles
        }
        public var text: String { String(decoding: units, as: UTF16.self) }
    }

    /// One tile's observations joined left to right; a space (spanning the gap) goes between observations.
    /// Vision can read one stretch of a strip twice: a full reading plus a short fragment of the same ink (measured
    /// 2026-10-27 on cloud.aws.sessiontoken: a 23-unit fragment inside a 119-unit reading of the same strip, and a 28-unit
    /// one over another strip's last 970 sheet px). Joined, the fragment repeated text and put a space inside the token,
    /// and a strip holding ONLY a fragment looked read. So an observation that lies mostly (`duplicateOverlap`) inside a
    /// longer one kept before it is the same ink read twice and is dropped (`distinct`).
    public static func run(of observations: [OCRLine]) -> Run {
        var run = Run(units: [], boxes: [])
        for line in distinct(observations).sorted(by: { $0.rect.minX < $1.rect.minX }) {
            let units = Array(line.text.utf16)
            guard !units.isEmpty else { continue }
            let boxes = UnitBoxes.of(line)
            if let last = run.boxes.last {
                let first = boxes.first ?? line.rect
                run.units.append(0x20)
                run.boxes.append(CGRect(x: last.maxX, y: line.rect.minY, width: max(0, first.minX - last.maxX), height: line.rect.height))
            }
            run.units.append(contentsOf: units)
            run.boxes.append(contentsOf: boxes)
        }
        return run
    }

    /// An observation whose horizontal extent lies at least this fraction inside a longer kept one is a duplicate reading.
    public static let duplicateOverlap: CGFloat = 0.5

    /// `observations` without the ones that re-read ink a longer observation already read: longest first (by UTF-16
    /// units, then width), each kept unless `duplicateOverlap` of its width lies inside one kept before it.
    public static func distinct(_ observations: [OCRLine]) -> [OCRLine] {
        let longestFirst = observations.filter { !$0.text.isEmpty }.sorted { a, b in
            let (ua, ub) = (a.text.utf16.count, b.text.utf16.count)
            return ua != ub ? ua > ub : a.rect.width > b.rect.width
        }
        var kept: [OCRLine] = []
        for line in longestFirst {
            let width = max(line.rect.width, 1)
            let inside = kept.map { max(0, min($0.rect.maxX, line.rect.maxX) - max($0.rect.minX, line.rect.minX)) }.max() ?? 0
            if inside < duplicateOverlap * width { kept.append(line) }
        }
        return kept
    }

    /// Joins the runs of consecutive overlapping `tiles` (same order). An empty run is a tile with no reading: it is
    /// skipped and listed in the result's `unreadTiles` (fail-open #22), never stitched over quietly.
    public static func stitch(_ runs: [Run], tiles: [CGRect], advance: CGFloat) -> Run {
        var accumulated = Run(units: [], boxes: [])
        var accumulatedTile: CGRect?
        var unread: [Int] = []
        for (index, (run, tile)) in zip(runs, tiles).enumerated() {
            guard !run.units.isEmpty else {
                unread.append(index)
                continue
            }
            guard let previous = accumulatedTile, !accumulated.units.isEmpty else {
                accumulated = run; accumulatedTile = tile; continue
            }
            accumulated = join(accumulated, run, overlap: max(tile.minX, previous.minX)...max(tile.minX, previous.maxX), advance: advance)
            accumulatedTile = previous.union(tile)
        }
        accumulated.unreadTiles = unread
        return accumulated
    }

    /// `left` then `right`, which overlap on `overlap` (x, full resolution).
    static func join(_ left: Run, _ right: Run, overlap: ClosedRange<CGFloat>, advance: CGFloat) -> Run {
        let margin = 2 * advance
        let leftStart = left.boxes.firstIndex { $0.midX >= overlap.lowerBound - margin } ?? left.units.count
        let rightEnd = (right.boxes.lastIndex { $0.midX <= overlap.upperBound + margin } ?? -1) + 1
        if let seam = longestCommonRun(Array(left.units[leftStart...]), Array(right.units[..<rightEnd])), seam.length >= minimumSeam {
            var cut = seam.length / 2
            // Never split a surrogate pair.
            while cut < seam.length, UTF16.isTrailSurrogate(left.units[leftStart + seam.left + cut]) { cut += 1 }
            let leftEnd = leftStart + seam.left + cut
            let rightBegin = seam.right + cut
            return Run(units: Array(left.units[..<leftEnd]) + Array(right.units[rightBegin...]),
                       boxes: Array(left.boxes[..<leftEnd]) + Array(right.boxes[rightBegin...]))
        }
        // No common run: cut at the middle of the overlap by position.
        let middle = (overlap.lowerBound + overlap.upperBound) / 2
        var leftEnd = left.boxes.firstIndex { $0.midX >= middle } ?? left.units.count
        var rightBegin = right.boxes.firstIndex { $0.midX >= middle } ?? right.units.count
        while leftEnd < left.units.count, UTF16.isTrailSurrogate(left.units[leftEnd]) { leftEnd += 1 }
        while rightBegin < right.units.count, UTF16.isTrailSurrogate(right.units[rightBegin]) { rightBegin += 1 }
        return Run(units: Array(left.units[..<leftEnd]) + Array(right.units[rightBegin...]),
                   boxes: Array(left.boxes[..<leftEnd]) + Array(right.boxes[rightBegin...]))
    }

    /// The longest common contiguous run of `a` and `b` (offsets into each); the earliest in `a` on ties. Nil when none.
    static func longestCommonRun(_ a: [UTF16.CodeUnit], _ b: [UTF16.CodeUnit]) -> (left: Int, right: Int, length: Int)? {
        guard !a.isEmpty, !b.isEmpty else { return nil }
        var best: (left: Int, right: Int, length: Int)?
        var previous = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            var current = [Int](repeating: 0, count: b.count + 1)
            for j in 1...b.count where a[i - 1] == b[j - 1] {
                current[j] = previous[j - 1] + 1
                if current[j] > (best?.length ?? 0) { best = (i - current[j], j - current[j], current[j]) }
            }
            previous = current
        }
        return best
    }

    /// The stitched band as one line: `index` is a placeholder the caller renumbers; the rect spans the units' boxes.
    public static func line(_ run: Run, index: Int) -> OCRLine? {
        let text = run.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let rect = run.boxes.reduce(CGRect.null) { $0.union($1) }
        guard !rect.isNull else { return nil }
        return OCRLine(index: index, text: text, rect: rect, candidate: CharacterBoxes(boxes: run.boxes))
    }
}
