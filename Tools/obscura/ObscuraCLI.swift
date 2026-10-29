// obscura — the engine CLI. Runs the same packages the app runs, against a temp Journal and in-memory settings.
// Output never contains matched text: counts, detector ids and rects only.
import ArgumentParser
import CoreGraphics
import Foundation
import ObscuraCapture
import ObscuraDetect
import ObscuraEngine
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraRender
import ObscuraSearch
import ObscuraSupport
import UniformTypeIdentifiers

let obscuraVersion = "0.2.0"

@main
struct Obscura: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "obscura",
        abstract: "Obscura engine CLI: scan images for secrets, render redactions, run the fixture suite.",
        version: obscuraVersion,
        subcommands: [Scan.self, Redact.self, Detectors.self, Fixtures.self, Journal.self, Search.self, Release.self, Version.self],
        defaultSubcommand: Version.self
    )
}

// MARK: - Shared helpers

enum CLI {
    static func temporaryRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("obscura-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A Journal in a temporary root: its rule key lives in memory and goes with the process (G-30); the Keychain is
    /// never asked.
    static func temporaryJournal(root: URL) throws -> SQLiteJournalStore {
        try SQLiteJournalStore(root: root, ruleKeys: InMemoryRuleKeyStore())
    }


    static func makeEngine(root: URL) throws -> ShieldEngine {
        let journal = try temporaryJournal(root: root)
        return ShieldEngine(sources: [], recognizer: VisionTextRecognizer(), journal: journal, settings: InMemorySettingsStore(),
                            clock: SystemClock(), folderWatcher: nil, clipboardGuard: nil)
    }

    static func rect(_ r: CGRect) -> String {
        String(format: "%.0f,%.0f %.0fx%.0f", r.origin.x, r.origin.y, r.width, r.height)
    }

    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Detector id → cover label (`CoverLabels`: a custom rule's own words never reach a cover).
    static func titles(_ catalogue: CompiledCatalogue) -> [String: String] { CoverLabels.titles(for: catalogue) }

    static func fixturesDirectory() -> URL? {
        var candidates = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        candidates.append(URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent())
        for start in candidates {
            var dir = start
            for _ in 0..<8 {
                let probe = dir.appendingPathComponent("Tests/Fixtures/text", isDirectory: true)
                if FileManager.default.fileExists(atPath: probe.path) { return probe }
                dir.deleteLastPathComponent()
            }
        }
        return nil
    }
}

struct ScanResultJSON: Encodable {
    struct FindingJSON: Encodable {
        let line: Int
        let detectors: [String]
        let category: String
        let rect: [Double]
    }
    let file: String
    let outcome: String
    let findings: Int
    let entryID: String?
    let durationMs: Int?
    let details: [FindingJSON]
}

// MARK: - scan

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Scan images and report what would be redacted (temp Journal, nothing written back).")

    @Argument(help: "Image files to scan.") var images: [String]
    @Flag(name: .long, help: "Print one JSON object per image.") var json = false

    func run() async throws {
        let root = try CLI.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try CLI.temporaryJournal(root: root)
        let engine = ShieldEngine(sources: [], recognizer: VisionTextRecognizer(), journal: journal, settings: InMemorySettingsStore(),
                                  clock: SystemClock(), folderWatcher: nil, clipboardGuard: nil)
        if let ms = await engine.warmUp(), !json { print("vision warm-up: \(ms) ms") }
        var exit: Int32 = 0
        for path in images {
            let url = URL(fileURLWithPath: path)
            let data: Data
            do { data = try Data(contentsOf: url) } catch {
                FileHandle.standardError.write(Data("\(path): cannot read\n".utf8))
                exit = 2
                continue
            }
            let outcome = await engine.scan(imageData: data, source: .imported, displayName: url.lastPathComponent, filePath: nil, origin: nil)
            var result = ScanResultJSON(file: path, outcome: outcome.statLabel, findings: 0, entryID: nil, durationMs: nil, details: [])
            switch outcome {
            case .redacted(let entryID, let count, let duration):
                let entry = try await journal.entry(entryID)
                result = ScanResultJSON(file: path, outcome: "redacted", findings: count, entryID: entryID.uuidString,
                                        durationMs: Int(duration / .milliseconds(1)),
                                        details: entry.findings.map {
                                            .init(line: $0.lineIndex, detectors: $0.detectorIDs, category: $0.category,
                                                  rect: [$0.rect.origin.x, $0.rect.origin.y, $0.rect.width, $0.rect.height].map { (v: CGFloat) -> Double in (Double(v) * 10).rounded() / 10 })
                                        })
            case .clean(let duration):
                result = ScanResultJSON(file: path, outcome: "clean", findings: 0, entryID: nil, durationMs: Int(duration / .milliseconds(1)), details: [])
            case .skipped, .failed:
                exit = 1
            }
            if json {
                print(try CLI.json(result))
            } else {
                print("\(path): \(result.outcome), \(result.findings) finding(s)\(result.durationMs.map { " in \($0) ms" } ?? "")")
                for d in result.details {
                    let rect = CGRect(x: d.rect[0], y: d.rect[1], width: d.rect[2], height: d.rect[3])
                    print("  line \(d.line)  \(d.detectors.joined(separator: "+"))  [\(d.category)]  \(CLI.rect(rect))")
                }
            }
        }
        if exit != 0 { throw ExitCode(exit) }
    }
}

// MARK: - redact

struct Redact: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write a redacted copy of one image. No Journal is touched.")

    enum Style: String, ExpressibleByArgument, CaseIterable { case solid, erase, blur, mosaic }

    @Argument(help: "The image to redact.") var image: String
    @Option(name: .long, help: "Output path (container follows the input: PNG/JPEG/HEIC, others become PNG).") var out: String
    @Option(name: .long, help: "solid | erase | blur | mosaic") var style: Style = .solid

    func run() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: image))
        let decoded = try ImageCodec.decode(data)
        let queue = OCRQueue(recognizer: VisionTextRecognizer())
        // Cold start: the first Vision request loads the models (12–25 s); give it the room the engine's warm-up gives it.
        let catalogue = try Catalogue.resolved()
        let scanner = ObscuraDetect.Scanner(catalogue: catalogue)
        let reading = try await RecallPipeline.read(decoded.image, options: OCROptions(timeout: PipelineConstants.ocrTimeout * 3), queue: queue,
                                                    priority: .file, scanner: scanner)
        let detection = RecallPipeline.detect(reading, image: decoded.image, scanner: scanner, imageSize: CGSize(width: decoded.image.width, height: decoded.image.height),
                                              titles: CLI.titles(catalogue))
        let placed = detection.areas.map(\.placed)
        let lines = reading.lines
        var spec = StyleSpec.defaultStyle
        spec.kind = StyleSpec.Kind(rawValue: style.rawValue) ?? .solid
        let rendered = try Redactor.render(decoded.image, findings: placed, style: spec, environment: RenderEnvironment(redactedWord: PipelineConstants.defaultRedactedWord))
        let target: UTType = decoded.uti.conforms(to: .jpeg) ? .jpeg : decoded.uti.conforms(to: .heic) ? .heic : .png
        let encoded = try ImageCodec.encode(rendered, as: target, dpi: decoded.dpi, quality: PipelineConstants.jpegQuality)
        try FileAtomics.write(encoded, to: URL(fileURLWithPath: out), mode: .default)
        print("\(out): \(placed.count) finding(s) redacted with \(style.rawValue), \(lines.count) line(s) read")
        for p in placed { print("  \(p.label)  \(CLI.rect(p.rect))") }
        // Fail-open #1: the app ends such a picture "not checked"; say so here too (counts and gap names only).
        if !reading.completeness.isComplete {
            let gaps = Set(reading.completeness.incomplete.flatMap(\.gaps)).sorted().map(\.rawValue).joined(separator: ",")
            print("NOT CHECKED: \(reading.completeness.incomplete.count) of \(reading.completeness.planned) re-read band(s) not read (\(gaps))")
        }
    }
}

// MARK: - detectors

struct Detectors: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "The built-in detector catalogue.", subcommands: [List.self, Show.self], defaultSubcommand: List.self)

    struct Row: Encodable {
        let id: String
        let title: String
        let category: String
        let severity: String
        let enabledByDefault: Bool
        let patterns: Int
        let validator: String
    }

    static func row(_ d: Detector) -> Row {
        Row(id: d.id, title: d.title, category: d.category.rawValue, severity: d.severity.rawValue, enabledByDefault: d.enabledByDefault,
            patterns: d.patterns.count, validator: d.validator.typeName)
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List every built-in detector.")
        @Flag(name: .long) var json = false

        func run() throws {
            let rows = Catalogue.builtIn.map(Detectors.row)
            if json { print(try CLI.json(rows)); return }
            print("\(rows.count) detectors")
            for r in rows {
                print("\(r.id.padding(toLength: 34, withPad: " ", startingAt: 0)) \(r.category.padding(toLength: 10, withPad: " ", startingAt: 0)) \(r.severity.padding(toLength: 9, withPad: " ", startingAt: 0)) \(r.enabledByDefault ? "on " : "off") \(r.title)")
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one detector: patterns, validator, scope, hint.")
        @Argument var id: String

        func run() throws {
            guard let d = Catalogue.builtIn.first(where: { $0.id == id }) else {
                throw ValidationError("no detector \(id)")
            }
            print("id:        \(d.id)")
            print("title:     \(d.title)")
            print("category:  \(d.category.rawValue)")
            print("severity:  \(d.severity.rawValue)")
            print("enabled:   \(d.enabledByDefault)")
            print("validator: \(d.validator.typeName)\(d.validatedPatternIndexes.map { " (patterns \($0))" } ?? "")")
            print("scope:     \(d.scope)")
            print("hint:      \(d.hint)")
            for (i, p) in d.patterns.enumerated() {
                print("pattern \(i): \(p.kind.rawValue)  \(p.humanDescription)")
                if let regex = try? p.compiledPattern() { print("           \(regex)") }
            }
        }
    }
}

// MARK: - fixtures

struct Fixtures: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Fixture suite.", subcommands: [Verify.self, Render.self], defaultSubcommand: Verify.self)

    struct Fixture: Decodable { let positive: [String]; let negative: [String] }

    struct Verify: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run every Tests/Fixtures/text/<id>.json line through the Scanner; exit 1 on any miss.",
            discussion: "--images instead runs the end-to-end image suite: real Vision OCR + detection + render on every Tests/Fixtures/images/<id>.png (slow: ~25 s cold model load).")
        @Option(name: .long, help: "Fixture directory (default: Tests/Fixtures/text found from cwd or the binary).") var fixtures: String?
        @Flag(name: .long, help: "Run the end-to-end image suite (real Vision OCR) instead of the text suite.") var images = false
        @Option(name: .long, help: "With --images: comma-separated detector ids to run (default: all).") var only: String?

        func run() async throws {
            guard let dir = fixtures.map({ URL(fileURLWithPath: $0, isDirectory: true) }) ?? CLI.fixturesDirectory() else {
                throw ValidationError("fixtures directory not found; pass --fixtures")
            }
            if images {
                let imagesDir = dir.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
                let filter = only.map { Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }
                let results = try await ImageSuite().run(dir: imagesDir, only: filter)
                if results.isEmpty || results.contains(where: { !$0.passed }) { throw ExitCode(1) }
                return
            }
            let ids = Catalogue.builtIn.map(\.id)
            let allOff = Dictionary(uniqueKeysWithValues: ids.map { ($0, false) })
            var totalTP = 0, totalFN = 0, totalFP = 0, totalTN = 0, missing = 0, readUnverified = 0, readVerified = 0
            print("detector".padding(toLength: 34, withPad: " ", startingAt: 0) + "  pos  hit miss   neg  ok  fp  precision  recall")
            for id in ids {
                let file = dir.appendingPathComponent("\(id).json")
                guard let data = try? Data(contentsOf: file), let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
                    print("\(id.padding(toLength: 34, withPad: " ", startingAt: 0))  MISSING FIXTURE")
                    missing += 1
                    continue
                }
                var state = allOff
                state[id] = true
                let scanner = ObscuraDetect.Scanner(catalogue: try Catalogue.resolved(state: state))
                var tp = 0, fn = 0, fp = 0, tn = 0
                // Fail-open #20: on OCR text a full-shape token whose vendor-format check fails is covered unverified.
                // Precision above is the exact-text verdict; this counts what the same negatives become when read.
                let recognized = scanner.reading(.recognized)
                for line in fixture.negative {
                    let found = recognized.scan([ScanLine(index: 0, text: line)])
                    readUnverified += found.filter(\.unverified).count
                    readVerified += found.filter { !$0.unverified }.count
                }
                for line in fixture.positive {
                    if scanner.scan([ScanLine(index: 0, text: line)]).contains(where: { $0.detectorIDs.contains(id) }) { tp += 1 } else { fn += 1 }
                }
                for line in fixture.negative {
                    // A negative is clean only when it was searched to the end (security scan F14: never a stopped search).
                    let result = scanner.check([ScanLine(index: 0, text: line)])
                    if result.findings.isEmpty && result.isComplete { tn += 1 } else { fp += 1 }
                }
                totalTP += tp; totalFN += fn; totalFP += fp; totalTN += tn
                let precision = tp + fp == 0 ? 1.0 : Double(tp) / Double(tp + fp)
                let recall = tp + fn == 0 ? 1.0 : Double(tp) / Double(tp + fn)
                let flag = (fn > 0 || fp > 0) ? "  <-- MISS" : ""
                print(String(format: "%@ %4d %4d %4d  %4d %3d %3d  %8.3f  %6.3f%@",
                             id.padding(toLength: 34, withPad: " ", startingAt: 0), tp + fn, tp, fn, tn + fp, tn, fp, precision, recall, flag))
            }
            let precision = totalTP + totalFP == 0 ? 1.0 : Double(totalTP) / Double(totalTP + totalFP)
            let recall = totalTP + totalFN == 0 ? 1.0 : Double(totalTP) / Double(totalTP + totalFN)
            print(String(format: "TOTAL %d detectors: positives %d (hit %d, miss %d), negatives %d (ok %d, false %d), precision %.3f, recall %.3f, missing fixtures %d",
                         ids.count, totalTP + totalFN, totalTP, totalFN, totalTN + totalFP, totalTN, totalFP, precision, recall, missing))
            print("as recognized text: negatives covered unverified \(readUnverified) (full-shape tokens whose vendor-format check fails), verified \(readVerified)")
            if totalFN > 0 || totalFP > 0 || missing > 0 || readVerified > 0 { throw ExitCode(1) }
        }
    }
}

// MARK: - journal

struct Journal: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Journal inspection. Read-only: a --root Journal is opened without migrating, purging or writing anything.", subcommands: [List.self, Rules.self], defaultSubcommand: List.self)

    /// F2: a Journal the user names with `--root` (the app's, or a copy someone sent) is only read: opened read-only,
    /// with none of the store's open-time upkeep (no migration, layout move, trash purge or new key). Without `--root`, a
    /// fresh temporary Journal (memory key), which is empty.
    static func inspect(root: String?) throws -> (JournalInspector, URL, any RuleKeyStore) {
        if let root {
            let url = URL(fileURLWithPath: root, isDirectory: true)
            return (try JournalInspector(root: url), url, KeychainRuleKeyStore())
        }
        let url = try CLI.temporaryRoot()
        _ = try CLI.temporaryJournal(root: url)
        return (try JournalInspector(root: url), url, InMemoryRuleKeyStore())
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List live Journal entries.")
        @Option(name: .long, help: "Journal root (default: a fresh temp root, which is empty).") var root: String?

        func run() async throws {
            let (journal, rootURL, _) = try Journal.inspect(root: root)
            let entries = try journal.liveEntries()
            print("\(entries.count) entries in \(rootURL.path)")
            let formatter = ISO8601DateFormatter()
            for e in entries {
                print("\(e.id.uuidString)  \(formatter.string(from: e.createdAt))  rev \(e.revision)  \(e.findings.count) finding(s)  \(e.source.rawValue)  \(e.displayName)")
            }
        }
    }

    /// G-30: which custom rules there are and whether each can be read here. Ids, actions, kinds, names and the reason
    /// only: a rule's value is never printed (it may be the secret itself).
    struct Rules: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List custom rules (id, action, kind, name, readable or why not). Never prints a rule's value.")
        @Option(name: .long, help: "Journal root (default: a fresh temp root, which is empty).") var root: String?

        func run() async throws {
            let (journal, rootURL, keys) = try Journal.inspect(root: root)
            let rules = try journal.rules(ruleKeys: keys)
            let unreadable = rules.filter { if case .unreadable = $0.state { return true } else { return false } }
            print("\(rules.count) rule(s) in \(rootURL.path), \(unreadable.count) unreadable on this Mac")
            for r in rules {
                let state: String
                switch r.state {
                case .readable: state = "readable"
                case .unreadable(let problem): state = "unreadable:\(problem.rawValue)"
                case .notSealedYet: state = "not-sealed-yet(schema \(journal.schemaVersion))"
                }
                print("\(r.id)  \(r.action.rawValue)  \(r.kind.rawValue)  \(r.enabled ? "on" : "off")  \(state)  \(r.name ?? "")")
            }
            if !unreadable.isEmpty { throw ExitCode(1) }
        }
    }
}

// MARK: - search (G-24)

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Spotlight entries and Finder tags of covered files.", subcommands: [Report.self],
                                                    defaultSubcommand: Report.self)

    struct Report: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Counts and ids of the covered files Obscura labels, and which carry Obscura's Finder tags. Read-only: opens the "
                + "database without migrating or writing anything. Core Spotlight's own count needs the app (debug build: -ObscuraSearchReport YES).")
        @Option(name: .long, help: "Store root (default: ~/Library/Application Support/Obscura).") var root: String?

        func run() async throws {
            let rootURL = root.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? JournalLocations.defaultRoot()
            let report = SearchReport.make(records: try CoveredFilesReader.read(root: rootURL))
            print(try CLI.json(report))
        }
    }
}

// MARK: - version

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the engine version.")
    func run() { print("obscura \(obscuraVersion) — \(Catalogue.builtIn.count) detectors") }
}
