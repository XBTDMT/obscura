// Fail-open #15: a deadline that fires while Vision keeps running must not hand the queue to the next image. The
// caller gets its timeout at once (the image ends "not checked"), but the queue's turn is held until the abandoned
// work really ends, so two recognitions never overlap. Proved with a recognizer that ignores cancellation, the way a
// Vision request does once it has started.
import CoreGraphics
import Foundation
import Testing
@testable import ObscuraOCR

@Suite("OCR queue keeps its turn while abandoned work runs (fail-open #15)")
struct AbandonedWorkTests {
    /// Busy for `busy` on its first call in a way cancellation cannot stop (a dispatch timer, like a Vision request in
    /// flight); later calls return at once. Every call is recorded as entering and leaving, so overlap is measurable.
    /// `innerDeadline`: the recognizer races its own work against `options.timeout` (as VisionTextRecognizer does),
    /// so it gives up first and its work is abandoned inside the turn.
    struct UncancellableRecognizer: TextRecognizer {
        let recorder: CallRecorder
        let busy: Duration
        let innerDeadline: Bool

        func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine] {
            let work: @Sendable () async throws -> [OCRLine] = { [recorder, busy] in
                await recorder.enter("w\(image.width)")
                if image.width == 1 {
                    let nanoseconds = Int(busy / .nanoseconds(1))
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) { done.resume() }
                    }
                }
                await recorder.leave()
                return [OCRLine(index: 0, text: "w\(image.width)", rect: .zero)]
            }
            if innerDeadline { return try await Deadline.run(timeout: options.timeout, work) }
            return try await work()
        }
    }

    /// The first image times out; the second, already waiting, must not start until the first one's work has ended.
    func overlap(innerDeadline: Bool, timeout: Duration, busy: Duration) async throws -> (maxConcurrent: Int, timedOutBeforeWorkEnded: Bool) {
        let recorder = CallRecorder()
        let queue = OCRQueue(recognizer: UncancellableRecognizer(recorder: recorder, busy: busy, innerDeadline: innerDeadline))
        let started = ContinuousClock.now
        let first = Task { () -> Duration in
            do {
                _ = try await queue.recognize(blankImage(width: 1), options: OCROptions(timeout: timeout), priority: .file)
                Issue.record("the first image should time out")
            } catch OCRError.timeout {}
            return ContinuousClock.now - started
        }
        while await recorder.order.isEmpty { await Task.yield() }
        let second = Task { try await queue.recognize(blankImage(width: 2), options: OCROptions(timeout: .seconds(5)), priority: .file) }
        let timedOutAfter = try await first.value
        let lines = try await second.value
        #expect(lines.first?.text == "w2")
        #expect(await recorder.order == ["w1", "w2"])
        #expect(await queue.depth == 0)
        return (await recorder.maxConcurrent, timedOutAfter < busy)
    }

    @Test func aRecognizerThatIgnoresTheQueueDeadlineNeverOverlapsTheNextImage() async throws {
        // The queue's backstop is the timeout + 1 s, so the work must outlast that.
        let result = try await overlap(innerDeadline: false, timeout: .milliseconds(100), busy: .milliseconds(1800))
        #expect(result.timedOutBeforeWorkEnded, "the caller must get its timeout without waiting for the abandoned work")
        #expect(result.maxConcurrent == 1)
    }

    @Test func workTheRecognizerItselfAbandonsStillHoldsTheTurn() async throws {
        let result = try await overlap(innerDeadline: true, timeout: .milliseconds(100), busy: .milliseconds(700))
        #expect(result.timedOutBeforeWorkEnded)
        #expect(result.maxConcurrent == 1)
    }

    @Test func aTurnWhoseWorkEndedReleasesAtOnce() async throws {
        let recorder = CallRecorder()
        let queue = OCRQueue(recognizer: RecordingRecognizer(recorder: recorder, delay: .milliseconds(5)))
        _ = try await queue.recognize(blankImage(width: 3), options: OCROptions(), priority: .file)
        #expect(await queue.depth == 0)
        #expect(await queue.abandonedTurns == 0)
    }
}
