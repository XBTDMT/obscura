// Timeout race used by VisionTextRecognizer. Internal; tested directly through @testable import.
import Foundation

/// Runs `operation` on a detached task at `priority` and races it against `timeout`.
/// Whichever finishes first wins; the loser is cancelled. Cancelling the caller cancels the work and throws `.cancelled`.
/// Built on a one-shot continuation rather than a task group so a Vision call that ignores cancellation cannot
/// hold the caller past the deadline (a group would await every child before returning).
/// The work is not forgotten when the caller moves on (fail-open #15): inside an `OCRQueue` turn it is counted in the
/// turn's `WorkLedger` from before it starts until its closure really returns, so the queue keeps the turn until work
/// the deadline abandoned has ended, and never starts the next image's recognition beside it.
enum Deadline {
    static func run<T: Sendable>(timeout: Duration,
                                 priority: TaskPriority = .userInitiated,
                                 _ operation: @escaping @Sendable () async throws -> T) async throws(OCRError) -> T {
        let slot = OneShot<T>()
        // Task-locals do not reach a detached task, so the turn's ledger is carried in by hand (nested deadlines, such
        // as the recognizer's own inside the queue's backstop, register with the same ledger).
        let ledger = WorkLedger.current
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                    ledger?.begin()
                    let work = Task.detached(priority: priority) {
                        defer { ledger?.end() }
                        await WorkLedger.$current.withValue(ledger) {
                            do {
                                let value = try await operation()
                                slot.resolve(.success(value))
                            } catch is CancellationError {
                                slot.resolve(.failure(OCRError.cancelled))
                            } catch let error as OCRError {
                                slot.resolve(.failure(error))
                            } catch {
                                slot.resolve(.failure(OCRError.failed(underlying: error)))
                            }
                        }
                    }
                    let timer = Task.detached(priority: priority) {
                        do { try await Task.sleep(for: timeout) } catch { return }
                        slot.resolve(.failure(OCRError.timeout))
                    }
                    slot.arm(continuation: continuation, work: work, timer: timer)
                }
            } onCancel: {
                slot.resolve(.failure(OCRError.cancelled))
            }
        } catch let error as OCRError {
            throw error
        } catch {
            throw .failed(underlying: error)
        }
    }
}

/// The recognition work one `OCRQueue` turn started that has not ended yet (fail-open #15). `Deadline.run` counts
/// each piece of work from before it starts until its closure returns, whether its caller still waits for it or a
/// deadline gave up on it; the queue releases the turn only once the count is back to zero.
final class WorkLedger: @unchecked Sendable {
    @TaskLocal static var current: WorkLedger?

    private let lock = NSLock()
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func begin() { lock.withLock { running += 1 } }

    func end() {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            running -= 1
            guard running == 0 else { return [] }
            defer { waiters = [] }
            return waiters
        }
        ready.forEach { $0.resume() }
    }

    /// Work started and not yet ended.
    var outstanding: Int { lock.withLock { running } }

    /// Returns once no work is outstanding (at once when none is).
    func drained() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock {
                if running == 0 { return true }
                waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }
}

/// Lock-guarded one-shot: the first `resolve` wins, resumes the continuation once and cancels both racers.
/// `arm` may run after `resolve` (the caller was cancelled before the continuation existed); it then resumes immediately.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var pending: Result<T, any Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func arm(continuation: CheckedContinuation<T, any Error>, work: Task<Void, Never>, timer: Task<Void, Never>) {
        let fire: Result<T, any Error>? = lock.withLock {
            self.work = work
            self.timer = timer
            if let pending {
                return pending
            }
            self.continuation = continuation
            return nil
        }
        if let fire {
            work.cancel(); timer.cancel()
            continuation.resume(with: fire)
        }
    }

    func resolve(_ result: Result<T, any Error>) {
        let (continuation, work, timer): (CheckedContinuation<T, any Error>?, Task<Void, Never>?, Task<Void, Never>?) = lock.withLock {
            if pending != nil { return (nil, nil, nil) }
            pending = result
            defer { self.continuation = nil }
            return (self.continuation, self.work, self.timer)
        }
        work?.cancel(); timer?.cancel()
        continuation?.resume(with: result)
    }
}
