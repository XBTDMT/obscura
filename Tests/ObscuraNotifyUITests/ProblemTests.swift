import Foundation
import Testing
import ObscuraEngine
import ObscuraUIKit
@testable import ObscuraNotifyUI

@Suite struct ProblemTests {
    let downloads = URL(fileURLWithPath: "/home/example/Downloads", isDirectory: true)
    let desktop = URL(fileURLWithPath: "/home/example/Desktop", isDirectory: true)

    func titles(_ kind: ProblemNotice.Kind) -> [String] { NotificationCopy.actions(for: kind).map(\.title) }

    @Test func folderAccessLostOffersAllowAccess() throws {
        let p = Problem(kind: .folderAccess, messageKey: "problem.folder.denied", url: desktop)
        let notice = try #require(ProblemNotice.from(p, downloads: downloads, extraFolders: []))
        #expect(notice.kind == .screenshotFolderDenied)
        #expect(notice.title == "Can't read your screenshot folder")
        #expect(notice.body == "New screenshots on the Desktop are not being checked until you allow access again.")
        #expect(titles(.screenshotFolderDenied) == ["Allow Access…", "Later"])
    }

    @Test func downloadsUnreadableOffersSystemSettingsAndStopWatching() throws {
        let p = Problem(kind: .folderAccess, messageKey: "problem.folder.denied", url: downloads)
        let notice = try #require(ProblemNotice.from(p, downloads: downloads, extraFolders: []))
        #expect(notice.kind == .watchedFolderDenied)
        #expect(notice.body == "Access to the Downloads folder was removed in System Settings. New images there are not checked.")
        #expect(titles(.watchedFolderDenied) == ["Open System Settings", "Stop Watching"])
        #expect(NotificationRouting.route(kind: .problem, action: NotifyID.stopWatching, userInfo: notice.userInfo, defaultAction: "default")
                == .stopWatchingDownloads)
    }

    @Test func anAddedFolderStopsWatchingExactlyThatEntry() throws {
        let p = Problem(kind: .folderAccess, messageKey: "problem.folder.denied", url: URL(fileURLWithPath: "/home/example/Shots"))
        let notice = try #require(ProblemNotice.from(p, downloads: downloads, extraFolders: ["/home/example/Shots"]))
        #expect(notice.kind == .watchedFolderDenied)
        #expect(NotificationRouting.route(kind: .problem, action: NotifyID.stopWatching, userInfo: notice.userInfo, defaultAction: "default")
                == .stopWatchingFolder("/home/example/Shots"))
    }

    @Test func ocrTimedOutOffersCheckAgainAndShowInFinder() {
        let path = "/home/example/Desktop/Screenshot 2026-10-26 at 9.44.08 AM.png"
        let triage = ReportTriage.classify(key: .path(path), outcome: .skipped(.ocrTimeout))
        #expect(triage == .unchecked(.timedOut, path: path))
        let notice = ProblemNotice.unchecked(.timedOut, path: path, displayName: "Screenshot 2026-10-26 at 9.44.08 AM.png",
                                             timeoutSeconds: 20, pixelSize: (9800, 6200))
        #expect(notice.kind == .fileUnchecked)
        #expect(notice.title == "Couldn't check one screenshot")
        #expect(notice.body.contains("took over 20 s"))
        #expect(notice.body.hasSuffix("It was left as it is, unchecked."))
        #expect(titles(.fileUnchecked) == ["Check Again", "Show in Finder"])
        #expect(NotificationRouting.route(kind: .problem, action: NotifyID.checkAgain, userInfo: notice.userInfo, defaultAction: "d")
                == .checkAgain(path: path))
    }

    /// Fail-open #5 and #6: an unfinished picture and one with several frames each post their own words, with the
    /// unchecked file's fixes for a file and the clipboard alert for a copied image.
    @Test func anUnfinishedOrMultiFramePictureSaysWhyItWasLeftAsItIs() {
        let path = "/home/example/Downloads/Recording.gif"
        #expect(ReportTriage.classify(key: .path(path), outcome: .skipped(.incomplete)) == .incomplete(path: path))
        #expect(ReportTriage.classify(key: .path(path), outcome: .skipped(.multiFrame)) == .severalFrames(path: path))
        #expect(ReportTriage.classify(key: .pasteboard(changeCount: 4), outcome: .skipped(.multiFrame)) == .severalFrames(path: nil))

        let unfinished = ProblemNotice.incomplete(path: path, displayName: "Recording.gif")
        #expect(unfinished.kind == .fileUnchecked && unfinished.title == "Couldn't check an unfinished image")
        let frames = ProblemNotice.severalFrames(path: path, displayName: "Recording.gif")
        #expect(frames.kind == .fileUnchecked && frames.title == "Couldn't cover an image with several frames")
        #expect(frames.body.contains("a secret may be in it"))
        #expect(ProblemNotice.severalFrames(path: nil, displayName: "Clipboard").kind == .clipboardUnchecked)
        #expect(ProblemNotice.incomplete(path: nil, displayName: "Clipboard").kind == .clipboardUnchecked)
    }

    /// Fail-open #9: several image files copied at once are left as they are and the alert says so.
    @Test func severalCopiedFilesSayTheyWereNotChecked() {
        #expect(ReportTriage.classify(key: .pasteboard(changeCount: 5), outcome: .skipped(.severalFiles)) == .severalFiles)
        let notice = ProblemNotice.severalFiles()
        #expect(notice.kind == .clipboardUnchecked)
        #expect(notice.title == "Couldn't check the files you copied")
    }

    /// F6/F12 (G-35): a file copied from outside the guarded folders was never opened, and the alert says so.
    @Test func aCopiedFileOutsideTheGuardedFoldersSaysItWasNotOpened() {
        #expect(ReportTriage.classify(key: .pasteboard(changeCount: 6), outcome: .skipped(.copiedFileNotGuarded)) == .copiedFileNotGuarded)
        let notice = ProblemNotice.copiedFileNotGuarded()
        #expect(notice.kind == .clipboardUnchecked)
        #expect(notice.title == "Didn't check the file you copied")
        #expect(notice.body.contains("didn't open it"))
    }

    @Test func writeFailedOffersCopyCleanAndShowInFinder() {
        let path = "/home/example/Desktop/Screenshot 2026-10-26 at 9.45.30 AM.png"
        #expect(ReportTriage.classify(key: .path(path), outcome: .failed(.writeBack("EPERM"))) == .writeFailed(path: path))
        let id = UUID()
        let notice = ProblemNotice.writeFailed(path: path, displayName: "Screenshot 2026-10-26 at 9.45.30 AM.png", entryID: id,
                                               secrets: "the Stripe secret key", readOnly: true, keepBoth: false)
        #expect(notice.kind == .writeFailed)
        #expect(notice.title == "Couldn't save the clean copy")
        #expect(notice.body == "Screenshot 2026-10-26 at 9.45.30 AM.png is read-only, so the Stripe secret key is still in that file. The clean copy is in the Journal.")
        #expect(titles(.writeFailed) == ["Copy Clean", "Show in Finder"])
        #expect(NotificationRouting.route(kind: .problem, action: NotifyID.copyClean, userInfo: notice.userInfo, defaultAction: "d")
                == .copyClean(id))
    }

    /// Fail-open #2: a picture that could not be opened or read used to post nothing. A file gets "Couldn't read this
    /// image" with Check Again and Show in Finder; a copied image gets its clipboard alert.
    @Test func aPictureThatCannotBeOpenedPostsCouldntReadThisImage() {
        let path = "/home/example/Desktop/Screenshot 2026-10-27 at 9.41.12 AM.png"
        for reason in [SkipReason.decodeFailed, .unsupportedImage, .unreadable] {
            #expect(ReportTriage.classify(key: .path(path), outcome: .skipped(reason)) == .unreadable(path: path))
            #expect(ReportTriage.classify(key: .pasteboard(changeCount: 9), outcome: .skipped(reason)) == .unreadable(path: nil))
        }
        #expect(ReportTriage.classify(key: .path(path), outcome: .skipped(.notAnImage)) == .none, "an extension never read stays quiet")

        let file = ProblemNotice.unreadable(path: path, displayName: "Screenshot 2026-10-27 at 9.41.12 AM.png")
        #expect(file.kind == .fileUnchecked)
        #expect(file.title == "Couldn't read this image")
        #expect(file.body == "Obscura couldn't open Screenshot 2026-10-27 at 9.41.12 AM.png to check it, so it was left as it is, unchecked. Any secret in it is still there.")
        #expect(titles(.fileUnchecked) == ["Check Again", "Show in Finder"])
        #expect(NotificationRouting.route(kind: .problem, action: NotifyID.checkAgain, userInfo: file.userInfo, defaultAction: "d")
                == .checkAgain(path: path))

        let clipboard = ProblemNotice.unreadable(path: nil, displayName: "Clipboard")
        #expect(clipboard.kind == .clipboardUnchecked)
        #expect(clipboard.title == "Couldn't read the image you copied")
        #expect(NotificationCopy.problemPlan(clipboard).categoryIdentifier == nil)
    }

    @Test func problemsAreSoundedAndTimeSensitive() {
        let notice = ProblemNotice.scanFailed(path: "/tmp/x.png", displayName: "x.png")
        let plan = NotificationCopy.problemPlan(notice)
        #expect(plan.sound == true)
        #expect(plan.level == .timeSensitive)
        #expect(plan.kind == .problem)
        #expect(plan.verdict == nil)
        #expect(plan.categoryIdentifier == NotifyID.problemCategory(.fileUnchecked))
    }

    @Test func clipboardProblemsHaveNoButtons() {
        let notice = ProblemNotice.unchecked(.timedOut, path: nil, displayName: "Clipboard image", timeoutSeconds: 20, pixelSize: nil)
        #expect(notice.kind == .clipboardUnchecked)
        #expect(NotificationCopy.problemPlan(notice).categoryIdentifier == nil)
    }

    @Test func panelOnlyProblemsAreNotPosted() {
        #expect(ProblemNotice.from(Problem(kind: .ocrWarmup, messageKey: "problem.warmup.failed"), downloads: downloads, extraFolders: []) == nil)
        #expect(ProblemNotice.from(Problem(kind: .scanFailure, messageKey: "problem.scan.failed", detail: "3"), downloads: downloads, extraFolders: []) == nil)
    }

    @Test func rulesAndSourcesOpenTheirSettingsPane() throws {
        let rule = try #require(ProblemNotice.from(Problem(kind: .ruleCompile, messageKey: "problem.rule.compile", detail: "custom.1"),
                                                   downloads: downloads, extraFolders: []))
        #expect(NotificationRouting.route(kind: .problem, action: NotifyID.openSettings, userInfo: rule.userInfo, defaultAction: "d")
                == .openSettings(.customRules))
        let source = try #require(ProblemNotice.from(Problem(kind: .sourceStart, messageKey: "problem.source.start", detail: "ClipboardGuard"),
                                                     downloads: downloads, extraFolders: []))
        #expect(source.title == "The clipboard isn't being checked")
        #expect(NotificationRouting.route(kind: .problem, action: "d", userInfo: source.userInfo, defaultAction: "d")
                == .openSettings(.protection))
    }

    /// Fail-open #3: an edited detector that does not compile has its own key; the alert says the detector runs on its
    /// built-in patterns and opens Detectors (it used to say a custom rule was skipped and open Custom Rules).
    @Test func anOverrideThatDoesNotCompileSaysTheBuiltInPatternsAreUsed() throws {
        let notice = try #require(ProblemNotice.from(Problem(kind: .ruleCompile, messageKey: "problem.override.compile",
                                                             detail: "payments.stripe.secretkey: This isn't a valid regular expression"),
                                                     downloads: downloads, extraFolders: []))
        #expect(notice.title == "Edited patterns aren't being used")
        #expect(notice.body.contains("built-in patterns"))
        #expect(NotificationRouting.route(kind: .problem, action: NotifyID.openSettings, userInfo: notice.userInfo, defaultAction: "d")
                == .openSettings(.detectors))
    }

    @Test func reportsThatNeedNothingPostNothing() {
        #expect(ReportTriage.classify(key: .path("/a.png"), outcome: .clean(duration: .seconds(1))) == .none)
        #expect(ReportTriage.classify(key: .path("/a.png"), outcome: .skipped(.cancelled)) == .none)
        #expect(ReportTriage.classify(key: .pasteboard(changeCount: 3), outcome: .skipped(.protectionPaused)) == .none)
        let id = UUID()
        #expect(ReportTriage.classify(key: nil, outcome: .redacted(entryID: id, findings: 2, duration: .seconds(1))) == .caught(entryID: id))
    }
}

@Suite struct RoutingTests {
    let id = UUID()
    var info: [String: String] { [NotifyKey.entry: id.uuidString] }

    @Test func catchActions() {
        #expect(NotificationRouting.route(kind: .catchOne, action: "undo", userInfo: info, defaultAction: "tap") == .undo(id))
        #expect(NotificationRouting.route(kind: .catchOne, action: "review", userInfo: info, defaultAction: "tap") == .review(id))
        #expect(NotificationRouting.route(kind: .catchOne, action: "tap", userInfo: info, defaultAction: "tap") == .review(id))
        #expect(NotificationRouting.route(kind: .catchOne, action: "dismiss", userInfo: info, defaultAction: "tap") == .nothing)
    }

    @Test func restoredSummaryAndUpdate() {
        #expect(NotificationRouting.route(kind: .restored, action: NotifyID.blackOutAgain, userInfo: info, defaultAction: "tap") == .blackOutAgain(id))
        #expect(NotificationRouting.route(kind: .summary, action: "tap", userInfo: [:], defaultAction: "tap") == .openJournal)
        #expect(NotificationRouting.route(kind: .update, action: NotifyID.installUpdate, userInfo: [:], defaultAction: "tap") == .installUpdate)
        #expect(NotificationRouting.route(kind: .update, action: NotifyID.later, userInfo: [:], defaultAction: "tap") == .nothing)
        #expect(NotificationRouting.route(kind: nil, action: "tap", userInfo: [:], defaultAction: "tap") == .nothing)
    }
}

@Suite struct DeliveryModeTests {
    @Test func modes() {
        #expect(DeliveryMode(DeliverySnapshot(authorization: .notDetermined, showsOnScreen: false, keepsInCentre: false)) == .undetermined)
        #expect(DeliveryMode(DeliverySnapshot(authorization: .denied, showsOnScreen: true, keepsInCentre: true)) == .off)
        #expect(DeliveryMode(DeliverySnapshot(authorization: .authorized, showsOnScreen: true, keepsInCentre: true)) == .banners)
        let quiet = DeliveryMode(DeliverySnapshot(authorization: .authorized, showsOnScreen: false, keepsInCentre: true))
        #expect(quiet == .quiet)
        #expect(quiet.holdsBanners && quiet.posts)
        #expect(DeliveryMode(DeliverySnapshot(authorization: .authorized, showsOnScreen: false, keepsInCentre: false)) == .off)
    }
}
