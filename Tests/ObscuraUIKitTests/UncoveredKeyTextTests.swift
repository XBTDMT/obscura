// G-17: a finding left visible shows its key as text with Copy, behind a switch. Every key here is made up
// (SampleData's terminal values, shaped to each vendor's public format; none is a real credential).
import AppKit
import Foundation
import Testing
import ObscuraCapture
import ObscuraDetect
import ObscuraEngine
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSupport
@testable import ObscuraUIKit

/// A pasteboard of the test's own, released afterwards; the general pasteboard is never touched.
@MainActor
private func withPrivatePasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("obscura-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    try body(pasteboard)
}

private func finding(enabled: Bool, id: UUID = UUID()) -> ObscuraJournal.Finding {
    ObscuraJournal.Finding(id: id, entryID: UUID(), lineIndex: 0, rect: CGRect(x: 10, y: 10, width: 200, height: 20),
            detectorIDs: ["payments.stripe.secretkey"], category: "payments", enabled: enabled)
}

/// SampleData's made-up Stripe-shaped value (the text after `=` on its terminal's Stripe line).
private let madeUpKey = String(SampleData.envLines[1].split(separator: "=", maxSplits: 1)[1])

/// Counts reads and answers with `answer`, after `gate` opens when one is given.
@MainActor
private final class StubReads {
    var calls: [(finding: UUID, entry: UUID)] = []
    var answer: Result<String, any Error> = .success(madeUpKey)
    var gate: CheckedContinuation<Void, Never>?
    var holds = false

    var reader: UncoveredKeyText.Reader {
        { [self] finding, entry in
            calls.append((finding, entry))
            if holds { await withCheckedContinuation { gate = $0 } }
            return try answer.get()
        }
    }

    func open() { gate?.resume(); gate = nil }
}

@Suite @MainActor struct KeyPasteboardTests {
    @Test func writesTheTextMarkedConcealedAndTransient() {
        withPrivatePasteboard { pb in
            pb.clearContents()
            pb.setString("something earlier", forType: .string)
            #expect(KeyPasteboard.write(madeUpKey, to: pb))
            #expect(pb.string(forType: .string) == madeUpKey)
            let types = Set(pb.types ?? [])
            #expect(types.contains(.string))
            #expect(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
            #expect(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
            // The clipboard guard's skip list names exactly these markers, so Obscura never re-reads its own copy.
            #expect(Set(ObscuraCapture.ClipboardGuardConfig().skipTypes) == [KeyPasteboard.concealedType.rawValue, KeyPasteboard.transientType.rawValue])
        }
    }
}

@Suite @MainActor struct UncoveredKeyTextModelTests {
    @Test func showsOnlyWithTheSwitchOnAndTheFindingUncovered() async {
        let reads = StubReads()
        let keys = UncoveredKeyText(read: reads.reader)
        let uncovered = finding(enabled: false), covered = finding(enabled: true)
        #expect(UncoveredKeyText.shows(uncovered, switchOn: true))
        #expect(!UncoveredKeyText.shows(uncovered, switchOn: false))
        #expect(!UncoveredKeyText.shows(covered, switchOn: true))
        #expect(!UncoveredKeyText.shows(covered, switchOn: false))

        // Switch off, or covered: no field, and nothing is read.
        keys.request(uncovered, in: UUID(), switchOn: false)
        keys.request(covered, in: UUID(), switchOn: true)
        await keys.settle()
        #expect(reads.calls.isEmpty)
        #expect(keys.state(for: uncovered, switchOn: false) == nil)
        #expect(keys.state(for: covered, switchOn: true) == nil)

        // Switch on and uncovered: reading, then the text.
        let entryID = UUID()
        #expect(keys.state(for: uncovered, switchOn: true) == .reading)
        keys.request(uncovered, in: entryID, switchOn: true)
        keys.request(uncovered, in: entryID, switchOn: true)   // a second appearance does not read again
        await keys.settle()
        #expect(reads.calls.count == 1)
        #expect(reads.calls.first?.finding == uncovered.id && reads.calls.first?.entry == entryID)
        #expect(keys.state(for: uncovered, switchOn: true) == .text(madeUpKey))
        // Turning the switch off hides it at once, even before a sync.
        #expect(keys.state(for: uncovered, switchOn: false) == nil)
    }

    @Test func coveringAgainClearsTheText() async {
        let reads = StubReads()
        let keys = UncoveredKeyText(read: reads.reader)
        let id = UUID()
        keys.request(finding(enabled: false, id: id), in: UUID(), switchOn: true)
        await keys.settle()
        #expect(keys.heldIDs == [id])

        let recovered = finding(enabled: true, id: id)
        #expect(keys.state(for: recovered, switchOn: true) == nil)
        keys.sync([recovered], switchOn: true)
        #expect(keys.heldIDs.isEmpty, "the text stays in memory after the finding is covered again")

        // Uncovered once more: read afresh, not from a cache.
        keys.request(finding(enabled: false, id: id), in: UUID(), switchOn: true)
        await keys.settle()
        #expect(reads.calls.count == 2)
    }

    @Test func theSwitchOffAndClosingTheWindowClearEverything() async {
        let reads = StubReads()
        let keys = UncoveredKeyText(read: reads.reader)
        let a = finding(enabled: false), b = finding(enabled: false)
        keys.request(a, in: UUID(), switchOn: true)
        keys.request(b, in: UUID(), switchOn: true)
        await keys.settle()
        #expect(keys.heldIDs == [a.id, b.id])
        keys.sync([a, b], switchOn: false)
        #expect(keys.heldIDs.isEmpty)

        keys.request(a, in: UUID(), switchOn: true)
        await keys.settle()
        keys.sync([], switchOn: true)   // the finding is gone from the entry
        #expect(keys.heldIDs.isEmpty)

        keys.request(a, in: UUID(), switchOn: true)
        await keys.settle()
        keys.clear()
        #expect(keys.heldIDs.isEmpty)
    }

    @Test func aReadThatEndsAfterTheFindingWasCoveredIsDropped() async {
        let reads = StubReads()
        reads.holds = true
        let keys = UncoveredKeyText(read: reads.reader)
        let id = UUID()
        keys.request(finding(enabled: false, id: id), in: UUID(), switchOn: true)
        while reads.gate == nil { await Task.yield() }
        keys.sync([finding(enabled: true, id: id)], switchOn: true)
        reads.open()
        await keys.settle()
        #expect(keys.heldIDs.isEmpty)
        #expect(keys.state(for: finding(enabled: false, id: id), switchOn: true) == .reading, "a fresh field starts a fresh read")
    }

    @Test func aFailedReadSaysSoAndCopyNeedsText() async {
        let reads = StubReads()
        reads.answer = .failure(KeyTextError.nothingRead)
        let keys = UncoveredKeyText(read: reads.reader)
        let f = finding(enabled: false)
        keys.request(f, in: UUID(), switchOn: true)
        await keys.settle()
        #expect(keys.state(for: f, switchOn: true) == .unreadable)
        withPrivatePasteboard { pb in
            pb.clearContents()
            #expect(!keys.copy(f.id, to: pb))
            #expect(pb.string(forType: .string) == nil)
        }
    }

    @Test func copyPutsTheTextOnThePasteboardConcealed() async {
        let reads = StubReads()
        let keys = UncoveredKeyText(read: reads.reader)
        let f = finding(enabled: false)
        keys.request(f, in: UUID(), switchOn: true)
        await keys.settle()
        withPrivatePasteboard { pb in
            #expect(keys.copy(f.id, to: pb))
            #expect(pb.string(forType: .string) == madeUpKey)
            #expect(pb.types?.contains(KeyPasteboard.concealedType) == true)
            #expect(pb.types?.contains(KeyPasteboard.transientType) == true)
        }
    }

    @Test func theFieldsWordsAreTheRuledOnes() {
        #expect(KeyTextCopy.note == "Read from the picture — check before using.")
        #expect(KeyTextCopy.unreadable == "Couldn't read this one.")
        #expect(KeyTextCopy.copied == "Key copied.")
    }
}

/// The same text up to the look-alike glyphs OCR confuses (0/O, 1/l/I): what the field's note "check before using" is
/// for (G-17). Measured 2026-10-27 on this terminal in Menlo: the Anthropic and GitHub values read one or two such
/// characters wrong at every read scale from 1× to 3×; the Stripe and database values read exactly.
private func sameUpToLookAlikes(_ a: String, _ b: String) -> Bool {
    func fold(_ s: String) -> String {
        String(s.map { c -> Character in
            switch c { case "O", "o": return "0"; case "l", "I", "|": return "1"; default: return c }
        })
    }
    return a.count == b.count && fold(a) == fold(b)
}

/// The whole path on SampleData's made-up terminal with real Vision: the model reads each left-visible value through
/// the engine, and the text is the detector's secret part of the line as drawn (exactly for the Stripe key, up to
/// look-alike glyphs for every key). Skipped under CI (no Vision models).
@Suite @MainActor struct UncoveredKeyTextEndToEndTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func readsEverySampleSecretThroughTheModel() async throws {
        let journal = try SampleData.makeJournal()
        defer { try? FileManager.default.removeItem(at: journal.journalRoot.deletingLastPathComponent()) }
        let layout = SampleData.TerminalLayout()
        let findings = SampleData.terminalFindings(layout: layout, leftVisible: Set(SampleData.secretLines.indices))
        let entry = try await journal.create(NewEntry(source: .file, displayName: "Sample.png", containerUTI: "public.png",
                                                      pixelWidth: Int(layout.pixelSize.width), pixelHeight: Int(layout.pixelSize.height),
                                                      findings: findings),
                                             original: SampleData.terminalPNG(covered: false), clean: SampleData.terminalPNG(covered: false))
        var settings = Settings.default
        settings.showsUncoveredKeyText = true
        let store = InMemorySettingsStore(settings)
        let engine = ShieldEngine(sources: [], recognizer: VisionTextRecognizer(), journal: journal, settings: store, clock: SystemClock(),
                                  folderWatcher: nil, clipboardGuard: nil)
        #expect(await engine.warmUp() != nil)
        let model = AppModel(engine: engine, journal: journal, settings: store)
        let keys = UncoveredKeyText(model: model)
        let scanner = ObscuraDetect.Scanner(catalogue: try Catalogue.resolved())

        for (stored, sample) in zip(entry.findings.sorted { $0.lineIndex < $1.lineIndex }, SampleData.secretLines) {
            // The oracle: the detector's secret part of the line exactly as SampleData drew it.
            let line = SampleData.envLines[sample.line]
            let expected = try #require(scanner.scan([ScanLine(index: 0, text: line)]).first { $0.detectorIDs.contains(sample.detectorID) })
            let secret = (line as NSString).substring(with: expected.secretRange)
            keys.request(stored, in: entry.id, switchOn: true)
            await keys.settle()
            guard case .text(let read)? = keys.state(for: stored, switchOn: true) else {
                Issue.record("\(sample.detectorID): nothing read"); continue
            }
            #expect(sameUpToLookAlikes(read, secret), "\(sample.detectorID): the read is not the made-up value")
            if sample.detectorID == "payments.stripe.secretkey" { #expect(read == secret) }
        }
    }
}
