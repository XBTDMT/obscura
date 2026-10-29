import Foundation

/// Read access to the current settings and a stream of every later value.
///
/// `changes` yields one `Settings` per committed change (never the current value first; call `current()` for that).
/// Each access returns an independent stream, so several consumers may listen at once.
public protocol SettingsReader: Sendable {
    func current() -> Settings
    var changes: AsyncStream<Settings> { get }
}

/// A `SettingsReader` that can also change the settings.
public protocol SettingsWriter: SettingsReader {
    /// Applies `transform` to the current settings atomically and emits the result on `changes` exactly once.
    /// A transform that leaves the settings unchanged emits nothing.
    func update(_ transform: @Sendable (inout Settings) -> Void)
}

/// Fan-out of `Settings` values to any number of `AsyncStream` consumers. Internal to the stores.
final class SettingsBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Settings>.Continuation] = [:]

    func makeStream() -> AsyncStream<Settings> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
            }
        }
    }

    func send(_ settings: Settings) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets { continuation.yield(settings) }
    }

    func finish() {
        let targets = lock.withLock {
            let values = Array(continuations.values)
            continuations.removeAll()
            return values
        }
        for continuation in targets { continuation.finish() }
    }
}
