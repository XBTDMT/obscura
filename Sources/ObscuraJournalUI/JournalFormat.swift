// Words, numbers and dates the Journal prints. Verdict words come from the kit (`Verdict`, `ProtectionCopy`); this file
// holds only the Journal's own phrases: sources, day headers, retention, counts and the Details lines.
import Foundation
import SwiftUI
import ObscuraUIKit
import ObscuraJournal
import ObscuraPrefs

enum JournalFormat {
    // MARK: Counts

    static func screenshots(_ n: Int) -> String {
        n == 1 ? String(localized: "1 screenshot") : String(localized: "\(n) screenshots")
    }

    static func detectors(_ n: Int) -> String {
        n == 1 ? String(localized: "1 detector") : String(localized: "\(n) detectors")
    }

    /// "5 found by 5 detectors" for the Details grid.
    static func foundBy(secrets: Int, detectors count: Int) -> String {
        String(localized: "\(secrets) found by \(detectors(count))")
    }

    // MARK: Sources

    static func sourceName(_ source: EntrySource) -> String {
        switch source {
        case .file: return String(localized: "Screenshot")
        case .clipboard: return String(localized: "Clipboard")
        case .imported: return String(localized: "Imported")
        case .demo: return String(localized: "Test shot")
        }
    }

    static func sourceSymbol(_ source: EntrySource) -> String {
        switch source {
        case .file: return "camera"
        case .clipboard: return "clipboard"
        case .imported: return "square.and.arrow.down"
        case .demo: return "flask"
        }
    }

    // MARK: Retention

    /// "24 hours", "1 hour", "7 days", "30 days".
    static func retention(_ r: JournalRetention) -> String {
        switch r {
        case .oneHour: return String(localized: "1 hour")
        case .oneDay: return String(localized: "24 hours")
        case .oneWeek: return String(localized: "7 days")
        case .thirtyDays: return String(localized: "30 days")
        }
    }

    static func expiry(of entry: Entry, retention: JournalRetention) -> Date {
        entry.createdAt.addingTimeInterval(TimeInterval(retention.hours * 3600))
    }

    /// "Original kept until tomorrow 9:41 AM".
    static func keptUntil(_ expiry: Date, now: Date, calendar: Calendar = .current) -> String {
        if expiry <= now { return String(localized: "Original deletes at the next cleanup") }
        return String(localized: "Original kept until \(relativeMoment(expiry, now: now, calendar: calendar))")
    }

    /// The short list-column form: "Kept until tomorrow 9:41 AM".
    static func keptUntilShort(_ expiry: Date, now: Date, calendar: Calendar = .current) -> String {
        if expiry <= now { return String(localized: "Deletes at next cleanup") }
        return String(localized: "Kept until \(relativeMoment(expiry, now: now, calendar: calendar))")
    }

    /// "today 3:00 PM", "tomorrow 9:41 AM", "Oct 30, 9:41 AM".
    static func relativeMoment(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let t = time(date)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "today \(t)") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "tomorrow \(t)")
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(t)"
    }

    // MARK: Dates

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// Day header: "Today", "Yesterday", "Saturday, Oct 24".
    static func dayTitle(_ day: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return String(localized: "Today") }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) {
            return String(localized: "Yesterday")
        }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    /// Card meta: "9:41 AM", "Yesterday 6:20 PM", "Oct 24, 6:20 PM".
    static func cardWhen(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let t = time(date)
        if calendar.isDate(date, inSameDayAs: now) { return t }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return String(localized: "Yesterday \(t)")
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(t)"
    }

    /// Details date: "Today, 9:41 AM", "Yesterday, 6:20 PM", "Oct 24, 2026, 6:20 PM".
    static func detailDate(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let t = time(date)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today, \(t)") }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return String(localized: "Yesterday, \(t)")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Details

    static func kindName(uti: String) -> String {
        switch uti {
        case "public.png": return "PNG"
        case "public.jpeg": return "JPEG"
        case "public.heic": return "HEIC"
        default: return uti.split(separator: ".").last.map { $0.uppercased() } ?? uti
        }
    }

    /// "PNG · 1,920 × 460 · 1.4 MB" (the size part only once it is known).
    static func kindLine(_ entry: Entry, bytes: Int64?) -> String {
        var parts = [kindName(uti: entry.containerUTI), "\(entry.pixelWidth.formatted()) × \(entry.pixelHeight.formatted())"]
        if let bytes { parts.append(bytes.formatted(.byteCount(style: .file))) }
        return parts.joined(separator: " · ")
    }

    /// Where the caught file lives: "~/Desktop", "Pasteboard only", "Journal only".
    static func location(_ entry: Entry) -> String {
        if let path = entry.cleanCopyPath ?? entry.filePath {
            let folder = (path as NSString).deletingLastPathComponent
            return (folder as NSString).abbreviatingWithTildeInPath
        }
        switch entry.source {
        case .clipboard: return String(localized: "Pasteboard only")
        case .demo: return String(localized: "Setup demo")
        case .file, .imported: return String(localized: "Journal only")
        }
    }

    /// The inspector subtitle: "Screenshot · 9:41 AM · 5 secrets".
    static func subtitle(_ entry: Entry, now: Date) -> String {
        [sourceName(entry.source), cardWhen(entry.createdAt, now: now), ProtectionCopy.secrets(entry.findings.count)].joined(separator: " · ")
    }

    // MARK: Multi-select

    /// What is true of a set of files, by verdict: "2 safe to share · 1 with secrets left visible".
    static func batchSummary(safe: Int, leftVisible: Int, original: Int) -> String {
        if leftVisible == 0 && original == 0 { return String(localized: "All \(safe) files are safe to share.") }
        if safe == 0 && leftVisible == 0 { return String(localized: "All \(original) files show the original.") }
        var parts: [String] = []
        if leftVisible > 0 {
            parts.append(leftVisible == 1 ? String(localized: "1 file shows secrets you left visible")
                                           : String(localized: "\(leftVisible) files show secrets you left visible"))
        }
        if original > 0 {
            parts.append(original == 1 ? String(localized: "1 file shows the original")
                                        : String(localized: "\(original) files show the original"))
        }
        if safe > 0 {
            parts.append(safe == 1 ? String(localized: "1 is safe to share") : String(localized: "\(safe) are safe to share"))
        }
        return parts.joined(separator: "; ") + "."
    }

    // MARK: Not covered on disk (fail-open #7)

    /// The Not covered on disk symbol, shared with the panel's "N files still show secrets" banner.
    static let notCoveredSymbol = "exclamationmark.lock"

    /// "1 file not covered", "3 files not covered", and "Every file is covered" once the last one went.
    static func notCovered(_ n: Int) -> String {
        if n == 0 { return String(localized: "Every file is covered") }
        return n == 1 ? String(localized: "1 file not covered") : String(localized: "\(n) files not covered")
    }

    /// Why the file still shows what was caught, in plain words.
    static func notCoveredReason(cleanCopy: Bool, attempts: Int) -> String {
        let base = cleanCopy
            ? String(localized: "The clean copy couldn't be written beside the original.")
            : String(localized: "The covered picture couldn't be written to this file, so it still shows the secret.")
        return attempts > 1 ? base + " " + String(localized: "Tried \(attempts) times.") : base
    }

    // MARK: Not checked (G-13)

    /// The Not checked symbol, shared with the panel's "N images weren't checked" banner.
    static let notCheckedSymbol = "clock.badge.exclamationmark"

    /// "1 image not checked", "3 images not checked", and "Nothing left to check" once the last one went.
    static func notChecked(_ n: Int) -> String {
        if n == 0 { return String(localized: "Nothing left to check") }
        return n == 1 ? String(localized: "1 image not checked") : String(localized: "\(n) images not checked")
    }

    /// Why the file was left without a verdict, in plain words. The timeout names the Settings' own seconds.
    static func uncheckedReason(_ reason: UncheckedReason?, timeoutSeconds: Int) -> String {
        switch reason {
        case .ocrTimeout: return String(localized: "Reading it took longer than \(timeoutSeconds) s, so it was stopped.")
        case .ocrFailed: return String(localized: "Its text couldn't be read.")
        case .textNotRead: return String(localized: "Part of it looks like text but couldn't be read.")
        case .unreadPatch: return SpotCopy.reason
        case .queueFull: return String(localized: "Too many images arrived at once to read them all.")
        case .renderFailed: return String(localized: "A secret was found but couldn't be covered.")
        case .encodeFailed: return String(localized: "The clean image couldn't be saved.")
        case .journalFailed: return String(localized: "The Journal couldn't store the catch.")
        case .catalogueFailed: return String(localized: "The detectors weren't loaded.")
        case .decodeFailed: return String(localized: "The picture couldn't be opened. It may be damaged.")
        case .unsupportedImage: return String(localized: "It's a kind of image Obscura can't read.")
        case .unreadable: return String(localized: "The file couldn't be read. It may be in iCloud only, or Obscura may not have access.")
        case .tooLarge: return String(localized: "It's larger than the size Obscura reads.")
        case .incomplete: return String(localized: "It looked unfinished, as if it was still being saved or downloaded.")
        case .multiFrame: return String(localized: "It has several frames, and Obscura can't cover those yet. A secret may be in it.")
        case .protectionPaused: return String(localized: "It arrived while protection was paused.")
        case nil: return String(localized: "It couldn't be checked.")
        }
    }

    /// The folder that holds the file, as Finder names it ("Desktop", "Downloads").
    static func folderName(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
    }

    /// The meta line under the file name: "Desktop · Today 9:44 AM", with the try count once there were several.
    static func uncheckedMeta(folder: String, date: Date, attempts: Int, now: Date, calendar: Calendar = .current) -> String {
        var parts = [folder, cardWhen(date, now: now, calendar: calendar)]
        if attempts > 1 { parts.append(String(localized: "tried \(attempts) times")) }
        return parts.joined(separator: " · ")
    }
}

extension Verdict {
    var isSafe: Bool { if case .safeToShare = self { return true } else { return false } }
}

/// Detector category → tile symbol (the colour is `OColor.category`).
enum DetectorGlyph {
    static func symbol(category: String, detectorID: String) -> String {
        let id = detectorID.lowercased()
        if id.contains("email") { return "envelope" }
        if id.contains("phone") { return "phone" }
        if id.contains("card") || id.contains("cvc") || id.contains("iban") { return "creditcard" }
        switch category {
        case "ai": return "sparkles"
        case "cloud": return "cloud"
        case "payments": return "creditcard"
        case "scm": return "arrow.triangle.branch"
        case "messaging": return "bubble.left.and.bubble.right"
        case "databases": return "cylinder"
        case "tokens": return "key"
        case "config": return "gearshape"
        case "personal": return "person"
        case "network": return "network"
        default: return "key"
        }
    }
}
