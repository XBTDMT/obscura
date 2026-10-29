import Foundation
import Testing
import ObscuraJournal
import ObscuraUIKit
@testable import ObscuraNotifyUI

@Suite struct BatchingTests {
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    func facts(_ d: (id: String, category: String), source: EntrySource = .file) -> CatchFacts {
        CatchFacts(entry: makeEntry([d], source: source))!
    }

    @Test func twoCatchesInAMinuteStaySingle() {
        var b = CatchBatcher()
        #expect(b.add(facts(stripe), at: t0) == .single)
        #expect(b.add(facts(github), at: t0.addingTimeInterval(30)) == .single)
    }

    @Test func theThirdCatchInAMinuteBecomesOneSummaryAndWithdrawsTheSingles() throws {
        var b = CatchBatcher()
        let a = facts(stripe), c = facts(awsKey), d = facts(card)
        _ = b.add(a, at: t0)
        _ = b.add(c, at: t0.addingTimeInterval(20))
        guard case .summary(let id, let items, let since, let withdraw, let first) = b.add(d, at: t0.addingTimeInterval(40)) else {
            Issue.record("expected a summary"); return
        }
        #expect(items.count == 3)
        #expect(since == t0)
        #expect(withdraw == [a.entryID.uuidString, c.entryID.uuidString])
        #expect(first, "the summary appears with one banner")

        let plan = NotificationCopy.summaryPlan(identifier: id, items: items, since: since, now: t0.addingTimeInterval(40))
        #expect(plan.title == "3 secrets blacked out")
        #expect(plan.body.hasPrefix(DetectorNames.title(for: stripe.id)))
        #expect(plan.body.contains(DetectorNames.title(for: awsKey.id)))
        #expect(plan.body.contains("payment card number"))
        #expect(plan.body.contains("in 3 screenshots since"))
        #expect(plan.body.hasSuffix("All clean."))
        #expect(plan.verdict == "Safe to share")
        #expect(plan.threadIdentifier == "obscura.catch.file")
        #expect(plan.sound == false)

        // A fourth catch keeps coming within a minute of the last: same summary, nothing more to withdraw.
        guard case .summary(let id4, let items4, _, let withdraw4, let first4) = b.add(facts(github), at: t0.addingTimeInterval(90)) else {
            Issue.record("expected the burst to continue"); return
        }
        #expect(id4 == id)
        #expect(items4.count == 4)
        #expect(withdraw4.isEmpty)
        #expect(!first4, "S-15: a later catch updates the summary in place")
        let update = NotificationCopy.summaryPlan(identifier: id4, items: items4, since: t0, now: t0.addingTimeInterval(90), first: false)
        #expect(update.identifier == id, "same request: it replaces the delivered summary")
        #expect(update.level == .passive, "no new banner, no sound")
        #expect(update.sound == false)
        #expect(plan.level == .active)
    }

    @Test func undoingACatchPutsTheSummaryRightOrWithdrawsIt() {
        var b = CatchBatcher()
        let a = facts(stripe), c = facts(awsKey), d = facts(card)
        _ = b.add(a, at: t0)
        _ = b.add(c, at: t0.addingTimeInterval(1))
        guard case .summary(let id, _, _, _, _) = b.add(d, at: t0.addingTimeInterval(2)) else { Issue.record("expected a summary"); return }
        #expect(b.remove(entryID: c.entryID) == .update(identifier: id, items: [a, d], since: t0))
        _ = b.remove(entryID: a.entryID)
        #expect(b.remove(entryID: d.entryID) == .withdraw(identifier: id))
        #expect(b.remove(entryID: UUID()) == .none)
    }

    @Test func aSingleCatchUndoneLeavesNoSummaryToFix() {
        var b = CatchBatcher()
        let a = facts(stripe)
        _ = b.add(a, at: t0)
        #expect(b.remove(entryID: a.entryID) == .none)
    }

    @Test func catchesSpreadOverMoreThanAMinuteNeverBatch() {
        var b = CatchBatcher()
        #expect(b.add(facts(stripe), at: t0) == .single)
        #expect(b.add(facts(github), at: t0.addingTimeInterval(45)) == .single)
        #expect(b.add(facts(card), at: t0.addingTimeInterval(75)) == .single)
    }

    @Test func aGapEndsTheBurst() {
        var b = CatchBatcher()
        for i in 0..<3 { _ = b.add(facts(stripe), at: t0.addingTimeInterval(Double(i))) }
        #expect(b.add(facts(stripe), at: t0.addingTimeInterval(200)) == .single)
    }

    @Test func sourcesBatchSeparately() {
        var b = CatchBatcher()
        _ = b.add(facts(stripe), at: t0)
        _ = b.add(facts(stripe), at: t0.addingTimeInterval(1))
        #expect(b.add(facts(github, source: .clipboard), at: t0.addingTimeInterval(2)) == .single)
    }

    @Test func clipboardSummarySaysCopiedImagesAndSafeToPaste() {
        let items = (0..<3).map { _ in facts(github, source: .clipboard) }
        let plan = NotificationCopy.summaryPlan(identifier: "s", items: items, since: t0, now: t0)
        #expect(plan.body.contains("in 3 copied images since"))
        #expect(plan.verdict == "Safe to paste")
        #expect(plan.body.hasPrefix("GitHub token, in"))
    }

    @Test func moreThanThreeDetectorNamesFoldIntoACount() {
        let list = NotificationCopy.namesList(["A", "B", "C", "D", "E"], inSentence: ["A", "B", "C", "D", "E"])
        #expect(list.contains("2 more"))
        #expect(!list.contains("D"))
    }
}
