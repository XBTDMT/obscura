// Glyph-box providers that are not Vision's own: per-unit boxes for a stitched re-read, and a coordinate transform for
// observations made on a re-read sheet (G-12 route A/B). Pure value types; no Vision import.
public import Foundation
import CoreGraphics

/// One box per UTF-16 unit of a line's text (full resolution). Answers a range with the union of its units' boxes.
/// Spaces carry the gap between their neighbours, so a range that spans words is one continuous box.
public struct CharacterBoxes: GlyphBoxProvider {
    public let boxes: [CGRect]

    public init(boxes: [CGRect]) { self.boxes = boxes }

    public var isCharacterExact: Bool { true }

    public func boundingBox(forUTF16Range range: NSRange) -> CGRect? {
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= boxes.count else { return nil }
        var union = CGRect.null
        for box in boxes[range.location..<NSMaxRange(range)] where !box.isNull {
            union = union.union(box)
        }
        return union.isNull ? nil : union
    }
}

/// A provider whose boxes live in another coordinate space (a strip on a re-read sheet): `full = origin + (p − sheetOrigin) / scale`.
struct TransformedGlyphBoxes: GlyphBoxProvider {
    let base: any GlyphBoxProvider
    let sheetOrigin: CGPoint
    let origin: CGPoint
    let scale: CGFloat

    var isCharacterExact: Bool { base.isCharacterExact }

    func boundingBox(forUTF16Range range: NSRange) -> CGRect? {
        base.boundingBox(forUTF16Range: range).map(apply)
    }

    func apply(_ rect: CGRect) -> CGRect {
        CGRect(x: origin.x + (rect.minX - sheetOrigin.x) / scale, y: origin.y + (rect.minY - sheetOrigin.y) / scale,
               width: rect.width / scale, height: rect.height / scale)
    }
}

enum UnitBoxes {
    /// One box per UTF-16 unit of `line.text`. Each whitespace-separated word takes the provider's box for it (Vision
    /// answers words) or, failing that, its proportional share of the line rect; the word's units split that box evenly.
    /// A whitespace unit spans the gap between the boxes around it.
    static func of(_ line: OCRLine) -> [CGRect] {
        let units = Array(line.text.utf16)
        let count = units.count
        guard count > 0 else { return [] }
        if let candidate = line.candidate, candidate.isCharacterExact {
            return (0..<count).map { candidate.boundingBox(forUTF16Range: NSRange(location: $0, length: 1)) ?? .null }
        }
        var boxes = [CGRect](repeating: .null, count: count)
        var start = 0
        while start < count {
            if isSpace(units[start]) { start += 1; continue }
            var stop = start
            while stop < count, !isSpace(units[stop]) { stop += 1 }
            let word = NSRange(location: start, length: stop - start)
            var box = BoxMapper.proportionalRect(word, textLength: count, lineRect: line.rect)
            if let candidate = line.candidate, let vision = candidate.boundingBox(forUTF16Range: word), BoxMapper.accepts(vision, lineRect: line.rect) {
                box = CGRect(x: vision.minX, y: line.rect.minY, width: vision.width, height: line.rect.height)
            }
            let unit = box.width / CGFloat(word.length)
            for i in 0..<word.length {
                boxes[start + i] = CGRect(x: box.minX + unit * CGFloat(i), y: box.minY, width: unit, height: box.height)
            }
            start = stop
        }
        // Whitespace: from the previous box's end to the next box's start (or a zero-width box at an edge).
        for i in 0..<count where boxes[i].isNull {
            let left = boxes[..<i].last(where: { !$0.isNull })
            let right = boxes[(i + 1)...].first(where: { !$0.isNull })
            let minX = left?.maxX ?? right?.minX ?? line.rect.minX
            let maxX = max(minX, right?.minX ?? left?.maxX ?? line.rect.minX)
            boxes[i] = CGRect(x: minX, y: line.rect.minY, width: maxX - minX, height: line.rect.height)
        }
        return boxes
    }

    static func isSpace(_ unit: UTF16.CodeUnit) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
