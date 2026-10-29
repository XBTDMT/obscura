// Fail-open #21: screenshots taken while protection was paused were never listed after the resume, so a secret in one
// stayed on disk with nothing to say so. Each is now a "Not checked (paused)" row; after the resume (by hand, or when the
// pause runs out) the status counts it and Check Again checks it. Every image is the engine fixtures' blank PNG.
import Foundation
import Testing
import ObscuraCapture
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSupport
@testable import ObscuraEngine

@Suite(.serialized) struct PausedFilesTests {
    @Test func aShotTakenWhilePausedIsListedAfterTheResumeAndCheckAgainChecksIt() async throws {
        let h = try Harness(recognizer: StubTextRecognizer(lines: []))
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("paused")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Screenshot while paused.png")
        try Fixture.pngData().write(to: file)

        await h.engine.pause()
        let stream = h.engine.outcomes
        await h.engine.submit(.file(file, origin: .screenshotFolder))
        #expect(try #require(await collect(stream, count: 1, timeout: .seconds(5)).first).outcome.skipReason == .protectionPaused)
        let whilePaused = await h.engine.currentStatus()
        #expect(whilePaused.protection == .paused, "while paused the status says Paused, not a problem")
        #expect(whilePaused.unchecked.first?.reason == "protectionPaused")
        #expect(try await h.journal.uncheckedFiles().map(\.reason) == [.protectionPaused], "it survives a relaunch")

        await h.engine.resume()
        let resumed = await h.engine.currentStatus()
        #expect(resumed.problems.first { $0.kind == .scanFailure }?.detail == "1")
        if case .needsAttention = resumed.protection {} else { Issue.record("after the resume it is not Protected, got \(resumed.protection)") }

        let again = h.engine.outcomes
        #expect(await h.engine.retryUnchecked() == 1)
        #expect(try #require(await collect(again, count: 1, timeout: .seconds(5)).first).outcome.isClean)
        #expect(await h.engine.currentStatus().unchecked.isEmpty)
        #expect(try await h.journal.uncheckedFiles().isEmpty)
    }

    /// A pause set in Settings (with an end time, G-10) that runs out is a resume too: the file stays listed.
    @Test func aShotTakenDuringATimedPauseIsListedWhenThePauseRunsOut() async throws {
        var settings = Settings.default
        settings.protectionPaused = true
        let h = try Harness(recognizer: StubTextRecognizer(lines: []), settings: settings)
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("timed-pause")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Screenshot timed.png")
        try Fixture.pngData().write(to: file)
        let stream = h.engine.outcomes
        await h.engine.submit(.file(file, origin: .screenshotFolder))
        _ = await collect(stream, count: 1, timeout: .seconds(5))

        h.settings.update { $0.protectionPaused = false }
        let after = await h.engine.currentStatus()
        #expect(after.unchecked.map(\.displayName) == ["Screenshot timed.png"])
        #expect(after.problems.first { $0.kind == .scanFailure }?.detail == "1")
    }

    @Test func aPauseIsNotAnAlertButIsARow() {
        #expect(ShieldEngine.uncheckedReason(for: .skipped(.protectionPaused)) == .protectionPaused)
        #expect(!ScanOutcome.skipped(.protectionPaused).needsAttention, "no alert per file: the pause was the user's choice")
    }
}
