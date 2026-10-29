// ObscuraThumbnailUI — the thumbnail's side effects on the Mac: Preview, Finder, the clipboard, the Trash, and a
// downsampled image of a screenshot file (or of a covered shot's clean bytes) for the card.
import AppKit
import Foundation
import ImageIO
import ObscuraSupport

@MainActor
final class LiveThumbnailSystem: ThumbnailSystem {
    static let previewBundleID = "com.apple.Preview"

    func mouseLocation() -> CGPoint { NSEvent.mouseLocation }

    var hasDisplay: Bool { !NSScreen.screens.isEmpty }

    func fileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Opens the file in Preview and brings Preview forward. Preview has no supported way to be asked for its Markup
    /// toolbar: its scripting dictionary is the Standard Suite only and NSWorkspace passes no arguments, so Preview
    /// opens the way the user left it (View › Show Markup Toolbar, ⇧⌘A, is remembered by Preview itself).
    func openInPreview(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.previewBundleID) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: configuration) { _, error in
            if error != nil { Log.app.error("thumbnail: Preview did not open the file") }
        }
    }

    func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The file and its image, as Finder's Copy does. This is the user's own copy, not the guard's write, so the clipboard
    /// guard checks it: it reads the copied file itself (a file reference to an image file is checked like a copied
    /// image, fail-open #9; before that fix a file reference made the guard skip the copy entirely). The card offers this
    /// only for a shot already checked clean, so that check normally finds nothing; if it does find something, the
    /// clipboard gets the covered picture.
    func copyFile(_ url: URL) {
        let board = NSPasteboard.general
        board.clearContents()
        var objects: [any NSPasteboardWriting] = [url as NSURL]
        if let image = NSImage(contentsOf: url) { objects.append(image) }
        board.writeObjects(objects)
    }

    func moveToTrash(_ urls: [URL]) {
        for url in urls {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            catch { Log.app.error("thumbnail: move to Trash failed") }
        }
    }

    func loadImage(_ url: URL) async -> NSImage? {
        let image = await Task.detached(priority: .userInitiated) { ThumbnailImage.downsample(url) }.value
        return image.map { NSImage(cgImage: $0.cgImage, size: .zero) }
    }

    func decodeImage(_ data: Data) async -> NSImage? {
        let image = await Task.detached(priority: .userInitiated) { ThumbnailImage.downsample(data) }.value
        return image.map { NSImage(cgImage: $0.cgImage, size: .zero) }
    }
}

/// A screenshot file decoded at card size (2× the 176 × 110 pt card, with room for fill cropping).
struct ThumbnailImage: @unchecked Sendable {
    let cgImage: CGImage

    static let maxPixelSize = 720

    static func downsample(_ url: URL) -> ThumbnailImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return downsample(source)
    }

    /// The same for image bytes already in memory (a covered shot's clean image, read from the Journal).
    static func downsample(_ data: Data) -> ThumbnailImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return downsample(source)
    }

    /// Decoded here, off the main thread, so the first frame of the slide draws a ready bitmap.
    private static func downsample(_ source: CGImageSource) -> ThumbnailImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(ThumbnailImage.init)
    }
}
