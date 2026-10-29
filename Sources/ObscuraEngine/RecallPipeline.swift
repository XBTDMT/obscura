// ObscuraEngine — the one read → detect → place path every caller uses (ShieldEngine.scan, `obscura redact`, and the
// image suite `obscura fixtures verify --images`), so the suite measures exactly what ships. G-12 (routes A–D).
public import CoreGraphics
public import Foundation
public import ObscuraDetect
public import ObscuraOCR
public import ObscuraRender

/// One finding placed on the image.
public struct DetectedArea: Sendable {
    public let rect: CGRect
    public let textHeight: CGFloat
    public let lineIndex: Int
    public let detectorIDs: [String]
    public let category: String
    public let label: String
    public let id: UUID
    /// G-22: the area sits on a line whose reading stayed short of its ink, so it was covered conservatively, from the
    /// finding's start to the end of the line's ink, and may be wider than the secret. For the Journal and reports.
    public var conservative: Bool = false
    /// Fail-open #20: the vendor's prefix and shape were read but its format check (checksum, JWT header) failed, as a
    /// misread does: covered at lower confidence. True only when every finding merged into the area is unverified.
    public var unverified: Bool = false

    public var placed: PlacedFinding { PlacedFinding(rect: rect, textHeight: textHeight, label: label, id: id) }
}

public struct ImageDetection: Sendable {
    public let reading: RecallReading
    /// The lines the detection read, in reading order, with every re-read in place of the lines it replaces.
    public let lines: [OCRLine]
    /// Findings the Scanner reported (both readings), before placement, plus the values covered only by the G-22
    /// short-read rule (`RecallPipeline.shortReadAreas`).
    public let findingCount: Int
    /// Placed findings; a re-read's finding and a first-pass finding it overlaps on the same text row are one area
    /// (that row's height, the horizontal union of both). Areas on different rows are never merged.
    public let areas: [DetectedArea]
    /// Lines the Scanner could not search to the end (too long, or over the regex budget: security scan F9/F14/F23),
    /// over both readings. What was found on them is in `areas`; the picture is not called checked.
    public var uncheckedLines: Int = 0

    /// Every line of every reading was searched to the end.
    public var isComplete: Bool { uncheckedLines == 0 }

    /// Re-read bands still short of their ink after the bounded retries (G-22); their findings are covered to the end of
    /// the line's ink.
    public var shortReads: Int { reading.stats.shortBands }
    /// Areas covered conservatively because their line's reading was short (G-22).
    public var conservativeAreas: Int { areas.filter(\.conservative).count }
    /// Areas covered at lower confidence: a vendor-shaped token whose format check failed on the read text (#20).
    public var unverifiedAreas: Int { areas.filter(\.unverified).count }
}

public enum RecallPipeline {
    /// Pass 1 plus the G-12 re-reads, as one queue turn under `options.timeout`. The label trigger runs `scanner` on the
    /// pass-1 text and asks `LabelTrust` which labelled values no vendor detector recognized. Every scan here reads OCR
    /// text, so the scanner runs as `.recognized` (fail-open #20).
    public static func read(_ image: CGImage, options: OCROptions, queue: OCRQueue, priority: OCRPriority,
                            scanner: ObscuraDetect.Scanner, tuning: RecallTuning = RecallTuning()) async throws -> RecallReading {
        let scanner = scanner.reading(.recognized)
        return try await queue.withTurn(priority: priority, timeout: options.timeout) { recognizer in
            try await RecallReader.read(image, options: options, recognizer: recognizer, tuning: tuning) { lines in
                let scanLines = lines.map { ScanLine(index: $0.index, text: $0.text) }
                return LabelTrust.unrecognizedLabelLines(scanLines, findings: scanner.scan(scanLines))
            }
        }
    }

    /// Scans the first reading and, when there are re-reads, the reading with them in place; places both and merges
    /// areas that are one finding on one text row (`merge`), so nothing either reading found is lost. With `image`,
    /// every line that carries a finding has its row's ink measured (`InkCells`) and covers snap to it.
    public static func detect(_ reading: RecallReading, image: CGImage? = nil, scanner: ObscuraDetect.Scanner, imageSize: CGSize,
                              titles: [String: String]) -> ImageDetection {
        // The lines are OCR text: a vendor-format rejection keeps the match unverified (fail-open #20).
        let scanner = scanner.reading(.recognized)
        let first = scanAndPlace(reading.lines, image: image, scanner: scanner, imageSize: imageSize, titles: titles)
        guard !reading.rereads.isEmpty else {
            return ImageDetection(reading: reading, lines: first.ordered, findingCount: first.findings, areas: first.areas,
                                  uncheckedLines: first.unchecked)
        }
        let second = scanAndPlace(reading.rereadLines, image: image, scanner: scanner, imageSize: imageSize, titles: titles)
        return ImageDetection(reading: reading, lines: second.ordered, findingCount: first.findings + second.findings,
                              areas: merge(first.areas, second.areas), uncheckedLines: first.unchecked + second.unchecked)
    }

    static func scanAndPlace(_ lines: [OCRLine], image: CGImage?, scanner: ObscuraDetect.Scanner, imageSize: CGSize,
                             titles: [String: String]) -> (ordered: [OCRLine], findings: Int, areas: [DetectedArea], unchecked: Int) {
        var ordered = LineOrdering.readingOrder(lines)
        let result = scanner.check(ordered.map { ScanLine(index: $0.index, text: $0.text) })
        let findings = result.findings
        let candidates = shortReadCandidates(findings, on: ordered, scanner: scanner)
        if let image {
            for index in Set(findings.map(\.lineIndex) + candidates.map(\.line)) where ordered.indices.contains(index) {
                ordered[index].glyphBoxes = InkCells.measure(image, line: ordered[index])
            }
        }
        var areas = place(findings, on: ordered, imageSize: imageSize, titles: titles)
        areas += shortReadAreas(candidates, on: ordered, imageSize: imageSize, titles: titles)
        return (ordered, findings.count + candidates.count, areas, result.uncheckedLines.count)
    }

    /// G-22's fail-closed rule for a line whose reading stayed short of its ink (`OCRLine.shortRead`), part 2: a short
    /// read can cut a value below its detector's minimum or break its check, so a short line is also searched for how a
    /// secret starts (`LabelTrust.shortReadCandidates`: a labelled value, or a token with a vendor prefix). Each start
    /// no finding on that line already covers becomes a candidate; `shortReadAreas` covers it to the line's ink end.
    static func shortReadCandidates(_ findings: [ObscuraDetect.Finding], on ordered: [OCRLine],
                                    scanner: ObscuraDetect.Scanner) -> [(line: Int, candidate: LabelTrust.ShortReadCandidate)] {
        var result: [(line: Int, candidate: LabelTrust.ShortReadCandidate)] = []
        for line in ordered where line.shortRead != nil {
            let covered = findings.filter { $0.lineIndex == line.index }.map { $0.wholeLine ? NSRange(location: 0, length: (line.text as NSString).length) : $0.secretRange }
            var starts = Set<Int>()
            for candidate in LabelTrust.shortReadCandidates(in: line.text, catalogue: scanner.catalogue)
            where !covered.contains(where: { NSIntersectionRange($0, candidate.range).length > 0 || NSLocationInRange(candidate.range.location, $0) })
                && starts.insert(candidate.range.location).inserted {
                result.append((line.index, candidate))
            }
        }
        return result
    }

    static func shortReadAreas(_ candidates: [(line: Int, candidate: LabelTrust.ShortReadCandidate)], on ordered: [OCRLine], imageSize: CGSize,
                               titles: [String: String]) -> [DetectedArea] {
        let bounds = CGRect(origin: .zero, size: imageSize)
        var result: [DetectedArea] = []
        for (index, candidate) in candidates where ordered.indices.contains(index) {
            let line = ordered[index]
            guard let short = line.shortRead else { continue }
            let start = BoxMapper.rect(forUTF16Range: candidate.range, in: line)
            let rect = toInkEnd(start, short: short).intersection(bounds)
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { continue }
            var area = DetectedArea(rect: rect, textHeight: line.rect.height, lineIndex: index, detectorIDs: [candidate.detectorID],
                                    category: candidate.category.rawValue, label: CoverLabels.label(for: [candidate.detectorID], titles: titles), id: UUID())
            area.conservative = true
            result.append(area)
        }
        return result
    }

    /// `rect` (a cover on a short-read line) widened right to the end of the ink that continues it (`ShortRead.inkEnd`),
    /// plus the grid cover's tenth of an advance; its left edge (the finding's start: never the key name before it),
    /// top and height are kept.
    static func toInkEnd(_ rect: CGRect, short: ShortRead) -> CGRect {
        let end = short.inkEnd(from: rect.maxX, start: rect.minX)
        guard end > rect.maxX else { return rect }
        return CGRect(x: rect.minX, y: rect.minY, width: end + 0.1 * short.advance - rect.minX, height: rect.height)
    }

    /// Finding → pixel rect. `ordered[i].index == i` after `readingOrder`. Whole-line (block) findings cover the
    /// line's ink extent; ranged findings go through BoxMapper. Rects are clipped to the image; < 1 px is dropped.
    public static func place(_ findings: [ObscuraDetect.Finding], on ordered: [OCRLine], imageSize: CGSize,
                             titles: [String: String]) -> [DetectedArea] {
        var byIndex: [Int: OCRLine] = [:]
        for line in ordered { byIndex[line.index] = line }
        let bounds = CGRect(origin: .zero, size: imageSize)
        var result: [DetectedArea] = []
        for finding in findings {
            guard let line = byIndex[finding.lineIndex] else { continue }
            var rect = finding.wholeLine ? BoxMapper.wholeLineRect(line) : BoxMapper.rect(forUTF16Range: finding.secretRange, in: line)
            // G-22, part 1: on a line whose reading stayed short of its ink, the cover runs from the finding's start to
            // the end of the line's ink (the read may have lost any of the secret's characters, and with them its end).
            if let short = line.shortRead { rect = toInkEnd(rect, short: short) }
            rect = rect.intersection(bounds)
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { continue }
            var area = DetectedArea(rect: rect, textHeight: line.rect.height, lineIndex: finding.lineIndex,
                                    detectorIDs: finding.detectorIDs, category: finding.category.rawValue,
                                    label: CoverLabels.label(for: finding.detectorIDs, titles: titles), id: finding.id)
            area.conservative = line.shortRead != nil
            area.unverified = finding.unverified
            result.append(area)
        }
        return result
    }

    /// `first` plus `second`, with every area of `second` that is the same finding as earlier areas merged into them.
    ///
    /// Two areas are the same finding only when they sit on the same text row (`sameRow`) and overlap horizontally.
    /// The second scan places every finding of the image again, not only those on re-read lines, and Vision's line boxes
    /// are taller than a tight line pitch (measured 2026-10-27 on a six-line editor shot: neighbouring lines' covers
    /// overlap by 2–6 px). So a plain overlap test, or a rect that grows while it is matched, chains one line's cover into
    /// the next until a whole block is one box over its key names. Here the match uses the second area's own rect, every
    /// merged area is on one row (the matched area with the most vertical overlap), and the merged rect keeps that row's
    /// height and top: only its horizontal extent becomes the union, so a re-read that reads a value further than pass 1
    /// still covers all of it, and a duplicate dedupes to the earlier box without growing.
    /// The merged area keeps the second area's id, label and line; detector ids are its own followed by the others'.
    static func merge(_ first: [DetectedArea], _ second: [DetectedArea]) -> [DetectedArea] {
        var result = first
        for area in second {
            let candidates = result.indices.filter { sameRow(result[$0].rect, area.rect) && horizontalOverlap(result[$0].rect, area.rect) > 0 }
            guard let anchor = candidates.max(by: { verticalOverlap(result[$0].rect, area.rect) < verticalOverlap(result[$1].rect, area.rect) })
            else {
                result.append(area)
                continue
            }
            let row = result[anchor]
            let members = candidates.filter { $0 == anchor || sameRow(result[$0].rect, row.rect) }
            var minX = area.rect.minX, maxX = area.rect.maxX
            var ids = area.detectorIDs
            for i in members {
                minX = min(minX, result[i].rect.minX)
                maxX = max(maxX, result[i].rect.maxX)
                for id in result[i].detectorIDs where !ids.contains(id) { ids.append(id) }
            }
            var merged = DetectedArea(rect: CGRect(x: minX, y: row.rect.minY, width: maxX - minX, height: row.rect.height),
                                      textHeight: row.textHeight, lineIndex: area.lineIndex, detectorIDs: ids, category: area.category,
                                      label: area.label, id: area.id)
            merged.conservative = area.conservative || members.contains { result[$0].conservative }
            merged.unverified = area.unverified && members.allSatisfy { result[$0].unverified }
            let position = members.min()!
            result = result.indices.compactMap { i in i == position ? merged : (members.contains(i) ? nil : result[i]) }
        }
        return result
    }

    /// Two covers are on one text row when their vertical overlap is at least half the shorter one's height (the rule
    /// `RereadPlanner` and `LineOrdering` use for lines).
    static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        verticalOverlap(a, b) >= 0.5 * min(a.height, b.height)
    }

    static func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        min(a.maxY, b.maxY) - max(a.minY, b.minY)
    }

    static func horizontalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        min(a.maxX, b.maxX) - max(a.minX, b.minX)
    }
}
