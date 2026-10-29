// ObscuraEngine — how a scan ends. Error policy (ARCHITECTURE.md §3): every image that enters the pipeline
// ends in exactly one of these; nothing is dropped silently.
public import Foundation

public enum ScanOutcome: Sendable {
    /// The outcomes that leave an image without a verdict and that the user must hear about: the image is still as it
    /// was, possibly with a secret in it. Each is a "Not checked" row for a file (G-13) and a status count for a clipboard
    /// image (fail-open #2, #13). Not: a verdict, a cancellation (a newer scan replaced it), a pause (#21 lists those
    /// separately), a source switched off, or a file whose extension was never read.
    public var needsAttention: Bool {
        switch self {
        case .clean, .redacted: return false
        case .failed: return true
        case .skipped(let reason):
            switch reason {
            case .ocrTimeout, .ocrFailed, .queueFull, .tooLarge, .decodeFailed, .unsupportedImage, .unreadable, .incomplete,
                 .multiFrame, .severalFiles, .copiedFileNotGuarded, .writeFailed, .unreadPatch, .textNotRead: return true
            case .notAnImage, .cancelled, .protectionPaused, .sourceOff: return false
            }
        }
    }

    /// Findings were painted over, a Journal entry exists and the write-back happened (or was not wanted).
    case redacted(entryID: UUID, findings: Int, duration: Duration)
    /// OCR ran, nothing matched. Counted as `checked`; no entry, no write.
    case clean(duration: Duration)
    /// The image left the pipeline early for a known reason. Counted under `stats_days.skipped[reason]`.
    case skipped(SkipReason)
    /// A stage threw. Also counted under `skipped[reason]` so the panel can show "needs attention".
    case failed(EngineError)

    public var isRedacted: Bool { if case .redacted = self { return true } else { return false } }
    public var isClean: Bool { if case .clean = self { return true } else { return false } }
    public var skipReason: SkipReason? { if case .skipped(let r) = self { return r } else { return nil } }
    public var engineError: EngineError? { if case .failed(let e) = self { return e } else { return nil } }

    /// Short identifier for logs and stats; never image content.
    public var statLabel: String {
        switch self {
        case .redacted: return "redacted"
        case .clean: return "clean"
        case .skipped(let reason): return reason.rawValue
        case .failed(let error): return error.statLabel
        }
    }
}

public enum SkipReason: String, Sendable, Hashable, CaseIterable, Codable {
    /// The file's extension is not one Obscura reads, so not a byte of it was read (the only silent skip of a file).
    case notAnImage
    case tooLarge
    /// The bytes are an image container that does not decode (corrupt, or not the image its extension claims).
    case decodeFailed
    /// The bytes are a real image container Obscura does not read (ImageIO knows it; `ImageCodec.supportedInput` does not).
    case unsupportedImage
    /// The file could not be read at all: no permission, an I/O error, an iCloud file not downloaded, or it vanished.
    case unreadable
    /// The container stops before it says it ends: still being written, or cut short (fail-open #5).
    case incomplete
    /// A picture with several frames that holds a finding on one of them (or more frames than are read): it cannot be
    /// covered frame by frame yet, so it is left as it is, "not checked" (fail-open #6).
    case multiFrame
    /// Several image files were copied at once: one clipboard holds one covered picture, so they are left as they are,
    /// "not checked", with a notice (fail-open #9). Clipboard only; never a file's row.
    case severalFiles
    /// A file copied from outside the folders Obscura guards: never opened (F6/F12, G-35). Any process can put a file
    /// reference on the clipboard, so it is left as it is, "not checked", with a notice. Clipboard only.
    case copiedFileNotGuarded
    case ocrTimeout
    case ocrFailed
    /// G-40: Vision answered every call, but the picture's only unread parts are small spots that look like text to its
    /// rectangle detector and that no reading could read. Not a failure and no alarm: the file is listed under Not
    /// checked with the spots (`ScanReport.spots`) for the person to settle, and is never called clean before that.
    case unreadPatch
    /// G-40 (true wording): part of the picture looks like text but no reading could read it, and it is not the small-spot
    /// case: Vision answered every call with no text, so not `ocrFailed`. It keeps today's alarm, in true words.
    case textNotRead
    case writeFailed
    case cancelled
    case protectionPaused
    case queueFull
    /// The source that produced the event is switched off in Settings (an event raced the switch).
    case sourceOff
}

/// A stage that threw. The payload is a message for the log; it never contains recognized text.
public enum EngineError: Error, Sendable, Hashable {
    case render(String)
    case encode(String)
    case journal(String)
    case writeBack(String)
    case ocr(String)
    case catalogue(String)
    case entryNotFound(UUID)

    public var statLabel: String {
        switch self {
        case .render: return "renderFailed"
        case .encode: return "encodeFailed"
        case .journal: return "journalFailed"
        case .writeBack: return SkipReason.writeFailed.rawValue
        case .ocr: return SkipReason.ocrFailed.rawValue
        case .catalogue: return "catalogueFailed"
        case .entryNotFound: return "entryNotFound"
        }
    }
}

extension EngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .render(let m): return "Render failed: \(m)"
        case .encode(let m): return "Encode failed: \(m)"
        case .journal(let m): return "Journal failed: \(m)"
        case .writeBack(let m): return "Write-back failed: \(m)"
        case .ocr(let m): return "OCR failed: \(m)"
        case .catalogue(let m): return "Catalogue failed: \(m)"
        case .entryNotFound(let id): return "No Journal entry \(id.uuidString)"
        }
    }
}
