// The viewer's own words. Verdict titles and details come from the kit (Verdict); these are the sentences only this
// window says, in sentence case, plurals handled.
import Foundation
import UniformTypeIdentifiers
import ObscuraUIKit
import ObscuraJournal

enum ViewerCopy {
    /// The red subtitle and banner line while Original shows.
    static var originalWarning: String { String(localized: "Original showing. Every secret is visible.") }
    static var originalBannerTrailing: String { String(localized: "Nothing copied from here is safe to share · back with") }
    static var peekPill: String { String(localized: "Peeking · release to go back") }
    static var peekShort: String { String(localized: "Peeking", comment: "Short red pill beside the Redacted/Original control while the original is held") }
    static var redacted: String { String(localized: "Redacted", comment: "Viewer mode: the blacked-out file") }
    static var original: String { String(localized: "Original", comment: "Viewer mode: the original with every secret visible") }
    static var compareRedacted: String { String(localized: "Redacted · what you share") }
    static var compareOriginal: String { String(localized: "Original") }
    /// VoiceOver's value for the wipe compare's divider.
    static func wipeValue(_ position: Double) -> String {
        let covered = Int((WipeGeometry.clamp(position) * 100).rounded())
        return String(localized: "\(covered) percent redacted, \(100 - covered) percent original")
    }
    static var fileMatches: String { String(localized: "the file matches this preview") }
    static var testShotCaption: String { String(localized: "made-up keys · nothing left your Mac") }
    static var blackOutAll: String { String(localized: "Black Out All") }
    static var originalGone: String { String(localized: "The original was deleted; only the redacted file is left.") }
    static var entryGone: String { String(localized: "This screenshot is no longer in the Journal.") }
    static var loadFailed: String { String(localized: "Couldn't open this screenshot.") }

    /// "4 of 4 secrets blacked out", "3 of 4 secrets blacked out · 1 left visible", "1 of 1 secret blacked out".
    static func subtitle(enabled: Int, total: Int) -> String {
        if total == 0 { return String(localized: "No secrets found") }
        let head = total == 1 ? String(localized: "\(enabled) of 1 secret blacked out")
                              : String(localized: "\(enabled) of \(total) secrets blacked out")
        let visible = total - enabled
        return visible == 0 ? head : head + " · " + String(localized: "\(visible) left visible")
    }

    /// The tooltip on a bar: "2 · Phone number — blacked out. Click to leave it visible."
    static func findingTip(number: Int, name: String, enabled: Bool) -> String {
        enabled ? String(localized: "\(number) · \(name) — blacked out. Click to leave it visible.")
                : String(localized: "\(number) · \(name) — left visible. Click to black it out.")
    }

    /// VoiceOver label for a bar: "Finding 2, Phone number, blacked out".
    static func findingAccessibility(number: Int, name: String, enabled: Bool) -> String {
        enabled ? String(localized: "Finding \(number), \(name), blacked out")
                : String(localized: "Finding \(number), \(name), left visible")
    }

    static func findingState(enabled: Bool) -> String {
        enabled ? String(localized: "blacked out") : String(localized: "left visible")
    }

    /// The full detector name of a finding (its first detector id is the display label).
    static func name(of finding: Finding) -> String {
        DetectorNames.title(for: finding.detectorIDs.first ?? "")
    }

    // MARK: Test shot

    static func testShotHeadline(secrets: Int, durationMS: Int) -> String {
        secrets == 1 ? String(localized: "1 secret blacked out in \(durationMS) ms.")
                     : String(localized: "\(secrets) secrets blacked out in \(durationMS) ms.")
    }
    static var testShotDetail: String { String(localized: "This is exactly what your clipboard gets.") }

    static func testShotSteps(detectors: Int, secrets: Int, retentionHours: Int) -> [String] {
        let matched: String
        switch (detectors == 1, secrets == 1) {
        case (true, true): matched = String(localized: "1 detector matched 1 secret")
        case (true, false): matched = String(localized: "1 detector matched \(secrets) secrets")
        case (false, true): matched = String(localized: "\(detectors) detectors matched 1 secret")
        case (false, false): matched = String(localized: "\(detectors) detectors matched \(secrets) secrets")
        }
        return [
            String(localized: "Read the text on your Mac"),
            matched,
            String(localized: "Covered them fill-first; nothing can be un-blurred"),
            String(localized: "Clean image on the clipboard; original in the Journal for \(retention(retentionHours))"),
        ]
    }

    // MARK: Details

    static func source(_ entry: Entry) -> String {
        switch entry.source {
        case .clipboard: return String(localized: "Clipboard")
        case .imported: return String(localized: "Imported")
        case .demo: return String(localized: "Setup test shot")
        case .file:
            guard let path = entry.filePath else { return String(localized: "Screenshots folder") }
            let folder = (path as NSString).deletingLastPathComponent
            return FileManager.default.displayName(atPath: folder)
        }
    }

    static func date(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }

    /// "PNG · 1440×1024".
    static func kind(_ entry: Entry) -> String {
        let ext = UTType(entry.containerUTI)?.preferredFilenameExtension?.uppercased() ?? String(localized: "Image")
        return "\(ext) · \(entry.pixelWidth)×\(entry.pixelHeight)"
    }

    /// "deleted in 23 h" — when the entry (and its original) expires.
    static func originalExpiry(createdAt: Date, retentionHours: Int, available: Bool, now: Date = Date()) -> String {
        guard available else { return String(localized: "deleted") }
        let remaining = createdAt.addingTimeInterval(TimeInterval(retentionHours) * 3600).timeIntervalSince(now)
        if remaining <= 3600 {
            let minutes = max(1, Int((remaining / 60).rounded(.up)))
            return String(localized: "deleted in \(minutes) min")
        }
        return String(localized: "deleted in \(Int((remaining / 3600).rounded(.down))) h")
    }

    static var leftMacNever: String { String(localized: "Never") }

    /// "24 h", "7 days".
    static func retention(_ hours: Int) -> String {
        hours < 48 ? String(localized: "\(hours) h") : String(localized: "\(hours / 24) days")
    }
}
