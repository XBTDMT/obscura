// Reading order for OCR lines (ARCHITECTURE.md §4 row 7).
import Foundation
import CoreGraphics

public enum LineOrdering {
    /// Top-to-bottom, then left-to-right. Lines whose vertical centers differ by at most half a line height
    /// (half the mean height of the two lines compared) share a row and are ordered by `minX`.
    /// Rows are formed by a single pass over the lines sorted by `midY`, so the result is total and deterministic
    /// (a tolerance comparator alone is not transitive). `index` is reassigned to the position in the result.
    public static func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        let byY = lines.sorted { a, b in
            if a.rect.midY != b.rect.midY { return a.rect.midY < b.rect.midY }
            if a.rect.minX != b.rect.minX { return a.rect.minX < b.rect.minX }
            return a.index < b.index
        }
        var rows: [[OCRLine]] = []
        var anchor: OCRLine?
        for line in byY {
            if let current = anchor, sameRow(current, line) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
                anchor = line
            }
        }
        var ordered: [OCRLine] = []
        ordered.reserveCapacity(lines.count)
        for row in rows {
            for line in row.sorted(by: { a, b in a.rect.minX != b.rect.minX ? a.rect.minX < b.rect.minX : a.index < b.index }) {
                var copy = line
                copy.index = ordered.count
                ordered.append(copy)
            }
        }
        return ordered
    }

    static func sameRow(_ a: OCRLine, _ b: OCRLine) -> Bool {
        let tolerance = 0.5 * (a.rect.height + b.rect.height) / 2
        return abs(a.rect.midY - b.rect.midY) <= tolerance
    }
}
