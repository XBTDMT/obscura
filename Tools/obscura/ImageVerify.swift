// obscura fixtures verify --images — the end-to-end image suite (DETECTORS.md §9).
// For every Tests/Fixtures/images/<id>.png: REAL Vision OCR (VisionTextRecognizer through OCRQueue, engine options)
// → reading order → Scanner (defaults + the detector under test) → BoxMapper placement → Redactor (default solid style).
// Then the rendered pixels are judged against the generator's own glyph layout, not against OCR:
//   found    — a finding carries the detector id;
//   covered  — every ink pixel of every secret glyph changed (no secret glyph survives, even partly);
//   nothing else — no other glyph lost more than half its ink, and no finding is attributed only to other detectors.
//     One exception, by design: the single framing glyph (BoxMapper's boundary set: `= : , ; @ " ' ( ) [ ] { } < >`)
//     directly before or after a secret may be covered. BoxMapper pads half a glyph and the renderer pads 0.14 × text
//     height, so the cover reaches about three quarters into the neighbouring cell; that neighbour is a delimiter, never
//     part of the key name. Such glyphs are counted as `edge`, not as spill.
// Opt-in: real Vision costs a ~25 s cold model load plus ~0.1–0.5 s per image, so it never runs in `swift test`.
// Output carries detector ids, counts and — only on a miss, for these made-up fixtures — the OCR confusion pairs.
import CoreGraphics
import Foundation
import ObscuraDetect
import ObscuraEngine
import ObscuraOCR
import ObscuraRender

struct ImageSuite {
    struct Result {
        let id: String
        let frame: String
        let ocrMs: Int
        let found: Bool
        let secretGlyphs: Int
        let exposedGlyphs: Int
        let hiddenOther: Int
        /// Framing glyphs (`=` `"` `:` …) directly next to a secret that the cover's designed padding reaches.
        let edgeGlyphs: Int
        let touchedOther: Int
        let extraDetectors: [String]
        let diagnosis: [String]
        /// G-12 re-read bands on this image (0 when pass 1 needed none).
        var rereads = 0
        /// The re-read reasons with their band counts, and why a planned re-read did not run, if it did not.
        var recall = ""
        /// The read ended without a reading (`timeout`, `failed`, …): the image is a failed row, never the end of the run.
        var error: String?
        /// Re-read bands that could not be read (fail-open #1): the app ends such an image "not checked", so it fails here.
        var unreadBands = 0

        var passed: Bool { error == nil && unreadBands == 0 && found && exposedGlyphs == 0 && hiddenOther == 0 && extraDetectors.isEmpty }
        var failure: String {
            if let error { return "FAIL \(error)" }
            if unreadBands > 0 { return "FAIL not-checked" }
            if !found { return "FAIL ocr/detect" }
            if exposedGlyphs > 0 { return "FAIL cover" }
            if hiddenOther > 0 { return "FAIL spill" }
            if !extraDetectors.isEmpty { return "FAIL extra" }
            return "pass"
        }
    }

    /// Two pixels differ when any channel moved by more than this (PNG round trips are exact; this absorbs nothing else).
    static let changeThreshold = 8

    static func changed(_ a: RGBAPixels, _ b: RGBAPixels, _ p: (Int, Int)) -> Bool {
        let (r1, g1, b1) = a.rgb(p.0, p.1), (r2, g2, b2) = b.rgb(p.0, p.1)
        return max(abs(r1 - r2), abs(g1 - g2), abs(b1 - b2)) > changeThreshold
    }

    let queue = OCRQueue(recognizer: VisionTextRecognizer())

    /// Loads Vision's models on a tiny drawn word so the first fixture is timed warm. Returns elapsed ms.
    func warmUp() async throws -> Int {
        let layout = FixtureLayout(frame: .envLight, lines: ["warm"], dimmedLines: [])
        let started = ContinuousClock.now
        _ = try await queue.recognize(try layout.render(), options: OCROptions(timeout: .seconds(180)), priority: .file)
        return Int((ContinuousClock.now - started) / .milliseconds(1))
    }

    func check(png: URL, sidecar: ImageSidecar) async throws -> Result {
        let id = sidecar.detector
        let decoded = try ImageCodec.decode(try Data(contentsOf: png))
        let image = decoded.image
        let catalogue = try Catalogue.resolved(state: [id: true])
        let scanner = ObscuraDetect.Scanner(catalogue: catalogue)
        // The engine's own path (RecallPipeline: pass 1, the G-12 re-reads, both readings scanned and placed).
        let started = ContinuousClock.now
        let reading = try await RecallPipeline.read(image, options: OCROptions(timeout: PipelineConstants.ocrTimeout), queue: queue,
                                                    priority: .file, scanner: scanner)
        let detection = RecallPipeline.detect(reading, image: image, scanner: scanner, imageSize: CGSize(width: image.width, height: image.height),
                                              titles: CLI.titles(catalogue))
        let ocrMs = Int((ContinuousClock.now - started) / .milliseconds(1))
        let ordered = detection.lines
        let placed = detection.areas.map(\.placed)
        let rendered = try Redactor.render(image, findings: placed, style: .defaultStyle,
                                           environment: RenderEnvironment(redactedWord: PipelineConstants.defaultRedactedWord))

        let layout = FixtureComposer.layout(for: sidecar)
        guard layout.width == image.width, layout.height == image.height else {
            return Result(id: id, frame: sidecar.frame.rawValue, ocrMs: ocrMs, found: false, secretGlyphs: 0, exposedGlyphs: 0, hiddenOther: 0, edgeGlyphs: 0,
                          touchedOther: 0, extraDetectors: [], diagnosis: ["layout \(layout.width)x\(layout.height) does not match the PNG; re-render the fixtures"])
        }
        let before = try RGBAPixels(image), after = try RGBAPixels(rendered)
        let background = sidecar.frame.background

        var secretUnits: [Int: Set<Int>] = [:], edgeUnits: [Int: Set<Int>] = [:]
        for e in sidecar.expected {
            let text = Array(sidecar.lines[e.line].utf16)
            let units = e.wholeLine ? 0..<text.count : e.range[0]..<(e.range[0] + e.range[1])
            secretUnits[e.line, default: []].formUnion(units)
            for u in [units.lowerBound - 1, units.upperBound] where u >= 0 && u < text.count && Self.framing.contains(text[u]) {
                edgeUnits[e.line, default: []].insert(u)
            }
        }

        var secretGlyphs = 0, exposed = 0, hidden = 0, edge = 0, touched = 0
        var exposedAt: [Int: [Int]] = [:], hiddenAt: [Int: [Int]] = [:]
        for (li, line) in layout.lines.enumerated() {
            for u in 0..<line.text.utf16.count {
                let ink = before.inkPixels(unit: u, of: line, background: background)
                guard !ink.isEmpty else { continue }
                let moved = ink.reduce(0) { $0 + (Self.changed(before, after, $1) ? 1 : 0) }
                if secretUnits[li]?.contains(u) == true {
                    secretGlyphs += 1
                    if moved < ink.count { exposed += 1; exposedAt[li, default: []].append(u) }
                } else if moved * 2 > ink.count {
                    if edgeUnits[li]?.contains(u) == true { edge += 1 } else { hidden += 1; hiddenAt[li, default: []].append(u) }
                } else if moved > 0 {
                    touched += 1
                }
            }
        }

        let found = detection.areas.contains { $0.detectorIDs.contains(id) }
        let extra = Array(Set(detection.areas.filter { !$0.detectorIDs.contains(id) }.flatMap(\.detectorIDs))).sorted()
        let rereads = reading.stats.bands
        if ProcessInfo.processInfo.environment["OBSCURA_SUITE_SHOW_REREADS"] != nil {
            // Made-up fixtures only: what each re-read band read and which pass-1 lines it replaced.
            for r in reading.rereads {
                let old = r.replaces.map { "\"\(reading.lines[$0].text)\" \(CLI.rect(reading.lines[$0].rect))" }.joined(separator: " + ")
                print("    reread \(r.reasons.map(\.rawValue).sorted()) \(CLI.rect(r.line.rect)) \"\(r.line.text)\" replaces \(old.isEmpty ? "nothing" : old)")
            }
        }
        if ProcessInfo.processInfo.environment["OBSCURA_SUITE_SHOW_COUNTS"] != nil {
            // Counts only (G-22): each strip reading per attempt, and each re-read band's final reading against its ink.
            for r in reading.stats.stripReads {
                print("    attempt \(r.attempt) strip \(r.strip): observations \(r.observations) distinct \(r.distinct)"
                      + (r.count.map { " units \($0.units) ink \($0.ink) uncovered \($0.uncovered)" } ?? ""))
            }
            for (b, c) in reading.stats.bandCounts.enumerated() {
                print("    band \(b): units \(c.units) ink \(c.ink) uncovered \(c.uncovered) grid \(c.isGrid)")
            }
        }
        var recall = reading.stats.reasons.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)×\($0.value)" }.joined(separator: " ")
        recall += reading.stats.skipped.map { " skipped:\($0)" } ?? ""
        // G-22: strips re-read because they came back short of their ink, and bands covered to the ink's end.
        if reading.stats.shortStrips > 0 { recall += " short-strips:\(reading.stats.shortStrips)" }
        if reading.stats.shortBands > 0 { recall += " short-bands:\(reading.stats.shortBands) conservative:\(detection.conservativeAreas)" }
        // Fail-open #20: vendor-shaped tokens whose format check failed on the read text, covered unverified.
        if detection.unverifiedAreas > 0 { recall += " unverified:\(detection.unverifiedAreas)" }
        // Fail-open #1/#22: bands the re-read could not read, with why, and sheets that threw.
        if !reading.completeness.isComplete {
            let gaps: [String] = Set(reading.completeness.incomplete.flatMap(\.gaps)).sorted().map(\.rawValue)
            recall += " unread-bands:\(reading.completeness.incomplete.count)(\(gaps.joined(separator: ",")))"
        }
        if reading.stats.failedSheets > 0 { recall += " failed-sheets:\(reading.stats.failedSheets)" }
        // G-32: bands no re-read could read, given the bounded last attempt: which attempt read each, how many stayed
        // unread, how many attempts the deadline skipped, and the calls made (at most two per band).
        let last = reading.completeness.lastAttempts
        if !last.isEmpty {
            let read = ReadCompleteness.LastReader.allCases.compactMap { reader in
                let n = reading.completeness.readByLastAttempt(reader)
                return n > 0 ? "\(reader.rawValue)×\(n)" : nil
            }
            let unread = last.filter { $0.readBy == nil }.count
            let skipped = last.filter(\.skippedForDeadline).count
            recall += " last-attempt:" + (read + (unread > 0 ? ["unread×\(unread)"] : []) + (skipped > 0 ? ["skipped×\(skipped)"] : []))
                .joined(separator: ",") + " calls:\(reading.stats.lastAttemptCalls)"
        }

        var diagnosis: [String] = []
        if !found || exposed > 0 {
            for e in sidecar.expected where !e.wholeLine || e.line == sidecar.expected.first?.line {
                diagnosis.append(contentsOf: Self.diagnose(expected: e, sidecar: sidecar, layout: layout, ocr: ordered))
            }
        }
        for (li, units) in exposedAt.sorted(by: { $0.key < $1.key }) {
            diagnosis.append("line \(li): \(units.count) secret glyph(s) still visible at units \(Self.spans(units))")
        }
        for (li, units) in hiddenAt.sorted(by: { $0.key < $1.key }) {
            let text = Array(sidecar.lines[li].utf16)
            let chars = units.map { String(utf16CodeUnits: [text[$0]], count: 1) }.joined()
            diagnosis.append("line \(li): \(units.count) context glyph(s) hidden at units \(Self.spans(units)) (\"\(chars)\")")
        }
        return Result(id: id, frame: sidecar.frame.rawValue, ocrMs: ocrMs, found: found, secretGlyphs: secretGlyphs, exposedGlyphs: exposed,
                      hiddenOther: hidden, edgeGlyphs: edge, touchedOther: touched, extraDetectors: extra, diagnosis: diagnosis,
                      rereads: rereads, recall: recall, unreadBands: reading.completeness.incomplete.count)
    }

    /// A short name for an error that ended an image's read (an `OCRError` case, else the error's type): no text.
    static func describe(_ error: any Error) -> String {
        switch error as? OCRError {
        case .timeout: return "timeout"
        case .cancelled: return "cancelled"
        case .badImage: return "bad-image"
        case .queueFull: return "queue-full"
        case .failed: return "ocr-failed"
        case nil: return "error (\(type(of: error)))"
        }
    }

    /// The delimiters BoxMapper widens up to (its `framing` set) plus the space.
    static let framing: Set<UTF16.CodeUnit> = Set("=:,;@\"'`()[]{}<> ".utf16)

    /// "3-7, 12" for a sorted list of unit offsets.
    static func spans(_ units: [Int]) -> String {
        var parts: [String] = []
        var start: Int?, prev: Int?
        for u in units.sorted() {
            if let p = prev, u == p + 1 { prev = u; continue }
            if let s = start, let p = prev { parts.append(s == p ? "\(s)" : "\(s)-\(p)") }
            start = u; prev = u
        }
        if let s = start, let p = prev { parts.append(s == p ? "\(s)" : "\(s)-\(p)") }
        return parts.joined(separator: ", ")
    }

    /// What OCR made of the secret: the OCR observations on the secret's line band, joined left to right, aligned
    /// against the drawn line (Levenshtein), and every edit that falls inside the secret listed as a confusion pair.
    static func diagnose(expected e: ImageSidecar.Expected, sidecar: ImageSidecar, layout: FixtureLayout, ocr: [OCRLine]) -> [String] {
        let line = layout.lines[e.line]
        let band = CGRect(x: 0, y: line.baseline - line.ascent, width: CGFloat(layout.width), height: line.ascent + line.descent)
        let hits = ocr.filter { $0.rect.intersection(band).height > band.height * 0.4 }.sorted { $0.rect.minX < $1.rect.minX }
        guard !hits.isEmpty else { return ["line \(e.line): Vision returned no observation on this line"] }
        let truth = Array(sidecar.lines[e.line].unicodeScalars)
        let read = Array(hits.map(\.text).joined(separator: " ").unicodeScalars)
        let secretRange = e.wholeLine ? 0..<truth.count : Self.scalarRange(utf16: e.range, in: sidecar.lines[e.line])
        let ops = align(truth, read)
        var pairs: [String] = []
        var contextEdits = 0
        for op in ops {
            switch op {
            case .match: continue
            case .substitute(let i, let a, let b):
                if secretRange.contains(i) { pairs.append("\(Self.show(a))→\(Self.show(b)) @\(i - secretRange.lowerBound)") } else { contextEdits += 1 }
            case .delete(let i, let a):
                if secretRange.contains(i) { pairs.append("\(Self.show(a))→∅ @\(i - secretRange.lowerBound)") } else { contextEdits += 1 }
            case .insert(let i, let b):
                if secretRange.contains(i) || i == secretRange.upperBound { pairs.append("∅→\(Self.show(b)) @\(i - secretRange.lowerBound)") } else { contextEdits += 1 }
            }
        }
        var out = ["line \(e.line): \(hits.count) OCR observation(s) on the line; \(pairs.count) edit(s) inside the secret, \(contextEdits) outside"]
        if !pairs.isEmpty { out.append("  confusions: " + pairs.joined(separator: "  ")) }
        return out
    }

    static func show(_ s: Unicode.Scalar) -> String {
        s == " " ? "␠" : (s.properties.isWhitespace ? String(format: "U+%04X", s.value) : String(s))
    }

    static func scalarRange(utf16 range: [Int], in text: String) -> Range<Int> {
        let utf16 = text.utf16
        let start = utf16.index(utf16.startIndex, offsetBy: range[0]), end = utf16.index(start, offsetBy: range[1])
        let lower = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: start)
        let upper = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: end)
        return lower..<upper
    }

    enum EditOp { case match, substitute(Int, Unicode.Scalar, Unicode.Scalar), delete(Int, Unicode.Scalar), insert(Int, Unicode.Scalar) }

    /// Levenshtein alignment with backtrace; indexes are positions in `a` (the drawn truth).
    static func align(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> [EditOp] {
        let n = a.count, m = b.count
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n { for j in 1...m {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            } }
        }
        var ops: [EditOp] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) {
                ops.append(a[i - 1] == b[j - 1] ? .match : .substitute(i - 1, a[i - 1], b[j - 1])); i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                ops.append(.delete(i - 1, a[i - 1])); i -= 1
            } else {
                ops.append(.insert(i, b[j - 1])); j -= 1
            }
        }
        return ops.reversed()
    }

    /// Runs every sidecar in `dir` (or only `only`) and prints the per-detector table. Returns the results.
    func run(dir: URL, only: Set<String>?) async throws -> [Result] {
        let ids = Catalogue.builtIn.map(\.id).filter { only?.contains($0) ?? true }
        let warm = try await warmUp()
        print("vision warm-up: \(warm) ms")
        print("detector".padding(toLength: 34, withPad: " ", startingAt: 0) + " frame          ocr-ms reread found secret exposed hidden edge touched  result")
        var results: [Result] = []
        for id in ids {
            let png = dir.appendingPathComponent("\(id).png"), json = dir.appendingPathComponent("\(id).json")
            guard let data = try? Data(contentsOf: json), let sidecar = try? JSONDecoder().decode(ImageSidecar.self, from: data),
                  FileManager.default.fileExists(atPath: png.path) else {
                print("\(id.padding(toLength: 34, withPad: " ", startingAt: 0)) MISSING IMAGE FIXTURE (run `obscura fixtures render`)")
                results.append(Result(id: id, frame: "-", ocrMs: 0, found: false, secretGlyphs: 0, exposedGlyphs: 0, hiddenOther: 0, edgeGlyphs: 0, touchedOther: 0,
                                      extraDetectors: [], diagnosis: ["missing fixture"]))
                continue
            }
            // A read that ends in an error (a timeout above all) fails this image and the suite goes on to the next one:
            // one slow image must not hide the verdicts of the rest.
            let r: Result
            do {
                r = try await check(png: png, sidecar: sidecar)
            } catch {
                r = Result(id: id, frame: sidecar.frame.rawValue, ocrMs: 0, found: false, secretGlyphs: 0, exposedGlyphs: 0, hiddenOther: 0,
                           edgeGlyphs: 0, touchedOther: 0, extraDetectors: [], diagnosis: [], error: Self.describe(error))
            }
            results.append(r)
            print(String(format: "%@ %@ %6d %6d %5@ %6d %7d %6d %4d %7d  %@",
                         id.padding(toLength: 34, withPad: " ", startingAt: 0), r.frame.padding(toLength: 14, withPad: " ", startingAt: 0),
                         r.ocrMs, r.rereads, r.found ? "yes" : "NO", r.secretGlyphs, r.exposedGlyphs, r.hiddenOther, r.edgeGlyphs, r.touchedOther,
                         r.failure + (r.extraDetectors.isEmpty ? "" : " (+\(r.extraDetectors.joined(separator: ",")))")
                         + (r.recall.isEmpty ? "" : "  [\(r.recall)]")))
            for line in r.diagnosis where !r.passed { print("    " + line) }
        }
        let passed = results.filter(\.passed).count
        let times = results.map(\.ocrMs).filter { $0 > 0 }.sorted()
        if !times.isEmpty {
            let plain = results.filter { $0.rereads == 0 && $0.ocrMs > 0 }.map(\.ocrMs).sorted()
            let reread = results.filter { $0.rereads > 0 }.map(\.ocrMs).sorted()
            func median(_ v: [Int]) -> Int { v.isEmpty ? 0 : v[v.count / 2] }
            print("read+detect ms: median \(median(times)) (no re-read \(median(plain)) over \(plain.count) images, re-read \(median(reread)) over \(reread.count) images), max \(times.last!)")
        }
        let byKind = Dictionary(grouping: results.filter { !$0.passed }, by: \.failure).mapValues(\.count)
        print("TOTAL \(results.count) images: \(passed) pass, \(results.count - passed) fail"
              + (byKind.isEmpty ? "" : " (" + byKind.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + ")"))
        return results
    }
}
