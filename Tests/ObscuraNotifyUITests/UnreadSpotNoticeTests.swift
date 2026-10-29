// G-40: a picture whose only unread parts are small spots no reading could read raises no alarm (a file is listed for the
// person; a copied image gets one quiet notice), a catch says how many spots were covered or wait, and every file notice
// names the picture by where it came from ("screenshot" only for the screenshot folder). Made-up names and entries.
import CoreGraphics
import Foundation
import Testing
import ObscuraCapture
import ObscuraEngine
import ObscuraJournal
import ObscuraPrefs
@testable import ObscuraNotifyUI

@MainActor
@Suite struct UnreadSpotNoticeTests {
    static let spot = SpotRecord(rect: CGRect(x: 10, y: 10, width: 40, height: 8), coverRect: CGRect(x: 2, y: 2, width: 66, height: 30), state: .pending)

    @Test func aFileWithSpotsPostsNothing() async throws {
        let client = RecordingClient()
        let (notifier, _) = try await NotifierTests().makeNotifier(client: client)
        let file = URL(fileURLWithPath: "/home/example/Downloads/photo.png")
        let report = ScanReport(key: CaptureKey(file: file), displayName: "photo.png", outcome: .skipped(.unreadPatch), fileURL: file,
                                origin: .downloads, notes: [.unreadSpots], spots: [Self.spot])
        #expect(ReportTriage.classify(report) == .unreadSpots(path: file.path))
        notifier.handle(report)
        await notifier.drain()
        #expect(client.added.isEmpty, "no alarm banner: the panel and the Journal list it")
    }

    @Test func aCopiedImageWithASpotGetsOneQuietNotice() async throws {
        let client = RecordingClient()
        let (notifier, _) = try await NotifierTests().makeNotifier(client: client)
        let report = ScanReport(key: .pasteboard(changeCount: 3), displayName: "Clipboard", outcome: .skipped(.unreadPatch),
                                notes: [.unreadSpots], spots: [Self.spot])
        notifier.handle(report)
        await notifier.drain()
        let plan = try #require(client.added.first)
        #expect(client.added.count == 1)
        #expect(plan.title == "1 spot couldn't be read")
        #expect(plan.body == "Obscura couldn't read a small spot in the image you copied. Your clipboard still holds it as it is; check it before you paste it.")
        #expect(plan.level == .passive && !plan.sound && plan.categoryIdentifier == nil)
    }

    @Test func theSpotsStatusRowIsNeverANotification() {
        let problem = Problem(kind: .unreadSpots, messageKey: ShieldEngine.unreadSpotsKey, url: URL(fileURLWithPath: "/home/example/a.png"), detail: "2")
        #expect(ProblemNotice.from(problem, downloads: URL(fileURLWithPath: "/home/example/Downloads"), extraFolders: []) == nil)
    }

    // MARK: Catches with spots

    func facts(spotsCovered: Int = 0, pending: Int = 0, names: [String] = ["Stripe secret key"]) -> CatchFacts {
        var f = CatchFacts(entryID: UUID(), source: "file", displayName: "photo.png", delivery: .fileReplaced, createdAt: Date(),
                           findingNames: names, restoreTargetName: "photo.png")
        f.spotsCovered = spotsCovered
        f.pendingSpots = pending
        return f
    }

    @Test func aCatchOfOnlyCoveredSpotsSaysSoAndIsNeverPresentedAsFullyRead() {
        let plan = NotificationCopy.catchPlan(facts(spotsCovered: 1, names: []), retentionHours: 24, now: Date())
        #expect(plan.title == "1 unreadable spot covered")
        #expect(plan.body.hasSuffix("Obscura couldn't read 1 small spot in it, so it was covered too."))
        #expect(plan.verdict == nil, "no \"Safe to share\" for a picture with a spot no reading read")
        let two = NotificationCopy.catchPlan(facts(spotsCovered: 2, names: []), retentionHours: 24, now: Date())
        #expect(two.title == "2 unreadable spots covered")
        #expect(two.body.hasSuffix("Obscura couldn't read 2 small spots in it, so they were covered too."))
    }

    @Test func aCatchWithAWaitingSpotSaysToCheckIt() {
        let plan = NotificationCopy.catchPlan(facts(pending: 1), retentionHours: 24, now: Date())
        #expect(plan.title == "Stripe secret key blacked out")
        #expect(plan.body.hasSuffix("Obscura couldn't read a small spot in it. Check it in the viewer."))
        #expect(plan.verdict == nil)
        let plain = NotificationCopy.catchPlan(facts(), retentionHours: 24, now: Date())
        #expect(plain.verdict != nil && !plain.body.contains("spot"))
    }

    @Test func aSpotsCoverIsNotNamedOrCountedAsASecret() {
        let id = UUID()
        let style = StyleRecord()
        let findings = [
            Finding(id: UUID(), entryID: id, lineIndex: 0, rect: .zero, detectorIDs: ["payments.stripe.secretkey"], category: "payments", enabled: true),
            Finding(id: UUID(), entryID: id, lineIndex: -1, rect: .zero, detectorIDs: [SpotRecord.coverDetectorID], category: SpotRecord.coverCategory, enabled: true),
        ]
        let entry = Entry(id: id, createdAt: Date(), source: .file, displayName: "photo.png", filePath: "/home/example/Downloads/photo.png",
                          cleanCopyPath: nil, containerUTI: "public.png", pixelWidth: 10, pixelHeight: 10, revision: 1, style: style,
                          trashedAt: nil, findings: findings)
        let f = CatchFacts(entry: entry)
        #expect(f?.findingCount == 1 && f?.spotsCovered == 1)
    }

    // MARK: The picture's noun (redman small row)

    @Test func aFileNoticeNamesThePictureByWhereItCameFrom() {
        let path = "/home/example/Downloads/photo.png"
        #expect(ImageNoun(.screenshotFolder) == .screenshot)
        #expect(ImageNoun(.downloads) == .image && ImageNoun(.imported) == .image && ImageNoun(nil) == .image)
        #expect(ProblemNotice.unchecked(.ocrFailed, path: path, displayName: "photo.png", timeoutSeconds: 20, pixelSize: nil, noun: .image).title
                == "Couldn't check one image")
        #expect(ProblemNotice.unchecked(.ocrFailed, path: path, displayName: "photo.png", timeoutSeconds: 20, pixelSize: nil, noun: .screenshot).title
                == "Couldn't check one screenshot")
        #expect(ProblemNotice.partlyRead(path: path, displayName: "photo.png", timedOut: false, timeoutSeconds: 20, noun: .image).title
                == "Couldn't check all of one image")
        #expect(ProblemNotice.tooLarge(path: path, displayName: "photo.png", pixelSize: nil, noun: .image).title == "Couldn't check one image")
        #expect(ProblemNotice.scanFailed(path: path, displayName: "photo.png", noun: .image).title == "Couldn't black out one image")
    }

    @Test func aDownloadsImageThatCouldNotBeReadIsNotCalledAScreenshot() async throws {
        let client = RecordingClient()
        let (notifier, _) = try await NotifierTests().makeNotifier(client: client)
        let file = URL(fileURLWithPath: "/home/example/Downloads/photo.png")
        notifier.handle(ScanReport(key: CaptureKey(file: file), displayName: "photo.png", outcome: .skipped(.ocrFailed), fileURL: file, origin: .downloads))
        await notifier.drain()
        #expect(client.added.first?.title == "Couldn't check one image")
    }

    @Test func textVisionAnsweredWithNoneOfIsSaidTruly() {
        let notice = ProblemNotice.unchecked(.textNotRead, path: "/home/example/Downloads/photo.png", displayName: "photo.png", timeoutSeconds: 20,
                                             pixelSize: nil, noun: .image)
        #expect(notice.body == "Part of photo.png looks like text but couldn't be read. It was left as it is, unchecked.")
        #expect(notice.kind == .fileUnchecked, "outside the small-spot case it keeps today's alarm")
        #expect(ReportTriage.classify(key: .path("/x.png"), outcome: .skipped(.textNotRead)) == .unchecked(.textNotRead, path: "/x.png"))
        let clipboard = ProblemNotice.unchecked(.textNotRead, path: nil, displayName: "", timeoutSeconds: 20, pixelSize: nil)
        #expect(clipboard.body == "Part of the image you copied looks like text but couldn't be read. Your clipboard still holds it as it is, unchecked.")
    }
}
