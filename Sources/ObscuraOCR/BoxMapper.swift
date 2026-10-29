// Finding range → pixel rect (ARCHITECTURE.md §4 row 13).
public import Foundation
import CoreGraphics

public enum BoxMapper {
    /// Pixel rect covering `range` (UTF-16 offsets into `line.text`) on the image.
    /// 1. Widen to the value token (`widenToToken`), so a cover never cuts a value in half or spills over its key name.
    /// 2. Ask `line.candidate` for the box of the token: a character-exact provider (a stitched re-read) answers the
    ///    token itself; Vision measures words, and asked for part of a word it answers with the whole word's box
    ///    (measured live: in `KEY=value` the "word" is the entire line), so the token is placed inside the word box by
    ///    character offset. A box is accepted when its width > 1 px and it intersects the line rect inset by −4 px.
    /// 3. Otherwise estimate proportionally by UTF-16 character count across the line rect.
    /// 4. Snap to the row's glyph grid (G-12, 2026-10-27) when the line's ink boxes (`InkCells`, else text-rectangle
    ///    glyph boxes) fit a monospace grid: `GlyphGrid.cover` picks the cells from the word's own run of ink, anchored
    ///    from both of its ends and settled by how the text around the token agrees with the ink. Character offsets
    ///    inside a Vision word box drift when the read is shorter than the ink (measured: a URL read 3 characters short
    ///    put the cover one glyph past the `@`); the cells do not. On a side where the token ends at its word's edge the
    ///    snapped cells never end before the step-2 box's run of ink (`GlyphGrid.reach`, fail-open #16).
    /// 5. Pad horizontally by half a glyph width (a tenth of the advance on the grid; else box width ÷ characters; line
    ///    height × 0.25 when the range is empty), plus `padding` px on every side, then clip to the line's extent (its
    ///    rect and its ink) inset by −2 px.
    public static func rect(forUTF16Range range: NSRange, in line: OCRLine, padding: CGFloat = 0) -> CGRect {
        let text = line.text
        let widened = widenToToken(range, in: text)
        let estimate = proportionalRect(widened, textLength: (text as NSString).length, lineRect: line.rect)

        var chosen = estimate
        let word = widenToWord(widened, in: text)
        if let candidate = line.candidate {
            if candidate.isCharacterExact, widened.length > 0, let box = candidate.boundingBox(forUTF16Range: widened),
               accepts(box, lineRect: line.rect) {
                chosen = CGRect(x: box.minX, y: line.rect.minY, width: box.width, height: line.rect.height)
            } else if let box = candidate.boundingBox(forUTF16Range: word), accepts(box, lineRect: line.rect) {
                chosen = place(widened, inWord: word, wordBox: box)
            }
        }

        var glyphWidth: CGFloat = widened.length > 0 ? chosen.width / CGFloat(widened.length) : line.rect.height * 0.25
        // Half a glyph of slack where the edges are estimates; on the grid the edges are cell boundaries, so a tenth of
        // an advance is enough and the cover stops short of a neighbour that is not a delimiter (measured: the wide `/`
        // before a Sentry DSN key lost half its ink to a half-glyph pad). The renderer adds its own 0.14 × text height.
        var slack: CGFloat = 0.5
        if widened.length > 0, let grid = GlyphGrid.fit(line.glyphBoxes, lineHeight: line.rect.height) {
            let near = grid.cell(nearest: chosen.minX + glyphWidth / 2)
            // Fail-open #16: the cells are counted from the characters the read returned, so a read that dropped more
            // than `cover` can reconcile ends them inside the token's ink, while the pre-snap box (the word's own box)
            // reaches its end. On an open side the cover never ends before the pre-snap box's run of ink.
            let cells = grid.reach(grid.cover(Array(text.utf16), token: widened, word: word, near: near), toward: chosen,
                                   openLeft: widened.location == word.location, openRight: NSMaxRange(widened) == NSMaxRange(word))
            chosen = CGRect(x: grid.left(of: cells.lowerBound), y: chosen.minY,
                            width: grid.advance * CGFloat(cells.count), height: chosen.height)
            glyphWidth = grid.advance
            slack = 0.1
        }

        let extent = lineExtent(line).insetBy(dx: -2, dy: -2)
        let padded = chosen.insetBy(dx: -(glyphWidth * slack + padding), dy: -padding)
        let clipped = padded.intersection(extent)
        if clipped.isNull || clipped.isEmpty {
            return estimate.insetBy(dx: -(glyphWidth * 0.5 + padding), dy: -padding).intersection(extent)
        }
        return clipped
    }

    /// The cover for a whole-line (block-scope) finding: the line's rect grown over the ink glyphs that continue it on
    /// its row (Vision's line box ends where it stopped reading: measured on a PEM armor line, the dashes it dropped
    /// were left outside the box).
    public static func wholeLineRect(_ line: OCRLine) -> CGRect {
        lineExtent(line)
    }

    /// The line rect, widened left and right over the row's ink glyphs that chain onto it (gaps under two advances).
    static func lineExtent(_ line: OCRLine) -> CGRect {
        guard !line.glyphBoxes.isEmpty else { return line.rect }
        let reach = 2 * max(line.rect.height * 0.6, 1)
        var minX = line.rect.minX, maxX = line.rect.maxX
        for glyph in line.glyphBoxes.sorted(by: { $0.maxX > $1.maxX }) where glyph.maxX < minX + reach && glyph.minX < minX {
            if glyph.maxX >= minX - reach { minX = min(minX, glyph.minX) }
        }
        for glyph in line.glyphBoxes.sorted(by: { $0.minX < $1.minX }) where glyph.minX > maxX - reach && glyph.maxX > maxX {
            if glyph.minX <= maxX + reach { maxX = max(maxX, glyph.maxX) }
        }
        return CGRect(x: minX, y: line.rect.minY, width: maxX - minX, height: line.rect.height)
    }

    /// The part of `wordBox` that `token` occupies, by character offset within `word`.
    static func place(_ token: NSRange, inWord word: NSRange, wordBox: CGRect) -> CGRect {
        guard word.length > 0, token.length < word.length else { return wordBox }
        let unit = wordBox.width / CGFloat(word.length)
        return CGRect(x: wordBox.minX + unit * CGFloat(token.location - word.location), y: wordBox.minY,
                      width: unit * CGFloat(token.length), height: wordBox.height)
    }

    /// Extends `range` to whitespace on both sides: the word Vision measures.
    static func widenToWord(_ range: NSRange, in text: String) -> NSRange {
        let units = Array(text.utf16)
        let count = units.count
        guard count > 0 else { return NSRange(location: 0, length: 0) }
        let location = min(max(range.location, 0), count)
        let end = min(max(location + max(range.length, 0), location), count)
        var start = location
        while start > 0, !isSpace(units[start - 1]) { start -= 1 }
        var stop = end
        while stop < count, !isSpace(units[stop]) { stop += 1 }
        return NSRange(location: start, length: stop - start)
    }

    private static func isSpace(_ unit: UTF16.CodeUnit) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Vision box acceptance: wide enough to be real geometry and on this line.
    static func accepts(_ box: CGRect, lineRect: CGRect) -> Bool {
        box.width > 1 && box.intersects(lineRect.insetBy(dx: -4, dy: -4))
    }

    /// Character-count estimate across the full line rect, full line height.
    static func proportionalRect(_ range: NSRange, textLength: Int, lineRect: CGRect) -> CGRect {
        let denominator = CGFloat(max(textLength, 1))
        let x = lineRect.minX + lineRect.width * CGFloat(range.location) / denominator
        let width = lineRect.width * CGFloat(range.length) / denominator
        return CGRect(x: x, y: lineRect.minY, width: width, height: lineRect.height)
    }

    /// Extends `range` backwards and forwards to the nearest boundary (or the text's ends): whitespace, or a character
    /// that frames a value without being part of it (`=` `:` `,` `;` `@` quotes, brackets). So `KEY=value` widens to `value`,
    /// never over the key name; characters inside the match itself are never boundaries, since widening only grows outward.
    /// Offsets are UTF-16; the range is clamped to the text first. An empty text yields `{0, 0}`.
    public static func widenToToken(_ range: NSRange, in text: String) -> NSRange {
        let units = Array(text.utf16)
        let count = units.count
        guard count > 0 else { return NSRange(location: 0, length: 0) }
        let location = min(max(range.location, 0), count)
        let end = min(max(location + max(range.length, 0), location), count)

        var start = location
        while start > 0, !isBoundary(units[start - 1]), !endsSchemeSeparator(units, at: start) { start -= 1 }
        var stop = end
        while stop < count, !isBoundary(units[stop]) { stop += 1 }
        // A side whose extension holds no ASCII at all is OCR noise standing in for a delimiter (measured: the closing
        // `",` of a JSON value read `¿‚`), not part of a value: secret formats are ASCII. Keep that side at the match.
        if start < location, !units[start..<location].contains(where: { $0 < 0x80 }) { start = location }
        if stop > end, !units[end..<stop].contains(where: { $0 < 0x80 }) { stop = end }
        return NSRange(location: start, length: stop - start)
    }

    /// Includes the curly quotes the Scanner folds to `"` and `'` (ConfusableFold): OCR reads a closing `",` as `”‚`
    /// often enough (measured on network.ip.v6), and a cover must stop at it as it stops at `"`.
    private static let framing: Set<UTF16.CodeUnit> = Set("=:,;@\"'`()[]{}<>\u{201C}\u{201D}\u{201E}\u{2018}\u{2019}\u{201A}".utf16)

    /// True when `units[..<end]` ends with `://`: a URL scheme separator is syntax, never part of a value, so widening
    /// backwards stops after it (measured: a Sentry DSN key widened over `//` and its cover took `://` with it).
    static func endsSchemeSeparator(_ units: [UTF16.CodeUnit], at end: Int) -> Bool {
        end >= 3 && units[end - 1] == 0x2F && units[end - 2] == 0x2F && units[end - 3] == 0x3A
    }

    /// True when `unit` ends a value token: whitespace or a framing character (`widenToToken`'s boundaries).
    public static func isTokenBoundary(_ unit: UTF16.CodeUnit) -> Bool { isBoundary(unit) }

    private static func isBoundary(_ unit: UTF16.CodeUnit) -> Bool {
        if framing.contains(unit) { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }   // surrogate halves are never boundaries
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

/// A monospace grid fitted to a row's ink glyph boxes: cell k's centre is `origin + k × advance`; `ink` is the widest
/// glyph found in each occupied cell, `middle` the cells whose ink crosses the row's middle (every letter and digit
/// does; `"` `'` sit above it and `,` `.` `_` below).
public struct GlyphGrid: Sendable, Equatable {
    public let origin: CGFloat
    public let advance: CGFloat
    public let ink: [Int: CGFloat]
    public let middle: Set<Int>

    public init(origin: CGFloat, advance: CGFloat, ink: [Int: CGFloat] = [:], middle: Set<Int>? = nil) {
        self.origin = origin
        self.advance = advance
        self.ink = ink
        self.middle = middle ?? Set(ink.keys)
    }

    /// The grid, when `glyphs` (one row) fit one: at least 8 glyphs, the advance between 0.3 and 1.0 line heights, and
    /// at least 90 % of the centres within a quarter advance of their cell. Glyphs the detector missed or merged leave
    /// empty cells and do not disturb the fit. Proportional text does not fit and returns nil.
    public static func fit(_ glyphs: [CGRect], lineHeight: CGFloat) -> GlyphGrid? {
        let centers = glyphs.map(\.midX).sorted()
        guard centers.count >= 8, lineHeight > 0 else { return nil }
        let steps = zip(centers.dropFirst(), centers).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        guard !steps.isEmpty else { return nil }
        // Neighbouring glyphs one cell apart give the first advance; cells are then counted step by step (each gap is
        // a small whole number of cells), so a slightly wrong advance never accumulates over a long row.
        let median = steps[steps.count / 2]
        let single = steps.filter { $0 >= 0.75 * median && $0 <= 1.25 * median }
        var advance = single.isEmpty ? median : single.reduce(0, +) / CGFloat(single.count)
        var origin = centers[0]
        for _ in 0..<3 {
            guard advance > 0 else { return nil }
            var cells: [CGFloat] = [0]
            for (previous, x) in zip(centers, centers.dropFirst()) {
                cells.append(cells[cells.count - 1] + max(0, ((x - previous) / advance).rounded()))
            }
            let n = CGFloat(centers.count)
            let meanCell = cells.reduce(0, +) / n, meanX = centers.reduce(0, +) / n
            let variance = cells.reduce(0) { $0 + ($1 - meanCell) * ($1 - meanCell) }
            guard variance > 0 else { return nil }
            advance = zip(cells, centers).reduce(0) { $0 + ($1.0 - meanCell) * ($1.1 - meanX) } / variance
            origin = meanX - advance * meanCell
        }
        guard advance >= 0.3 * lineHeight, advance <= 1.0 * lineHeight else { return nil }
        let fitting = centers.filter { x in
            let cell = ((x - origin) / advance).rounded()
            return abs(x - (origin + cell * advance)) <= 0.25 * advance
        }.count
        guard CGFloat(fitting) >= 0.9 * CGFloat(centers.count) else { return nil }
        var ink: [Int: CGFloat] = [:]
        var middle = Set<Int>()
        // The row's middle: the median of the glyphs' vertical centres (letters and digits dominate any row).
        let mids = glyphs.map(\.midY).sorted()
        let row = mids[mids.count / 2]
        for glyph in glyphs {
            let cell = Int(((glyph.midX - origin) / advance).rounded())
            ink[cell] = max(ink[cell] ?? 0, glyph.width)
            if glyph.minY <= row, glyph.maxY >= row { middle.insert(cell) }
        }
        return GlyphGrid(origin: origin, advance: advance, ink: ink, middle: middle)
    }

    public func cell(nearest x: CGFloat) -> Int { Int(((x - origin) / advance).rounded()) }

    /// The left edge of `cell`.
    public func left(of cell: Int) -> CGFloat { origin + CGFloat(cell) * advance - advance / 2 }

    /// How far a token may be moved from its estimated cell: drift inside a Vision word box measured up to a glyph and
    /// a half; three cells covers it with margin.
    public static let alignmentReach = 3

    /// The cell where `token` (UTF-16 range of `text`) starts: of the cells within `alignmentReach` of `near`, the one
    /// where the text around the token best matches the row's ink. Spaces want an empty cell, thin punctuation
    /// (`. , : ; ! | '`) a narrow glyph or none, other characters a glyph; four characters either side of the token
    /// take part, so the delimiters around a value (`": "`, `:`, `@`, `.`) pin it. Ties go to the cell nearest `near`.
    public func align(_ text: [UTF16.CodeUnit], token: NSRange, near: Int) -> Int {
        let context = 4
        let from = max(0, token.location - context), to = min(text.count, NSMaxRange(token) + context)
        guard from < to else { return near }
        var best = near, bestScore = Int.min
        for shift in [0, -1, 1, -2, 2, -3, 3].prefix(2 * Self.alignmentReach + 1) {
            let start = near + shift
            var score = 0
            for i in from..<to {
                score += agreement(text[i], cell: start + (i - token.location))
            }
            if score > bestScore { bestScore = score; best = start }
        }
        return best
    }

    /// The cells a cover takes for `token` (inside the whitespace-separated `word` of `text`), estimated to start
    /// at cell `near`.
    /// The word's ink is one unbroken run of inked cells between empty ones (a space is an empty cell). When the run is
    /// within a few cells of the word's length, the token is anchored inside it from both ends: from the word's start
    /// (its offset in the word) and from its end (the characters after it). The two agree unless the read dropped or
    /// added characters; then the text around each edge (`agreement`) picks the anchor that matches the ink, and a tie
    /// takes the wider cover (a dropped glyph inside the token stays covered: measured on scm.rubygems.key).
    /// Without such a run the token is aligned by its text alone (`align`).
    public func cover(_ text: [UTF16.CodeUnit], token: NSRange, word: NSRange, near: Int) -> ClosedRange<Int> {
        let n = max(token.length, 1)
        let offset = token.location - word.location, trailing = NSMaxRange(word) - NSMaxRange(token)
        if let run = wordRun(near: near - offset, length: word.length) {
            let startLeft = run.lowerBound + offset, startRight = run.upperBound + 1 - trailing - n
            let endLeft = startLeft + n - 1, endRight = run.upperBound - trailing
            let start = pick(startLeft, startRight, text: text, anchor: token.location, before: true, preferLower: true)
            let end = pick(endLeft, endRight, text: text, anchor: NSMaxRange(token) - 1, before: false, preferLower: false)
            if start <= end { return start...end }
        }
        let start = align(text, token: token, near: near)
        return start...(start + n - 1)
    }

    /// `cells` grown on each open side over the inked cells that continue it, while their centres lie inside `box`
    /// (fail-open #16). An open side is one where the token ends at its word's edge: whitespace or the line's end, never
    /// a delimiter inside the word such as the `=` before a value, so the cells grown over are the token's own glyphs
    /// the read dropped. Growth stops at an empty cell (a space: another word), at `box`'s edge, and at ink shaped like
    /// the punctuation that frames a value (`tokenLike`): a read that dropped a value's closing `",` also makes that
    /// side look open (measured on scm.rubygems.key), and the `",` is not the token's. It never shrinks a cover.
    public func reach(_ cells: ClosedRange<Int>, toward box: CGRect, openLeft: Bool, openRight: Bool) -> ClosedRange<Int> {
        var lower = cells.lowerBound, upper = cells.upperBound
        func centre(_ cell: Int) -> CGFloat { origin + CGFloat(cell) * advance }
        if openRight {
            while ink[upper] != nil, tokenLike(upper + 1), centre(upper + 1) <= box.maxX { upper += 1 }
        }
        if openLeft {
            while ink[lower] != nil, tokenLike(lower - 1), centre(lower - 1) >= box.minX { lower -= 1 }
        }
        return lower...upper
    }

    /// Ink in `cell` shaped like a glyph of a secret token: it crosses the row's middle (every letter and digit, and
    /// `-` `/` `+` `=`), or it is low but as wide as a letter (`_`). Quotes sit above the middle and `,` `.` below it,
    /// narrow: the framing a value ends with (`agreement` reads the cells the same way).
    func tokenLike(_ cell: Int) -> Bool {
        guard let width = ink[cell] else { return false }
        return middle.contains(cell) || width >= 0.6 * advance
    }

    /// The run of inked cells (bounded by empty cells) for a word estimated to start at `near`, when its length is
    /// within max(3, 10 %) of the word's.
    /// A word is text with no space in it, so when its run of ink falls short of it by more than that, the read may
    /// have dropped a space the ink has: the run then takes in the neighbouring run across one empty cell, on the side
    /// where the word's estimated cells reach further past it, until it is long enough (measured 2026-10-27: Vision read
    /// `(212) 555-0199` in Menlo as `（212）555-0199`, 13 characters on 14 cells, and the cover lost the `(`).
    func wordRun(near: Int, length: Int) -> ClosedRange<Int>? {
        guard length > 0 else { return nil }
        let tolerance = max(3, length / 10)
        let middle = near + length / 2
        for probe in [middle, middle - 1, middle + 1, middle - 2, middle + 2] where ink[probe] != nil {
            var lower = probe, upper = probe
            while ink[lower - 1] != nil { lower -= 1 }
            while ink[upper + 1] != nil { upper += 1 }
            while length - (upper - lower + 1) > tolerance {
                let leftOpen = ink[lower - 1] == nil && ink[lower - 2] != nil
                let rightOpen = ink[upper + 1] == nil && ink[upper + 2] != nil
                let leftFirst = (lower - near) >= (near + length - 1 - upper)
                if leftOpen, leftFirst || !rightOpen {
                    lower -= 2
                    while ink[lower - 1] != nil { lower -= 1 }
                } else if rightOpen {
                    upper += 2
                    while ink[upper + 1] != nil { upper += 1 }
                } else {
                    break
                }
            }
            let count = upper - lower + 1
            guard abs(count - length) <= tolerance, abs(lower - near) <= Self.alignmentReach + tolerance else { return nil }
            return lower...upper
        }
        return nil
    }

    /// Of the cells from `a` to `b` (the two anchors and every cell between), the one where the token's edge character
    /// `text[anchor]` sits best: the four characters on each side of it agree most with the ink. A tie takes the lowest
    /// (`preferLower`, for a start: the wider cover) or the highest (for an end).
    func pick(_ a: Int, _ b: Int, text: [UTF16.CodeUnit], anchor: Int, before: Bool, preferLower: Bool) -> Int {
        guard a != b else { return a }
        func score(_ cell: Int) -> Int {
            let from = max(0, anchor - 4), to = min(text.count, anchor + 5)
            return (from..<to).reduce(0) { $0 + agreement(text[$1], cell: cell + ($1 - anchor)) }
        }
        var best = preferLower ? min(a, b) : max(a, b), bestScore = score(best)
        let order = preferLower ? Array(min(a, b)...max(a, b)) : Array((min(a, b)...max(a, b)).reversed())
        for cell in order {
            let value = score(cell)
            if value > bestScore { best = cell; bestScore = value }
        }
        return best
    }

    static let thin: Set<UTF16.CodeUnit> = Set(".,:;!|'".utf16)
    static let unconstrained: Set<UTF16.CodeUnit> = Set("`".utf16)

    /// +1/+2 when a character agrees with the ink in its cell, −1/−2 when it does not.
    func agreement(_ unit: UTF16.CodeUnit, cell: Int) -> Int {
        let width = ink[cell]
        if unit == 0x20 || unit == 0x09 { return width == nil ? 1 : -2 }
        if Self.unconstrained.contains(unit) { return 0 }
        if Self.thin.contains(unit) {
            guard let width else { return 0 }
            return width < 0.45 * advance ? 2 : -2
        }
        guard let width else { return -1 }
        // A glyph that is not punctuation is at least about half an advance wide; ink narrower than 0.45 of one is a
        // `,` `.` `:` or the like that the read left out (measured: a JSON value read without its trailing `,`).
        if width < 0.45 * advance, !Self.narrowLetters.contains(unit) { return -1 }
        // A letter or digit always crosses the row's middle; ink that does not is a quote or a comma.
        if Self.alphanumeric(unit), !middle.contains(cell) { return -1 }
        return 1
    }

    static let narrowLetters: Set<UTF16.CodeUnit> = Set("iIlj1|".utf16)

    static func alphanumeric(_ unit: UTF16.CodeUnit) -> Bool {
        (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }
}
