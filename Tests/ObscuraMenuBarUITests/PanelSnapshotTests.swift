// Every state in design/mockups/unified/menubar.html, built as a snapshot value and checked for what the mockup shows.
import Foundation
import AppKit
import Testing
import ObscuraUIKit
import ObscuraEngine
import ObscuraJournal
import ObscuraPrefs
@testable import ObscuraMenuBarUI

/// Clock times carry a narrow no-break space before AM/PM; compare them as plain spaces.
func plain(_ s: String?) -> String? { s?.replacingOccurrences(of: "\u{202F}", with: " ") }

@Suite struct PanelSnapshotTests {
    // MARK: Caught just now

    @Test func caughtJustNowShowsTheCatchCardAndTheWeek() {
        let catchInfo = LastCatch(entryID: TestData.stripeAndEmail.id, displayName: TestData.stripeAndEmail.displayName,
                                  findings: 2, date: TestData.date(9, 41, 12))
        let s = PanelSnapshot.make(TestData.inputs(status: EngineStatus(lastCatch: catchInfo, weekStats: TestData.week(today: 2))))

        #expect(s.header.tone == .ok && s.header.halo)
        #expect(s.header.title == "Protected")
        #expect(s.header.sentence == "Blacked out 2 secrets just now.")
        #expect(s.banners.isEmpty && s.paused == nil && s.checking == nil && s.recent == nil)

        let c = try! #require(s.lastCatch)
        #expect(c.timeLabel == "just now")
        #expect(c.title.contains("Stripe secret") && c.title.contains("Email address"))
        #expect(c.lines == ["Screenshot 2026-10-26 at 9.41.12 AM.png", "Replaced with a clean copy · original in the Journal for 24 h"])
        #expect(c.buttons.map(\.title) == ["Undo", "Copy Clean", "Review"])
        #expect(c.buttons[0].action == .undo(TestData.stripeAndEmail.id))
        #expect(c.buttons[0].shortcut == KeyChord("z", .command))
        #expect(c.buttons[1].action == .copyClean(TestData.stripeAndEmail.id))
        #expect(c.buttons[2].action == .review(TestData.stripeAndEmail.id))

        #expect(s.week.secrets == 8 && s.week.checked == 42)
        #expect(s.week.bars.count == 7)
        #expect(s.week.bars.last?.isToday == true && s.week.bars.last?.isZero == false)
        #expect(s.week.bars.map(\.initial) == ["T", "W", "T", "F", "S", "S", "M"])
        #expect(s.week.bars.map(\.isZero) == [false, true, false, false, true, true, false])
        #expect(s.week.bars.map(\.height).max() == PanelSnapshot.barMaxHeight)

        #expect(s.menuTitles == ["Pause Protection", "Open Journal", "Settings…", "Setup…", "Check for Updates…", "Quit Obscura"])
        #expect(s.menuRow("journal")?.shortcut == KeyChord("j", .command))
        #expect(s.menuRow("settings")?.shortcut == KeyChord(",", .command))
        #expect(s.menuRow("quit")?.shortcut == KeyChord("q", .command))
        #expect(s.footer == "Free and open source. Nothing leaves this Mac. Originals live in the Journal for 24 hours, then are deleted.")
    }

    // MARK: Shortcuts follow the person's bindings (G-20)

    @Test func menuRowsShowTheAppCommandsCurrentChords() {
        var settings = TestData.settings()
        settings.keyBindings.set(KeyChord("k", [.control, .command]), for: .appOpenJournal)
        let s = PanelSnapshot.make(TestData.inputs(settings: settings))
        #expect(s.menuRow("journal")?.shortcut == KeyChord("k", [.control, .command]))
        #expect(s.menuRow("journal")?.shortcut?.display == "⌃⌘K")
        settings.keyBindings.set(nil, for: .appOpenJournal)
        #expect(PanelSnapshot.make(TestData.inputs(settings: settings)).menuRow("journal")?.shortcut == nil)
    }

    @Test func escapeAloneClosesThePanel() {
        #expect(MenuBarController.isClose(keyCode: 53, baseCharacters: "\u{1b}", flags: []))
        #expect(MenuBarController.isClose(keyCode: 53, baseCharacters: "\u{1b}", flags: .capsLock))
        #expect(!MenuBarController.isClose(keyCode: 53, baseCharacters: "\u{1b}", flags: .command))
        #expect(!MenuBarController.isClose(keyCode: 12, baseCharacters: "q", flags: []))
    }

    // MARK: Idle protected and the pause pop

    @Test func protectedIdleSaysWhatIsWatchedAndThePopRemembersItsDuration() {
        let s = PanelSnapshot.make(TestData.inputs(pauseChoice: .oneHour, now: TestData.date(10, 5)))
        #expect(s.header.sentence == "Screenshots, two folders, and the clipboard are watched.")
        #expect(s.lastCatch?.timeLabel.contains("9:41") == true)
        let pause = try! #require(s.menuRow("pause"))
        #expect(pause.kind == .pauseMenu(current: .oneHour))
        #expect(pause.accessory == "1 hour")
        #expect(PauseChoice.allCases.map(\.menuTitle) == ["For 15 Minutes", "For 1 Hour", "Until Tomorrow", "Until I Resume"])
    }

    @Test func watchedSentenceFollowsTheSources() {
        #expect(PanelCopy.watchedSentence(TestData.settings { $0.guardsDownloads = false; $0.extraFolders = [] })
                == "Screenshots and the clipboard are watched.")
        #expect(PanelCopy.watchedSentence(TestData.settings { $0.guardsScreenshotFolder = false; $0.guardsClipboard = false; $0.extraFolders = [] })
                == "One folder is watched.")
        #expect(PanelCopy.watchedSentence(TestData.settings {
            $0.guardsScreenshotFolder = false; $0.guardsClipboard = false; $0.guardsDownloads = false; $0.extraFolders = []
        }).hasPrefix("Nothing is watched"))
    }

    @Test func pauseDurationsEndWhereTheyShould() {
        let now = TestData.date(23, 10)
        #expect(PauseChoice.fifteenMinutes.resumeDate(from: now, calendar: TestData.calendar) == now.addingTimeInterval(900))
        #expect(PauseChoice.oneHour.resumeDate(from: now, calendar: TestData.calendar) == now.addingTimeInterval(3600))
        #expect(PauseChoice.untilTomorrow.resumeDate(from: now, calendar: TestData.calendar) == TestData.date(0, 0, day: 27))
        #expect(PauseChoice.untilResumed.resumeDate(from: now, calendar: TestData.calendar) == nil)
    }

    // MARK: Checking

    @Test func checkingReplacesTheLastCatchWithProgress() {
        let s = PanelSnapshot.make(TestData.inputs(status: EngineStatus(inFlight: 2, queueDepth: 2, weekStats: TestData.week()),
                                                   checkingPeak: 3))
        #expect(s.header.tone == .accent)
        #expect(s.header.title == "Checking 2 images…")
        #expect(s.header.sentence == "Reading the text on this Mac. Nothing leaves it.")
        let c = try! #require(s.checking)
        #expect(c.position == "2 of 3")
        #expect(s.lastCatch == nil)

        let single = PanelSnapshot.make(TestData.inputs(status: EngineStatus(inFlight: 1, queueDepth: 1)))
        #expect(single.checking?.title == "Checking 1 image…")
        #expect(single.checking?.position == nil)
    }

    // MARK: Needs attention

    @Test func needsAttentionShowsOrangeBannersWithTheirFix() {
        let denied = Problem(kind: .folderAccess, messageKey: "problem.folder.denied", url: TestData.downloads)
        let failed = Problem(kind: .scanFailure, messageKey: "problem.scan.failed", detail: "1")
        let status = EngineStatus(protection: .needsAttention(problems: [denied, failed]), weekStats: TestData.week(), problems: [denied, failed])
        let s = PanelSnapshot.make(TestData.inputs(status: status))

        #expect(s.header.tone == .needs)
        #expect(s.header.title == "Needs attention")
        #expect(s.header.sentence == "Downloads can't be read: folder access was lost.")
        #expect(s.banners.count == 2)
        #expect(s.banners.allSatisfy { $0.tone == .needs })
        #expect(s.banners[0].title == "Downloads can't be read")
        #expect(s.banners[0].body.contains("New downloads aren't checked"))
        #expect(s.banners[0].buttons.map(\.title) == ["Grant Access…", "Stop Watching"])
        #expect(s.banners[0].buttons[0].role == .warn)
        #expect(s.banners[0].buttons[0].action == .openSettings(.protection))
        #expect(s.banners[0].buttons[1].action == .stopWatching(.downloads))
        #expect(s.banners[1].title == "1 image wasn't checked")
        #expect(s.banners[1].body == "An image couldn't be checked, so it was left as it is. Any secret in it is still there.")
        #expect(s.banners[1].buttons.map(\.action) == [.openJournal], "no file to check again, so no Check Again")
        // Red never appears in a banner.
        #expect(!s.banners.flatMap(\.buttons).contains { $0.role == .primary && $0.action != .installUpdate })
        #expect(s.lastCatch != nil)
    }

    @Test func stopWatchingTargetsExactlyTheFolderInTrouble() {
        let extra = Problem(kind: .folderAccess, messageKey: "problem.folder.missing",
                            url: URL(fileURLWithPath: ("~/Projects/example" as NSString).expandingTildeInPath))
        let shots = Problem(kind: .folderAccess, messageKey: "problem.folder.denied", url: TestData.screenshots)
        let unknown = Problem(kind: .folderAccess, messageKey: "problem.folder.denied", url: URL(fileURLWithPath: "/Volumes/Example"))
        let s = PanelSnapshot.make(TestData.inputs(status: EngineStatus(problems: [extra, shots, unknown])))
        #expect(s.banners[0].title == "example is missing")
        #expect(s.banners[0].buttons.map(\.action) == [.openSettings(.protection), .stopWatching(.extra("~/Projects/example"))])
        #expect(s.banners[1].buttons.last?.action == .stopWatching(.screenshotFolder))
        #expect(s.banners[2].buttons.map(\.title) == ["Grant Access…"])
    }

    @Test func everyProblemKindHasWordsAndNoDeadButtons() {
        let problems = [
            Problem(kind: .ruleCompile, messageKey: "problem.rule.compile", detail: "custom.example"),
            Problem(kind: .ruleCompile, messageKey: "problem.override.undecodable"),
            Problem(kind: .ruleCompile, messageKey: "problem.catalogue.failed"),
            Problem(kind: .sourceStart, messageKey: "problem.source.start"),
            Problem(kind: .ocrWarmup, messageKey: "problem.warmup.failed"),
            Problem(kind: .scanFailure, messageKey: "problem.scan.failed", detail: "3"),
            Problem(kind: .ruleCompile, messageKey: "problem.override.compile", detail: "payments.stripe.secretkey: bad"),
        ]
        let s = PanelSnapshot.make(TestData.inputs(status: EngineStatus(problems: problems)))
        #expect(s.banners.count == problems.count)
        #expect(s.banners.allSatisfy { !$0.title.isEmpty && !$0.body.isEmpty })
        #expect(s.banners[0].buttons.first?.action == .openSettings(.customRules))
        #expect(s.banners[1].buttons.first?.action == .openSettings(.detectors))
        #expect(s.banners[2].buttons.first?.action == .openSettings(.detectors))
        #expect(s.banners[3].buttons.first?.action == .openSettings(.protection))
        #expect(s.banners[4].buttons.isEmpty)
        #expect(s.banners[5].title == "3 images weren't checked")
        #expect(s.banners[5].buttons.map(\.action) == [.openJournal])
        // Fail-open #3: an edited detector on its built-in fallback says so and opens Detectors, not Custom Rules.
        #expect(s.banners[6].title == "Edited patterns aren't in use")
        #expect(s.banners[6].body.contains("built-in patterns"))
        #expect(s.banners[6].buttons.first?.action == .openSettings(.detectors))
        // A rule problem alone does not change the protection state.
        #expect(s.header.title == "Protected")
    }

    // MARK: Paused

    @Test func pausedIsRedWithResumeFirst() {
        let record = PauseState(since: TestData.date(9, 30), resumesAt: TestData.date(10, 30))
        let s = PanelSnapshot.make(TestData.inputs(status: EngineStatus(protection: .paused, inFlight: 1, queueDepth: 1),
                                                   pause: record))
        // G-19 #17: Paused shows red by default (Settings.pausedColor; grey is a choice).
        #expect(s.header.tone == .live && !s.header.halo)
        #expect(s.header.title == "Paused")
        #expect(s.header.sentence == "Nothing is checked until you resume. Originals are still kept.")
        let p = try! #require(s.paused)
        #expect(plain(p.title) == "Paused since 9:30 AM")
        #expect(plain(p.detail) == "Resumes automatically at 10:30 AM.")
        #expect(p.resume.action == .resume && p.resume.role == .primary)
        #expect(s.checking == nil)
        #expect(s.menuTitles.first == "Resume Protection")
        #expect(s.menuRow("resume")?.kind == .action(.resume))
        #expect(s.menuRow("pause") == nil)
    }

    @Test func pausedElsewhereStillReadsRight() {
        let s = PanelSnapshot.make(TestData.inputs(status: EngineStatus(protection: .paused)))
        #expect(s.paused?.title == "Paused")
        #expect(s.paused?.detail == "Stays paused until you resume.")
        let overnight = PanelSnapshot.make(TestData.inputs(status: EngineStatus(protection: .paused),
                                                           pause: PauseState(since: TestData.date(9, 30), resumesAt: TestData.date(0, 0, day: 27))))
        #expect(plain(overnight.paused?.detail) == "Resumes automatically tomorrow at 12:00 AM.")
    }

    @Test func aPauseCarriedOverARelaunchStillSaysWhenItEnds() {
        // After a relaunch only the end is known: no start time, but the resume time (or "until you resume") stays.
        let timed = PanelSnapshot.make(TestData.inputs(status: EngineStatus(protection: .paused),
                                                       pause: PauseState(since: nil, resumesAt: TestData.date(10, 30)),
                                                       now: TestData.date(10, 5)))
        #expect(timed.paused?.title == "Paused")
        #expect(plain(timed.paused?.detail) == "Resumes automatically at 10:30 AM.")
        let indefinite = PanelSnapshot.make(TestData.inputs(status: EngineStatus(protection: .paused),
                                                            pause: PauseState(since: nil, resumesAt: nil), now: TestData.date(10, 5)))
        #expect(indefinite.paused?.title == "Paused")
        #expect(indefinite.paused?.detail == "Stays paused until you resume.")
    }

    // MARK: Partly protected

    @Test func partlyProtectedNamesWhatIsOff() {
        let s = PanelSnapshot.make(TestData.inputs(status: EngineStatus(protection: .partlyProtected(reasons: ["protection.clipboardOff"])),
                                                   settings: TestData.settings { $0.guardsClipboard = false }))
        #expect(s.header.tone == .needs)
        #expect(s.header.title == "Partly protected")
        #expect(s.header.sentence == "Clipboard guard is off. 3 of 4 sources are watched.")
        #expect(s.banners.isEmpty)
    }

    /// Fail-open #3: a rule that does not compile is never plain Protected; every source is still watched.
    @Test func partlyProtectedNamesSkippedRules() {
        let problem = Problem(kind: .ruleCompile, messageKey: "problem.override.compile", detail: "payments.stripe.secretkey: bad")
        let s = PanelSnapshot.make(TestData.inputs(status: EngineStatus(protection: .partlyProtected(reasons: ["protection.rulesSkipped"]),
                                                                        problems: [problem])))
        #expect(s.header.title == "Partly protected")
        #expect(s.header.sentence == "Some of your rules or edited patterns aren't in use. 4 of 4 sources are watched.")
        #expect(s.banners.map(\.title) == ["Edited patterns aren't in use"])
    }

    // MARK: Update available

    @Test func updateAvailableIsABlueBannerWithItsVersionAndAnInstallRow() {
        let offer = UpdateOffer(version: "1.1")
        let s = PanelSnapshot.make(TestData.inputs(updateOffer: offer, now: TestData.date(10, 5)))
        #expect(s.header.sentence == "Obscura 1.1 is ready to install.")
        let b = try! #require(s.banners.first)
        #expect(b.tone == .accent)
        #expect(b.title == "Obscura 1.1 is ready")
        #expect(b.body == "Installing downloads it, checks it is signed by the same developer as this copy, and relaunches the app; protection resumes right away.")
        #expect(b.buttons.map(\.title) == ["Install and Relaunch", "Later"])
        #expect(b.buttons.map(\.action) == [.installUpdate, .dismissUpdate])
        #expect(b.buttons[0].role == .primary)
        #expect(s.menuRow("updates")?.title == "Install Update 1.1…")
        #expect(s.menuRow("updates")?.kind == .action(.installUpdate))
    }

    @Test func anInstallingUpdateHasNoButtonsAndSaysSo() {
        let s = PanelSnapshot.make(TestData.inputs(updateOffer: UpdateOffer(version: "1.2", phase: .installing), now: TestData.date(10, 5)))
        let b = try! #require(s.banners.first)
        #expect(b.title == "Installing Obscura 1.2…")
        #expect(b.buttons.isEmpty, "nothing to press until it relaunches or stops")
        #expect(s.header.sentence == "Installing Obscura 1.2…")
        #expect(s.menuRow("updates")?.title == "Installing Update 1.2…")
    }

    @Test func aFailedUpdateSaysWhyThatNothingChangedAndOffersTryAgain() {
        let reason = "The downloaded update doesn't match its signed description, so Obscura discarded it."
        let s = PanelSnapshot.make(TestData.inputs(updateOffer: UpdateOffer(version: "1.2", phase: .failed(reason: reason)),
                                                   now: TestData.date(10, 5)))
        let b = try! #require(s.banners.first)
        #expect(b.tone == .needs)
        #expect(b.title == "Obscura 1.2 wasn't installed")
        #expect(b.body == reason + " This copy of Obscura is unchanged.")
        #expect(b.buttons.map(\.title) == ["Try Again", "Later"])
        #expect(b.buttons.map(\.action) == [.installUpdate, .dismissUpdate])
        #expect(s.header.sentence == "Obscura 1.2 couldn't be installed.")
        #expect(s.menuRow("updates")?.title == "Install Update 1.2…")
    }

    @Test func noOfferIsNoBannerAndTheCheckRow() {
        // Later clears the model's offer, so a dismissed update looks exactly like none until the next scheduled check.
        let s = PanelSnapshot.make(TestData.inputs(updateOffer: nil, now: TestData.date(10, 5)))
        #expect(s.banners.isEmpty)
        #expect(s.menuRow("updates")?.title == "Check for Updates…")
        #expect(s.menuRow("updates")?.kind == .action(.checkForUpdates))
    }

    @Test func focusHoldingSaysSo() {
        let s = PanelSnapshot.make(TestData.inputs(focusHolding: true, now: TestData.date(10, 5)))
        #expect(s.header.sentence.hasPrefix("Focus is holding"))
    }

    // MARK: After a burst

    @Test func aBurstFoldsIntoRecentAndARestoredOriginalIsRed() {
        let card = TestData.entry("Screenshot 2026-10-26 at 9.42.40 AM.png", at: TestData.date(9, 42, 40), cleanCopy: true,
                                  detectors: [("personal.card.pan", true)])
        let undone = TestData.entry("Screenshot 2026-10-26 at 9.41.12 AM.png", at: TestData.date(9, 41, 12),
                                    detectors: [("payments.stripe.secretkey", false)])
        let token = TestData.entry("Copied image", at: TestData.date(9, 41, 50), source: .clipboard,
                                   detectors: [("scm.github.token", true)])
        let entries = [card, token, undone]
        let lc = LastCatch(entryID: card.id, displayName: card.displayName, findings: 1, date: card.createdAt)
        let s = PanelSnapshot.make(TestData.inputs(status: EngineStatus(lastCatch: lc, weekStats: TestData.week(today: 3)),
                                                   entries: entries, lastSeen: TestData.date(9, 30), now: TestData.date(9, 44)))

        #expect(plain(s.header.sentence) == "Blacked out 3 secrets since 9:41 AM.")
        #expect(s.lastCatch?.entryID == card.id)
        #expect(plain(s.lastCatch?.timeLabel) == "9:42 AM")
        #expect(s.lastCatch?.lines.last?.hasPrefix("Clean copy saved next to it") == true)
        let recent = try! #require(s.recent)
        #expect(recent.badge == "2 more")
        #expect(recent.rows.map(\.id) == [undone.id, token.id])
        #expect(recent.rows[1].tone == .ok)
        #expect(recent.rows[1].title == "GitHub token blacked out")
        #expect(recent.rows[1].subtitle == "Copied image · clipboard holds the clean copy")
        #expect(recent.rows[1].buttons.map(\.action) == [.undo(token.id), .review(token.id)])
        #expect(recent.rows[0].tone == .live && recent.rows[0].titleTone == .live)
        #expect(recent.rows[0].title.hasPrefix("Original showing · "))
        #expect(recent.rows[0].subtitle.hasSuffix("· undone"))
        #expect(recent.rows[0].buttons.map(\.action) == [.blackOutAgain(undone.id)])
    }

    @Test func recentStaysAwayOnceTheCatchesWereSeen() {
        let other = TestData.entry("Clipboard image", at: TestData.date(9, 40), source: .clipboard, detectors: [("scm.github.token", true)])
        let s = PanelSnapshot.make(TestData.inputs(entries: [TestData.stripeAndEmail, other], lastSeen: TestData.date(9, 45),
                                                   now: TestData.date(9, 50)))
        #expect(s.recent == nil)
    }

    @Test func anUndoneLastCatchOffersBlackOutAgain() {
        let undone = TestData.entry("Screenshot.png", at: TestData.date(9, 41), detectors: [("payments.stripe.secretkey", false)])
        let s = PanelSnapshot.make(TestData.inputs(entries: [undone]))
        let c = try! #require(s.lastCatch)
        #expect(c.titleTone == .live)
        #expect(c.title.hasPrefix("Original showing"))
        #expect(c.buttons.first?.action == .blackOutAgain(undone.id))
        #expect(!c.buttons.contains { $0.shortcut == KeyChord("z", .command) })
    }

    @Test func leftVisibleUsesTheVerdictWords() {
        let partly = TestData.entry("Screenshot.png", at: TestData.date(9, 41),
                                    detectors: [("payments.stripe.secretkey", true), ("personal.email.address", false)])
        let s = PanelSnapshot.make(TestData.inputs(entries: [partly]))
        #expect(s.lastCatch?.lines.last == "1 of 2 left visible")
    }

    // MARK: Empty and fresh

    @Test func aFreshInstallHasNoCatchAndAZeroWeek() {
        let s = PanelSnapshot.make(TestData.inputs(status: EngineStatus(), entries: [],
                                                   settings: TestData.settings { $0.hasFinishedSetup = false }))
        #expect(s.lastCatch == nil && s.recent == nil)
        #expect(s.week.secrets == 0 && s.week.bars.count == 7 && s.week.bars.allSatisfy(\.isZero))
        // An unfinished setup closed early must be resumable from the panel (picked onboarding design): the setup
        // card's Continue setup (G-19 M-19), which replaced the menu's "Continue Setup…" row.
        #expect(s.setup?.button.action == .openSetup)
        #expect(!s.menuTitles.contains("Continue Setup…") && !s.menuTitles.contains("Setup…"))
        #expect(s.header.title == "Protected")
    }
}
