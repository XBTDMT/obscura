// ObscuraEngine — an uncovered key's text, read again from the original on demand (G-17, option A). Nothing here is
// stored or logged: the text exists only in the returned String, for the view that asked. The area around the
// finding's rect is enlarged on a re-read sheet exactly as the G-12 recall pass draws one, read through the same
// queue turn and recall reader (pass 1 + re-reads), and the detector catalogue runs over the lines so the text is the
// detector's `secret` part; without a detector match it is the raw text read inside the rect.
import CoreGraphics
public import Foundation
import ObscuraDetect
import ObscuraOCR

/// Why `ShieldEngine.readText(of:in:)` returned no text. No case carries recognized text.
public enum KeyTextError: Error, Sendable, Hashable {
    /// No Journal entry with this id.
    case entryNotFound(UUID)
    /// The entry has no finding with this id.
    case findingNotFound(UUID)
    /// Settings → Journal & Privacy → "Show uncovered keys as text" is off.
    case switchedOff
    /// The finding is covered; only a key left visible is shown as text.
    case covered
    /// The original is gone (expired or missing) or does not decode.
    case originalUnavailable
    /// The re-read found no text in the finding's area.
    case nothingRead
    /// The re-read did not finish within the OCR deadline (or the queue was full).
    case timedOut
    /// Vision failed.
    case readFailed
}

/// The pure half of the key-text read: where to read, and which text of the reading is the key.
enum KeyText {
    /// Left context, in glyph advances, so a labelled detector (`PASSWORD=…`) sees its label on the re-read.
    static let contextGlyphs: CGFloat = 40
    /// Right context, in glyph advances: the value's closing delimiter.
    static let trailingGlyphs: CGFloat = 2
    /// Vertical padding, in line heights, above and below: ascenders and descenders of a tightly stored rect.
    static let verticalPadding: CGFloat = 0.5
    /// Advance estimate from the line height (Menlo and SF Mono are ~0.6 em; proportional text is narrower, which only
    /// widens the context).
    static let advancePerHeight: CGFloat = 0.6

    /// The area to read around `rect` (image pixels, top-left origin), clipped to the image, and how much it is enlarged:
    /// to the recall pass's target line height, never shrunk, at most its maximum scale. Nil when nothing is left.
    static func strip(around rect: CGRect, imageSize: CGSize, tuning: RecallTuning = RecallTuning()) -> RereadStrip? {
        let height = max(rect.height, 1)
        let advance = height * advancePerHeight
        let area = CGRect(x: rect.minX - advance * contextGlyphs, y: rect.minY - height * verticalPadding,
                          width: rect.width + advance * (contextGlyphs + trailingGlyphs), height: height * (1 + 2 * verticalPadding))
            .intersection(CGRect(origin: .zero, size: imageSize)).integral
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return nil }
        let scale = min(max(tuning.targetLineHeight / height, 1), tuning.maxScale)
        return RereadStrip(band: 0, tile: area, scale: scale)
    }

    /// `rect` (image pixels) in the sheet's pixels: where the strip's tile was drawn, at its scale.
    static func onSheet(_ rect: CGRect, strip: RereadStrip, slot: CGRect) -> CGRect {
        CGRect(x: slot.minX + (rect.minX - strip.tile.minX) * strip.scale, y: slot.minY + (rect.minY - strip.tile.minY) * strip.scale,
               width: rect.width * strip.scale, height: rect.height * strip.scale)
    }

    /// What the read found: the text, and whether a detector's secret group bounded it.
    struct Pick: Sendable, Equatable {
        let text: String
        let detectorID: String?
    }

    /// The key in `reading` at `target` (sheet pixels). The detector finding whose cover overlaps the target most wins
    /// (a finding by one of `detectorIDs`, the detectors that caught it, wins a tie); the re-read reading is tried
    /// before pass 1. Without a detector finding on the target, the raw tokens read inside it.
    static func pick(_ reading: RecallReading, image: CGImage?, target: CGRect, detectorIDs: [String],
                     scanner: ObscuraDetect.Scanner) -> Pick? {
        let readings = reading.rereads.isEmpty ? [reading.lines] : [reading.rereadLines, reading.lines]
        var best: (pick: Pick, score: CGFloat)?
        var orderedReadings: [[OCRLine]] = []
        for lines in readings {
            var ordered = LineOrdering.readingOrder(lines)
            let findings = scanner.scan(ordered.map { ScanLine(index: $0.index, text: $0.text) })
            if let image {
                for index in Set(findings.map(\.lineIndex)) where ordered.indices.contains(index) {
                    ordered[index].glyphBoxes = InkCells.measure(image, line: ordered[index])
                }
            }
            orderedReadings.append(ordered)
            for finding in findings where ordered.indices.contains(finding.lineIndex) {
                let line = ordered[finding.lineIndex]
                let cover = finding.wholeLine ? BoxMapper.wholeLineRect(line) : BoxMapper.rect(forUTF16Range: finding.secretRange, in: line)
                let overlap = overlapFraction(cover, target)
                guard overlap > 0 else { continue }
                let text = substring(line.text, finding.secretRange)
                guard !text.isEmpty else { continue }
                let score = overlap + (finding.detectorIDs.contains(where: detectorIDs.contains) ? 1 : 0)
                if score > (best?.score ?? 0) { best = (Pick(text: text, detectorID: finding.detectorIDs.first), score) }
            }
        }
        if let best { return best.pick }
        for ordered in orderedReadings {
            if let raw = rawText(ordered, target: target) { return Pick(text: raw, detectorID: nil) }
        }
        return nil
    }

    /// The tokens (BoxMapper's value tokens) of the lines on the target's row whose covers are centred inside the
    /// target, joined as read from the first such token to the last on each line, lines joined by a space.
    static func rawText(_ lines: [OCRLine], target: CGRect) -> String? {
        var parts: [String] = []
        for line in lines where target.minY <= line.rect.midY && line.rect.midY <= target.maxY {
            let units = Array(line.text.utf16)
            var first: Int?, last: Int?
            var position = 0
            while position < units.count {
                guard !BoxMapper.isTokenBoundary(units[position]) else { position += 1; continue }
                var end = position
                while end < units.count, !BoxMapper.isTokenBoundary(units[end]) { end += 1 }
                let token = NSRange(location: position, length: end - position)
                let cover = BoxMapper.rect(forUTF16Range: token, in: line)
                if target.minX <= cover.midX && cover.midX <= target.maxX {
                    if first == nil { first = token.location }
                    last = end
                }
                position = end
            }
            if let first, let last, last > first {
                let text = substring(line.text, NSRange(location: first, length: last - first))
                if !text.isEmpty { parts.append(text) }
            }
        }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// How much of the smaller of the two rects lies inside the other (0…1).
    static func overlapFraction(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 ? (i.width * i.height) / smaller : 0
    }

    /// The UTF-16 range of `text`, clamped, trimmed of whitespace.
    static func substring(_ text: String, _ range: NSRange) -> String {
        let ns = text as NSString
        let location = min(max(range.location, 0), ns.length)
        let length = min(max(range.length, 0), ns.length - location)
        return ns.substring(with: NSRange(location: location, length: length)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
