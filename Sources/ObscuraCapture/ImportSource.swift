public import Foundation
import ObscuraSupport

/// A manual source: files the user drops, opens or passes on the command line. `submit` emits each URL as
/// `.file(url, origin: .imported)` immediately; there is no settle step because the file is already complete.
public struct ImportSource: CaptureSource {
    public let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation

    public init() {
        let (stream, continuation) = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = continuation
    }

    public func start() async throws {}
    public func stop() async {}

    /// Emits one event per URL, in order.
    public func submit(_ urls: [URL]) {
        for url in urls {
            continuation.yield(.file(url, origin: .imported))
        }
        Log.capture.debug("import: \(urls.count) files submitted")
    }
}
