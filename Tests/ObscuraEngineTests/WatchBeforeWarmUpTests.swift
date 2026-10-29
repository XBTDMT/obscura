import CoreGraphics
import Foundation
import Testing
import ObscuraCapture
import ObscuraOCR
import ObscuraPrefs
@testable import ObscuraEngine

/// A recognizer whose first call (the launch warm-up) is slow, as Vision's cold start is; later calls answer at once.
private final class SlowFirstCallRecognizer: TextRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let inner: StubTextRecognizer
    private let firstDelay: Duration
    init(lines: [OCRLine], firstDelay: Duration) {
        inner = StubTextRecognizer(lines: lines)
        self.firstDelay = firstDelay
    }
    func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine] {
        let first = lock.withLock { calls += 1; return calls == 1 }
        if first { try await Task.sleep(for: firstDelay) }
        return try await inner.recognize(image, options: options)
    }
}

/// A screenshot taken while Vision is still warming up (at login, say) is checked once the engine is ready, never missed.
@Suite(.serialized) struct WatchBeforeWarmUpTests {
    @Test func aScreenshotTakenDuringTheWarmUpIsStillChecked() async throws {
        let dir = try Fixture.tempDirectory("warmup-watch")
        defer { try? FileManager.default.removeItem(at: dir) }
        var settings = Settings.default
        settings.guardsScreenshotFolder = false
        settings.extraFolders = [dir.path]
        let watcher = FolderWatcher(roots: ShieldEngine.watchedRoots(from: settings, approvals: [try #require(FolderApproval.current(dir, at: Date()))]))
        let recognizer = SlowFirstCallRecognizer(lines: [Fixture.keyLine], firstDelay: .seconds(3))
        let h = try Harness(recognizer: recognizer, settings: settings, sources: [watcher], folderWatcher: watcher)
        defer { h.tearDown() }
        let outcomes = h.engine.outcomes
        let runner = Task { await h.engine.run() }
        defer { runner.cancel() }

        // The watcher opens before the warm-up finishes.
        let started = ContinuousClock.now
        while !(await watcher.isRunning), ContinuousClock.now - started < .seconds(2) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await watcher.isRunning, "the folder is watched while Vision is still warming up")
        #expect(ContinuousClock.now - started < .seconds(3), "watching did not wait for the warm-up")

        // A screenshot lands mid-warm-up (written beside, then moved in, as screencapture does).
        let temp = dir.appendingPathComponent(".shot.tmp")
        try Fixture.pngData().write(to: temp)
        try FileManager.default.moveItem(at: temp, to: dir.appendingPathComponent("Screenshot during warm-up.png"))

        let reports = await collect(outcomes, count: 1, timeout: .seconds(20))
        #expect(reports.count == 1, "the screenshot taken during the warm-up reached a verdict")
        if case .redacted? = reports.first?.outcome {} else {
            Issue.record("expected the made-up key to be covered, got \(String(describing: reports.first?.outcome))")
        }
    }
}
