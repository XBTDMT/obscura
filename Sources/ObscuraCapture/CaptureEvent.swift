public import Foundation
public import UniformTypeIdentifiers

/// Where a captured file came from. The engine uses it for the Journal's `source` column and for
/// write-back policy (a screenshot is replaced in place; an import is never touched on disk).
public enum FileOrigin: Sendable, Hashable {
    case screenshotFolder
    case downloads
    case watched(URL)
    case imported
}

/// One image entering the pipeline. Spec: ARCHITECTURE.md §3 event flow, §7.
public enum CaptureEvent: Sendable {
    /// A file that has finished settling on disk (spec §4 row 3) in a watched folder, or a manual import.
    case file(URL, origin: FileOrigin)
    /// Raw image bytes read from the pasteboard (PNG preferred, TIFF otherwise). `changeCount` is the
    /// pasteboard generation the bytes were read from; `preservedText` is the `public.utf8-plain-text`
    /// representation that sat beside the image, so the write-back can keep it (spec §4 row 4, "differs").
    case pasteboardImage(Data, uti: UTType, changeCount: Int, preservedText: String?)
    /// File references to image files on the pasteboard (a Finder copy, a file copied from an app): pasting them hands
    /// over the files themselves, so the files are what gets checked, not the icon or thumbnail beside them (fail-open #9).
    case pasteboardFiles([URL], changeCount: Int, preservedText: String?)
}

/// A producer of capture events. Each source owns one `AsyncStream` for its whole lifetime: it survives
/// `stop()`/`start()` cycles and is finished only when the source is deallocated. Exactly one consumer
/// (the engine) iterates it.
public protocol CaptureSource: Sendable {
    var events: AsyncStream<CaptureEvent> { get }
    func start() async throws
    func stop() async
}
