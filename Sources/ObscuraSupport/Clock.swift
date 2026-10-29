public import Foundation

/// Injectable wall clock so retention, trust windows and TTLs are testable without sleeping.
public protocol WallClock: Sendable {
    func now() -> Date
}

public struct SystemClock: WallClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// A clock tests can move by hand.
public final class ManualClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    public init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = start }
    public func now() -> Date { lock.withLock { current } }
    public func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}
