import Foundation

/// A `SettingsWriter` that lives only in memory: tests and the `obscura` CLI use it.
/// Behaves exactly like `UserDefaultsSettingsStore` minus persistence and external-change observation.
public final class InMemorySettingsStore: SettingsWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: Settings
    private let broadcaster = SettingsBroadcaster()

    public init(_ settings: Settings = .default) {
        self.settings = settings
    }

    public func current() -> Settings {
        lock.withLock { settings }
    }

    public var changes: AsyncStream<Settings> {
        broadcaster.makeStream()
    }

    public func update(_ transform: @Sendable (inout Settings) -> Void) {
        let emitted: Settings? = lock.withLock {
            var next = settings
            transform(&next)
            guard next != settings else { return nil }
            settings = next
            return next
        }
        if let emitted { broadcaster.send(emitted) }
    }
}
