// ObscuraNotifyUI — the problems that earn a sounded, time-sensitive alert, each with the fix the mockup puts in view.
// Two inputs feed it: standing engine `Problem`s (folder access, rules, sources) and single-image failures read from a
// `ScanReport` (OCR timed out, write failed). Pure: every input is a value; the thin layer gathers them.
import Foundation
import ObscuraEngine
import ObscuraCapture

struct ProblemNotice: Sendable, Hashable {
    /// One kind per action set: macOS fixes a category's buttons, so each distinct pair of fixes is its own kind.
    enum Kind: String, Sendable, Hashable, CaseIterable {
        /// The screenshot folder can no longer be read (TCC revoked). Allow Access… / Later.
        case screenshotFolderDenied
        /// The screenshot folder was moved or deleted. Open Settings / Later.
        case screenshotFolderMissing
        /// Downloads or an added folder lost its permission. Open System Settings / Stop Watching.
        case watchedFolderDenied
        /// Downloads or an added folder is gone. Open Settings / Stop Watching.
        case watchedFolderMissing
        /// A file was left unchecked (OCR timed out or failed, or the picture could not be opened) or a stage threw before
        /// the clean copy existed.
        /// Check Again / Show in Finder.
        case fileUnchecked
        /// A file too large for the reading budget. Show in Finder / Open Settings.
        case fileTooLarge
        /// The clean copy could not be written; the secret is still on disk. Copy Clean / Show in Finder.
        case writeFailed
        /// The copied image was left unchecked or uncleaned; nothing to retry from a banner. No buttons.
        case clipboardUnchecked
        /// A rule, an edited detector or the catalogue could not be compiled. Open Settings.
        case ruleSkipped
        /// A capture source refused to start. Open Settings.
        case sourceDown
        /// Several files left unchecked within a minute, folded into one alert (`ProblemBatcher`). Show Not Checked.
        case filesUnchecked
        /// Several files too large to read within a minute, as one alert. Open Settings.
        case filesTooLarge
        /// Several clean copies not saved within a minute, as one alert. Open Journal.
        case cleanCopiesFailed
    }

    var kind: Kind
    /// Stable key for the request identifier: the same problem replaces itself, a different one stacks.
    var key: String
    var title: String
    var body: String
    /// Routing data (path, entry id, settings pane).
    var userInfo: [String: String]
    /// The file's display name, for a per-file problem: the combined alert lists it.
    var subject: String? = nil
}

/// What a file's notice calls the picture (redman small row, G-40): a picture from the screenshot folder is a
/// "screenshot"; one from Downloads, an added folder or an import is an "image". Each title is a whole sentence per noun
/// (never a noun pasted into a sentence), so every language can word it.
enum ImageNoun: Sendable, Hashable {
    case screenshot, image

    init(_ origin: FileOrigin?) { self = origin == .screenshotFolder ? .screenshot : .image }
}

/// Where a watched folder sits in Settings, decided from the folder URL and the settings.
enum FolderRole: Sendable, Hashable {
    case screenshotFolder
    case downloads
    /// An added folder; `path` is the string stored in `Settings.extraFolders`.
    case extra(path: String)

    static func of(_ url: URL, downloads: URL, extraFolders: [String]) -> FolderRole {
        let target = url.standardizedFileURL.path
        if target == downloads.standardizedFileURL.path { return .downloads }
        for path in extraFolders {
            let expanded = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.path
            if expanded == target { return .extra(path: path) }
        }
        return .screenshotFolder
    }
}

/// What a finished scan means for notifications.
enum ReportTriage: Sendable, Hashable {
    /// Something was blacked out: post a catch for this entry.
    case caught(entryID: UUID)
    /// The image was left as it is because reading its text failed or ran out of time.
    case unchecked(UncheckedReason, path: String?)
    /// The image is larger than the reading budget.
    case tooLarge(path: String?)
    /// The picture could not be opened: unreadable, undecodable, or a container Obscura does not read (fail-open #2).
    case unreadable(path: String?)
    /// The file still looked unfinished when the watcher's settle bound passed (fail-open #5).
    case incomplete(path: String?)
    /// A picture with several frames that could not be covered frame by frame (fail-open #6).
    case severalFrames(path: String?)
    /// Several image files were copied at once and left as they are (fail-open #9).
    case severalFiles
    /// A file copied from outside the guarded folders, never opened (F6/F12).
    case copiedFileNotGuarded
    /// The entry exists in the Journal but the clean bytes could not replace the file.
    case writeFailed(path: String?)
    /// A stage threw before the clean copy reached the disk.
    case scanFailed(path: String?)
    /// G-40: the picture's only unread parts are small spots no reading could read. No alarm: a file is listed under Not
    /// checked for the person to settle; a copied image (no row) gets one quiet notice.
    case unreadSpots(path: String?)
    /// Nothing for the user (clean, cancelled, paused, an extension never read, a full queue the engine retries).
    case none

    /// `textNotRead` (G-40): Vision answered, with no text, for a part that looks like text: true words, same alarm.
    enum UncheckedReason: String, Sendable, Hashable { case timedOut, ocrFailed, textNotRead }

    /// What one report means. The path is the report's capture-key path (symlinks resolved), the identity
    /// `ShieldEngine.retry(_:)` looks a remembered file up by.
    static func classify(_ report: ScanReport) -> ReportTriage {
        classify(key: report.key, outcome: report.outcome)
    }

    static func classify(key: CaptureKey?, outcome: ScanOutcome) -> ReportTriage {
        let path: String? = { if case .path(let p) = key { return p } else { return nil } }()
        switch outcome {
        case .redacted(let entryID, _, _): return .caught(entryID: entryID)
        case .clean: return .none
        case .skipped(let reason):
            switch reason {
            case .ocrTimeout: return .unchecked(.timedOut, path: path)
            case .ocrFailed: return .unchecked(.ocrFailed, path: path)
            case .textNotRead: return .unchecked(.textNotRead, path: path)
            case .tooLarge: return .tooLarge(path: path)
            case .writeFailed: return .writeFailed(path: path)
            case .decodeFailed, .unsupportedImage, .unreadable: return .unreadable(path: path)
            case .incomplete: return .incomplete(path: path)
            case .multiFrame: return .severalFrames(path: path)
            case .severalFiles: return .severalFiles
            case .copiedFileNotGuarded: return .copiedFileNotGuarded
            case .unreadPatch: return .unreadSpots(path: path)
            case .notAnImage, .cancelled, .protectionPaused, .queueFull, .sourceOff: return .none
            }
        case .failed(let error):
            switch error {
            case .writeBack: return .writeFailed(path: path)
            case .ocr: return .unchecked(.ocrFailed, path: path)
            case .render, .encode, .journal, .catalogue: return .scanFailed(path: path)
            case .entryNotFound: return .none
            }
        }
    }
}

extension ProblemNotice {
    // MARK: Standing engine problems

    /// The alert for an engine problem, or nil when it stays a panel row only (OCR warm-up, the aggregated
    /// scan-failure count — each failed image already alerted on its own from its report).
    static func from(_ problem: Problem, downloads: URL, extraFolders: [String]) -> ProblemNotice? {
        let key = problem.id
        switch problem.kind {
        case .folderAccess:
            guard let url = problem.url else { return nil }
            let missing = problem.messageKey.hasSuffix(".missing")
            let name = FileManager.default.displayName(atPath: url.path)
            var info = [NotifyKey.path: url.path, NotifyKey.problem: ""]
            let role = FolderRole.of(url, downloads: downloads, extraFolders: extraFolders)
            switch role {
            case .screenshotFolder:
                let place = url.lastPathComponent == "Desktop"
                    ? String(localized: "on the Desktop") : String(localized: "in \(name)")
                if missing {
                    info[NotifyKey.problem] = Kind.screenshotFolderMissing.rawValue
                    return ProblemNotice(kind: .screenshotFolderMissing, key: key,
                                         title: String(localized: "Can't find your screenshot folder"),
                                         body: String(localized: "\(name) was moved or deleted, so new screenshots are not being checked."),
                                         userInfo: info)
                }
                info[NotifyKey.problem] = Kind.screenshotFolderDenied.rawValue
                return ProblemNotice(kind: .screenshotFolderDenied, key: key,
                                     title: String(localized: "Can't read your screenshot folder"),
                                     body: String(localized: "New screenshots \(place) are not being checked until you allow access again."),
                                     userInfo: info)
            case .downloads, .extra:
                if case .extra(let stored) = role { info[NotifyKey.extraFolder] = stored }
                let isDownloads = role == .downloads
                if missing {
                    info[NotifyKey.problem] = Kind.watchedFolderMissing.rawValue
                    return ProblemNotice(kind: .watchedFolderMissing, key: key,
                                         title: String(localized: "\(name) isn't being watched"),
                                         body: String(localized: "\(name) was moved or deleted. New images there are not checked."),
                                         userInfo: info)
                }
                info[NotifyKey.problem] = Kind.watchedFolderDenied.rawValue
                let body = isDownloads
                    ? String(localized: "Access to the Downloads folder was removed in System Settings. New images there are not checked.")
                    : String(localized: "Access to \(name) was removed in System Settings. New images there are not checked.")
                return ProblemNotice(kind: .watchedFolderDenied, key: key,
                                     title: String(localized: "\(name) isn't being watched"), body: body, userInfo: info)
            }

        case .ruleCompile:
            let isDetector = problem.messageKey.contains("override") || problem.messageKey.contains("catalogue")
            let pane = isDetector ? "detectors" : "customRules"
            let info = [NotifyKey.problem: Kind.ruleSkipped.rawValue, NotifyKey.pane: pane]
            if problem.messageKey.contains("catalogue") {
                return ProblemNotice(kind: .ruleSkipped, key: key, title: String(localized: "Detectors couldn't be loaded"),
                                     body: String(localized: "Obscura couldn't build its list of detectors, so new images are not being checked."),
                                     userInfo: info)
            }
            if problem.messageKey == CatalogueBuilder.unreadableKey {
                // G-30: one notice for all of them; the count is in the title, never a rule's text.
                let n = max(1, Int(problem.detail ?? "") ?? 1)
                return ProblemNotice(kind: .ruleSkipped, key: key,
                                     title: n == 1 ? String(localized: "1 custom rule can't be read on this Mac")
                                                   : String(localized: "\(n) custom rules can't be read on this Mac"),
                                     body: String(localized: "Re-enter them or import a rules file. Until then they aren't used; built-in detectors still run."),
                                     userInfo: info)
            }
            if problem.messageKey == CatalogueBuilder.keychainUnavailableKey {
                let n = max(1, Int(problem.detail ?? "") ?? 1)
                return ProblemNotice(kind: .ruleSkipped, key: key,
                                     title: n == 1 ? String(localized: "1 custom rule isn't being used")
                                                   : String(localized: "\(n) custom rules aren't being used"),
                                     body: String(localized: "The keychain didn't hand over the key that protects your rules. Built-in detectors still run."),
                                     userInfo: info)
            }
            if isDetector {
                return ProblemNotice(kind: .ruleSkipped, key: key, title: String(localized: "Edited patterns aren't being used"),
                                     body: String(localized: "Your edited patterns for one detector couldn't be read, so that detector uses its built-in patterns."),
                                     userInfo: info)
            }
            return ProblemNotice(kind: .ruleSkipped, key: key, title: String(localized: "One of your rules isn't being used"),
                                 body: String(localized: "A custom rule couldn't be read, so Obscura skips it until it is fixed."),
                                 userInfo: info)

        case .sourceStart:
            let info = [NotifyKey.problem: Kind.sourceDown.rawValue, NotifyKey.pane: "protection"]
            if (problem.detail ?? "").localizedCaseInsensitiveContains("clipboard") {
                return ProblemNotice(kind: .sourceDown, key: key, title: String(localized: "The clipboard isn't being checked"),
                                     body: String(localized: "Obscura couldn't start watching the clipboard. Copied images are not checked."),
                                     userInfo: info)
            }
            return ProblemNotice(kind: .sourceDown, key: key, title: String(localized: "New screenshots aren't being checked"),
                                 body: String(localized: "Obscura couldn't start watching your folders."),
                                 userInfo: info)

        case .scanFailure, .ocrWarmup:
            return nil
        case .journalMaintenance:
            // Upkeep retries every tick; the panel's banner says it until one finishes. No notification of its own.
            return nil
        case .notCovered:
            // Each failed write already posted its own "couldn't write" notice when it happened (`writeFailed`); the
            // persisted list is the panel's and the Journal's, not a second notification.
            return nil
        case .unreadSpots:
            // G-40: no alarm. The panel and the Journal list the spots for the person to settle.
            return nil
        }
    }

    // MARK: Single-image failures (from a ScanReport)

    /// OCR timed out or failed on one image; it was left as it is.
    static func unchecked(_ reason: ReportTriage.UncheckedReason, path: String?, displayName: String,
                          timeoutSeconds: Int, pixelSize: (width: Int, height: Int)?, noun: ImageNoun = .screenshot) -> ProblemNotice {
        guard let path else {
            let body: String
            switch reason {
            case .timedOut:
                body = String(localized: "Reading the text in the image you copied took over \(timeoutSeconds) s. Your clipboard still holds it as it is, unchecked.")
            case .ocrFailed:
                body = String(localized: "The text in the image you copied couldn't be read. Your clipboard still holds it as it is, unchecked.")
            case .textNotRead:
                body = String(localized: "Part of the image you copied looks like text but couldn't be read. Your clipboard still holds it as it is, unchecked.")
            }
            return ProblemNotice(kind: .clipboardUnchecked, key: "clipboard.unchecked",
                                 title: String(localized: "Couldn't check the image you copied"), body: body,
                                 userInfo: [NotifyKey.problem: Kind.clipboardUnchecked.rawValue])
        }
        let body: String
        switch (reason, pixelSize) {
        case (.timedOut, let size?):
            let dims = "\(size.width.formatted()) × \(size.height.formatted()) px"
            body = String(localized: "Reading the text in \(displayName) took over \(timeoutSeconds) s (\(dims)). It was left as it is, unchecked.")
        case (.timedOut, nil):
            body = String(localized: "Reading the text in \(displayName) took over \(timeoutSeconds) s. It was left as it is, unchecked.")
        case (.ocrFailed, _):
            body = String(localized: "The text in \(displayName) couldn't be read. It was left as it is, unchecked.")
        case (.textNotRead, _):
            body = String(localized: "Part of \(displayName) looks like text but couldn't be read. It was left as it is, unchecked.")
        }
        return ProblemNotice(kind: .fileUnchecked, key: "unchecked.\(path)",
                             title: noun == .screenshot ? String(localized: "Couldn't check one screenshot") : String(localized: "Couldn't check one image"),
                             body: body,
                             userInfo: [NotifyKey.problem: Kind.fileUnchecked.rawValue, NotifyKey.path: path], subject: displayName)
    }

    /// Fail-open #1: a catch whose picture was only partly read. What was found is blacked out, but part of the text
    /// could not be read (it ran out of time, or the read failed), so it is not called checked: a file is listed with
    /// Check Again, a copied image is counted. The same kinds (and keys) as a picture left unchecked, so the same
    /// actions apply.
    static func partlyRead(path: String?, displayName: String, timedOut: Bool, timeoutSeconds: Int, noun: ImageNoun = .screenshot) -> ProblemNotice {
        let why = timedOut ? String(localized: "Part of its text took over \(timeoutSeconds) s to read") : String(localized: "Part of its text couldn't be read")
        guard let path else {
            return ProblemNotice(kind: .clipboardUnchecked, key: "clipboard.unchecked",
                                 title: String(localized: "Couldn't check all of the image you copied"),
                                 body: String(localized: "\(why). What was found is blacked out on your clipboard; the rest is unchecked."),
                                 userInfo: [NotifyKey.problem: Kind.clipboardUnchecked.rawValue])
        }
        return ProblemNotice(kind: .fileUnchecked, key: "unchecked.\(path)",
                             title: noun == .screenshot ? String(localized: "Couldn't check all of one screenshot")
                                                        : String(localized: "Couldn't check all of one image"),
                             body: String(localized: "\(why) in \(displayName). What was found is blacked out; check it again before you share it."),
                             userInfo: [NotifyKey.problem: Kind.fileUnchecked.rawValue, NotifyKey.path: path], subject: displayName)
    }

    /// The image is larger than the OCR pixel budget.
    static func tooLarge(path: String?, displayName: String, pixelSize: (width: Int, height: Int)?, noun: ImageNoun = .screenshot) -> ProblemNotice {
        guard let path else {
            return ProblemNotice(kind: .clipboardUnchecked, key: "clipboard.unchecked",
                                 title: String(localized: "Couldn't check the image you copied"),
                                 body: String(localized: "The image you copied is too large to read. Your clipboard still holds it as it is, unchecked."),
                                 userInfo: [NotifyKey.problem: Kind.clipboardUnchecked.rawValue])
        }
        let body: String
        if let size = pixelSize {
            let dims = "\(size.width.formatted()) × \(size.height.formatted()) px"
            body = String(localized: "\(displayName) (\(dims)) is larger than the size Obscura reads. It was left as it is, unchecked.")
        } else {
            body = String(localized: "\(displayName) is larger than the size Obscura reads. It was left as it is, unchecked.")
        }
        return ProblemNotice(kind: .fileTooLarge, key: "unchecked.\(path)",
                             title: noun == .screenshot ? String(localized: "Couldn't check one screenshot") : String(localized: "Couldn't check one image"),
                             body: body,
                             userInfo: [NotifyKey.problem: Kind.fileTooLarge.rawValue, NotifyKey.path: path], subject: displayName)
    }

    /// The picture could not be opened to check it (fail-open #2): the file or the clipboard holds it as it was. A file
    /// gets the unchecked file's fixes (Check Again / Show in Finder); the clipboard has nothing to retry from a banner.
    static func unreadable(path: String?, displayName: String) -> ProblemNotice {
        guard let path else {
            return ProblemNotice(kind: .clipboardUnchecked, key: "clipboard.unchecked",
                                 title: String(localized: "Couldn't read the image you copied"),
                                 body: String(localized: "Obscura couldn't open it to check it. Your clipboard still holds it as it is, unchecked."),
                                 userInfo: [NotifyKey.problem: Kind.clipboardUnchecked.rawValue])
        }
        return ProblemNotice(kind: .fileUnchecked, key: "unchecked.\(path)",
                             title: String(localized: "Couldn't read this image"),
                             body: String(localized: "Obscura couldn't open \(displayName) to check it, so it was left as it is, unchecked. Any secret in it is still there."),
                             userInfo: [NotifyKey.problem: Kind.fileUnchecked.rawValue, NotifyKey.path: path], subject: displayName)
    }

    /// The picture still looked unfinished (fail-open #5): it was not judged on the part that was there. A watched file is
    /// handed over again when it changes; Check Again works too.
    static func incomplete(path: String?, displayName: String) -> ProblemNotice {
        guard let path else {
            return ProblemNotice(kind: .clipboardUnchecked, key: "clipboard.unchecked",
                                 title: String(localized: "Couldn't check the image you copied"),
                                 body: String(localized: "The image you copied looks cut short. Your clipboard still holds it as it is, unchecked."),
                                 userInfo: [NotifyKey.problem: Kind.clipboardUnchecked.rawValue])
        }
        return ProblemNotice(kind: .fileUnchecked, key: "unchecked.\(path)",
                             title: String(localized: "Couldn't check an unfinished image"),
                             body: String(localized: "\(displayName) looks unfinished, as if it is still being saved or downloaded, so it was left as it is, unchecked. Obscura checks it when it is complete."),
                             userInfo: [NotifyKey.problem: Kind.fileUnchecked.rawValue, NotifyKey.path: path], subject: displayName)
    }

    /// A picture with several frames (an animation or pages) that Obscura could not cover frame by frame (fail-open #6):
    /// left as it is, and said so, rather than judged on its first frame.
    static func severalFrames(path: String?, displayName: String) -> ProblemNotice {
        guard let path else {
            return ProblemNotice(kind: .clipboardUnchecked, key: "clipboard.unchecked",
                                 title: String(localized: "Couldn't cover the image you copied"),
                                 body: String(localized: "It has several frames, and Obscura can't cover those yet. Your clipboard still holds it as it is, and a secret may be in it."),
                                 userInfo: [NotifyKey.problem: Kind.clipboardUnchecked.rawValue])
        }
        return ProblemNotice(kind: .fileUnchecked, key: "unchecked.\(path)",
                             title: String(localized: "Couldn't cover an image with several frames"),
                             body: String(localized: "\(displayName) has several frames (an animation or pages), and Obscura can't cover those yet. It was left as it is, and a secret may be in it."),
                             userInfo: [NotifyKey.problem: Kind.fileUnchecked.rawValue, NotifyKey.path: path], subject: displayName)
    }

    /// Several image files were copied at once (fail-open #9): one clipboard holds one covered picture, so they were left
    /// as they are, and said so rather than passed as checked.
    static func severalFiles() -> ProblemNotice {
        ProblemNotice(kind: .clipboardUnchecked, key: "clipboard.unchecked",
                      title: String(localized: "Couldn't check the files you copied"),
                      body: String(localized: "You copied several image files at once, and Obscura checks one copied image at a time. They were left as they are, unchecked."),
                      userInfo: [NotifyKey.problem: Kind.clipboardUnchecked.rawValue])
    }

    /// A file copied from outside the folders Obscura guards (F6/F12, G-35): it was never opened, because any app can put a
    /// file on the clipboard; it was left as it is, unchecked.
    static func copiedFileNotGuarded() -> ProblemNotice {
        ProblemNotice(kind: .clipboardUnchecked, key: "clipboard.unchecked",
                      title: String(localized: "Didn't check the file you copied"),
                      body: String(localized: "It's outside the folders Obscura watches, so Obscura didn't open it. It was left as it is, unchecked. To have copied files checked there, add the folder in Settings."),
                      userInfo: [NotifyKey.problem: Kind.clipboardUnchecked.rawValue])
    }

    /// A stage threw before the clean copy reached the disk; the image still holds every secret.
    static func scanFailed(path: String?, displayName: String, noun: ImageNoun = .screenshot) -> ProblemNotice {
        guard let path else {
            return ProblemNotice(kind: .clipboardUnchecked, key: "clipboard.failed",
                                 title: String(localized: "Couldn't black out the image you copied"),
                                 body: String(localized: "Something went wrong while cleaning it. Your clipboard still holds it as it is."),
                                 userInfo: [NotifyKey.problem: Kind.clipboardUnchecked.rawValue])
        }
        return ProblemNotice(kind: .fileUnchecked, key: "unchecked.\(path)",
                             title: noun == .screenshot ? String(localized: "Couldn't black out one screenshot")
                                                        : String(localized: "Couldn't black out one image"),
                             body: String(localized: "Something went wrong while cleaning \(displayName), so it was left as it is. Any secret in it is still there."),
                             userInfo: [NotifyKey.problem: Kind.fileUnchecked.rawValue, NotifyKey.path: path], subject: displayName)
    }

    /// The clean copy could not be written. `secrets` names what is still on disk ("the Stripe secret key", "3 secrets").
    static func writeFailed(path: String?, displayName: String, entryID: UUID?, secrets: String?,
                            readOnly: Bool, keepBoth: Bool) -> ProblemNotice {
        let what = secrets ?? String(localized: "every secret")
        guard let path else {
            // The clipboard write-back threw: the pasteboard still holds the original.
            var info = [NotifyKey.problem: Kind.clipboardUnchecked.rawValue]
            if let entryID { info[NotifyKey.entry] = entryID.uuidString }
            return ProblemNotice(kind: .clipboardUnchecked, key: "clipboard.writeFailed",
                                 title: String(localized: "Couldn't put the clean copy on the clipboard"),
                                 body: String(localized: "Your clipboard still holds the original, so \(what) is still in it. The clean copy is in the Journal."),
                                 userInfo: info)
        }
        let body: String
        if keepBoth {
            body = String(localized: "The clean copy couldn't be saved next to \(displayName), so \(what) is still in that file. The clean copy is in the Journal.")
        } else if readOnly {
            body = String(localized: "\(displayName) is read-only, so \(what) is still in that file. The clean copy is in the Journal.")
        } else {
            body = String(localized: "\(displayName) couldn't be overwritten, so \(what) is still in that file. The clean copy is in the Journal.")
        }
        var info = [NotifyKey.problem: Kind.writeFailed.rawValue, NotifyKey.path: path]
        if let entryID { info[NotifyKey.entry] = entryID.uuidString }
        return ProblemNotice(kind: .writeFailed, key: "writeFailed.\(path)",
                             title: String(localized: "Couldn't save the clean copy"), body: body, userInfo: info, subject: displayName)
    }
}
