import Foundation
import Testing
import ObscuraEngine
import ObscuraPrefs
import ObscuraUIKit
@testable import ObscuraNotifyUI

/// Several failing files raise one combined problem alert that updates in place, with one sound (S-16, G-15 ruling),
/// and the thumbnail's own answer decides whether a screenshot catch gets a banner (S-3, S-18). Every name is made up.
@MainActor
@Suite struct ProblemBatchingTests {
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    func timedOut(_ name: String) -> ProblemNotice {
        ProblemNotice.unchecked(.timedOut, path: "/home/example/Downloads/\(name)", displayName: name, timeoutSeconds: 10, pixelSize: nil)
    }

    @Test func theFirstFailureAlertsAloneAndTheSecondFoldsBothIntoOne() {
        var b = ProblemBatcher()
        let one = timedOut("one.png"), two = timedOut("two.png"), three = timedOut("three.png")
        #expect(b.add(one, at: t0) == .single)
        guard case .combined(let id, let family, let notices, let first, let withdraw) = b.add(two, at: t0.addingTimeInterval(2)) else {
            Issue.record("expected a combined alert"); return
        }
        #expect(family == .unchecked)
        #expect(notices == [one, two])
        #expect(first)
        #expect(withdraw == [NotifyID.problemRequest(one.key)], "the single alert is withdrawn, not left beside it")
        guard case .combined(let id3, _, let notices3, let first3, let withdraw3) = b.add(three, at: t0.addingTimeInterval(30)) else {
            Issue.record("expected the burst to continue"); return
        }
        #expect(id3 == id)
        #expect(notices3.count == 3)
        #expect(!first3)
        #expect(withdraw3.isEmpty)
    }

    @Test func theCombinedAlertSaysHowManyAndNeverSoundsAgain() {
        let notices = ["one.png", "two.png", "three.png"].map(timedOut)
        let plan = NotificationCopy.combinedProblemPlan(identifier: "c", family: .unchecked, notices: notices, first: true)
        #expect(plan.title == "3 images weren't checked")
        #expect(plan.body.hasPrefix("one.png, two.png"), "names the files")
        #expect(plan.body.contains("three.png were left as they are, unchecked."))
        #expect(plan.sound == false, "the single alert before it made the burst's one sound")
        #expect(plan.level == .timeSensitive)
        #expect(plan.categoryIdentifier == NotifyID.problemCategory(.filesUnchecked))
        let update = NotificationCopy.combinedProblemPlan(identifier: "c", family: .unchecked, notices: notices, first: false)
        #expect(update.level == .passive, "later failures update it in place without a new banner")
        #expect(NotificationCopy.actions(for: .filesUnchecked).map(\.identifier) == [NotifyID.openNotChecked])
        #expect(NotificationRouting.route(kind: .problem, action: "default", userInfo: plan.userInfo, defaultAction: "default") == .openNotChecked)
    }

    @Test func familiesFoldSeparatelyAndOtherProblemsNever() {
        var b = ProblemBatcher()
        #expect(b.add(timedOut("one.png"), at: t0) == .single)
        let large = ProblemNotice.tooLarge(path: "/home/example/Downloads/huge.png", displayName: "huge.png", pixelSize: nil)
        #expect(b.add(large, at: t0.addingTimeInterval(1)) == .single, "too large is its own family")
        let clipboard = ProblemNotice.unchecked(.timedOut, path: nil, displayName: "", timeoutSeconds: 10, pixelSize: nil)
        #expect(b.add(clipboard, at: t0.addingTimeInterval(2)) == .single)
        #expect(b.add(clipboard, at: t0.addingTimeInterval(3)) == .single, "the clipboard's one alert replaces itself")
    }

    @Test func theSameFileAgainIsNotASecondFile() {
        var b = ProblemBatcher()
        #expect(b.add(timedOut("one.png"), at: t0) == .single)
        #expect(b.add(timedOut("one.png"), at: t0.addingTimeInterval(5)) == .single)
    }

    @Test func aQuietMinuteEndsTheBurst() {
        var b = ProblemBatcher()
        _ = b.add(timedOut("one.png"), at: t0)
        #expect(b.add(timedOut("two.png"), at: t0.addingTimeInterval(61)) == .single)
    }

    @Test func aBurstOfFailuresMakesOneSoundThroughTheNotifier() async throws {
        let model = try await SampleData.model(entries: 0)
        let client = RecordingClient()
        let notifier = Notifier(model: model, client: client, now: { [t0] in t0 })
        for name in ["one.png", "two.png", "three.png", "four.png"] {
            await notifier.process(.unchecked(.timedOut, path: "/home/example/Downloads/\(name)"), displayName: name)
        }
        #expect(client.added.filter(\.sound).count == 1, "one sound for the burst")
        #expect(client.added.filter { $0.level != .passive }.count == 2, "the first alert, then the combined one once")
        #expect(client.added.last?.title == "4 images weren't checked")
        #expect(Set(client.added.dropFirst().map(\.identifier)).count == 1, "one combined alert, updated in place")
        #expect(client.removed == [client.added.first?.identifier], "the single alert was withdrawn")
    }

    @Test func theThumbnailsAnswerDecidesTheBanner() {
        let caught = ReportTriage.caught(entryID: UUID())
        #expect(!CatchBannerRule.posts(caught, thumbnailClaims: true))
        #expect(CatchBannerRule.posts(caught, thumbnailClaims: false), "the thumbnail cannot show it: the banner posts")
        #expect(CatchBannerRule.posts(.tooLarge(path: nil), thumbnailClaims: true), "problems always alert")
    }
}
