// ObscuraNotifyUI — every word a banner says, decided from values (CHANGES.md "Catch titles" 31, "The verdict" 30).
// Secret first, verb second, full detector name: "Stripe secret key blacked out", "3 secrets blacked out".
import Foundation
import ObscuraUIKit

enum NotificationCopy {
    // MARK: Catch

    /// The silent banner for one caught image. Request id = entry id; thread = source.
    static func catchPlan(_ facts: CatchFacts, retentionHours: Int, now: Date, calendar: Calendar = .current) -> NotificationPlan {
        let spots = spotSentence(facts)
        let body = catchBody(facts, retentionHours: retentionHours, now: now, calendar: calendar)
        return NotificationPlan(identifier: facts.entryID.uuidString,
                         title: catchTitle(facts),
                         body: spots.map { body + " " + $0 } ?? body,
                         // The clipboard kept a newer copy (#18): "Safe to paste" would describe something else. G-40: a
                         // picture with a spot no reading could read is never presented as fully read.
                         verdict: (facts.notes.contains(.clipboardChangedMeanwhile) && facts.delivery == .clipboard) || spots != nil
                            ? nil : catchVerdict(facts.delivery, count: 1),
                         threadIdentifier: NotifyID.catchThread(facts.source),
                         categoryIdentifier: NotifyID.catchCategory,
                         level: .active, sound: false, kind: .catchOne,
                         userInfo: [NotifyKey.entry: facts.entryID.uuidString])
    }

    /// G-40: what the catch says about spots no reading could read: covered with "Cover spots Obscura can't read" on, or
    /// waiting for the person. Nil when there were none.
    static func spotSentence(_ facts: CatchFacts) -> String? {
        if facts.spotsCovered > 0 {
            return facts.spotsCovered == 1
                ? String(localized: "Obscura couldn't read 1 small spot in it, so it was covered too.")
                : String(localized: "Obscura couldn't read \(facts.spotsCovered) small spots in it, so they were covered too.")
        }
        if facts.pendingSpots > 0 {
            return facts.pendingSpots == 1
                ? String(localized: "Obscura couldn't read a small spot in it. Check it in the viewer.")
                : String(localized: "Obscura couldn't read \(facts.pendingSpots) small spots in it. Check them in the viewer.")
        }
        return nil
    }

    /// G-40: the one quiet notice for a copied image whose only unread parts are spots no reading could read (it has no
    /// row to list). Passive: no sound, no banner over the work.
    static func clipboardSpotsPlan(spots: Int) -> NotificationPlan {
        NotificationPlan(identifier: NotifyID.problemRequest("clipboard.spots"),
                         title: spots == 1 ? String(localized: "1 spot couldn't be read") : String(localized: "\(spots) spots couldn't be read"),
                         body: String(localized: "Obscura couldn't read a small spot in the image you copied. Your clipboard still holds it as it is; check it before you paste it."),
                         verdict: nil, threadIdentifier: NotifyID.problemThread, categoryIdentifier: nil,
                         level: .passive, sound: false, kind: .problem,
                         userInfo: [NotifyKey.problem: "clipboardSpots"])
    }

    static func catchTitle(_ facts: CatchFacts) -> String {
        if facts.findingCount == 0 && facts.spotsCovered > 0 {
            // G-40: only spots no reading could read were covered: no secret was found, and the title says so.
            return facts.spotsCovered == 1 ? String(localized: "1 unreadable spot covered")
                                           : String(localized: "\(facts.spotsCovered) unreadable spots covered")
        }
        if facts.findingCount == 1, let name = facts.findingNames.first {
            return String(localized: "\(name) blacked out")
        }
        return String(localized: "\(facts.findingCount) secrets blacked out")
    }

    static func catchBody(_ facts: CatchFacts, retentionHours: Int, now: Date, calendar: Calendar = .current) -> String {
        let expiry = facts.createdAt.addingTimeInterval(TimeInterval(retentionHours) * 3600)
        // Several findings in one image: the body names them, as the burst summary does.
        let lead: String = facts.findingCount > 1
            ? String(localized: "\(namesList(facts.findingNames, inSentence: facts.inSentenceNames)), in")
            : String(localized: "In")
        switch facts.delivery {
        case .fileReplaced:
            let until = untilPhrase(expiry, now: now, calendar: calendar, withTime: true)
            return String(localized: "\(lead) \(facts.displayName). The file is clean; the original is in the Journal \(until).")
        case .keepBoth(let cleanName):
            let shown = shortCleanName(cleanName, original: facts.displayName)
            let still = facts.findingCount == 1 ? String(localized: "The original file still shows the secret.")
                                                : String(localized: "The original file still shows every secret.")
            return String(localized: "\(lead) \(facts.displayName). Saved the clean copy next to it as “\(shown)”. \(still)")
        case .clipboard:
            let until = untilPhrase(expiry, now: now, calendar: calendar, withTime: false)
            let where_ = facts.findingCount > 1 ? String(localized: "\(lead) the image you copied.") : String(localized: "In the image you copied.")
            if facts.notes.contains(.clipboardChangedMeanwhile) {
                return String(localized: "\(where_) You copied something else while it was checked, so that was left on your clipboard. The clean copy and the original are in the Journal \(until).")
            }
            if facts.notes.contains(.companionTextRemoved) {
                return String(localized: "\(where_) Your clipboard now holds the clean copy. The text copied with it held a secret too, so it was left out. The original is in the Journal \(until).")
            }
            if facts.notes.contains(.companionTextNotChecked) {
                return String(localized: "\(where_) Your clipboard now holds the clean copy. The text copied with it was too long to check, so it was left out. The original is in the Journal \(until).")
            }
            return String(localized: "\(where_) Your clipboard now holds the clean copy. The original is in the Journal \(until).")
        }
    }

    /// The line under the body (the mockup's pill): what the user may do with the result now.
    static func catchVerdict(_ delivery: CatchDelivery, count: Int) -> String {
        switch delivery {
        case .fileReplaced: return Verdict.safeToShare(total: count).title
        case .clipboard: return String(localized: "Safe to paste")
        case .keepBoth: return count == 1 ? String(localized: "Share the (clean) copy") : String(localized: "Share the (clean) copies")
        }
    }

    // MARK: Burst summary

    /// Three or more catches from one source inside a minute, as one banner. Names the detectors, counts the secrets.
    /// `first`: the summary appears with one banner; a later catch updates it in place quietly (`.passive`: no banner,
    /// no sound), so a burst does not slide a new banner in for every catch.
    static func summaryPlan(identifier: String, items: [CatchFacts], since: Date, now: Date, first: Bool = true) -> NotificationPlan {
        let secrets = items.reduce(0) { $0 + $1.findingCount }
        let names = uniqueNames(items)
        let time = since.formatted(date: .omitted, time: .shortened)
        let source = items.first?.source ?? "file"
        let keepsOriginals = items.contains { if case .keepBoth = $0.delivery { return true } else { return false } }
        let images: String
        if source == "clipboard" {
            images = String(localized: "\(items.count) copied images")
        } else {
            images = String(localized: "\(items.count) screenshots")
        }
        let tail = keepsOriginals ? String(localized: "Clean copies saved next to them; the originals still show the secrets.")
                                  : String(localized: "All clean.")
        let body = String(localized: "\(names), in \(images) since \(time). \(tail)")
        let delivery: CatchDelivery = keepsOriginals ? .keepBoth(cleanName: "") : (source == "clipboard" ? .clipboard : .fileReplaced)
        return NotificationPlan(identifier: identifier,
                                title: String(localized: "\(secrets) secrets blacked out"),
                                body: body,
                                verdict: catchVerdict(delivery, count: items.count),
                                threadIdentifier: NotifyID.catchThread(source),
                                categoryIdentifier: nil,
                                level: first ? .active : .passive, sound: false, kind: .summary,
                                userInfo: [:])
    }

    /// Distinct detector names across a burst, first-seen order, at most three then "N more".
    static func uniqueNames(_ items: [CatchFacts]) -> String {
        var titles: [String] = [], sentence: [String] = [], seen = Set<String>()
        for item in items {
            for (i, name) in item.findingNames.enumerated() where seen.insert(name).inserted {
                titles.append(name)
                sentence.append(i < item.inSentenceNames.count ? item.inSentenceNames[i] : name)
            }
        }
        return namesList(titles, inSentence: sentence)
    }

    /// "Stripe secret key, AWS access key and payment card number" — the first name keeps its title case, the rest
    /// take their in-sentence form; more than three become "and N more".
    static func namesList(_ titles: [String], inSentence: [String]) -> String {
        var seen = Set<String>(), parts: [String] = []
        for (i, title) in titles.enumerated() where seen.insert(title).inserted {
            parts.append(parts.isEmpty ? title : (i < inSentence.count ? inSentence[i] : title))
        }
        if parts.count > 3 {
            let extra = parts.count - 3
            parts = Array(parts.prefix(3)) + [String(localized: "\(extra) more")]
        }
        return parts.formatted(.list(type: .and))
    }

    // MARK: After Undo

    /// Replaces the catch banner (same request id) once the original is back on disk.
    static func restoredPlan(_ facts: CatchFacts) -> NotificationPlan {
        let file = facts.restoreTargetName ?? facts.displayName
        let what = facts.findingCount == 1 ? String(localized: "the \(facts.inSentenceNames.first ?? "")")
                                           : String(localized: "\(facts.findingCount) secrets")
        return NotificationPlan(identifier: facts.entryID.uuidString,
                                title: String(localized: "Undone · original showing"),
                                body: String(localized: "\(file) shows \(what) again. Sensitive. The clean copy is in the Journal."),
                                verdict: Verdict.originalShowing(total: facts.findingCount).title,
                                threadIdentifier: NotifyID.catchThread(facts.source),
                                categoryIdentifier: NotifyID.restoredCategory,
                                level: .active, sound: false, kind: .restored,
                                userInfo: [NotifyKey.entry: facts.entryID.uuidString])
    }

    // MARK: Problems and the update

    static func problemPlan(_ notice: ProblemNotice) -> NotificationPlan {
        NotificationPlan(identifier: NotifyID.problemRequest(notice.key),
                         title: notice.title, body: notice.body, verdict: nil,
                         threadIdentifier: NotifyID.problemThread,
                         categoryIdentifier: actions(for: notice.kind).isEmpty ? nil : NotifyID.problemCategory(notice.kind),
                         level: .timeSensitive, sound: true, kind: .problem,
                         userInfo: notice.userInfo)
    }

    /// Several per-file problems of one family, as one alert (`ProblemBatcher`). Never sounded: the single alert it
    /// replaces already made the burst's one sound. `first`: it shows once; later it updates in place quietly.
    static func combinedProblemPlan(identifier: String, family: ProblemBatcher.Family, notices: [ProblemNotice], first: Bool) -> NotificationPlan {
        let names = notices.compactMap(\.subject)
        let list = namesList(names, inSentence: names)
        let n = notices.count
        let title: String, body: String, kind: ProblemNotice.Kind
        switch family {
        case .unchecked:
            title = String(localized: "\(n) images weren't checked")
            body = String(localized: "\(list) were left as they are, unchecked. Any secret in them is still there.")
            kind = .filesUnchecked
        case .tooLarge:
            title = String(localized: "\(n) images weren't checked")
            body = String(localized: "\(list) are larger than the size Obscura reads. They were left as they are, unchecked.")
            kind = .filesTooLarge
        case .writeFailed:
            title = String(localized: "Couldn't save \(n) clean copies")
            body = String(localized: "\(list) still hold their secrets. The clean copies are in the Journal.")
            kind = .cleanCopiesFailed
        }
        return NotificationPlan(identifier: identifier, title: title, body: body, verdict: nil,
                                threadIdentifier: NotifyID.problemThread,
                                categoryIdentifier: NotifyID.problemCategory(kind),
                                level: first ? .timeSensitive : .passive, sound: false, kind: .problem,
                                userInfo: [NotifyKey.problem: kind.rawValue])
    }

    static func updatePlan(version: String) -> NotificationPlan {
        NotificationPlan(identifier: NotifyID.updateRequest,
                         title: String(localized: "Obscura \(version) is ready"),
                         body: String(localized: "Installs on the next launch. Checking for updates is the only time Obscura goes online."),
                         verdict: nil,
                         threadIdentifier: NotifyID.updateThread,
                         categoryIdentifier: NotifyID.updateCategory,
                         level: .passive, sound: false, kind: .update,
                         userInfo: [:])
    }

    // MARK: Categories

    /// The buttons each problem kind puts in view (unified notifications.html, "Needs attention" rows).
    static func actions(for kind: ProblemNotice.Kind) -> [ActionSpec] {
        let later = ActionSpec(identifier: NotifyID.later, title: String(localized: "Later"), foreground: false)
        let finder = ActionSpec(identifier: NotifyID.showInFinder, title: String(localized: "Show in Finder"), foreground: true)
        let settings = ActionSpec(identifier: NotifyID.openSettings, title: String(localized: "Open Settings"), foreground: true)
        let stop = ActionSpec(identifier: NotifyID.stopWatching, title: String(localized: "Stop Watching"), foreground: false)
        switch kind {
        case .screenshotFolderDenied:
            return [ActionSpec(identifier: NotifyID.allowAccess, title: String(localized: "Allow Access…"), foreground: true), later]
        case .screenshotFolderMissing:
            return [settings, later]
        case .watchedFolderDenied:
            return [ActionSpec(identifier: NotifyID.openSystemSettings, title: String(localized: "Open System Settings"), foreground: true), stop]
        case .watchedFolderMissing:
            return [settings, stop]
        case .fileUnchecked:
            return [ActionSpec(identifier: NotifyID.checkAgain, title: String(localized: "Check Again"), foreground: false), finder]
        case .fileTooLarge:
            return [finder, settings]
        case .writeFailed:
            return [ActionSpec(identifier: NotifyID.copyClean, title: String(localized: "Copy Clean"), foreground: false), finder]
        case .clipboardUnchecked:
            return []
        case .ruleSkipped, .sourceDown, .filesTooLarge:
            return [settings]
        case .filesUnchecked:
            return [ActionSpec(identifier: NotifyID.openNotChecked, title: String(localized: "Show Not Checked"), foreground: true)]
        case .cleanCopiesFailed:
            return [ActionSpec(identifier: NotifyID.openJournal, title: String(localized: "Open Journal"), foreground: true)]
        }
    }

    /// Every category Obscura registers: the one catch category (Undo in the background, Review in the foreground),
    /// the restored banner's, the update's, and one per problem kind that has buttons.
    static func categories() -> [CategorySpec] {
        let review = ActionSpec(identifier: NotifyID.review, title: String(localized: "Review"), foreground: true)
        var all = [
            CategorySpec(identifier: NotifyID.catchCategory,
                         actions: [ActionSpec(identifier: NotifyID.undo, title: String(localized: "Undo"), foreground: false), review]),
            CategorySpec(identifier: NotifyID.restoredCategory,
                         actions: [ActionSpec(identifier: NotifyID.blackOutAgain, title: String(localized: "Black Out Again"), foreground: false), review]),
            CategorySpec(identifier: NotifyID.updateCategory,
                         actions: [ActionSpec(identifier: NotifyID.installUpdate, title: String(localized: "Install and Relaunch"), foreground: true),
                                   ActionSpec(identifier: NotifyID.whatsNew, title: String(localized: "What's New"), foreground: true),
                                   ActionSpec(identifier: NotifyID.later, title: String(localized: "Later"), foreground: false)]),
        ]
        for kind in ProblemNotice.Kind.allCases {
            let actions = actions(for: kind)
            if !actions.isEmpty { all.append(CategorySpec(identifier: NotifyID.problemCategory(kind), actions: actions)) }
        }
        return all
    }

    // MARK: Helpers

    /// "until 10:41 AM", "until tomorrow 9:41 AM", "until Nov 25"; without the time: "until today", "until tomorrow".
    static func untilPhrase(_ expiry: Date, now: Date, calendar: Calendar = .current, withTime: Bool) -> String {
        let time = expiry.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(expiry, inSameDayAs: now) {
            return withTime ? String(localized: "until \(time)") : String(localized: "until later today")
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(expiry, inSameDayAs: tomorrow) {
            return withTime ? String(localized: "until tomorrow \(time)") : String(localized: "until tomorrow")
        }
        let day = expiry.formatted(.dateTime.month(.abbreviated).day())
        return String(localized: "until \(day)")
    }

    /// The keep-both copy's name as the banner shows it: "… (clean).png" when it extends the original's stem.
    static func shortCleanName(_ clean: String, original: String) -> String {
        let stem = (original as NSString).deletingPathExtension
        guard !stem.isEmpty, clean.hasPrefix(stem), clean.count > stem.count else { return clean }
        return "…" + clean.dropFirst(stem.count)
    }
}
