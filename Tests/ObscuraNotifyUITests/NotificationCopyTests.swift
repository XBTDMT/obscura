import Foundation
import Testing
import ObscuraEngine
import ObscuraJournal
import ObscuraUIKit
@testable import ObscuraNotifyUI

/// Builds an invented Journal entry. Detector ids are real catalogue ids; nothing here is a real secret.
func makeEntry(_ detectors: [(id: String, category: String)], source: EntrySource = .file,
               name: String = "Screenshot 2026-10-26 at 9.41.12 AM.png",
               filePath: String? = "/home/example/Desktop/Screenshot 2026-10-26 at 9.41.12 AM.png",
               cleanCopyPath: String? = nil, createdAt: Date = Date(), id: UUID = UUID()) -> Entry {
    let findings = detectors.enumerated().map { i, d in
        Finding(id: UUID(), entryID: id, lineIndex: i, rect: CGRect(x: 0, y: i * 20, width: 100, height: 16),
                detectorIDs: [d.id], category: d.category, enabled: true)
    }
    return Entry(id: id, createdAt: createdAt, source: source, displayName: name,
                 filePath: source == .clipboard ? nil : filePath, cleanCopyPath: cleanCopyPath,
                 containerUTI: "public.png", pixelWidth: 1920, pixelHeight: 1080, revision: 1,
                 style: .builtInDefault, trashedAt: nil, findings: findings)
}

let stripe = (id: "payments.stripe.secretkey", category: "payments")
let github = (id: "scm.github.token", category: "scm")
let card = (id: "personal.card.pan", category: "personal")
let awsKey = (id: "cloud.aws.accesskeyid", category: "cloud")

@Suite struct CatchTitleTests {
    @Test(arguments: ["payments.stripe.secretkey", "scm.github.token", "personal.card.pan", "cloud.aws.accesskeyid",
                      "personal.email.address"])
    func singleFindingTitleIsTheFullDetectorNameFirst(detectorID: String) throws {
        let facts = try #require(CatchFacts(entry: makeEntry([(detectorID, "x")])))
        #expect(NotificationCopy.catchTitle(facts) == "\(DetectorNames.title(for: detectorID)) blacked out")
    }

    @Test func knownTitlesReadAsTheMockupDoes() throws {
        #expect(NotificationCopy.catchTitle(try #require(CatchFacts(entry: makeEntry([github])))) == "GitHub token blacked out")
        #expect(NotificationCopy.catchTitle(try #require(CatchFacts(entry: makeEntry([card])))) == "Payment card number blacked out")
    }

    @Test func severalFindingsCountSecrets() throws {
        let facts = try #require(CatchFacts(entry: makeEntry([stripe, github, card])))
        #expect(NotificationCopy.catchTitle(facts) == "3 secrets blacked out")
        let body = NotificationCopy.catchBody(facts, retentionHours: 24, now: facts.createdAt)
        #expect(body.hasPrefix(DetectorNames.title(for: stripe.id)))
        #expect(body.contains("payment card number"))
    }

    @Test func personalTitlesLowerCaseMidSentenceAndBrandsDoNot() {
        #expect(CatchFacts.inSentence("Payment card number", category: "personal") == "payment card number")
        #expect(CatchFacts.inSentence("IBAN", category: "personal") == "IBAN")
        #expect(CatchFacts.inSentence("GitHub token", category: "scm") == "GitHub token")
    }

    @Test func importsAndTheDemoNeverNotify() {
        #expect(CatchFacts(entry: makeEntry([stripe], source: .imported)) == nil)
        #expect(CatchFacts(entry: makeEntry([stripe], source: .demo)) == nil)
        #expect(CatchFacts(entry: makeEntry([], source: .file)) == nil)
    }
}

@Suite struct CatchVariantTests {
    let created = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func fileReplacedIsSilentNamedAndKeyedByEntry() throws {
        let entry = makeEntry([stripe], createdAt: created)
        let facts = try #require(CatchFacts(entry: entry))
        let plan = NotificationCopy.catchPlan(facts, retentionHours: 24, now: created)
        #expect(plan.identifier == entry.id.uuidString)
        #expect(plan.userInfo[NotifyKey.entry] == entry.id.uuidString)
        #expect(plan.categoryIdentifier == NotifyID.catchCategory)
        #expect(plan.threadIdentifier == "obscura.catch.file")
        #expect(plan.level == .active)
        #expect(plan.sound == false)
        #expect(plan.kind == .catchOne)
        #expect(plan.body.hasPrefix("In Screenshot 2026-10-26 at 9.41.12 AM.png. The file is clean; the original is in the Journal until tomorrow"))
        #expect(plan.verdict == Verdict.safeToShare(total: 1).title)
        #expect(plan.deliveredBody.hasSuffix("\nSafe to share"))
    }

    @Test func clipboardSaysTheClipboardHoldsTheCleanCopy() throws {
        let facts = try #require(CatchFacts(entry: makeEntry([github], source: .clipboard, name: "Clipboard image", createdAt: created)))
        let plan = NotificationCopy.catchPlan(facts, retentionHours: 24, now: created)
        #expect(plan.title == "GitHub token blacked out")
        #expect(plan.body == "In the image you copied. Your clipboard now holds the clean copy. The original is in the Journal until tomorrow.")
        #expect(plan.verdict == "Safe to paste")
        #expect(plan.threadIdentifier == "obscura.catch.clipboard")
        #expect(facts.restoreTargetName == nil)
    }

    /// Fail-open #18: when the user copied something else during the check, the newer copy stays and the banner says so,
    /// without "Safe to paste" (the clipboard holds something this catch did not check).
    @Test func aClipboardCatchWhoseClipboardChangedSaysTheNewerCopyWasKept() throws {
        var facts = try #require(CatchFacts(entry: makeEntry([github], source: .clipboard, name: "Clipboard image", createdAt: created)))
        facts.notes = [.clipboardChangedMeanwhile]
        let plan = NotificationCopy.catchPlan(facts, retentionHours: 24, now: created)
        #expect(plan.body == "In the image you copied. You copied something else while it was checked, so that was left on your clipboard. The clean copy and the original are in the Journal until tomorrow.")
        #expect(plan.verdict == nil)
    }

    /// Fail-open #8: the catch banner says the copied text was left out because it held a secret.
    @Test func aClipboardCatchWhoseTextWasLeftOutSaysSo() throws {
        var facts = try #require(CatchFacts(entry: makeEntry([github], source: .clipboard, name: "Clipboard image", createdAt: created)))
        facts.notes = [.companionTextRemoved]
        let plan = NotificationCopy.catchPlan(facts, retentionHours: 24, now: created)
        #expect(plan.body == "In the image you copied. Your clipboard now holds the clean copy. The text copied with it held a secret too, so it was left out. The original is in the Journal until tomorrow.")
        #expect(plan.verdict == "Safe to paste")
    }

    @Test func keepBothNamesTheCleanCopyAndWarnsAboutTheOriginal() throws {
        let entry = makeEntry([stripe], cleanCopyPath: "/home/example/Desktop/Screenshot 2026-10-26 at 9.41.12 AM (clean).png",
                              createdAt: created)
        let facts = try #require(CatchFacts(entry: entry))
        let plan = NotificationCopy.catchPlan(facts, retentionHours: 24, now: created)
        #expect(plan.body == "In Screenshot 2026-10-26 at 9.41.12 AM.png. Saved the clean copy next to it as “… (clean).png”. The original file still shows the secret.")
        #expect(plan.verdict == "Share the (clean) copy")
        #expect(facts.restoreTargetName == "Screenshot 2026-10-26 at 9.41.12 AM (clean).png")
    }

    @Test func undoneBannerReplacesTheCatchAndIsRed() throws {
        let entry = makeEntry([stripe], createdAt: created)
        let facts = try #require(CatchFacts(entry: entry))
        let plan = NotificationCopy.restoredPlan(facts)
        #expect(plan.identifier == entry.id.uuidString)
        #expect(plan.title == "Undone · original showing")
        #expect(plan.body == "Screenshot 2026-10-26 at 9.41.12 AM.png shows the \(DetectorNames.title(for: stripe.id)) again. Sensitive. The clean copy is in the Journal.")
        #expect(plan.verdict == Verdict.originalShowing(total: 1).title)
        #expect(plan.categoryIdentifier == NotifyID.restoredCategory)
        #expect(plan.sound == false)
    }

    @Test func untilPhraseFollowsTheRetention() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let morning = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9, minute: 41))!
        #expect(NotificationCopy.untilPhrase(morning.addingTimeInterval(3600), now: morning, calendar: cal, withTime: true).hasPrefix("until "))
        #expect(!NotificationCopy.untilPhrase(morning.addingTimeInterval(3600), now: morning, calendar: cal, withTime: true).contains("tomorrow"))
        #expect(NotificationCopy.untilPhrase(morning.addingTimeInterval(86_400), now: morning, calendar: cal, withTime: true).hasPrefix("until tomorrow "))
        #expect(NotificationCopy.untilPhrase(morning.addingTimeInterval(86_400), now: morning, calendar: cal, withTime: false) == "until tomorrow")
        #expect(!NotificationCopy.untilPhrase(morning.addingTimeInterval(720 * 3600), now: morning, calendar: cal, withTime: true).contains("tomorrow"))
    }

    @Test func updateIsPassiveAndSilent() {
        let plan = NotificationCopy.updatePlan(version: "1.1")
        #expect(plan.title == "Obscura 1.1 is ready")
        #expect(plan.level == .passive)
        #expect(plan.sound == false)
        #expect(plan.categoryIdentifier == NotifyID.updateCategory)
    }
}

@Suite struct CategoryTests {
    @Test func oneCatchCategoryWithBackgroundUndoAndForegroundReview() throws {
        let cats = NotificationCopy.categories()
        let catchCat = try #require(cats.first { $0.identifier == NotifyID.catchCategory })
        #expect(catchCat.actions == [ActionSpec(identifier: "undo", title: "Undo", foreground: false),
                                     ActionSpec(identifier: "review", title: "Review", foreground: true)])
        #expect(cats.filter { $0.identifier == NotifyID.catchCategory }.count == 1)
        #expect(Set(cats.map(\.identifier)).count == cats.count)
    }

    @Test func everyProblemKindWithButtonsHasItsCategory() {
        let ids = Set(NotificationCopy.categories().map(\.identifier))
        for kind in ProblemNotice.Kind.allCases where !NotificationCopy.actions(for: kind).isEmpty {
            #expect(ids.contains(NotifyID.problemCategory(kind)))
        }
    }
}
