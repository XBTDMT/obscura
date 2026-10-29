// ObscuraThumbnailUI — the decisions behind Obscura's floating screenshot thumbnail (B-9, G-8, design r3-a), as pure
// values the tests drive: which card shows for a scan start or report, when it appears, folds and leaves, how a burst
// stacks, and what hover, drag and the right-click menu may do. The AppKit layer only carries these decisions out.
import CoreGraphics
import Foundation
import ObscuraCapture
import ObscuraEngine
import ObscuraPrefs

/// How a scan ended, as far as the thumbnail cares.
enum ShotResult: Sendable, Hashable {
    /// Checked, nothing found: the file on disk is the screenshot as taken.
    case clean
    /// Findings were covered; the Journal entry says where the clean file is.
    case redacted(entryID: UUID, findings: Int)
    /// Skipped or failed: nothing was checked, so nothing is offered (problems keep their banners).
    case dropped

    init(_ outcome: ScanOutcome) {
        switch outcome {
        case .clean: self = .clean
        case .redacted(let id, let findings, _): self = .redacted(entryID: id, findings: findings)
        case .skipped, .failed: self = .dropped
        }
    }
}

/// What one card shows.
enum CardPhase: Sendable, Hashable {
    /// The check outlasted its first moment: blurred image, "Checking…", nothing to drag or open.
    case checking
    /// Checked and clean.
    case clean
    /// Secrets covered; the file holds the clean image.
    case covered(entryID: UUID, findings: Int)
    /// After Undo: the original is back on disk.
    case original(entryID: UUID, findings: Int)

    var entryID: UUID? {
        switch self {
        case .covered(let id, _), .original(let id, _): return id
        case .checking, .clean: return nil
        }
    }

    var isChecking: Bool { self == .checking }
}

/// One screenshot on the thumbnail.
struct ShotCard: Sendable, Hashable {
    let key: CaptureKey
    let displayName: String
    let fileURL: URL
    /// The pointer when the capture entered the pipeline: the card shows on that display.
    let screenPoint: CGPoint
    var phase: CardPhase
    /// When the card (or its result, for a card that was checking) appeared.
    var shownAt: TimeInterval
    /// "Checked" has folded to the Obscura tile.
    var folded = false
}

/// What the AppKit layer must do after a decision.
enum StackChange: Sendable, Hashable {
    case none
    /// Nothing was on screen; slide the thumbnail in.
    case appear
    /// The thumbnail is on screen; redraw it.
    case update
    /// Slide it away.
    case hide
}

/// Reasons the countdown is paused.
enum Hold: Sendable, Hashable { case hover, drag, menu }

/// The thumbnail's state machine. Times are seconds on a monotonic clock the caller supplies.
struct ThumbnailStack: Sendable {
    /// A check that takes longer than this shows the checking card (warm scans take about 0.1 s; G-8 evidence).
    static let checkingDelay: TimeInterval = 0.3
    /// A checking card, once shown, stays at least this long before its result replaces it: the 0.2 s slide-in
    /// (`OMotion.slideDuration`) plus the 0.3 s a state needs to be read. A check that ends just after the reveal then
    /// never flashes "Checking…" mid-slide; its result cross-fades in once the card has landed and been seen.
    static let checkingMinimum: TimeInterval = 0.5
    /// "Checked" folds to the tile after this; "N covered" never folds.
    static let foldDelay: TimeInterval = 1.5
    /// After the pointer leaves, at least this much time remains, so the card never vanishes under a moving pointer.
    static let minimumAfterHold: TimeInterval = 1.0
    /// Card edges drawn behind the newest shot.
    static let maxEdges = 2
    /// Time past the OCR deadline a checking card may still wait for its report. The engine bounds OCR itself
    /// (`PipelineConstants.ocrDeadlineSeconds`); this margin covers the stages around it (decode before; detect,
    /// render, encode, the Journal write and the write-back after), which take well under a second on a screenshot.
    static let ceilingMargin: TimeInterval = 10

    /// How long a checking card waits for its report before it is dropped: the OCR deadline the engine scans under
    /// plus `ceilingMargin`. Defence for a scan whose report never comes (cancelled with the engine, a hung stage);
    /// the start-before-report order itself is guaranteed by the engine's one event stream (G-9). A report that does
    /// arrive later still shows its result.
    static func checkingCeiling(ocrDeadline: TimeInterval) -> TimeInterval { ocrDeadline + ceilingMargin }
    /// The ceiling under the default settings.
    static let defaultCheckingCeiling = checkingCeiling(ocrDeadline: PipelineConstants.ocrDeadlineSeconds(.default))

    struct Pending: Sendable, Hashable {
        var displayName: String
        var fileURL: URL
        var screenPoint: CGPoint
        var startedAt: TimeInterval
        /// Starts not yet reported for this key (a repeated key cancels and replaces the older scan).
        var count: Int
        /// When the checking card gives up waiting (`checkingCeiling` after the latest start).
        var ceilingAt: TimeInterval
        /// The ceiling passed: no checking card shows for it again, but a late report still shows its result.
        var expired = false
    }

    private(set) var pending: [CaptureKey: Pending] = [:]
    /// A report that arrived while its checking card was younger than `checkingMinimum`, applied by `tick` at `at`.
    struct Held: Sendable, Hashable {
        var result: ShotResult
        var duration: TimeInterval
        var at: TimeInterval
    }
    private(set) var held: [CaptureKey: Held] = [:]
    /// Oldest first; the last one is in front. Only as many as the edges can show are kept.
    private(set) var cards: [ShotCard] = []
    private(set) var holds: Set<Hold> = []
    /// When the thumbnail leaves; nil while paused, while the front card is checking, or when nothing shows.
    private(set) var deadline: TimeInterval?
    /// Time left when a hold paused the countdown.
    private(set) var remaining: TimeInterval?
    /// The countdown the last result started with, for restarting it when a checking card in front is dropped.
    private var lastDuration: TimeInterval?

    var front: ShotCard? { cards.last }
    var isVisible: Bool { !cards.isEmpty }
    var edges: Int { max(0, min(cards.count - 1, Self.maxEdges)) }
    var isPaused: Bool { !holds.isEmpty }

    /// Only new screenshots get the thumbnail: the clipboard has no file to drag, and Downloads, extra folders and
    /// imports keep their banners (G-8 "The thumbnail and the catch banner").
    static func accepts(origin: FileOrigin?, hasFile: Bool, enabled: Bool) -> Bool {
        enabled && hasFile && origin == .screenshotFolder
    }

    func isTracking(_ key: CaptureKey) -> Bool { pending[key] != nil }

    // MARK: Events

    /// `ceiling` is `checkingCeiling(ocrDeadline:)` under the settings the scan runs with.
    mutating func start(key: CaptureKey, displayName: String, fileURL: URL, screenPoint: CGPoint, at now: TimeInterval,
                        ceiling: TimeInterval = ThumbnailStack.defaultCheckingCeiling) {
        var p = pending[key] ?? Pending(displayName: displayName, fileURL: fileURL, screenPoint: screenPoint, startedAt: now, count: 0,
                                        ceilingAt: now + ceiling)
        p.displayName = displayName
        p.fileURL = fileURL
        p.screenPoint = screenPoint
        p.startedAt = now
        p.count += 1
        p.ceilingAt = now + ceiling
        p.expired = false
        pending[key] = p
    }

    /// A scan ended. Clean and covered results show (or replace the checking card); a dropped scan removes its
    /// checking card. A report for a start never seen shows nothing.
    mutating func report(key: CaptureKey, result: ShotResult, duration: TimeInterval, at now: TimeInterval) -> StackChange {
        guard var p = pending[key] else { return .none }
        if held[key] == nil, let i = cards.lastIndex(where: { $0.key == key && $0.phase.isChecking }),
           now - cards[i].shownAt < Self.checkingMinimum {
            held[key] = Held(result: result, duration: duration, at: cards[i].shownAt + Self.checkingMinimum)
            return .none
        }
        p.count -= 1
        pending[key] = p.count > 0 ? p : nil
        let wasVisible = isVisible
        let checkingIndex = cards.lastIndex { $0.key == key && $0.phase.isChecking }

        let phase: CardPhase
        switch result {
        case .dropped:
            // A newer scan of the same file is still running: its checking card stays.
            guard pending[key] == nil, let i = checkingIndex else { return .none }
            cards.remove(at: i)
            if cards.isEmpty { return clear() }
            if deadline == nil, remaining == nil, front?.phase.isChecking == false { startCountdown(duration, at: now) }
            return .update
        case .clean: phase = .clean
        case .redacted(let id, let n): phase = .covered(entryID: id, findings: n)
        }

        if let i = checkingIndex {
            cards[i].phase = phase
            cards[i].shownAt = now
        } else {
            cards.append(ShotCard(key: key, displayName: p.displayName, fileURL: p.fileURL, screenPoint: p.screenPoint,
                                  phase: phase, shownAt: now))
            trim()
        }
        startCountdown(duration, at: now)
        lastDuration = duration
        return wasVisible ? .update : .appear
    }

    /// Reveals a check that outlasted its first moment, drops one that outlasted its ceiling, folds "Checked", and ends
    /// the countdown.
    mutating func tick(at now: TimeInterval) -> StackChange {
        var change = StackChange.none
        for (key, h) in held where h.at <= now {
            held[key] = nil
            change = Self.merge(change, report(key: key, result: h.result, duration: h.duration, at: now))
        }
        if change == .hide { return .hide }
        if expireChecking(at: now) {
            if cards.isEmpty { return clear() }
            if deadline == nil, remaining == nil, front?.phase.isChecking == false, let lastDuration {
                startCountdown(lastDuration, at: now)
            }
            change = .update
        }
        let shown = Set(cards.map(\.key))
        let due = pending.filter {
            !$0.value.expired && !shown.contains($0.key) && now - $0.value.startedAt >= Self.checkingDelay
        }
        if let (key, p) = due.max(by: { $0.value.startedAt < $1.value.startedAt }) {
            let wasVisible = isVisible
            cards.append(ShotCard(key: key, displayName: p.displayName, fileURL: p.fileURL, screenPoint: p.screenPoint,
                                  phase: .checking, shownAt: now))
            trim()
            change = wasVisible ? .update : .appear
        }
        if let d = deadline, !isPaused, front?.phase.isChecking == false, now >= d {
            return clear()
        }
        if let i = cards.indices.last, cards[i].phase == .clean, !cards[i].folded, now - cards[i].shownAt >= Self.foldDelay {
            cards[i].folded = true
            if change == .none { change = .update }
        }
        return change
    }

    /// Hover, a drag in flight or an open menu pause the countdown; releasing the last hold resumes it.
    mutating func setHold(_ hold: Hold, _ on: Bool, at now: TimeInterval) {
        let wasPaused = isPaused
        if on { holds.insert(hold) } else { holds.remove(hold) }
        if !wasPaused, isPaused, let d = deadline {
            remaining = max(0, d - now)
            deadline = nil
        } else if wasPaused, !isPaused, let r = remaining {
            deadline = now + max(r, Self.minimumAfterHold)
            remaining = nil
        }
    }

    /// Undo and Black Out Again change what the front card shows.
    mutating func setPhase(_ phase: CardPhase, for key: CaptureKey) -> StackChange {
        guard let i = cards.lastIndex(where: { $0.key == key }), cards[i].phase != phase else { return .none }
        cards[i].phase = phase
        return .update
    }

    /// Swipe, Close, a successful drop, a click that opened the file.
    mutating func dismiss() -> StackChange {
        isVisible ? clear() : .none
    }

    // MARK: Reading

    /// The next moment `tick` has something to do, if any.
    func nextWakeup() -> TimeInterval? {
        var times: [TimeInterval] = []
        let shown = Set(cards.map(\.key))
        times += held.values.map(\.at)
        for (key, p) in pending where !p.expired {
            if !shown.contains(key) { times.append(p.startedAt + Self.checkingDelay) }
            times.append(p.ceilingAt)
        }
        if let d = deadline, !isPaused, front?.phase.isChecking == false { times.append(d) }
        if let f = front, f.phase == .clean, !f.folded { times.append(f.shownAt + Self.foldDelay) }
        return times.min()
    }

    /// Keys still worth holding images for: cards on screen and scans not past their ceiling.
    var liveKeys: Set<CaptureKey> {
        Set(cards.map(\.key)).union(pending.filter { !$0.value.expired }.keys)
    }

    // MARK: Private

    /// Marks every scan past its ceiling as expired and removes its checking card. Returns whether a card went.
    private mutating func expireChecking(at now: TimeInterval) -> Bool {
        var removed = false
        for key in pending.keys {
            guard let p = pending[key], !p.expired, now >= p.ceilingAt else { continue }
            pending[key]?.expired = true
            if let i = cards.lastIndex(where: { $0.key == key && $0.phase.isChecking }) {
                cards.remove(at: i)
                removed = true
            }
        }
        return removed
    }

    private mutating func startCountdown(_ duration: TimeInterval, at now: TimeInterval) {
        if isPaused { remaining = duration; deadline = nil } else { deadline = now + duration; remaining = nil }
    }

    private mutating func trim() {
        let keep = Self.maxEdges + 1
        if cards.count > keep { cards.removeFirst(cards.count - keep) }
    }

    /// Two changes in one tick: leaving outranks appearing, which outranks a redraw.
    private static func merge(_ a: StackChange, _ b: StackChange) -> StackChange {
        let rank: [StackChange: Int] = [.none: 0, .update: 1, .appear: 2, .hide: 3]
        return (rank[a] ?? 0) >= (rank[b] ?? 0) ? a : b
    }

    private mutating func clear() -> StackChange {
        cards.removeAll()
        // A held report's scan has ended: count it, so its key is not revealed again as a checking card.
        for key in held.keys {
            guard var p = pending[key] else { continue }
            p.count -= 1
            pending[key] = p.count > 0 ? p : nil
        }
        held.removeAll()
        holds.removeAll()
        deadline = nil
        remaining = nil
        return .hide
    }
}
