// ObscuraEngine — fan-out of one value to any number of AsyncStream consumers (status, outcomes).
import Foundation

final class Broadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var latest: Element?

    init(replayLatest: Bool = false) { self.replayLatest = replayLatest }
    private let replayLatest: Bool

    func makeStream() -> AsyncStream<Element> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let replay: Element? = lock.withLock {
                continuations[id] = continuation
                return replayLatest ? latest : nil
            }
            if let replay { continuation.yield(replay) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
            }
        }
    }

    func send(_ element: Element) {
        let targets: [AsyncStream<Element>.Continuation] = lock.withLock {
            latest = element
            return Array(continuations.values)
        }
        for c in targets { c.yield(element) }
    }

    var subscriberCount: Int { lock.withLock { continuations.count } }
}
