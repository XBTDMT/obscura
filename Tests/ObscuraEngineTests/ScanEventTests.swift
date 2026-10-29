import CoreGraphics
import Foundation
import Testing
import ObscuraCapture
import ObscuraOCR
import ObscuraPrefs
import ObscuraSupport
@testable import ObscuraEngine

// Every secret below is made up (the engine fixtures' Stripe-shaped test value).

/// Collects scan events until `finished` reports arrived, or whatever arrived before `timeout`.
func collectEvents(_ stream: AsyncStream<ScanEvent>, finished count: Int, timeout: Duration) async -> [ScanEvent] {
    let box = EventBox()
    let task = Task {
        for await event in stream {
            if box.append(event) >= count { break }
        }
    }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline, box.finishedCount < count {
        try? await Task.sleep(for: .milliseconds(20))
    }
    task.cancel()
    return box.all
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ScanEvent] = []
    private var finished = 0
    /// Returns how many `.finished` events arrived so far.
    func append(_ e: ScanEvent) -> Int {
        lock.withLock {
            events.append(e)
            if case .finished = e { finished += 1 }
            return finished
        }
    }
    var finishedCount: Int { lock.withLock { finished } }
    var all: [ScanEvent] { lock.withLock { events } }
}

/// A recognizer that answers each call with the next scripted step (the last step repeats).
final class SequenceRecognizer: TextRecognizer, @unchecked Sendable {
    enum Step { case lines([OCRLine]); case error(OCRError) }
    private let lock = NSLock()
    private var steps: [Step]
    private(set) var calls = 0

    init(_ steps: [Step]) { self.steps = steps }

    func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine] {
        let step: Step = lock.withLock {
            calls += 1
            return steps.count > 1 ? steps.removeFirst() : steps[0]
        }
        switch step {
        case .lines(let lines): return lines
        case .error(let error): throw error
        }
    }
}

/// G-9: one ordered stream, a scan's start always ahead of its report.
@Suite(.serialized) struct ScanEventOrderTests {
    @Test func aBurstOfSubmissionsYieldsEachStartBeforeItsFinish() async throws {
        let h = try Harness(recognizer: ScriptedRecognizer(lines: [Fixture.keyLine], delay: .milliseconds(5)))
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("order")
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = Fixture.pngData()
        var files: [URL] = []
        for i in 0..<16 {
            let f = dir.appendingPathComponent("Shot \(i).png")
            try png.write(to: f)
            files.append(f)
        }
        let stream = h.engine.events
        // 16 distinct files, then the first four again while they are still in flight (each repeat cancels and replaces
        // the older scan, which still reports): 20 starts, 20 finishes.
        for f in files { await h.engine.submit(.file(f, origin: .screenshotFolder)) }
        for f in files.prefix(4) { await h.engine.submit(.file(f, origin: .screenshotFolder)) }
        let events = await collectEvents(stream, finished: 20, timeout: .seconds(20))

        var open: [CaptureKey: Int] = [:]
        var finishes = 0
        for event in events {
            switch event {
            case .started(let start):
                open[start.key, default: 0] += 1
            case .finished(let report):
                let key = try #require(report.key)
                let waiting = open[key, default: 0]
                #expect(waiting > 0, "a report arrived before its start")
                open[key] = waiting - 1
                finishes += 1
                #expect(report.fileURL != nil && report.origin == .screenshotFolder, "every report names its file and origin")
            }
        }
        #expect(finishes == 20, "every start ends in exactly one report")
        #expect(open.values.allSatisfy { $0 == 0 })
    }
}

/// The redman gap: a failed or timed-out file is kept with its name, URL and origin, and can be checked again.
@Suite(.serialized) struct CheckAgainTests {
    /// A key line whose rect lies outside the 480 × 120 fixture: the finding maps to no paintable rect, so the scan
    /// fails in the render stage (`.failed(.render)`), the one engine failure a fixture can produce on purpose.
    static let offImageLine = OCRLine(index: 0, text: Fixture.keyLine.text, rect: CGRect(x: 5000, y: 5000, width: 440, height: 28))

    @Test func aFailedFileIsKeptWithItsOriginAndCheckAgainResubmitsIt() async throws {
        let recognizer = SequenceRecognizer([.lines([Self.offImageLine]), .lines([Fixture.keyLine])])
        let h = try Harness(recognizer: recognizer)
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("retry")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Report.png")
        try Fixture.pngData().write(to: file)
        let origin = FileOrigin.watched(dir)
        h.watch(dir, as: origin)

        let first = h.engine.outcomes
        await h.engine.submit(.file(file, origin: origin))
        let failed = try #require(await collect(first, count: 1, timeout: .seconds(5)).first)
        #expect(failed.outcome.engineError?.statLabel == "renderFailed", "\(failed.outcome.statLabel)")
        #expect(failed.displayName == "Report.png")
        #expect(failed.fileURL == file)
        #expect(failed.origin == origin)

        let before = await h.engine.currentStatus()
        let kept = try #require(before.unchecked.first)
        #expect(before.unchecked.count == 1)
        #expect(kept.displayName == "Report.png")
        #expect(kept.fileURL == file)
        #expect(kept.origin == origin)
        #expect(kept.reason == "renderFailed")
        #expect(before.problems.contains { $0.kind == .scanFailure })
        #expect(before.problems.first { $0.kind == .scanFailure }?.detail == "1", "a failed file that is also unchecked counts once")

        let second = h.engine.outcomes
        #expect(await h.engine.retry(file) == origin, "checked again with the origin it first came from")
        let checked = try #require(await collect(second, count: 1, timeout: .seconds(5)).first)
        #expect(checked.outcome.isRedacted)
        #expect(checked.origin == origin)
        #expect(recognizer.calls == 2)

        let after = await h.engine.currentStatus()
        #expect(after.unchecked.isEmpty, "a file that reached a verdict is no longer unchecked")
        #expect(!after.problems.contains { $0.kind == .scanFailure }, "its failure no longer holds the status at needs attention")
    }

    @Test func aTimedOutFileIsKeptAndCheckAgainForAllResubmitsEveryOne() async throws {
        let recognizer = SequenceRecognizer([.error(.timeout), .error(.timeout), .lines([])])
        let h = try Harness(recognizer: recognizer)
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("timeout")
        defer { try? FileManager.default.removeItem(at: dir) }
        // F26: each file sits in the folder its origin names, watched as the settings would have it.
        let shots = dir.appendingPathComponent("Shots", isDirectory: true), downloads = dir.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        h.watch(shots, as: .screenshotFolder)
        h.watch(downloads, as: .downloads)
        let a = shots.appendingPathComponent("A.png"), b = downloads.appendingPathComponent("B.png")
        try Fixture.pngData().write(to: a)
        try Fixture.pngData().write(to: b)

        let first = h.engine.outcomes
        await h.engine.submit(.file(a, origin: .screenshotFolder))
        await h.engine.submit(.file(b, origin: .downloads))
        let timedOut = await collect(first, count: 2, timeout: .seconds(5))
        #expect(timedOut.allSatisfy { $0.outcome.skipReason == .ocrTimeout })
        let kept = await h.engine.currentStatus().unchecked
        #expect(Set(kept.map(\.fileURL)) == [a, b])
        #expect(kept.first { $0.fileURL == b }?.origin == .downloads)
        let status = await h.engine.currentStatus()
        #expect(status.problems.first { $0.kind == .scanFailure }?.detail == "2", "timeouts count as images that weren't checked")
        if case .needsAttention = status.protection {} else { Issue.record("a timed-out file holds the status at needs attention") }

        let second = h.engine.outcomes
        #expect(await h.engine.retryUnchecked() == 2)
        let checked = await collect(second, count: 2, timeout: .seconds(5))
        #expect(checked.count == 2 && checked.allSatisfy { $0.outcome.isClean })
        #expect(Set(checked.compactMap(\.origin)) == [.screenshotFolder, .downloads])
        let cleared = await h.engine.currentStatus()
        #expect(cleared.unchecked.isEmpty)
        #expect(!cleared.problems.contains { $0.kind == .scanFailure }, "checked again, nothing is left unchecked")
    }

    @Test func everyOutcomeThatLeavesThePictureAsItWasIsKept() {
        #expect(ShieldEngine.uncheckedReason(for: .skipped(.ocrTimeout)) == .ocrTimeout)
        #expect(ShieldEngine.uncheckedReason(for: .skipped(.ocrFailed)) == .ocrFailed)
        #expect(ShieldEngine.uncheckedReason(for: .skipped(.queueFull)) == .queueFull)
        #expect(ShieldEngine.uncheckedReason(for: .failed(.journal("disk"))) == .journalFailed)
        // Fail-open #2: a picture that could not be opened or read, or is too large, is "Not checked", never quiet.
        #expect(ShieldEngine.uncheckedReason(for: .skipped(.decodeFailed)) == .decodeFailed)
        #expect(ShieldEngine.uncheckedReason(for: .skipped(.unsupportedImage)) == .unsupportedImage)
        #expect(ShieldEngine.uncheckedReason(for: .skipped(.unreadable)) == .unreadable)
        #expect(ShieldEngine.uncheckedReason(for: .skipped(.tooLarge)) == .tooLarge)
        #expect(ShieldEngine.uncheckedReason(for: .failed(.writeBack("read-only"))) == nil, "its entry exists; the fix is Copy Clean")
        #expect(ShieldEngine.uncheckedReason(for: .skipped(.notAnImage)) == nil, "an extension the filter excluded before any read")
        #expect(ShieldEngine.uncheckedReason(for: .skipped(.cancelled)) == nil)
        #expect(ShieldEngine.uncheckedReason(for: .clean(duration: .milliseconds(5))) == nil)
    }

    @Test func aFileTheEngineNoLongerRemembersTakesItsWatchedFolderOrImported() {
        let home = URL(fileURLWithPath: "/home/example", isDirectory: true)
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let shots = downloads.appendingPathComponent("Shots", isDirectory: true)
        let roots = [WatchedRoot(url: desktop, origin: .screenshotFolder), WatchedRoot(url: downloads, origin: .downloads),
                     WatchedRoot(url: shots, origin: .watched(shots))]
        #expect(ShieldEngine.origin(of: desktop.appendingPathComponent("a.png"), in: roots) == .screenshotFolder)
        #expect(ShieldEngine.origin(of: downloads.appendingPathComponent("b.png"), in: roots) == .downloads)
        #expect(ShieldEngine.origin(of: shots.appendingPathComponent("c.png"), in: roots) == .watched(shots), "the deepest folder wins")
        #expect(ShieldEngine.origin(of: home.appendingPathComponent("Desktop2/d.png"), in: roots) == .imported,
                "a sibling with the same prefix is not inside")
        #expect(ShieldEngine.origin(of: home.appendingPathComponent("e.png"), in: roots) == .imported)
    }

    @Test func checkAgainOnAnUnknownFileOutsideEveryWatchedFolderChecksItAsAnImport() async throws {
        var settings = Settings.default
        settings.guardsScreenshotFolder = false
        settings.guardsDownloads = false
        settings.extraFolders = []
        let h = try Harness(recognizer: StubTextRecognizer(lines: []), settings: settings)
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("unknown")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Old.png")
        try Fixture.pngData().write(to: file)
        let stream = h.engine.outcomes
        #expect(await h.engine.retry(file) == .imported)
        let report = try #require(await collect(stream, count: 1, timeout: .seconds(5)).first)
        #expect(report.origin == .imported)
        #expect(report.outcome.isClean)
    }
}
