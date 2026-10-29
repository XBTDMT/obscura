// What the panel shows, as plain values built from the model's state at one instant. The view draws a snapshot and
// nothing else, so every state in design/mockups/unified/menubar.html is a value a test can build and check.
import Foundation
import CoreGraphics
import ObscuraUIKit
import ObscuraEngine
import ObscuraJournal
import ObscuraPrefs

/// The key equivalent shown beside a button or row and bound to it: the command's current chord from the person's
/// bindings (G-20), nil when it has none.
typealias Shortcut = KeyChord

struct PanelSnapshot: Equatable {
    enum ButtonRole: Hashable { case quiet, primary, warn }

    struct ActionButton: Equatable, Identifiable {
        var title: String
        var symbol: String? = nil
        var shortcut: Shortcut? = nil
        var role: ButtonRole = .quiet
        var action: PanelAction
        var id: String { title }
    }

    struct Header: Equatable {
        var tone: Tone
        var title: String
        var sentence: String
        /// The soft ring around the dot; paused draws none.
        var halo: Bool
    }

    struct Banner: Equatable, Identifiable {
        var id: String
        var tone: Tone
        var symbol: String
        var title: String
        var body: String
        /// A run of `body` drawn bold (the one unchecked file's name).
        var emphasis: String? = nil
        var buttons: [ActionButton]
    }

    struct Paused: Equatable {
        var title: String
        var detail: String
        var resume: ActionButton
        /// The colour that shows Paused (`Settings.pausedColor`, G-19 #17): its dot, and its title unless it is grey.
        var tone: Tone
    }

    /// The setup card that stands in the last catch's place while setup is unfinished (G-19 M-19; onboarding.html
    /// screen 11 "Menu bar while unfinished · resumable"): "Setup · 4 of 8 done", "4 left", the bar, the next step and
    /// Continue setup.
    struct SetupCard: Equatable {
        var title: String
        /// "4 left"; nil when the count is not known.
        var remaining: String?
        /// 0…1; nil when the count is not known (the bar is left out rather than guessed).
        var progress: Double?
        /// "Next: Floating thumbnail"; nil when not known.
        var next: String?
        var button: ActionButton
    }

    struct Checking: Equatable {
        var title: String
        var position: String?
        var detail: String
    }

    struct Catch: Equatable {
        var entryID: UUID
        var entry: Entry?
        var timeLabel: String
        var title: String
        /// Set when the title carries a verdict colour (red original showing, orange left visible).
        var titleTone: Tone?
        var lines: [String]
        var buttons: [ActionButton]
    }

    struct RecentRow: Equatable, Identifiable {
        var id: UUID
        var tone: Tone
        var title: String
        var titleTone: Tone?
        var subtitle: String
        var buttons: [ActionButton]
    }

    struct Recent: Equatable {
        var badge: String
        var rows: [RecentRow]
    }

    struct Bar: Equatable, Identifiable {
        var id: String
        var height: CGFloat
        var isZero: Bool
        var isToday: Bool
        var initial: String
    }

    struct Week: Equatable {
        var secrets: Int
        var checked: Int
        var secretsLabel: String
        var checkedLabel: String
        var bars: [Bar]
        var accessibilitySummary: String
    }

    struct MenuRow: Equatable, Identifiable {
        enum Kind: Equatable {
            case action(PanelAction)
            /// Pause Protection opens the duration pop.
            case pauseMenu(current: PauseChoice)
        }
        var id: String
        var symbol: String
        var title: String
        var shortcut: Shortcut?
        var accessory: String?
        var kind: Kind
    }

    enum MenuItem: Equatable, Identifiable {
        case row(MenuRow)
        case separator(String)
        var id: String {
            switch self {
            case .row(let r): return r.id
            case .separator(let id): return "sep." + id
            }
        }
    }

    var banners: [Banner]
    var header: Header
    var paused: Paused?
    var setup: SetupCard?
    var checking: Checking?
    var lastCatch: Catch?
    var recent: Recent?
    var week: Week
    var menu: [MenuItem]
    var footer: String

    /// The largest number of Recent rows drawn; the badge still counts them all.
    static let maxRecentRows = 3
    /// Under a minute, a catch is "just now".
    static let justNowWindow: TimeInterval = 60
    static let barMaxHeight: CGFloat = 20
    static let barMinHeight: CGFloat = 4
    static let barZeroHeight: CGFloat = 2
}

/// Everything a snapshot is built from.
struct PanelInputs {
    var status: EngineStatus
    var entries: [Entry]
    var settings: ObscuraPrefs.Settings
    /// The update waiting for the user (`AppModel.updateOffer`); nil when none is, or Later hid it.
    var updateOffer: UpdateOffer?
    /// The pause from the model (`AppModel.pause`): its persisted end and, until a relaunch, its start.
    var pause: PauseState?
    var focusHolding: Bool
    var memory: MemoryState
    /// Setup's progress (`AppModel.setupSummary`), for the setup card while setup is unfinished.
    var setup: SetupSummary? = nil
    var now: Date
    var calendar: Calendar = .current
    var downloadsFolder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    var screenshotFolder: URL

    /// The part of `PanelMemory` a snapshot reads, as a value.
    struct MemoryState: Equatable {
        var lastSeen: Date
        var pauseChoice: PauseChoice
        var checkingPeak: Int
    }
}

extension PanelSnapshot {
    static func make(_ input: PanelInputs) -> PanelSnapshot {
        let status = input.status, settings = input.settings
        let isPaused: Bool = { if case .paused = status.protection { return true }; return false }()
        let checkingCount = isPaused ? 0 : max(status.inFlight, status.queueDepth)

        // The last catch: the engine's, else the newest Journal entry (the engine forgets it on relaunch).
        let catchEntry: Entry? = status.lastCatch.flatMap { lc in input.entries.first { $0.id == lc.entryID } } ?? input.entries.first
        let catchID = status.lastCatch?.entryID ?? catchEntry?.id
        let catchDate = status.lastCatch?.date ?? catchEntry?.createdAt

        // Unreviewed: created after the panel was last seen, other than the last catch itself. A restored original
        // leads (it is the one thing on screen that is not safe), then newest first.
        let unseen = input.entries
            .filter { $0.createdAt > input.memory.lastSeen && $0.id != catchID }
            .enumerated()
            .sorted { a, b in
                let ao = input.verdict(a.element).isOriginalShowing, bo = input.verdict(b.element).isOriginalShowing
                return ao != bo ? ao : a.offset < b.offset
            }
            .map(\.element)

        let banners = makeBanners(input)
        let header = makeHeader(input, isPaused: isPaused, checkingCount: checkingCount, catchDate: catchDate,
                                catchEntry: catchEntry, unseen: unseen)

        var paused: Paused?
        if isPaused {
            let pause = input.pause
            paused = Paused(
                title: pause?.since.map { PanelCopy.pausedSince(PanelCopy.time($0, calendar: input.calendar)) } ?? PanelCopy.pausedTitle,
                detail: pause?.resumesAt.map { PanelCopy.resumes(at: $0, now: input.now, calendar: input.calendar) } ?? PanelCopy.staysPaused,
                resume: ActionButton(title: String(localized: "Resume"), role: .primary, action: .resume),
                tone: settings.pausedColor.tone)
        }
        let setup = settings.hasFinishedSetup ? nil : makeSetupCard(input.setup)

        var checking: Checking?
        if checkingCount > 0 {
            let peak = max(input.memory.checkingPeak, checkingCount)
            checking = Checking(title: PanelCopy.checkingTitle(checkingCount),
                                position: peak > 1 ? String(localized: "\(peak - checkingCount + 1) of \(peak)") : nil,
                                detail: PanelCopy.checkingDetail)
        }

        var lastCatch: Catch?
        if checking == nil, let id = catchID, let date = catchDate {
            lastCatch = makeCatch(id: id, entry: catchEntry, fallback: status.lastCatch, date: date, input: input)
        }

        var recent: Recent?
        if !unseen.isEmpty {
            recent = Recent(badge: String(localized: "\(unseen.count) more"),
                            rows: unseen.prefix(maxRecentRows).map(makeRecentRow))
        }

        return PanelSnapshot(banners: banners, header: header, paused: paused, setup: setup, checking: checking, lastCatch: lastCatch,
                             recent: recent, week: makeWeek(status.weekStats, now: input.now, calendar: input.calendar),
                             menu: makeMenu(input, isPaused: isPaused),
                             footer: PanelCopy.footer(retentionHours: settings.journalRetentionHours))
    }

    // MARK: Banners

    static func makeBanners(_ input: PanelInputs) -> [Banner] {
        var out: [Banner] = input.status.problems.map { problem in
            let words = ProblemCopy.words(for: problem, settings: input.settings, downloads: input.downloadsFolder,
                                          unchecked: input.status.unchecked)
            // G-40: spots waiting for the person are a quiet row, never the orange alarm.
            return Banner(id: problem.id, tone: problem.kind == .unreadSpots ? .accent : .needs, symbol: words.symbol, title: words.title,
                          body: words.body, emphasis: words.emphasis, buttons: problemButtons(problem, input: input))
        }
        if let offer = input.updateOffer {
            // Ready: Install / Later. Installing: no buttons (nothing to press until it relaunches or stops). Failed: the
            // reason in orange, with Try Again / Later.
            let buttons: [ActionButton]
            let tone: Tone
            let symbol: String
            switch offer.phase {
            case .ready:
                tone = .accent
                symbol = "arrow.down.circle"
                buttons = [ActionButton(title: String(localized: "Install and Relaunch"), role: .primary, action: .installUpdate),
                           ActionButton(title: String(localized: "Later"), action: .dismissUpdate)]
            case .installing:
                tone = .accent
                symbol = "arrow.down.circle"
                buttons = []
            case .failed:
                tone = .needs
                symbol = "exclamationmark.triangle"
                buttons = [ActionButton(title: String(localized: "Try Again"), role: .primary, action: .installUpdate),
                           ActionButton(title: String(localized: "Later"), action: .dismissUpdate)]
            }
            out.append(Banner(id: "update", tone: tone, symbol: symbol, title: PanelCopy.updateTitle(offer),
                              body: PanelCopy.updateBody(offer), buttons: buttons))
        }
        return out
    }

    /// The problem's fix is the one orange button; the second is the way out.
    static func problemButtons(_ problem: Problem, input: PanelInputs) -> [ActionButton] {
        switch problem.kind {
        case .folderAccess:
            let fix = problem.messageKey == "problem.folder.missing"
                ? ActionButton(title: String(localized: "Choose Folder…"), role: .warn, action: .openSettings(.protection))
                : problem.messageKey == ShieldEngine.unconfirmedFolderKey
                    ? ActionButton(title: String(localized: "Review…"), role: .warn, action: .openSettings(.protection))
                    : ActionButton(title: String(localized: "Grant Access…"), role: .warn, action: .openSettings(.protection))
            guard let folder = watchedFolder(for: problem.url, input: input) else { return [fix] }
            return [fix, ActionButton(title: String(localized: "Stop Watching"), action: .stopWatching(folder))]
        case .ruleCompile:
            if problem.messageKey.hasPrefix("problem.override.") || problem.messageKey == "problem.catalogue.failed" {
                return [ActionButton(title: String(localized: "Open Detectors"), role: .warn, action: .openSettings(.detectors))]
            }
            return [ActionButton(title: String(localized: "Open Custom Rules"), role: .warn, action: .openSettings(.customRules))]
        case .sourceStart:
            return [ActionButton(title: String(localized: "Open Settings"), role: .warn, action: .openSettings(.protection))]
        case .scanFailure:
            // menubar.html: Check Again (the fix, orange) sends every unchecked file back through the engine; Open in
            // Journal is the way out, onto the Journal's Not checked section, which lists each file (G-13). A failure with
            // no file to check again (a clipboard image, a failed write-back) gets no Check Again, so there is never a dead
            // button; its Open in Journal shows the catches, where a failed write-back's entry is.
            guard !input.status.unchecked.isEmpty else {
                return [ActionButton(title: String(localized: "Open in Journal"), action: .openJournal)]
            }
            let journal = ActionButton(title: String(localized: "Open in Journal"), action: .openJournalNotChecked)
            return [ActionButton(title: String(localized: "Check Again"), role: .warn, action: .checkAgain), journal]
        case .notCovered:
            // Try Again (the fix) writes each covered picture again; Open in Journal lists every such file.
            return [ActionButton(title: String(localized: "Try Again"), role: .warn, action: .retryNotCovered),
                    ActionButton(title: String(localized: "Open in Journal"), action: .openJournalNotCovered)]
        case .journalMaintenance:
            // Try Again runs the Journal's upkeep now; Open in Journal shows what is kept.
            return [ActionButton(title: String(localized: "Try Again"), role: .warn, action: .retryMaintenance),
                    ActionButton(title: String(localized: "Open in Journal"), action: .openJournal)]
        case .unreadSpots:
            // Review opens the newest such picture in the spot viewer; Open in Journal lists every one under Not checked.
            let journal = ActionButton(title: String(localized: "Open in Journal"), action: .openJournalNotChecked)
            guard let newest = input.status.unchecked.filter(\.isUnreadSpots).max(by: { $0.date < $1.date }) else { return [journal] }
            return [ActionButton(title: SpotCopy.review, role: .primary, action: .reviewSpots(newest.id)), journal]
        case .ocrWarmup:
            return []
        }
    }

    /// Which setting watches this folder, so Stop Watching turns off exactly that one.
    static func watchedFolder(for url: URL?, input: PanelInputs) -> WatchedFolder? {
        guard let path = url?.standardizedFileURL.path else { return nil }
        if input.settings.guardsDownloads, path == input.downloadsFolder.standardizedFileURL.path { return .downloads }
        if let raw = input.settings.extraFolders.first(where: {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path == path
        }) { return .extra(raw) }
        if input.settings.guardsScreenshotFolder, path == input.screenshotFolder.standardizedFileURL.path { return .screenshotFolder }
        return nil
    }

    // MARK: Header

    static func makeHeader(_ input: PanelInputs, isPaused: Bool, checkingCount: Int, catchDate: Date?, catchEntry: Entry?,
                           unseen: [Entry]) -> Header {
        let status = input.status
        switch status.protection {
        case .paused:
            return Header(tone: input.settings.pausedColor.tone, title: ProtectionCopy.title(.paused), sentence: PanelCopy.pausedSentence,
                          halo: false)
        case .needsAttention(let problems):
            let first = problems.first { $0.kind == .notCovered || $0.kind == .folderAccess || $0.kind == .scanFailure } ?? problems.first
            let sentence = first.map {
                ProblemCopy.words(for: $0, settings: input.settings, downloads: input.downloadsFolder, unchecked: status.unchecked).headline
            }
                ?? String(localized: "Something needs your attention.")
            return Header(tone: .needs, title: ProtectionCopy.title(status.protection), sentence: sentence, halo: true)
        default:
            break
        }
        if checkingCount > 0 {
            return Header(tone: .accent, title: PanelCopy.checkingTitle(checkingCount), sentence: PanelCopy.checkingSentence, halo: true)
        }
        if case .partlyProtected(let reasons) = status.protection {
            return Header(tone: .needs, title: ProtectionCopy.title(status.protection),
                          sentence: PanelCopy.partlySentence(reasons: reasons, settings: input.settings), halo: true)
        }
        let title = ProtectionCopy.title(.protected)
        if !unseen.isEmpty, let catchEntry {
            let burst = unseen + [catchEntry]
            let secrets = burst.reduce(0) { $0 + $1.findings.count }
            let oldest = burst.map(\.createdAt).min() ?? catchEntry.createdAt
            return Header(tone: .ok, title: title, sentence: PanelCopy.caughtSince(secrets, time: PanelCopy.time(oldest, calendar: input.calendar)), halo: true)
        }
        if let catchDate, input.now.timeIntervalSince(catchDate) < justNowWindow {
            let secrets = status.lastCatch?.findings ?? catchEntry?.findings.count ?? 1
            return Header(tone: .ok, title: title, sentence: PanelCopy.caughtJustNow(secrets), halo: true)
        }
        if let offer = input.updateOffer { return Header(tone: .ok, title: title, sentence: PanelCopy.updateSentence(offer), halo: true) }
        if input.focusHolding { return Header(tone: .ok, title: title, sentence: PanelCopy.focusSentence, halo: true) }
        return Header(tone: .ok, title: title, sentence: PanelCopy.watchedSentence(input.settings), halo: true)
    }

    // MARK: Setup

    static func makeSetupCard(_ summary: SetupSummary?) -> SetupCard {
        let button = ActionButton(title: String(localized: "Continue setup"), role: .primary, action: .openSetup)
        guard let summary, summary.total > 0 else {
            return SetupCard(title: String(localized: "Setup is not finished"), remaining: nil, progress: nil, next: nil, button: button)
        }
        let done = min(max(summary.done, 0), summary.total)
        let left = summary.total - done
        return SetupCard(title: String(localized: "Setup · \(done) of \(summary.total) done"),
                         remaining: left == 1 ? String(localized: "1 left") : String(localized: "\(left) left"),
                         progress: Double(done) / Double(summary.total),
                         next: summary.next.map { String(localized: "Next: \($0)") },
                         button: button)
    }

    // MARK: Catches

    static func makeCatch(id: UUID, entry: Entry?, fallback: LastCatch?, date: Date, input: PanelInputs) -> Catch {
        let timeLabel = input.now.timeIntervalSince(date) < justNowWindow ? String(localized: "just now") : PanelCopy.time(date, calendar: input.calendar)
        let copy = ActionButton(title: String(localized: "Copy Clean"), symbol: "doc.on.doc", action: .copyClean(id))
        let review = ActionButton(title: String(localized: "Review"), symbol: "eye", action: .review(id))
        let undo = ActionButton(title: String(localized: "Undo"), symbol: "arrow.uturn.backward", shortcut: input.settings.keyBindings.chord(for: .panelUndo), action: .undo(id))
        guard let entry else {
            let n = fallback?.findings ?? 0
            return Catch(entryID: id, entry: nil, timeLabel: timeLabel, title: ProtectionCopy.secrets(n), titleTone: nil,
                         lines: [fallback?.displayName ?? ""], buttons: [undo, copy, review])
        }
        switch input.verdict(entry) {
        case .originalShowing:
            return Catch(entryID: id, entry: entry, timeLabel: timeLabel, title: PanelCopy.originalShowingTitle(entry), titleTone: .live,
                         lines: [PanelCopy.undoneSubtitle(entry)],
                         buttons: [ActionButton(title: String(localized: "Black Out Again"), symbol: "eye.slash", action: .blackOutAgain(id)),
                                   copy, review])
        case .leftVisible(let visible, let total):
            return Catch(entryID: id, entry: entry, timeLabel: timeLabel, title: PanelCopy.foundTitle(entry), titleTone: nil,
                         lines: [entry.displayName, Verdict.leftVisible(visible: visible, total: total).title],
                         buttons: [undo, copy, review])
        case .safeToShare:
            return Catch(entryID: id, entry: entry, timeLabel: timeLabel, title: PanelCopy.foundTitle(entry), titleTone: nil,
                         lines: [entry.displayName, PanelCopy.cleanCopyLine(entry, retentionHours: input.settings.journalRetentionHours)],
                         buttons: [undo, copy, review])
        }
    }

    static func makeRecentRow(_ entry: Entry) -> RecentRow {
        let review = ActionButton(title: String(localized: "Review"), action: .review(entry.id))
        let verdict = Verdict(enabled: entry.enabledFindings.count, total: entry.findings.count)
        switch verdict {
        case .originalShowing:
            return RecentRow(id: entry.id, tone: .live, title: PanelCopy.originalShowingTitle(entry), titleTone: .live,
                             subtitle: PanelCopy.undoneSubtitle(entry),
                             buttons: [ActionButton(title: String(localized: "Black Out Again"), action: .blackOutAgain(entry.id))])
        case .leftVisible:
            return RecentRow(id: entry.id, tone: .needs, title: verdict.title, titleTone: .needs,
                             subtitle: PanelCopy.recentSubtitle(entry),
                             buttons: [ActionButton(title: String(localized: "Undo"), action: .undo(entry.id)), review])
        case .safeToShare:
            return RecentRow(id: entry.id, tone: .ok, title: PanelCopy.blackedOutTitle(entry), titleTone: nil,
                             subtitle: PanelCopy.recentSubtitle(entry),
                             buttons: [ActionButton(title: String(localized: "Undo"), action: .undo(entry.id)), review])
        }
    }

    // MARK: Week

    static func makeWeek(_ stats: [DayStats], now: Date, calendar: Calendar) -> Week {
        // Today and the six days before, oldest first; zero-filled when the engine has not reported yet.
        let parser = DateFormatter()
        parser.calendar = calendar
        parser.timeZone = calendar.timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        let days: [(key: String, date: Date)] = (0..<7).reversed().compactMap { back in
            guard let d = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            return (parser.string(from: d), d)
        }
        let byDay = Dictionary(stats.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let values = days.map { byDay[$0.key]?.secrets ?? 0 }
        let maxValue = max(1, values.max() ?? 0)
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let names = calendar.standaloneWeekdaySymbols
        let bars: [Bar] = days.enumerated().map { i, day in
            let v = values[i]
            let h = v == 0 ? barZeroHeight : max(barMinHeight, barMaxHeight * CGFloat(v) / CGFloat(maxValue))
            let weekday = calendar.component(.weekday, from: day.date) - 1
            return Bar(id: day.key, height: h, isZero: v == 0, isToday: i == days.count - 1, initial: symbols[weekday])
        }
        let secrets = days.reduce(0) { $0 + (byDay[$1.key]?.secrets ?? 0) }
        let checked = days.reduce(0) { $0 + (byDay[$1.key]?.checked ?? 0) }
        let perDay = days.enumerated().map { i, day in
            "\(names[calendar.component(.weekday, from: day.date) - 1]) \(values[i])"
        }.formatted(.list(type: .and))
        let summary = String(localized: "\(secrets) \(PanelCopy.secretsThisWeek(secrets)), \(checked) \(PanelCopy.imagesChecked(checked)). Secrets per day: \(perDay).")
        return Week(secrets: secrets, checked: checked, secretsLabel: PanelCopy.secretsThisWeek(secrets),
                    checkedLabel: PanelCopy.imagesChecked(checked), bars: bars, accessibilitySummary: summary)
    }

    // MARK: Menu

    static func makeMenu(_ input: PanelInputs, isPaused: Bool) -> [MenuItem] {
        // The rows show (and answer to) the App commands' chords: the same commands as the main menu's.
        let keys = input.settings.keyBindings
        var rows: [MenuItem] = []
        if isPaused {
            rows.append(.row(MenuRow(id: "resume", symbol: "play.fill", title: String(localized: "Resume Protection"),
                                     shortcut: nil, accessory: nil, kind: .action(.resume))))
        } else {
            rows.append(.row(MenuRow(id: "pause", symbol: "pause", title: String(localized: "Pause Protection"), shortcut: nil,
                                     accessory: input.memory.pauseChoice.shortTitle, kind: .pauseMenu(current: input.memory.pauseChoice))))
        }
        rows.append(.row(MenuRow(id: "journal", symbol: "list.bullet.rectangle", title: String(localized: "Open Journal"),
                                 shortcut: keys.chord(for: .appOpenJournal), accessory: nil, kind: .action(.openJournal))))
        rows.append(.row(MenuRow(id: "settings", symbol: "gearshape", title: String(localized: "Settings…"),
                                 shortcut: keys.chord(for: .appSettings), accessory: nil, kind: .action(.openSettings(.protection)))))
        // Setup is always reachable: an unfinished one resumes from the setup card's Continue setup (G-19 M-19, which
        // replaces the old "Continue Setup…" row), a finished one can be revisited from this row.
        if input.settings.hasFinishedSetup {
            rows.append(.row(MenuRow(id: "setup", symbol: "checklist", title: String(localized: "Setup…"),
                                     shortcut: nil, accessory: nil, kind: .action(.openSetup))))
        }
        if let offer = input.updateOffer {
            rows.append(.row(MenuRow(id: "updates", symbol: "arrow.down.circle", title: PanelCopy.installUpdateRow(offer),
                                     shortcut: nil, accessory: nil, kind: .action(.installUpdate))))
        } else {
            rows.append(.row(MenuRow(id: "updates", symbol: "arrow.up.circle", title: String(localized: "Check for Updates…"),
                                     shortcut: nil, accessory: nil, kind: .action(.checkForUpdates))))
        }
        rows.append(.separator("quit"))
        rows.append(.row(MenuRow(id: "quit", symbol: "rectangle.portrait.and.arrow.right", title: String(localized: "Quit Obscura"),
                                 shortcut: keys.chord(for: .appQuit), accessory: nil, kind: .action(.quit))))
        return rows
    }
}

extension Verdict {
    var isOriginalShowing: Bool { if case .originalShowing = self { return true }; return false }
}

extension PanelInputs {
    func verdict(_ entry: Entry) -> Verdict {
        Verdict(enabled: entry.enabledFindings.count, total: entry.findings.count)
    }
}
