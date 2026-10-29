public import AppKit
public import Foundation
public import ObscuraSupport
import UniformTypeIdentifiers

/// Constants for the clipboard poll (spec §4 row 4).
public struct ClipboardGuardConfig: Sendable {
    /// Timer period. One `changeCount` read per tick when nothing changed.
    public var pollInterval: TimeInterval = 0.35
    public var tolerance: TimeInterval = 0.15
    /// How long a ⌘C inside our own windows suppresses the guard.
    public var trustWindow: TimeInterval = 2.0
    /// Pasteboard types that mark content we never read: password managers and other concealed or
    /// transient writers (`ConcealedType` and `TransientType`, both honored).
    public var skipTypes: [String] = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
    /// Image payloads read from the pasteboard: every container the engine decodes, and PDF (Preview, Keynote and many
    /// apps copy a selection as PDF; the engine draws its pages). The first one in the pasteboard's own type order is
    /// read. Fail-open #9: PNG and TIFF alone left a copied JPEG, HEIC or PDF unchecked.
    public var imageTypes: [String] = ["public.png", "public.tiff", "public.jpeg", "public.heic", "public.heif",
                                       "com.compuserve.gif", "org.webmproject.webp", "com.microsoft.bmp", "com.adobe.pdf"]
    /// Extensions of copied files that are checked as images (the folder watcher's list).
    public var imageFileExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"]

    public init() {}
}

/// Watches a pasteboard for new images. Main-actor because `NSPasteboard` is main-thread friendly and the
/// timer lives on the main run loop (spec §3 isolation map).
@MainActor
public final class ClipboardGuard: CaptureSource {
    nonisolated public let events: AsyncStream<CaptureEvent>
    private nonisolated let continuation: AsyncStream<CaptureEvent>.Continuation

    private let pasteboard: NSPasteboard
    private let config: ClipboardGuardConfig
    private let clock: any WallClock
    private var timer: MainThreadTimer?
    private var lastChangeCount: Int
    /// The `changeCount` produced by our own `writeBack`; that generation is never inspected.
    private var ownWriteChangeCount: Int?
    private var trustedUntil: Date?

    public init(pasteboard: NSPasteboard = .general, config: ClipboardGuardConfig = .init(), clock: any WallClock = SystemClock()) {
        self.pasteboard = pasteboard
        self.config = config
        self.clock = clock
        self.lastChangeCount = pasteboard.changeCount
        let (stream, continuation) = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = continuation
    }

    deinit {
        // `timer` is a MainThreadTimer; releasing it invalidates the Timer on the main thread.
        continuation.finish()
    }

    public var isRunning: Bool { timer != nil }

    /// Installs the timer in `.common` modes so it keeps ticking while menus and modal panels are open.
    /// Safe to call repeatedly; a running guard is left alone.
    public func start() async throws {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: config.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = config.tolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = MainThreadTimer(timer)
        Log.capture.info("clipboard guard started")
    }

    public func stop() async {
        timer?.invalidate()
        timer = nil
        Log.capture.info("clipboard guard stopped")
    }

    /// Call after a ⌘C inside our own windows: the next changes for `duration` are not inspected.
    public func trust(for duration: Duration) {
        trustedUntil = clock.now().addingTimeInterval(duration.seconds)
    }

    /// Convenience over `trust(for:)` using the configured window.
    public func trust() {
        trust(for: .seconds(config.trustWindow))
    }

    /// The pasteboard's current generation. The engine reads it when a screenshot's check starts, so the picture it puts
    /// there afterwards (G-18) never replaces something copied in the meantime.
    public var changeCount: Int { pasteboard.changeCount }

    /// Puts a clean image back: PNG + TIFF (+ the preserved plain text), and remembers the resulting
    /// generation so the next tick skips it (spec §4 row 20).
    ///
    /// `expectedChangeCount` makes it a compare-and-swap (fail-open #18): when the pasteboard is no longer at that
    /// generation (the user copied something after the image being checked), nothing is written and false is returned,
    /// so an older scan finishing late never wipes a newer copy. The check and the write run in one main-actor turn;
    /// nil writes unconditionally (a user's own Copy, Undo).
    @discardableResult
    public func writeBack(png: Data, tiff: Data, preservedText: String?, expectedChangeCount: Int? = nil) -> Bool {
        if let expectedChangeCount, pasteboard.changeCount != expectedChangeCount {
            Log.capture.notice("clipboard write-back skipped: the clipboard changed since generation \(expectedChangeCount)")
            return false
        }
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        pasteboard.setData(tiff, forType: .tiff)
        if let preservedText {
            pasteboard.setString(preservedText, forType: .string)
        }
        ownWriteChangeCount = pasteboard.changeCount
        Log.capture.debug("clipboard write-back: \(png.count) PNG bytes, \(tiff.count) TIFF bytes, text \(preservedText == nil ? 0 : 1)")
        return true
    }

    /// One poll. Internal so tests can drive it without the run loop.
    func tick() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        if changeCount == ownWriteChangeCount { return }
        if let trustedUntil, clock.now() < trustedUntil {
            Log.capture.debug("clipboard change skipped: trust window")
            return
        }
        let types = pasteboard.types ?? []
        let skip = Set(config.skipTypes)
        if types.contains(where: { skip.contains($0.rawValue) }) {
            Log.capture.debug("clipboard change skipped: concealed or transient")
            return
        }
        let preservedText = types.contains(.string) ? pasteboard.string(forType: .string) : nil

        // Fail-open #9: a file reference no longer silences the guard. Copied image files are what a paste hands over,
        // so they are checked themselves; the icon or thumbnail an app puts beside them is not the picture.
        let files = imageFiles(types)
        if !files.isEmpty {
            continuation.yield(.pasteboardFiles(files, changeCount: changeCount, preservedText: preservedText))
            Log.capture.info("clipboard image file(s) captured: \(files.count), generation \(changeCount)")
            return
        }
        // Image data, whatever else is there (a file reference to something else, text, rich text). In the pasteboard's own
        // order: the writer's representations come before the ones macOS converts them to (a JPEG is also offered as
        // TIFF), so the bytes checked are the ones the app put there.
        let readable = Set(config.imageTypes)
        for type in types where readable.contains(type.rawValue) {
            guard let data = pasteboard.data(forType: type) else { continue }
            let identifier = type.rawValue
            let uti = UTType(identifier) ?? .image
            continuation.yield(.pasteboardImage(data, uti: uti, changeCount: changeCount, preservedText: preservedText))
            Log.capture.info("clipboard image captured: \(data.count) bytes, type \(identifier, privacy: .public), generation \(changeCount), text \(preservedText == nil ? 0 : 1)")
            return
        }
        // Nothing to check: the type names only, never content.
        Log.capture.debug("clipboard change without an image: \(types.map(\.rawValue).joined(separator: ","), privacy: .public)")
    }

    /// The file references on the pasteboard whose extension is an image's.
    private func imageFiles(_ types: [NSPasteboard.PasteboardType]) -> [URL] {
        guard types.contains(.fileURL) else { return [] }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { config.imageFileExtensions.contains($0.pathExtension.lowercased()) }
    }
}

/// Holds a run-loop timer and guarantees `invalidate()` runs on the main thread, where it was installed,
/// even if the owner's last reference is dropped elsewhere.
final class MainThreadTimer: @unchecked Sendable {
    private let timer: Timer
    init(_ timer: Timer) { self.timer = timer }
    func invalidate() { timer.invalidate() }
    deinit {
        let timer = timer
        if Thread.isMainThread {
            timer.invalidate()
        } else {
            DispatchQueue.main.async { timer.invalidate() }
        }
    }
}

extension Duration {
    var seconds: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
