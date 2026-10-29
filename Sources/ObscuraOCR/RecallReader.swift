// G-12 routes A and B, end to end: pass 1 (recognition + text regions), the caller's label trigger, the plan, one
// re-read sheet request for every band, and the stitched lines. Everything runs inside one OCR queue turn and one
// deadline. A band the re-read could not read completely (no time left, a sheet that timed out or failed, a strip with no
// text at every scale, a tile left out of the stitch) is never passed off as read (fail-open #1): `RecallReading`
// carries the plan's `completeness`, the band's lines are marked for G-22's conservative cover, and the engine lists
// the image "not checked". A band with no text at all after the re-read and its retries first gets G-32's bounded last
// attempt (the band cropped full-width at 1×, then at Vision's `.fast` level), inside the same deadline. Logs carry counts
// only.
import Foundation
public import CoreGraphics
import ObscuraSupport

/// A band's second reading: the stitched line and the pass-1 lines (positions) it reads again.
public struct Reread: Sendable {
    public let replaces: [Int]
    public let line: OCRLine
    public let reasons: Set<RereadReason>
}

/// What the recall passes cost on one image (for logs and the image suite).
public struct RecallStats: Sendable, Hashable {
    public var bands = 0
    public var strips = 0
    public var sheets = 0
    public var rereadMilliseconds = 0
    /// Strip readings tried again at another scale: the sheet returned no text for them, or (G-22) less text than the
    /// strip's ink.
    public var retriedStrips = 0
    /// Of `retriedStrips`, the ones that had text but too little for their ink (G-22).
    public var shortStrips = 0
    /// Bands still short of their ink after the bounded re-reads: their lines carry `shortRead` and are covered to the
    /// end of their ink (G-22).
    public var shortBands = 0
    /// Bands with no line at all (route B text nobody read) that the re-read could not read either: nothing to cover,
    /// and the image is "not checked" (fail-open #1).
    public var unreadBands = 0
    /// Tiles with no reading that the stitch had to join across or leave out (fail-open #22), over all bands.
    public var unreadTiles = 0
    /// Bands not completely read (fail-open #1): see `RecallReading.completeness`.
    public var incompleteBands = 0
    /// Sheet requests that threw (timed out or failed); the other sheets still ran (fail-open #1).
    public var failedSheets = 0
    /// Strip readings never drawn because the strip does not fit a sheet (`RereadSheet.fits`), over all attempts; such a
    /// strip is unread (`ReadCompleteness.Gap.oversize`) unless a smaller retry scale fits (security scan F13).
    public var oversizeStrips = 0
    /// G-32: recognition calls made by last attempts (at most two per band; see `ReadCompleteness.lastAttempts`).
    public var lastAttemptCalls = 0
    /// Every measured band's final reading against its ink, in plan order (counts only; bands without a profile absent).
    public var bandCounts: [ReadCount] = []
    /// Every strip reading the sheets returned, in order (counts only: G-22 diagnostics for the image suite).
    public var stripReads: [StripRead] = []
    /// Why a planned re-read did not run: nil when it ran or nothing was planned.
    public var skipped: String?
    public var reasons: [RereadReason: Int] = [:]
    public init() {}
}

/// One strip's reading on one attempt, as counts (G-22): observations Vision returned for it, how many were distinct
/// (not duplicate fragments), and the reading against the strip's ink (nil when the band has no ink profile).
public struct StripRead: Sendable, Hashable {
    public let attempt: Int
    public let strip: Int
    public let observations: Int
    public let distinct: Int
    public let count: ReadCount?
}

public struct RecallReading: Sendable {
    /// Pass-1 lines; `index` equals the position. Each carries the glyph boxes of its row.
    public let lines: [OCRLine]
    public let rereads: [Reread]
    public let regions: [TextRegion]
    public let stats: RecallStats
    /// How much of the planned re-read was read (fail-open #1). Complete when nothing was planned.
    public let completeness: ReadCompleteness

    public init(lines: [OCRLine], rereads: [Reread] = [], regions: [TextRegion] = [], stats: RecallStats = RecallStats(),
                completeness: ReadCompleteness = ReadCompleteness()) {
        self.lines = lines
        self.rereads = rereads
        self.regions = regions
        self.stats = stats
        self.completeness = completeness
    }

    /// The lines with every re-read band in place of the lines it replaces (re-reads of unread text are added).
    public var rereadLines: [OCRLine] {
        let replaced = Set(rereads.flatMap(\.replaces))
        var result = lines.filter { !replaced.contains($0.index) }
        for reread in rereads { result.append(reread.line) }
        for i in result.indices { result[i].index = i }
        return result
    }
}

public enum RecallReader {
    /// Reads `image` with `recognizer`, then re-reads what the plan selects. `labelLines` gets pass-1 lines (positions =
    /// indexes) and returns the positions to re-read for a secret-looking label (route A's label trigger).
    public static func read(_ image: CGImage, options: OCROptions, recognizer: any TextRecognizer, tuning: RecallTuning = RecallTuning(),
                            labelLines: @Sendable ([OCRLine]) -> Set<Int>) async throws -> RecallReading {
        let started = ContinuousClock.now
        let first = try await recognizer.read(image, options: options)
        var lines = first.lines
        for i in lines.indices { lines[i].index = i }
        lines = InkGlyphs.attach(lines, regions: first.regions)
        guard recognizer.rereadsPixels else { return RecallReading(lines: lines, regions: first.regions) }

        let imageSize = CGSize(width: image.width, height: image.height)
        let bands = RereadPlanner.plan(lines: lines, regions: first.regions, imageSize: imageSize, labelLines: labelLines(lines), tuning: tuning)
        var stats = RecallStats()
        guard !bands.isEmpty else { return RecallReading(lines: lines, regions: first.regions, stats: stats) }
        stats.bands = bands.count
        for band in bands { for reason in band.reasons { stats.reasons[reason, default: 0] += 1 } }

        let strips = bands.enumerated().flatMap { b, band in band.tiles.map { RereadStrip(band: b, tile: $0, scale: band.scale) } }
        stats.strips = strips.count

        // G-22: each band's ink, measured once from the pixels, is what its readings are judged against.
        let profiles = bands.map { band in
            InkCells.profile(image, rect: band.core, glyphs: InkGlyphs.glyphs(on: band.core, advance: band.advance, regions: first.regions))
        }
        // The band's padding can catch the edge of the line above or below; only observations centred on the band's own
        // text belong to it.
        func own(_ observations: [OCRLine], strip: Int) -> [OCRLine] {
            let core = bands[strips[strip].band].core
            return observations.filter { core.minY <= $0.rect.midY && $0.rect.midY <= core.maxY }
        }
        func count(_ observations: [OCRLine], strip: Int) -> ReadCount? {
            let band = bands[strips[strip].band]
            guard let profile = profiles[strips[strip].band] else { return nil }
            return ReadCoverage.count(TileStitcher.run(of: observations), profile: profile,
                                      span: ReadCoverage.judgedSpan(tile: strips[strip].tile, band: band.rect, advance: profile.advance))
        }

        // Fail-open #1: why each strip has no reading yet (cleared once it has one).
        var gap: [Int: ReadCompleteness.Gap] = [:]

        // One sheet request per attempt. A strip is read again at the next scale in `retryScales` when its reading has no
        // text (Vision returns nothing at all for some single lines at some sizes: measured 2026-10-27 on
        // cloud.supabase.key, read at 1×, 2×, 2.5×, nothing at 1.5×, 2.09×, 3×) or, G-22, falls short of the strip's ink
        // (`ReadCount.isShort`; measured under load: a strip that held only a 23-unit duplicate fragment of its 120 glyphs).
        // Each strip keeps its best reading: the one leaving the least ink uncovered, then the one with more units.
        // A sheet that throws marks its own strips and the other sheets still run (fail-open #1: one failure used to end
        // every attempt, so every later strip went unread); its strips are tried again at the next scale like empty ones.
        var best: [Int: [OCRLine]] = [:]
        var bestCount: [Int: ReadCount] = [:]
        func offer(_ observations: [OCRLine], strip: Int, attempt: Int) {
            let candidate = count(observations, strip: strip)
            stats.stripReads.append(StripRead(attempt: attempt, strip: strip, observations: observations.count,
                                              distinct: TileStitcher.distinct(observations).count, count: candidate))
            guard !observations.isEmpty else { return }
            if best[strip] != nil {
                guard let candidate, let held = bestCount[strip] else { return }
                guard candidate.uncovered < held.uncovered || (candidate.uncovered == held.uncovered && candidate.units > held.units) else { return }
            }
            best[strip] = observations
            bestCount[strip] = candidate
        }
        func needsReading(_ strip: Int) -> Bool {
            guard best[strip] != nil else { return true }
            return bestCount[strip]?.isShort(tuning) ?? false
        }
        var pending = Array(strips.indices)
        let rereadStarted = ContinuousClock.now
        attempts: for (attempt, factor) in ([1.0] + tuning.retryScales).enumerated() {
            guard !pending.isEmpty else { break }
            if attempt > 0 {
                stats.retriedStrips += pending.count
                stats.shortStrips += pending.filter { best[$0] != nil }.count
            }
            let scaled = pending.map { i in RereadStrip(band: strips[i].band, tile: strips[i].tile, scale: max(1, strips[i].scale * factor)) }
            let sheets = RereadSheet.layout(scaled, maxSide: tuning.sheetMaxSide)
            // A strip too large for any sheet is never drawn: unread, so its band ends "not checked" (fail closed).
            let placed = Set(sheets.flatMap { $0.slots.map(\.strip) })
            let oversize = scaled.indices.filter { !placed.contains($0) }.map { pending[$0] }
            if !oversize.isEmpty {
                stats.oversizeStrips += oversize.count
                for strip in oversize where best[strip] == nil { gap[strip] = .oversize }
                Log.ocr.notice("ocr re-read strips too large for a sheet=\(oversize.count) attempt=\(attempt); left unread")
            }
            for sheet in sheets {
                let onSheet = sheet.slots.map { pending[$0.strip] }
                let remaining = options.timeout - (ContinuousClock.now - started)
                guard remaining >= tuning.minimumRereadBudget else {
                    // No time is left for this sheet or any later one: every strip still without a reading stays so.
                    stats.skipped = "deadline"
                    let unread = pending.filter { best[$0] == nil }
                    for strip in unread { gap[strip] = .deadline }
                    Log.ocr.notice("ocr re-read stopped: deadline bands=\(bands.count) strips=\(strips.count) unread=\(unread.count)")
                    break attempts
                }
                stats.sheets += 1
                var sheetOptions = options
                sheetOptions.timeout = remaining
                sheetOptions.languages = tuning.rereadLanguages
                sheetOptions.pixelBudget = max(options.pixelBudget, Int(sheet.size.width * sheet.size.height) + 1)
                sheetOptions.maxLongestSide = max(options.maxLongestSide, Int(max(sheet.size.width, sheet.size.height)) + 1)
                do {
                    let rendered = try RereadSheet.render(image, layout: sheet, strips: scaled)
                    let observations = try await recognizer.recognize(rendered, options: sheetOptions)
                    let mapped = RereadSheet.mapBack(observations, layout: sheet, strips: scaled)
                    for slot in sheet.slots {
                        let strip = pending[slot.strip]
                        offer(own(mapped[slot.strip] ?? [], strip: strip), strip: strip, attempt: attempt)
                        gap[strip] = best[strip] == nil ? .empty : nil
                    }
                } catch OCRError.cancelled {
                    throw OCRError.cancelled
                } catch is CancellationError {
                    throw OCRError.cancelled
                } catch {
                    let cause: ReadCompleteness.Gap
                    if case .timeout? = error as? OCRError { cause = .timeout } else { cause = .failed }
                    stats.skipped = cause.rawValue
                    stats.failedSheets += 1
                    for strip in onSheet where best[strip] == nil { gap[strip] = cause }
                    Log.ocr.notice("ocr re-read sheet \(cause.rawValue, privacy: .public) strips=\(onSheet.count) attempt=\(attempt); the other sheets go on")
                    continue
                }
            }
            pending = pending.filter(needsReading)
        }

        // G-32: a band no re-read could read gets one bounded last attempt before it is left unread. The band is cropped
        // at the image's full width, scale 1 (measured on network.ip.v4: a row the tiles read as nothing at seven scales
        // read whole this way), and read with the accurate level in pass 1's languages (G-31); only if that reads
        // nothing, the same crop at Vision's `.fast` level, which reads text the accurate model drops. At most these two
        // calls, each only while the image's deadline leaves `minimumRereadBudget`, with the time left as its timeout:
        // never a longer one. Returns the band's observations (image coordinates, its own text only) when one read text.
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        func lastAttempt(band b: Int) async throws -> (observations: [OCRLine], record: ReadCompleteness.LastAttempt) {
            let band = bands[b]
            let crop = CGRect(x: 0, y: band.rect.minY, width: bounds.width, height: band.rect.height).integral.intersection(bounds)
            var calls = 0
            var answered = 0
            var skipped = false
            for reader in ReadCompleteness.LastReader.allCases {
                let remaining = options.timeout - (ContinuousClock.now - started)
                guard remaining >= tuning.minimumRereadBudget else {
                    skipped = true
                    Log.ocr.notice("reread last attempt: band \(b) \(reader.rawValue, privacy: .public) skipped, deadline")
                    break
                }
                guard !crop.isNull, crop.width >= 1, crop.height >= 1, let cropped = image.cropping(to: crop) else { break }
                // Read at full size, so never larger than a sheet may be (security scan F13): a band that tall stays unread.
                guard crop.width * crop.height <= CGFloat(tuning.sheetMaxPixels) else {
                    Log.ocr.notice("reread last attempt: band \(b) too large to read at full size; left unread")
                    break
                }
                calls += 1
                var lastOptions = options
                lastOptions.level = reader == .fast ? .fast : .accurate
                lastOptions.timeout = remaining
                // Scale 1: never downscaled.
                lastOptions.pixelBudget = max(options.pixelBudget, Int(crop.width * crop.height) + 1)
                lastOptions.maxLongestSide = max(options.maxLongestSide, Int(max(crop.width, crop.height)) + 1)
                do {
                    let observations = try await recognizer.recognize(cropped, options: lastOptions)
                    answered += 1
                    let slot = SheetLayout.Slot(strip: 0, rect: CGRect(origin: .zero, size: crop.size))
                    let mapped = RereadSheet.mapBack(observations, layout: SheetLayout(size: crop.size, slots: [slot]),
                                                     strips: [RereadStrip(band: b, tile: crop, scale: 1)])[0] ?? []
                    // Only the band's own text: centred on its rows, and touching its span (the crop's width reaches
                    // text pass 1 already read elsewhere on the row).
                    let own = mapped.filter { band.core.minY <= $0.rect.midY && $0.rect.midY <= band.core.maxY
                        && $0.rect.maxX > band.rect.minX && $0.rect.minX < band.rect.maxX }
                    if TileStitcher.line(TileStitcher.run(of: own), index: 0) != nil {
                        Log.ocr.notice("reread last attempt: band \(b) read by \(reader.rawValue, privacy: .public) observations=\(own.count) calls=\(calls)")
                        return (own, ReadCompleteness.LastAttempt(band: b, calls: calls, readBy: reader, skippedForDeadline: false, answered: answered))
                    }
                } catch OCRError.cancelled {
                    throw OCRError.cancelled
                } catch is CancellationError {
                    throw OCRError.cancelled
                } catch {
                    let cause = (error as? OCRError).map { if case .timeout = $0 { "timeout" } else { "failed" } } ?? "failed"
                    Log.ocr.notice("reread last attempt: band \(b) \(reader.rawValue, privacy: .public) \(cause, privacy: .public)")
                }
            }
            Log.ocr.notice("reread last attempt: band \(b) still unread calls=\(calls) skipped=\(skipped)")
            return ([], ReadCompleteness.LastAttempt(band: b, calls: calls, readBy: nil, skippedForDeadline: skipped, answered: answered))
        }

        var rereads: [Reread] = []
        var completeness = ReadCompleteness()
        var stripIndex = 0
        for (b, band) in bands.enumerated() {
            completeness.plan(band.reasons)
            let range = stripIndex..<(stripIndex + band.tiles.count)
            stripIndex += band.tiles.count
            let runs = range.map { TileStitcher.run(of: best[$0] ?? []) }
            var stitched = TileStitcher.stitch(runs, tiles: band.tiles, advance: band.advance)
            var unreadStrips = range.filter { best[$0] == nil }
            // G-32: no text for the band at all (every strip unread, or read as blank): the bounded last attempt. What it
            // reads is the band's reading, judged against the band's ink like any other (G-22).
            var lastReader: ReadCompleteness.LastReader?
            if TileStitcher.line(stitched, index: 0) == nil {
                let (observations, record) = try await lastAttempt(band: b)
                completeness.lastAttempts.append(record)
                stats.lastAttemptCalls += record.calls
                if let reader = record.readBy {
                    stitched = TileStitcher.run(of: observations)
                    unreadStrips = []
                    lastReader = reader
                }
            }
            if !stitched.unreadTiles.isEmpty {
                // Fail-open #22: never stitched over quietly.
                stats.unreadTiles += stitched.unreadTiles.count
                Log.ocr.notice("reread band \(b) tiles unread=\(stitched.unreadTiles.count) of \(band.tiles.count)")
            }
            // The re-read improves the text and its horizontal geometry; the row's height is pass 1's (lines and text
            // regions). A strip observation's box can include the band's padding and reach the neighbouring lines.
            stitched.boxes = stitched.boxes.map { $0.isNull ? $0 : CGRect(x: $0.minX, y: band.core.minY, width: $0.width, height: band.core.height) }
            let line = TileStitcher.line(stitched, index: lines.count + rereads.count)

            // The band's final reading (the stitched re-read, else the pass-1 lines it would have replaced) against the
            // band's ink.
            let judged = line != nil ? stitched : TileStitcher.run(of: band.replaces.map { lines[$0] })
            let read = profiles[b].map { ReadCoverage.count(judged, profile: $0, span: -CGFloat.infinity...CGFloat.infinity) }
            if let read { stats.bandCounts.append(read) }
            let hasLines = line != nil || !band.replaces.isEmpty

            // Fail-open #1 (and #22): a band with a strip that has no reading, or whose strips stitched to no text, was
            // not read. Its lines are covered as G-22 covers a short band, from each finding, labelled value or vendor
            // prefix to the end of the band's ink (its text's end when the ink could not be measured), and the band is
            // reported so the engine ends the image "not checked". A route-B band (text nobody read) has no line to
            // cover: only that verdict protects it.
            var short: ShortRead?
            if !unreadStrips.isEmpty || line == nil {
                let gaps = unreadStrips.isEmpty ? [ReadCompleteness.Gap.empty] : Set(unreadStrips.map { gap[$0] ?? .empty })
                completeness.incomplete.append(ReadCompleteness.Band(band: b, reasons: band.reasons, strips: range.count,
                                                                     readStrips: range.count - unreadStrips.count, gaps: gaps,
                                                                     hasLines: hasLines, rect: band.rect, core: band.core,
                                                                     lineHeight: band.lineHeight))
                stats.incompleteBands += 1
                if hasLines {
                    short = ShortRead(band: b, count: read ?? ReadCount(units: judged.units.count, ink: 0, uncovered: 0, isGrid: false),
                                      ink: profiles[b]?.boxes ?? [band.core], advance: profiles[b]?.advance ?? band.advance, cause: .unread)
                } else {
                    stats.unreadBands += 1
                }
                let gapNames = gaps.sorted().map(\.rawValue).joined(separator: ",")
                // A band with no lines has nothing to cover (G-40 diagnosis: the old wording said "fallback cover" for it too).
                let action = hasLines ? "fallback cover" : "nothing to cover"
                Log.ocr.notice("reread incomplete: band \(b) strips read \(range.count - unreadStrips.count) of \(range.count) gaps=\(gapNames, privacy: .public) lines=\(hasLines), \(action, privacy: .public) and not checked")
            } else if let read, let profile = profiles[b], read.isShort(tuning) {
                // G-22, fail closed: every strip was read and the reading is still short after the retries: every line of
                // the band is marked, and the engine covers each finding on it from its start to the end of the line's ink.
                completeness.complete(band.reasons)
                short = ShortRead(band: b, count: read, ink: profile.boxes, advance: profile.advance)
                stats.shortBands += 1
                Log.ocr.notice("reread short: band \(b) units \(read.units) of ink \(read.ink) uncovered \(read.uncovered) grid=\(read.isGrid) reread=\(line != nil), fallback cover")
            } else {
                completeness.complete(band.reasons)
                if lastReader == .fast {
                    // G-32: read only by the weaker `.fast` model, whose text may be misread: what it found is covered
                    // like any finding, and its line also keeps G-22's conservative cover.
                    short = ShortRead(band: b, count: read ?? ReadCount(units: judged.units.count, ink: 0, uncovered: 0, isGrid: false),
                                      ink: profiles[b]?.boxes ?? [band.core], advance: profiles[b]?.advance ?? band.advance, cause: .fast)
                }
            }
            if let short { for position in band.replaces { lines[position].shortRead = short } }
            guard var line else { continue }
            line = InkGlyphs.attach([line], regions: first.regions)[0]
            line.shortRead = short
            rereads.append(Reread(replaces: band.replaces, line: line, reasons: band.reasons))
        }
        stats.rereadMilliseconds = Int((ContinuousClock.now - rereadStarted) / .milliseconds(1))
        Log.ocr.info("ocr re-read bands=\(bands.count) strips=\(strips.count) retried=\(stats.retriedStrips) short-strips=\(stats.shortStrips) sheets=\(stats.sheets) failed-sheets=\(stats.failedSheets) lines=\(rereads.count) short-bands=\(stats.shortBands) incomplete-bands=\(stats.incompleteBands) last-attempts=\(completeness.lastAttempts.count) last-read=\(completeness.lastAttempts.filter { $0.readBy != nil }.count) last-calls=\(stats.lastAttemptCalls) ms=\(stats.rereadMilliseconds)")
        return RecallReading(lines: lines, rereads: rereads, regions: first.regions, stats: stats, completeness: completeness)
    }
}

/// Glyph boxes from text regions, handed to the lines on their row.
public enum InkGlyphs {
    /// Each line gets the glyph boxes of the regions on its row that touch it (within one advance), sorted by x.
    public static func attach(_ lines: [OCRLine], regions: [TextRegion]) -> [OCRLine] {
        guard !regions.isEmpty else { return lines }
        return lines.map { line in
            var copy = line
            copy.glyphBoxes = glyphs(on: line.rect, advance: RereadPlanner.advance(of: line), regions: regions)
            return copy
        }
    }

    /// The glyph boxes of the regions on `rect`'s row that touch it (within `advance`), sorted by x.
    static func glyphs(on rect: CGRect, advance: CGFloat, regions: [TextRegion]) -> [CGRect] {
        regions
            .filter { RereadPlanner.sameRow($0.rect, rect) && RereadPlanner.horizontalGap($0.rect, rect) <= advance }
            .flatMap(\.glyphs)
            .filter { RereadPlanner.sameRow($0, rect) }
            .sorted { $0.minX < $1.minX }
    }
}
