// ObscuraEngine — the heavy, pure stages of ARCHITECTURE.md §4, kept off the actor. Every function here is
// nonisolated and async or static so it runs on the cooperative pool, never on ShieldEngine's executor.
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ObscuraDetect
import ObscuraOCR
import ObscuraRender
import ObscuraSupport
import UniformTypeIdentifiers

/// A decoded image plus the metadata we re-attach on encode. Sendable so it can leave the decode task.
struct PreparedImage: Sendable {
    let image: CGImage
    let uti: UTType
    let dpi: CGSize?
    /// How many images the container holds; `image` is one of them (fail-open #6).
    var frameCount: Int = 1
    var width: Int { image.width }
    var height: Int { image.height }
    var pixels: Int { image.width * image.height }

    /// The container the clean image is written in (ImageCodec rule: PNG/JPEG/HEIC keep theirs, others → PNG).
    var outputUTI: UTType {
        if uti.conforms(to: .jpeg) { return .jpeg }
        if uti.conforms(to: .heic) { return .heic }
        return .png
    }
}

/// Why a watched file was not read (security scan F19): what the folder watcher checked when its event arrived no longer
/// holds at the moment of reading.
enum WatchedFileRefusal: Error {
    /// The name is now a symbolic link.
    case symbolicLink
    /// Not a regular file (a folder, a FIFO, a device).
    case notRegularFile
    /// Its real path is outside every watched folder.
    case outsideWatchedFolders
}

enum DecodeFailure: Error {
    /// A real image container ImageIO knows that Obscura does not read (`SkipReason.unsupportedImage`).
    case unsupportedImage
    /// The bytes do not decode as an image (`SkipReason.decodeFailed`).
    case decodeFailed
    /// The container stops before it says it ends: still being written or cut short (`SkipReason.incomplete`).
    case incomplete
    /// A page that would be drawn larger than the render ceiling (`SkipReason.tooLarge`).
    case tooLarge
}

/// One finding placed on the image, with what the Journal needs to store about it (never its text, nor a hash of it).
struct MappedFinding: Sendable {
    let placed: PlacedFinding
    let lineIndex: Int
    let detectorIDs: [String]
    let category: String
}

enum Pipeline {
    // MARK: Row 5 — decode

    static func decode(_ data: Data, frame: Int = 0) async throws(DecodeFailure) -> PreparedImage {
        do {
            // The render ceiling applies before a pixel is decoded (security scan F11), not only to what decode returns.
            let decoded = try ImageCodec.decode(data, frame: frame, maxPixels: PipelineConstants.maxRenderPixels)
            return PreparedImage(image: decoded.image, uti: decoded.uti, dpi: decoded.dpi, frameCount: decoded.frameCount)
        } catch ImageCodecError.unsupportedContainer {
            throw .unsupportedImage
        } catch ImageCodecError.incomplete {
            throw .incomplete
        } catch ImageCodecError.tooLarge {
            throw .tooLarge
        } catch {
            throw .decodeFailed
        }
    }

    static func readFile(_ url: URL, maxBytes: Int) async throws -> Data? {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > maxBytes { return nil }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    /// Reads a file a watched folder handed over (or a Check Again of one), checking again at the moment of reading what
    /// the folder watcher checked when its event arrived (security scan F19): the file is opened without following a
    /// symbolic link as its last component, it is a regular file (fstat on that descriptor), and, when `roots` is given,
    /// its real path (F_GETPATH on the descriptor, so a folder above it swapped for a link is caught too) lies inside one
    /// of them. The bytes are read through the same descriptor, so what was checked is what is read. nil: larger than
    /// `maxBytes`. A refusal throws `WatchedFileRefusal`, which the engine ends "not checked" (unreadable).
    static func readWatchedFile(_ url: URL, roots: [URL]?, maxBytes: Int) async throws -> Data? {
        // O_NONBLOCK: a FIFO swapped in opens at once (and is then refused) instead of blocking the read forever.
        let fd = open(url.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == ELOOP { throw WatchedFileRefusal.symbolicLink }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw WatchedFileRefusal.notRegularFile }
        if let roots {
            guard let real = realPath(of: fd), roots.contains(where: { root in realPath(of: root).map { real.hasPrefix($0) } ?? false }) else {
                throw WatchedFileRefusal.outsideWatchedFolders
            }
        }
        if info.st_size > maxBytes { return nil }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        return data.count > maxBytes ? nil : data
    }

    /// The path the kernel holds for an open file: every link resolved, as it is now.
    private static func realPath(of fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// A folder's real path with a trailing slash (a prefix of the real path of everything inside it); nil when it does
    /// not exist.
    private static func realPath(of folder: URL) -> String? {
        guard let resolved = realpath(folder.path(percentEncoded: false), nil) else { return nil }
        defer { free(resolved) }
        let path = String(cString: resolved)
        return path.hasSuffix("/") ? path : path + "/"
    }

    // MARK: Rows 7–13 — order, detect, map

    /// Scans the reading (and its re-reads) and places every finding (RecallPipeline, off the actor).
    static func detect(_ reading: RecallReading, image: CGImage, scanner: ObscuraDetect.Scanner,
                       titles: [String: String]) async -> ImageDetection {
        RecallPipeline.detect(reading, image: image, scanner: scanner, imageSize: CGSize(width: image.width, height: image.height), titles: titles)
    }

    // MARK: Rows 15–19 — render and encode

    static func render(_ prepared: PreparedImage, findings: [PlacedFinding], style: StyleSpec, redactedWord: String) async throws(EngineError) -> CGImage {
        do {
            return try Redactor.render(prepared.image, findings: findings, style: style, environment: RenderEnvironment(redactedWord: redactedWord))
        } catch {
            throw .render(String(describing: error))
        }
    }

    static func encode(_ image: CGImage, like prepared: PreparedImage) async throws(EngineError) -> Data {
        do {
            return try ImageCodec.encode(image, as: prepared.outputUTI, dpi: prepared.dpi, quality: PipelineConstants.jpegQuality)
        } catch {
            throw .encode(String(describing: error))
        }
    }

    static func encodePNG(_ image: CGImage, dpi: CGSize?) async throws(EngineError) -> Data {
        do { return try ImageCodec.encode(image, as: .png, dpi: dpi, quality: nil) } catch { throw .encode(String(describing: error)) }
    }

    /// TIFF for the pasteboard, made from the rendered image so the two representations agree pixel for pixel.
    static func encodeTIFF(_ image: CGImage) async throws(EngineError) -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let tiff = rep.tiffRepresentation else { throw .encode("TIFF representation unavailable") }
        return tiff
    }

    // MARK: Warm-up

    /// A tiny image with a harmless word drawn through CoreText; recognizing it loads Vision's models.
    static func warmupImage() -> CGImage? {
        let size = PipelineConstants.warmupImageSize
        let width = Int(size.width), height = Int(size.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)]
        guard let attributed = CFAttributedStringCreate(nil, PipelineConstants.warmupWord as CFString, attrs as CFDictionary) else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 4, y: 3)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }
}
