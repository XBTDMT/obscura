// ObscuraNotifyUI — the small picture on a catch banner (G-19 #10, ruled 2026-10-27: "crop"): a square crop of
// the CLEAN, covered image around the finding, the way open-calls.html #10 draws it (the cover bar across the middle of
// the crop, a line of the screenshot above and below). Only the clean image is ever read, and only for an entry whose
// every finding is covered, so the crop can never show a secret; it is written to a temporary file for
// UNNotificationAttachment and deleted once the request is posted. Nothing here logs text.
import CoreGraphics
import Foundation
import ImageIO
import ObscuraJournal
import ObscuraSupport
import UniformTypeIdentifiers

/// Where on the image the banner's crop is taken. Pure, in image pixels (top-left origin, as `Finding.rect`).
enum CatchCrop {
    /// The crop's side, in finding heights: the cover bar with about one line above and below it.
    static let heightMultiple: CGFloat = 3
    /// The smallest side, so a tiny finding still makes a readable picture.
    static let minimumSide: CGFloat = 64

    /// A square around `finding`, centred on it, `heightMultiple` finding heights wide (at least `minimumSide`, at most
    /// the image's shorter side), moved inside the image where it would cross an edge. Nil when the image is empty or
    /// the finding lies outside it.
    static func rect(imageSize: CGSize, finding: CGRect) -> CGRect? {
        let bounds = CGRect(origin: .zero, size: imageSize)
        guard imageSize.width >= 1, imageSize.height >= 1 else { return nil }
        let visible = finding.standardized.intersection(bounds)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        let side = min(max(visible.height * heightMultiple, minimumSide), imageSize.width, imageSize.height).rounded(.down)
        guard side >= 1 else { return nil }
        let x = min(max(visible.midX - side / 2, 0), imageSize.width - side).rounded(.down)
        let y = min(max(visible.midY - side / 2, 0), imageSize.height - side).rounded(.down)
        return CGRect(x: x, y: y, width: side, height: side)
    }
}

enum CatchPicture {
    /// Writes the banner's crop of the entry's clean image to a new temporary PNG and returns its URL, or nil when there
    /// is nothing safe to show: a finding left visible (the clean image shows it), no findings, a clean picture the
    /// Journal does not trust, or an image that does not decode. The caller deletes the file after posting.
    ///
    /// The flags and the bytes come from one Journal read at one revision (`cleanImage`, fail-open #14): an Undo that
    /// lands between "every finding is covered" and reading the picture can no longer put the original in the crop.
    static func write(entryID: UUID, journal: any JournalStore, directory: URL = FileManager.default.temporaryDirectory) async -> URL? {
        guard let image = try? await journal.cleanImage(entryID), image.coversEverything, let first = image.entry.findings.first else { return nil }
        let clean = image.data
        guard let source = CGImageSourceCreateWithData(clean as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let rect = CatchCrop.rect(imageSize: CGSize(width: image.width, height: image.height), finding: first.rect),
              let crop = image.cropping(to: rect) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, crop, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let url = directory.appendingPathComponent("obscura-catch-\(UUID().uuidString).png")
        do {
            try FileAtomics.write(data as Data, to: url, mode: .privateToUser)
        } catch {
            Log.app.error("catch picture not written")
            return nil
        }
        return url
    }
}
