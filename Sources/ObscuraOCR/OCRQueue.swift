// Serial, bounded, two-class FIFO in front of a TextRecognizer (ARCHITECTURE.md §3 "Back-pressure and bursts").
import Foundation
public import CoreGraphics
import ObscuraSupport

public actor OCRQueue {
    private struct Waiter {
        let id: UInt64
        let priority: OCRPriority
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let recognizer: any TextRecognizer
    private let maxQueued: Int
    private var running = false
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0
    /// Turns whose caller has had its answer (a deadline fired) while work they started is still running (#15).
    private var abandoned = 0

    /// Requests in flight: the running one plus everything waiting. The UI shows "Checking N images…" from this.
    public var depth: Int { waiters.count + (running ? 1 : 0) }

    /// Turns held because work a deadline abandoned is still running (0 or 1: the queue runs one turn at a time).
    public var abandonedTurns: Int { abandoned }

    public init(recognizer: any TextRecognizer, maxQueued: Int = 32) {
        self.recognizer = recognizer
        self.maxQueued = max(1, maxQueued)
    }

    /// Runs exactly one recognition at a time. `.clipboard` requests go ahead of every waiting `.file` request.
    /// When the waiting list is full, the oldest waiting `.file` request is evicted with `OCRError.queueFull`
    /// (the file is still on disk; the caller re-submits). Clipboard requests are never evicted or refused.
    public func recognize(_ image: CGImage, options: OCROptions, priority: OCRPriority) async throws -> [OCRLine] {
        try await withTurn(priority: priority, timeout: options.timeout) { recognizer in
            try await recognizer.recognize(image, options: options)
        }
    }

    /// Runs `body` as one queue turn: every Vision request `body` makes for one image (pass 1 and the G-12 re-read)
    /// holds the queue together, under one backstop deadline. Same ordering, eviction and cancellation as `recognize`.
    ///
    /// Fail-open #15: a deadline (the backstop here, or the recognizer's own) answers the caller at once, but Vision
    /// does not stop when its task is cancelled. The turn is therefore held until every piece of work it started has
    /// really ended (`WorkLedger`), so the next image's recognition never runs beside an abandoned one: overlapping
    /// requests slow each other down, which turns one timeout into many and starves the G-12 re-reads (G-22).
    public func withTurn<T: Sendable>(priority: OCRPriority, timeout: Duration,
                                      _ body: @escaping @Sendable (any TextRecognizer) async throws -> T) async throws -> T {
        try await acquire(priority: priority)
        let ledger = WorkLedger()
        if Task.isCancelled {
            endTurn(ledger)
            throw OCRError.cancelled
        }
        // The backstop deadline starts here, when this image's turn has come: time spent waiting in the queue (behind
        // the cold-start warm-up, or a burst) is never charged to the image. One second over the recognizer's own
        // timeout, so a recognizer that ignores its deadline still ends as `.timeout` for its caller.
        let recognizer = self.recognizer
        do {
            let value = try await WorkLedger.$current.withValue(ledger) {
                try await Deadline.run(timeout: timeout + .seconds(1)) {
                    try await body(recognizer)
                }
            }
            endTurn(ledger)
            return value
        } catch {
            endTurn(ledger)
            throw error
        }
    }

    /// Hands the turn on now when the turn's work has all ended, else once it has (#15). Counts only in the log.
    private func endTurn(_ ledger: WorkLedger) {
        let outstanding = ledger.outstanding
        guard outstanding > 0 else {
            release()
            return
        }
        abandoned += 1
        Log.ocr.notice("ocr turn held: abandoned work still running pieces=\(outstanding) waiting=\(self.waiters.count)")
        Task {
            await ledger.drained()
            self.releaseAbandoned()
        }
    }

    private func releaseAbandoned() {
        abandoned -= 1
        Log.ocr.info("ocr turn released: abandoned work ended waiting=\(self.waiters.count)")
        release()
    }

    private func acquire(priority: OCRPriority) async throws {
        if !running && waiters.isEmpty {
            running = true
            return
        }
        if waiters.count >= maxQueued {
            if let victim = waiters.firstIndex(where: { $0.priority == .file }) {
                let evicted = waiters.remove(at: victim)
                Log.ocr.notice("ocr queue full depth=\(self.depth) evicted oldest file request")
                evicted.continuation.resume(throwing: OCRError.queueFull)
            } else if priority == .file {
                Log.ocr.notice("ocr queue full of clipboard requests depth=\(self.depth) refused file request")
                throw OCRError.queueFull
            }
        }
        let id = nextID
        nextID &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: OCRError.cancelled)
    }

    private func release() {
        guard let index = waiters.firstIndex(where: { $0.priority == .clipboard }) ?? waiters.indices.first else {
            running = false
            return
        }
        let next = waiters.remove(at: index)
        running = true
        next.continuation.resume()
    }
}
