// ObscuraEngine — every constant of ARCHITECTURE.md §4, with the reason it has the value it has.
// The spec table is the source of truth; this file is its executable form. Change both or neither.
public import Foundation
public import ObscuraPrefs
import ObscuraSupport

public enum PipelineConstants {
    // MARK: Row 1 — FSEvents watch

    /// FSEvents latency. 0.05 s is the lowest value that does not produce event storms on a busy folder
    /// while still delivering a screenshot well inside the user's attention span.
    public static let fsEventsLatency: TimeInterval = 0.05

    /// How often the screenshot folder setting (`com.apple.screencapture location`) is re-read.
    /// The user changes it rarely; 15 min keeps the maintenance tick cheap and the drift short.
    public static let screenshotFolderRereadInterval: Duration = .seconds(15 * 60)

    // MARK: Row 2 — Event filter

    /// Lowercased extensions the watcher accepts. Matches `ImageCodec.supportedInput`; anything else is
    /// `SkipReason.notAnImage` before a byte is read.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"]

    /// Own-write suppression TTL. A write-back is followed by its FSEvents echo within milliseconds; 5 s
    /// covers slow disks without hiding a real new file saved under the same name later.
    public static let ignoredPathTTL: Duration = .seconds(5)

    /// How long the version of a file that was handed over is remembered, keyed on its identity (device, inode, size,
    /// modification time), so Created+Modified+Renamed of one version emit once and a rewrite is a new version.
    public static let recentlyHandledTTL: Duration = .seconds(30)

    /// A file older than this when it appears was renamed into the folder, not captured; it is not a screenshot.
    public static let creationAgeCutoff: TimeInterval = 20

    // MARK: Row 3 — Settle

    /// Poll period for the file's identity while it is still being written.
    public static let settlePoll: Duration = .milliseconds(50)
    /// The file must be unchanged for this long, and its container whole, before decoding.
    public static let settleStable: Duration = .milliseconds(120)
    /// A file still changing or unfinished at this bound enters the pipeline anyway, where an incomplete container is
    /// "not checked" (never judged on its top part), and the watcher keeps watching it (fail-open #5).
    public static let settleMax: Duration = .seconds(2)
    /// How often such a file is looked at after the bound: one stat call per tick.
    public static let settleWatchPoll: Duration = .milliseconds(500)
    /// How long after the bound its finished version is waited for: a slow download or network copy.
    public static let settleWatchMax: Duration = .seconds(600)

    // MARK: Row 4 — Clipboard poll

    /// Timer period. 0.35 s is the gap between a copy and a paste a user can perceive; a changeCount read is cheap.
    public static let clipboardPollInterval: TimeInterval = 0.35
    /// Timer tolerance; lets the system coalesce wake-ups.
    public static let clipboardPollTolerance: TimeInterval = 0.15
    /// After a ⌘C inside our own windows the next changes are trusted for this long.
    public static let clipboardTrustWindow: Duration = .seconds(2)

    // MARK: Row 5 — Decode

    /// Above this many pixels OCR runs on a downscaled copy (render still runs at full size).
    /// 24 MP is a 6K screenshot; Vision's accuracy on text stops improving beyond ~4K per side.
    public static let ocrPixelBudget = 24_000_000
    /// Longest side of the OCR working copy when the budget is exceeded.
    public static let ocrMaxLongestSide = 4096
    /// Hard ceiling on pixels we will render at all. The render context is 4 bytes/px, so 200 MP ≈ 800 MB;
    /// above that the image is `SkipReason.tooLarge` rather than a memory death.
    public static let maxRenderPixels = InputLimits.maxPixels
    /// Hard ceiling on encoded bytes read from disk or the pasteboard. No screenshot is this big; a file this
    /// size is a different kind of file and is `SkipReason.tooLarge`.
    public static let maxInputBytes = InputLimits.maxInputBytes

    /// Every frame of a multi-frame picture is read (fail-open #6), one recognition per frame through the serial queue.
    /// 120 frames is about 10 s of warm reading (85 ms median), the longest one animation may hold the queue; a picture
    /// with more frames is "not checked" with a notice rather than read in part.
    public static let maxCheckedFrames = 120

    /// The most plain text copied beside an image that is checked, in UTF-16 units (security scan F9). Anything a page
    /// or app can put on the pasteboard reaches the Scanner, so its length is bounded before a regex runs. 128 Ki units
    /// is thousands of spreadsheet cells or terminal lines; the whole catalogue searches it in about half a second (about
    /// 3.4 µs per character, measured 2026-10-28 in a release build), off the engine actor and inside the Scanner's 5 s
    /// budget. Longer text is not checked and is left out of the write-back as if it held a secret.
    public static let maxCompanionTextLength = 131_072

    // MARK: Row 6 — OCR

    /// Per-image Vision budget. Warm `.accurate` takes well under a second; 20 s only trips on a cold model
    /// load or a hung request, both of which must end in `skipped(.ocrTimeout)`, not a stuck queue.
    public static let ocrTimeout: Duration = .seconds(20)

    /// The per-image OCR deadline a scan runs under with these settings (the user's `ocrTimeoutSeconds`, at least 1 s).
    /// The engine passes it to the OCR queue; the floating thumbnail's checking-card ceiling is derived from it, so the
    /// two cannot drift apart.
    public static func ocrDeadlineSeconds(_ settings: Settings) -> TimeInterval { max(1, settings.ocrTimeoutSeconds) }

    // MARK: Row 12 — Block scope

    /// How many lines a private-key block may run before it is cut. PEM bodies are ≤ 70 lines.
    public static let blockScopeMaxLines = 80

    // MARK: Row 13 — Box mapping

    /// Line rect inset used to accept a Vision glyph box (`BoxMapper`). Negative = grown.
    public static let boxAcceptanceInset: CGFloat = -4
    /// Final clip of a cover to the line rect, grown by this much so descenders are covered.
    public static let boxClipInset: CGFloat = -2

    // MARK: Row 19 — Encode

    /// JPEG re-encode quality. 0.92 is visually lossless for UI text and keeps the file near its input size.
    public static let jpegQuality = 0.92

    // MARK: Back-pressure (§3)

    /// Waiting OCR requests beyond this many evict the oldest *file* request (re-submitted once); clipboard
    /// requests are never evicted. 32 is a screenshot burst a human can produce before the first one finishes.
    public static let maxQueuedScans = 32
    /// How many times an evicted file request is re-submitted before it ends as `skipped(.queueFull)`.
    public static let queueFullRetries = 1

    // MARK: Warm-up

    /// Size of the warm-up image. Big enough for Vision to run the whole model path, tiny so it is cheap.
    public static let warmupImageSize = CGSize(width: 64, height: 16)
    /// The word drawn on the warm-up image. Not a secret, matches nothing in the catalogue.
    public static let warmupWord = "warm"

    // MARK: Maintenance (§4 footer)

    /// Retention prune, stale sweep, folder re-read, access re-probe period.
    public static let maintenanceInterval: Duration = .seconds(15 * 60)
    public static let maintenanceTolerance: Duration = .seconds(2 * 60)

    // MARK: Status

    /// Failed outcomes within this window keep the status at `needsAttention`.
    public static let recentFailureWindow: Duration = .seconds(15 * 60)
    /// How many times a re-render is applied again when another change to the same entry landed while it rendered (G-28).
    public static let pictureCommitAttempts = 5

    /// Default label word for `StyleSpec.LabelMode.redacted`; the app passes a localized one.
    public static let defaultRedactedWord = "REDACTED"
}
