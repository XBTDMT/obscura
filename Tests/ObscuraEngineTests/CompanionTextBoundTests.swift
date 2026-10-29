// Security scan 2026-10-28 F9: the plain text any app or web page puts on the pasteboard beside an image went through
// the whole catalogue with no length cap, synchronously on the engine actor, so one copy could hold the engine (and
// with it every later screenshot) for minutes. It is now capped, searched off the actor under the Scanner's budget, and
// left out of the write-back whenever it is not checked in full. Every secret is made up.
import AppKit
import Foundation
import Testing
@testable import ObscuraCapture
import ObscuraDetect
import ObscuraOCR
@testable import ObscuraEngine

@Suite(.serialized) @MainActor struct CompanionTextBoundTests {
    static func scanner() throws -> ObscuraDetect.Scanner { ObscuraDetect.Scanner(catalogue: try ObscuraDetect.Catalogue.resolved()) }

    /// Benign text of `length` UTF-16 units in 60-character lines.
    static func benign(length: Int) -> String {
        let line = "region eu-west-1 replicas three status healthy uptime 99.9\n"
        var text = String(repeating: line, count: length / line.utf16.count + 1)
        text = String(text.utf16.prefix(length))!
        return text
    }

    @Test func textOverTheCapIsNotCheckedAndAtTheCapIsChecked() async throws {
        let scanner = try Self.scanner()
        let cap = PipelineConstants.maxCompanionTextLength
        #expect(await ShieldEngine.checkCompanionText(String(repeating: "a", count: cap + 1), scanner: scanner) == .notChecked)
        #expect(await ShieldEngine.checkCompanionText(Self.benign(length: cap), scanner: scanner) == .clean)
    }

    @Test func aLineLongerThanTheScannerReadsIsNotChecked() async throws {
        let scanner = try Self.scanner()
        let line = String(repeating: "x", count: ObscuraDetect.Scanner.Limits.standard.maxLineLength + 1)
        #expect(await ShieldEngine.checkCompanionText("fine\n" + line, scanner: scanner) == .notChecked)
    }

    /// The finding's text: one long line of `pass.` with no `=` (cubic in the old pattern) is now checked, and fast.
    @Test func theFindingsLineIsCheckedQuickly() async throws {
        let scanner = try Self.scanner()
        let line = String(String(repeating: "pass.", count: 900).prefix(4_000))
        let started = ContinuousClock.now
        #expect(await ShieldEngine.checkCompanionText(line, scanner: scanner) == .clean)
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func aCancelledCheckIsNotChecked() async throws {
        let scanner = try Self.scanner()
        let task = Task { () -> ShieldEngine.CompanionText in
            withUnsafeCurrentTask { $0?.cancel() }
            return await ShieldEngine.checkCompanionText("just words", scanner: scanner)
        }
        #expect(await task.value == .notChecked)
    }

    /// End to end: text over the cap is left out of the write-back, the notice says it was not checked, and the
    /// covered picture still goes back.
    @Test func textNotCheckedIsLeftOutAndTheNoticeSaysSo() async throws {
        let rig = try ClipboardRig()
        defer { rig.tearDown() }
        let text = String(repeating: "a", count: PipelineConstants.maxCompanionTextLength + 1)
        let generation = ClipboardFailOpenTests.copyImage(rig, text: text)
        let report = await ClipboardFailOpenTests.submitClipboard(rig, generation: generation, text: text)
        guard case .redacted = report?.outcome else { Issue.record("not redacted"); return }
        #expect(report?.notes.contains(.companionTextNotChecked) == true)
        #expect(report?.notes.contains(.companionTextRemoved) == false, "it is not said to hold a secret")
        #expect(rig.board.string(forType: .string) == nil)
        #expect(rig.board.data(forType: .png) != nil)
    }

    /// The engine answers while a long companion text is searched: the search runs off its actor. Status is asked
    /// every 20 ms through the whole scan; no answer waits for the search.
    @Test func theEngineAnswersWhileTheTextIsChecked() async throws {
        let rig = try ClipboardRig()
        defer { rig.tearDown() }
        let text = Self.benign(length: PipelineConstants.maxCompanionTextLength)
        // How long the search alone takes here, so the test knows it is long enough to see a blocked actor.
        let started = ContinuousClock.now
        #expect(await ShieldEngine.checkCompanionText(text, scanner: try Self.scanner()) == .clean)
        let searchTime = ContinuousClock.now - started
        try #require(searchTime > .milliseconds(200), "the search must take long enough to observe (took \(searchTime))")

        let generation = ClipboardFailOpenTests.copyImage(rig, text: text)
        let stream = rig.engine.outcomes
        await rig.engine.submit(.pasteboardImage(rig.board.data(forType: .png) ?? Data(), uti: .png, changeCount: generation, preservedText: text))
        let reports = Task { await collect(stream, count: 1, timeout: .seconds(60)) }
        var slowest: Duration = .zero
        var asked = 0
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            let before = ContinuousClock.now
            _ = await rig.engine.currentStatus()
            slowest = max(slowest, ContinuousClock.now - before)
            asked += 1
            if rig.board.string(forType: .string) == text, rig.board.data(forType: .png) != nil,
               rig.board.changeCount != generation { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let report = await reports.value.first
        guard case .redacted = report?.outcome else { Issue.record("not redacted"); return }
        #expect(rig.board.string(forType: .string) == text, "benign text is put back")
        #expect(asked >= 3)
        #expect(slowest < searchTime / 2, "a status answer waited \(slowest) during a \(searchTime) search")
    }
}
