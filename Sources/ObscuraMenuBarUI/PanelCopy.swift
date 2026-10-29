// The panel's words (design/mockups/unified/menubar.html and CHANGES.md "Verdict vocabulary and copy").
// Verdict and protection words come from the kit (Verdict, ProtectionCopy, DetectorNames); this file holds only the
// sentences the panel alone says. English source strings; the String Catalog localizes them.
import Foundation
import ObscuraUIKit
import ObscuraEngine
import ObscuraJournal
import ObscuraPrefs

enum PanelCopy {
    // MARK: Header sentences

    static let checkingSentence = String(localized: "Reading the text on this Mac. Nothing leaves it.")
    static let checkingDetail = String(localized: "Reading the text on this Mac. Each image is covered before it can reach the clipboard.")
    static let pausedSentence = String(localized: "Nothing is checked until you resume. Originals are still kept.")
    static func updateSentence(_ offer: UpdateOffer) -> String {
        switch offer.phase {
        case .ready: String(localized: "Obscura \(offer.version) is ready to install.")
        case .installing: String(localized: "Installing Obscura \(offer.version)…")
        case .failed: String(localized: "Obscura \(offer.version) couldn't be installed.")
        }
    }
    static let focusSentence = String(localized: "Focus is holding catch notifications. They're listed here.")

    static func checkingTitle(_ count: Int) -> String {
        String(localized: "Checking \(ProtectionCopy.images(count))…")
    }

    static func caughtJustNow(_ secrets: Int) -> String {
        String(localized: "Blacked out \(ProtectionCopy.secrets(secrets)) just now.")
    }

    static func caughtSince(_ secrets: Int, time: String) -> String {
        String(localized: "Blacked out \(ProtectionCopy.secrets(secrets)) since \(time).")
    }

    /// "Screenshots, two folders and the clipboard are watched."
    static func watchedSentence(_ settings: ObscuraPrefs.Settings) -> String {
        var parts: [String] = []
        if settings.guardsScreenshotFolder { parts.append(String(localized: "screenshots")) }
        let folders = (settings.guardsDownloads ? 1 : 0) + settings.extraFolders.count
        if folders == 1 { parts.append(String(localized: "one folder")) }
        else if folders > 1 { parts.append(String(localized: "\(spelled(folders)) folders")) }
        if settings.guardsClipboard { parts.append(String(localized: "the clipboard")) }
        guard !parts.isEmpty else { return String(localized: "Nothing is watched. Turn a source on in Settings.") }
        let list = capitalizedFirst(parts.formatted(.list(type: .and)))
        let singular = parts.count == 1 && !settings.guardsScreenshotFolder
        return singular ? String(localized: "\(list) is watched.") : String(localized: "\(list) are watched.")
    }

    /// "Clipboard guard is off. 3 of 4 sources are watched."
    static func partlySentence(reasons: [String], settings: ObscuraPrefs.Settings) -> String {
        let total = 2 + (settings.guardsDownloads ? 1 : 0) + settings.extraFolders.count
        let off = reasons.filter { $0 == "protection.clipboardOff" || $0 == "protection.screenshotsOff" || $0 == "protection.sourceDown" }.count
        let watched = max(0, total - off)
        let first: String
        switch reasons.first {
        case "protection.clipboardOff": first = String(localized: "Clipboard guard is off.")
        case "protection.screenshotsOff": first = String(localized: "The screenshot folder isn't watched.")
        case "protection.sourceDown": first = String(localized: "A capture source didn't start.")
        case "protection.rulesSkipped": first = String(localized: "Some of your rules or edited patterns aren't in use.")
        default: first = String(localized: "Some sources aren't watched.")
        }
        return first + " " + String(localized: "\(watched) of \(total) sources are watched.")
    }

    // MARK: Catches

    /// What was found, by full detector name: "Stripe secret key and Email address", "A, B and 2 more".
    static func foundTitle(_ entry: Entry) -> String {
        let names = detectorNames(entry)
        guard !names.isEmpty else { return ProtectionCopy.secrets(entry.findings.count) }
        if names.count <= 2 { return names.formatted(.list(type: .and)) }
        let more = String(localized: "\(names.count - 2) more")
        return (Array(names.prefix(2)) + [more]).formatted(.list(type: .and))
    }

    /// "GitHub token blacked out", "3 secrets blacked out" (secret first, verb second, CHANGES #31).
    static func blackedOutTitle(_ entry: Entry) -> String {
        let names = detectorNames(entry)
        if entry.findings.count == 1, let name = names.first { return String(localized: "\(name) blacked out") }
        return String(localized: "\(ProtectionCopy.secrets(entry.findings.count)) blacked out")
    }

    /// "Original showing · Stripe secret key visible".
    static func originalShowingTitle(_ entry: Entry) -> String {
        let names = detectorNames(entry)
        let what = entry.findings.count == 1 && names.count == 1 ? names[0] : ProtectionCopy.secrets(entry.findings.count)
        return Verdict.originalShowing(total: entry.findings.count).title + " · " + String(localized: "\(what) visible")
    }

    /// Where the clean image went, for the last-catch card.
    static func cleanCopyLine(_ entry: Entry, retentionHours: Int) -> String {
        let kept = String(localized: "original in the Journal for \(shortRetention(retentionHours))")
        switch entry.source {
        case .clipboard: return String(localized: "The clipboard holds the clean copy") + " · " + kept
        case .imported: return String(localized: "Imported · the file on disk is unchanged")
        case .demo: return String(localized: "The setup demo · nothing on disk changed")
        case .file:
            let what = entry.cleanCopyPath != nil ? String(localized: "Clean copy saved next to it")
                                                  : String(localized: "Replaced with a clean copy")
            return what + " · " + kept
        }
    }

    /// The short form for a Recent row: "Copied image · clipboard holds the clean copy".
    static func recentSubtitle(_ entry: Entry) -> String {
        let where_: String
        switch entry.source {
        case .clipboard: where_ = String(localized: "clipboard holds the clean copy")
        case .imported: where_ = String(localized: "imported")
        case .demo: where_ = String(localized: "setup demo")
        case .file: where_ = entry.cleanCopyPath != nil ? String(localized: "clean copy saved next to it")
                                                        : String(localized: "replaced with a clean copy")
        }
        return entry.displayName + " · " + where_
    }

    static func undoneSubtitle(_ entry: Entry) -> String {
        entry.displayName + " · " + String(localized: "undone")
    }

    // MARK: Week

    static func secretsThisWeek(_ n: Int) -> String {
        n == 1 ? String(localized: "secret this week") : String(localized: "secrets this week")
    }

    static func imagesChecked(_ n: Int) -> String {
        n == 1 ? String(localized: "image checked") : String(localized: "images checked")
    }

    // MARK: Paused

    static func pausedSince(_ time: String) -> String { String(localized: "Paused since \(time)") }
    static let pausedTitle = String(localized: "Paused")

    static func resumes(at date: Date, now: Date, calendar: Calendar) -> String {
        let time = Self.time(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Resumes automatically at \(time).") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "Resumes automatically tomorrow at \(time).")
        }
        return String(localized: "Resumes automatically on \(date.formatted(style(date: .abbreviated, time: .shortened, calendar: calendar))).")
    }

    static let staysPaused = String(localized: "Stays paused until you resume.")

    // MARK: Update

    static func updateTitle(_ offer: UpdateOffer) -> String {
        switch offer.phase {
        case .ready: String(localized: "Obscura \(offer.version) is ready")
        case .installing: String(localized: "Installing Obscura \(offer.version)…")
        case .failed: String(localized: "Obscura \(offer.version) wasn't installed")
        }
    }
    /// G-33: the update is verified before it replaces anything; a failure says why and that nothing changed.
    static func updateBody(_ offer: UpdateOffer) -> String {
        switch offer.phase {
        case .ready:
            String(localized: "Installing downloads it, checks it is signed by the same developer as this copy, and relaunches the app; protection resumes right away.")
        case .installing:
            String(localized: "Downloading and checking the update. Obscura relaunches when it's done.")
        case .failed(let reason):
            String(localized: "\(reason) This copy of Obscura is unchanged.")
        }
    }
    static func installUpdateRow(_ offer: UpdateOffer) -> String {
        offer.phase == .installing ? String(localized: "Installing Update \(offer.version)…") : String(localized: "Install Update \(offer.version)…")
    }

    // MARK: Footer

    static func footer(retentionHours: Int) -> String {
        String(localized: "Free and open source. Nothing leaves this Mac. Originals live in the Journal for \(longRetention(retentionHours)), then are deleted.")
    }

    // MARK: Helpers

    static func detectorNames(_ entry: Entry) -> [String] {
        var seen = Set<String>(), names: [String] = []
        for finding in entry.findings {
            guard let id = finding.detectorIDs.first else { continue }
            let name = DetectorNames.title(for: id)
            if seen.insert(name).inserted { names.append(name) }
        }
        return names
    }

    static func shortRetention(_ hours: Int) -> String {
        hours < 48 ? String(localized: "\(hours) h") : String(localized: "\(hours / 24) days")
    }

    static func longRetention(_ hours: Int) -> String {
        if hours == 1 { return String(localized: "1 hour") }
        if hours < 48 { return String(localized: "\(hours) hours") }
        return String(localized: "\(hours / 24) days")
    }

    /// A clock time in the calendar's time zone ("9:41 AM").
    static func time(_ date: Date, calendar: Calendar) -> String {
        date.formatted(style(date: .omitted, time: .shortened, calendar: calendar))
    }

    static func style(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle, calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(date: date, time: time, locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
    }

    static func spelled(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func capitalizedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}

/// Words for the engine's problems. `Problem.messageKey` is the key; the panel resolves it here.
enum ProblemCopy {
    struct Words: Equatable {
        var symbol: String
        var title: String
        var body: String
        /// The one-line reason the header shows under "Needs attention".
        var headline: String
        /// A run of `body` to draw bold.
        var emphasis: String? = nil
    }

    static func folderName(_ url: URL?) -> String {
        guard let url else { return String(localized: "A folder") }
        return FileManager.default.displayName(atPath: url.path)
    }

    /// `unchecked` is the engine's list of files left without a verdict; with exactly one, the banner names it.
    static func words(for problem: Problem, settings: ObscuraPrefs.Settings, downloads: URL, unchecked: [UncheckedFile] = []) -> Words {
        switch problem.kind {
        case .folderAccess:
            let name = folderName(problem.url)
            if problem.messageKey == "problem.folder.missing" {
                return Words(symbol: "questionmark.folder",
                             title: String(localized: "\(name) is missing"),
                             body: String(localized: "The folder was moved or deleted, so nothing in it is checked."),
                             headline: String(localized: "\(name) is missing."))
            }
            let isDownloads = problem.url?.standardizedFileURL.path == downloads.standardizedFileURL.path
            if problem.messageKey == ShieldEngine.unconfirmedFolderKey {
                // G-36: named in the settings by something other than Obscura's own Settings.
                return Words(symbol: "folder.badge.questionmark",
                             title: String(localized: "\(name) isn't watched yet"),
                             body: String(localized: "It was added outside Obscura. Confirm it in Settings to have new images there checked."),
                             headline: String(localized: "\(name) was added outside Obscura and isn't watched yet."))
            }
            return Words(symbol: "folder.badge.questionmark",
                         title: String(localized: "\(name) can't be read"),
                         body: isDownloads
                            ? String(localized: "Folder access was lost. New downloads aren't checked until it's granted again.")
                            : String(localized: "Folder access was lost. New files in it aren't checked until it's granted again."),
                         headline: String(localized: "\(name) can't be read: folder access was lost."))
        case .scanFailure:
            // The engine counts every file left without a verdict (OCR timeouts included) and the failures with no file.
            let n = max(1, Int(problem.detail ?? "") ?? unchecked.count)
            let seconds = Int(settings.ocrTimeoutSeconds.rounded())
            let title = n == 1 ? String(localized: "1 image wasn't checked") : String(localized: "\(n) images weren't checked")
            let timedOut = unchecked.count == n && unchecked.allSatisfy { $0.reason == SkipReason.ocrTimeout.rawValue }
            // The "took longer or failed" words fit only when every one of them is a file whose reading was stopped; a
            // picture that could not be opened, one too large, or a copied image gets plain words (fail-open #2, #13).
            let readingReasons: Set<String> = [SkipReason.ocrTimeout.rawValue, SkipReason.ocrFailed.rawValue, SkipReason.queueFull.rawValue]
            let readingStopped = unchecked.count == n && unchecked.allSatisfy { readingReasons.contains($0.reason) }
            // G-40's true wording: Vision answered, with no text, for a part that looks like text. Nothing failed.
            let noText = unchecked.count == n && unchecked.allSatisfy { $0.reason == SkipReason.textNotRead.rawValue }
            // Fail-open #21: shots taken while protection was paused, listed after the resume.
            let whilePaused = unchecked.count == n && unchecked.allSatisfy { $0.reason == SkipReason.protectionPaused.rawValue }
            let body: String
            var emphasis: String?
            if whilePaused {
                emphasis = n == 1 ? unchecked.first?.displayName : nil
                body = n == 1
                    ? String(localized: "\(unchecked.first?.displayName ?? "") arrived while protection was paused, so it wasn't checked.")
                    : String(localized: "They arrived while protection was paused, so they weren't checked.")
            } else if n == 1, let file = unchecked.first {
                emphasis = file.displayName
                if timedOut {
                    body = String(localized: "Reading \(file.displayName) took longer than \(seconds) s and was stopped. The file is untouched.")
                } else if noText {
                    body = String(localized: "Part of \(file.displayName) looks like text but couldn't be read. The file is untouched.")
                } else if readingStopped {
                    body = String(localized: "Reading \(file.displayName) took longer than \(seconds) s or failed, so it was stopped. The file is untouched.")
                } else {
                    body = String(localized: "\(file.displayName) couldn't be checked, so it was left as it is. Any secret in it is still there.")
                }
            } else if n == 1 {
                body = String(localized: "An image couldn't be checked, so it was left as it is. Any secret in it is still there.")
            } else if timedOut {
                body = String(localized: "Reading them took longer than \(seconds) s, so they were stopped. The files are untouched.")
            } else if noText {
                body = String(localized: "Part of each looks like text but couldn't be read. The files are untouched.")
            } else if readingStopped {
                body = String(localized: "Reading them took longer than \(seconds) s or failed, so they were stopped. The files are untouched.")
            } else {
                body = String(localized: "They couldn't be checked, so they were left as they are. Any secret in them is still there.")
            }
            return Words(symbol: "clock.badge.exclamationmark", title: title, body: body, headline: title + ".", emphasis: emphasis)
        case .ruleCompile:
            switch problem.messageKey {
            case "problem.override.undecodable":
                return Words(symbol: "exclamationmark.triangle",
                             title: String(localized: "A detector change was skipped"),
                             body: String(localized: "A saved change to a detector couldn't be read, so the detector uses its defaults."),
                             headline: String(localized: "A detector change was skipped."))
            case "problem.override.compile":
                return Words(symbol: "exclamationmark.triangle",
                             title: String(localized: "Edited patterns aren't in use"),
                             body: String(localized: "Your edited patterns for a detector don't compile, so it uses its built-in patterns until they're fixed."),
                             headline: String(localized: "Edited patterns aren't in use."))
            case CatalogueBuilder.unreadableKey:
                // G-30: the values were sealed with a key this Mac does not have (a restore, a reset keychain).
                let n = max(1, Int(problem.detail ?? "") ?? 1)
                let title = n == 1 ? String(localized: "1 custom rule can't be read on this Mac")
                                   : String(localized: "\(n) custom rules can't be read on this Mac")
                return Words(symbol: "lock.trianglebadge.exclamationmark", title: title,
                             body: String(localized: "They aren't in use until you re-enter them or import a rules file. Built-in detectors still run."),
                             headline: title + ".")
            case CatalogueBuilder.keychainUnavailableKey:
                let n = max(1, Int(problem.detail ?? "") ?? 1)
                let title = n == 1 ? String(localized: "1 custom rule isn't in use") : String(localized: "\(n) custom rules aren't in use")
                return Words(symbol: "lock.trianglebadge.exclamationmark", title: title,
                             body: String(localized: "The keychain didn't hand over the key that protects your rules. Obscura tries again; built-in detectors still run."),
                             headline: title + ".")
            case "problem.catalogue.failed":
                return Words(symbol: "exclamationmark.triangle",
                             title: String(localized: "Detectors didn't load"),
                             body: String(localized: "Nothing can be caught until they do. Quitting and reopening Obscura usually fixes it."),
                             headline: String(localized: "Detectors didn't load."))
            default:
                return Words(symbol: "exclamationmark.triangle",
                             title: String(localized: "A custom rule was skipped"),
                             body: String(localized: "It doesn't compile, so nothing uses it until it's fixed."),
                             headline: String(localized: "A custom rule was skipped."))
            }
        case .sourceStart:
            return Words(symbol: "exclamationmark.triangle",
                         title: String(localized: "A capture source didn't start"),
                         body: String(localized: "Some images aren't checked. Quitting and reopening Obscura usually fixes it."),
                         headline: String(localized: "A capture source didn't start."))
        case .notCovered:
            // Fail-open #7: Obscura caught a secret but the covered picture is not in the file; the file still shows it.
            let n = max(1, Int(problem.detail ?? "") ?? 1)
            let title = n == 1 ? String(localized: "1 file still shows a secret") : String(localized: "\(n) files still show secrets")
            let body = n == 1
                ? String(localized: "Obscura caught it, but couldn't write the covered picture to the file. Try again, or share the clean copy from the Journal.")
                : String(localized: "Obscura caught them, but couldn't write the covered pictures to the files. Try again, or share the clean copies from the Journal.")
            return Words(symbol: "exclamationmark.lock", title: title, body: body, headline: title + ".")
        case .journalMaintenance:
            return Words(symbol: "trash.slash",
                         title: String(localized: "Old originals weren't all deleted"),
                         body: String(localized: "Obscura couldn't remove some originals after the time you chose to keep them. It tries again every 15 minutes."),
                         headline: String(localized: "Old originals weren't all deleted."))
        case .unreadSpots:
            // G-40: plain words, no alarm. Vision read nothing there; the person decides in the viewer.
            let spotFiles = unchecked.filter(\.isUnreadSpots)
            let n = max(1, Int(problem.detail ?? "") ?? spotFiles.reduce(0) { $0 + max(1, $1.pendingSpots) })
            let title = SpotCopy.title(n)
            let name = spotFiles.count == 1 ? spotFiles.first?.displayName : nil
            return Words(symbol: "viewfinder", title: title, body: SpotCopy.body(spots: n, files: max(1, spotFiles.count), name: name),
                         headline: title + ".", emphasis: name)
        case .ocrWarmup:
            return Words(symbol: "hourglass",
                         title: String(localized: "Text reading is slow to start"),
                         body: String(localized: "The first image may take longer than usual to check."),
                         headline: String(localized: "Text reading is slow to start."))
        }
    }
}
