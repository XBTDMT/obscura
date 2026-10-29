// ObscuraNotifyUI — folds a paste-heavy session into one banner. Per source thread: the first two catches inside a
// minute post their own banners; the third turns the burst into one summary that names the detectors, the singles are
// withdrawn from Notification Centre (each stays a row in the panel's Recent), and later catches join the summary
// while they keep coming less than a minute apart. Only the first summary shows a banner; later catches update it in
// place quietly (G-15), and an Undo from a banner takes its catch out of the summary.
import Foundation

struct CatchBatcher: Sendable {
    /// Catches inside `window` that start a summary.
    static let threshold = 3
    static let window: TimeInterval = 60

    enum Decision: Sendable, Hashable {
        /// Post this catch on its own.
        case single
        /// Post (or replace) the burst's summary and withdraw the singles posted earlier in the burst. `first`: the
        /// summary appears now (one banner); otherwise it updates in place without a new banner.
        case summary(identifier: String, items: [CatchFacts], since: Date, withdraw: [String], first: Bool)
    }

    /// What taking a catch out of its burst means for the summary.
    enum Removal: Sendable, Hashable {
        /// The catch was not in a summary.
        case none
        /// Re-post the summary (quietly) with the catches left.
        case update(identifier: String, items: [CatchFacts], since: Date)
        /// Nothing left to summarise: withdraw it.
        case withdraw(identifier: String)
    }

    private struct Item: Sendable { var facts: CatchFacts; var at: Date }
    private struct Burst: Sendable {
        var items: [Item] = []
        var summaryID: String?
    }

    private var bursts: [String: Burst] = [:]

    init() {}

    mutating func add(_ facts: CatchFacts, at now: Date) -> Decision {
        let thread = facts.source
        var burst = bursts[thread] ?? Burst()
        if burst.summaryID != nil {
            // A summarising burst lives while catches keep arriving less than a window apart.
            if let last = burst.items.last, now.timeIntervalSince(last.at) > Self.window { burst = Burst() }
        }
        if burst.summaryID == nil {
            // Before the threshold the window slides: only catches in the last minute count.
            burst.items.removeAll { now.timeIntervalSince($0.at) > Self.window }
        }
        burst.items.append(Item(facts: facts, at: now))

        guard burst.summaryID != nil || burst.items.count >= Self.threshold else {
            bursts[thread] = burst
            return .single
        }
        var withdraw: [String] = []
        let first = burst.summaryID == nil
        if first {
            let start = burst.items.first?.at ?? now
            burst.summaryID = "obscura.summary.\(thread).\(Int(start.timeIntervalSince1970))"
            withdraw = burst.items.dropLast().map { $0.facts.entryID.uuidString }
        }
        bursts[thread] = burst
        return .summary(identifier: burst.summaryID ?? "", items: burst.items.map(\.facts),
                        since: burst.items.first?.at ?? now, withdraw: withdraw, first: first)
    }

    /// Drops a catch from its burst (it was undone, so it no longer belongs in a "blacked out" summary) and says what
    /// that does to a summary already posted.
    @discardableResult
    mutating func remove(entryID: UUID) -> Removal {
        var effect = Removal.none
        for (thread, var burst) in bursts {
            let before = burst.items.count
            burst.items.removeAll { $0.facts.entryID == entryID }
            bursts[thread] = burst
            guard burst.items.count != before, let id = burst.summaryID else { continue }
            if let since = burst.items.first?.at {
                effect = .update(identifier: id, items: burst.items.map(\.facts), since: since)
            } else {
                effect = .withdraw(identifier: id)
            }
        }
        return effect
    }
}
