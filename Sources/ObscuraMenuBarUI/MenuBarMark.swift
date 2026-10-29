// ObscuraMenuBarUI — the menu bar mark as it is shown over time (B-9, G-15, G-21): which mark, which state, when, and
// the image for each moment. One presenter per model owns every timing rule, so any host shows the same mark: today the
// status item's hosted label (`MenuBarLabel`), through `image` and `onChange`.
//
// Rules: checking shows only for a check that outlasts `MarkTiming.checkingReveal` and then stays at least
// `checkingMinimum` (`MarkCheckingGate`), so a warm ~0.1 s scan never blinks the mark and the caught dot under it is
// not pre-empted. The Classic ring keeps its 60 fps sweep and its dot fades (G-15). Every other mark (G-21) plays
// the ruled motion (G-21), drawn as frames because Apple's symbol effects do not run on an NSStatusBarButton: checking is
// the scan line loop; caught snaps shut (a file) or wipes (the clipboard) and then shows the green dot for 4 s; Copy
// Clean pulses; an Undo's original lifts the cover until it is covered again; pausing and resuming cross-fade; needs
// you pops; update ready fades. Each one-shot is ≤ 0.6 s (`MarkTimeline`); under Reduce Motion, read live, every one
// is its final frame at once and the scan line stands still. Nothing runs while nothing moves: no idle timer.
public import AppKit
public import Observation
public import ObscuraUIKit
public import ObscuraPrefs
import SwiftUI

@MainActor
@Observable
public final class MenuBarMarkPresenter {
    /// The state the mark shows (checking already gated).
    public private(set) var state: MarkState = .protected
    /// Catches the count badge stands for (notifications off, panel closed); 0 = no badge.
    public private(set) var count = 0
    /// The image for this moment: a template for one-colour marks with no colour in them, colour otherwise.
    public private(set) var image: NSImage
    /// Whether the gated checking state shows. A panel's checking card can follow it too, so it never flashes for a
    /// warm scan either.
    public private(set) var showsChecking = false
    /// The words VoiceOver reads for the mark, its state and the badge (unchanged by the mark picked).
    public var accessibilityLabel: String { MarkCopy.accessibilityLabel(state, count: count) }
    /// Runs after every change of `image`, for an AppKit status item (SwiftUI reads `image` through observation).
    @ObservationIgnored public var onChange: (@MainActor (MenuBarMarkPresenter) -> Void)?

    /// The menu bar the mark sits in: dark or light, and emphasized while the item is highlighted on an emphasized
    /// background. The status item's controller sets it from its button; until then it follows the app's appearance.
    @ObservationIgnored public var barAppearance: MarkAppearance? {
        didSet { if barAppearance != oldValue { redraw() } }
    }

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let memory: PanelMemory
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let busy: @MainActor () -> Bool
    @ObservationIgnored private let reduceMotion: @MainActor () -> Bool
    @ObservationIgnored private let schedulesTimers: Bool
    @ObservationIgnored private var gate = MarkCheckingGate()
    @ObservationIgnored private var wake: Task<Void, Never>?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var motionTask: Task<Void, Never>?
    /// Frame of the running loop: the Classic ring's sweep or the scan line.
    @ObservationIgnored private(set) var sweepIndex = 0
    /// The one-shot motion playing now, if any.
    @ObservationIgnored private(set) var motion: ActiveMotion?
    /// The cover is lifted (an Undo's original showing).
    @ObservationIgnored private(set) var lifted = false
    @ObservationIgnored private var lastCopiedClean: MarkCue?
    @ObservationIgnored private var shownMark: MenuBarMarkID?
    @ObservationIgnored private var loopFrames = LoopFrames()
    @ObservationIgnored private var drawnKey: DrawnKey?
    @ObservationIgnored private var reduceMotionObserver: (any NSObjectProtocol)?

    /// A one-shot action under way.
    struct ActiveMotion: Equatable {
        var kind: MarkMotion
        var start: Date
        /// The state the motion leaves (a dot fading out is drawn on it; a cross-fade starts from it).
        var from: MarkState
    }

    // MARK: One presenter per model

    private struct Slot {
        weak var model: AppModel?
        let presenter: MenuBarMarkPresenter
    }
    private static var slots: [ObjectIdentifier: Slot] = [:]

    /// The presenter for `model`; every host of the mark uses this one.
    public static func shared(for model: AppModel) -> MenuBarMarkPresenter {
        let id = ObjectIdentifier(model)
        if let slot = slots[id], slot.model === model { return slot.presenter }
        let presenter = MenuBarMarkPresenter(model: model, memory: PanelMemory.shared(for: model))
        slots[id] = Slot(model: model, presenter: presenter)
        return presenter
    }

    convenience init(model: AppModel, memory: PanelMemory) {
        self.init(model: model, memory: memory, clock: { Date() }, busy: { model.isChecking },
                  reduceMotion: { OMotion.systemReduceMotion }, schedulesTimers: true)
    }

    init(model: AppModel, memory: PanelMemory, clock: @escaping @MainActor () -> Date, busy: @escaping @MainActor () -> Bool,
         reduceMotion: @escaping @MainActor () -> Bool, schedulesTimers: Bool) {
        self.model = model
        self.memory = memory
        self.clock = clock
        self.busy = busy
        self.reduceMotion = reduceMotion
        self.schedulesTimers = schedulesTimers
        image = ObscuraMarkDrawing.menuBarImage(.protected)
        // What already happened before the mark existed is not replayed.
        lastCopiedClean = model.copiedClean
        lifted = model.showsOriginal
        shownMark = model.settings.menuBarMark
        refresh()
        observe()
        if schedulesTimers {
            reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reduceMotionChanged() }
            }
        }
    }

    isolated deinit {
        wake?.cancel(); loopTask?.cancel(); motionTask?.cancel()
        if let reduceMotionObserver { NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver) }
    }

    // MARK: Inputs

    /// Re-reads the model whenever anything the mark depends on changes.
    private func observe() {
        withObservationTracking {
            _ = model.markState(showingChecking: false, at: clock())
            _ = model.isChecking
            _ = MenuBarLabel.badgeCount(model: model, memory: memory)
            _ = model.settings.pausedColor
            _ = model.settings.menuBarMark
            _ = model.settings.menuBarMarkStyle
            _ = MenuBarLabel.reservesBadgeSpace(model.settings)
            _ = model.copiedClean
            _ = model.showsOriginal
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observe()
            }
        }
    }

    private var mark: MenuBarMarkID { model.settings.menuBarMark }

    /// Decides the state for this moment and redraws. Tests call it after moving the clock.
    func refresh() {
        let now = clock()
        showsChecking = gate.update(busy: busy(), at: now.timeIntervalSinceReferenceDate)
        let next = model.markState(showingChecking: showsChecking, at: now)
        if mark != shownMark {
            // A newly picked mark appears at once in its resting look; nothing half-played carries over.
            shownMark = mark
            stopMotion()
        } else if next != state {
            transition(from: state, to: next, at: now)
        }
        state = next
        count = MenuBarLabel.badgeCount(model: model, memory: memory)
        if model.showsOriginal != lifted {
            lifted = model.showsOriginal
            if mark.takesColourStyle, state.hasFullRing { play(lifted ? .coverLifts : .coverReturns, from: state, at: now) }
        }
        if model.copiedClean != lastCopiedClean {
            lastCopiedClean = model.copiedClean
            if mark.takesColourStyle, state.hasFullRing { play(.copyClean, from: state, at: now) }
        }
        runLoop()
        scheduleWake(after: now)
        redraw()
    }

    /// The next moment the state changes by itself: the checking reveal or its minimum, or the end of the caught dot.
    private func scheduleWake(after now: Date) {
        wake?.cancel()
        wake = nil
        guard schedulesTimers else { return }
        var times: [Date] = []
        if let t = gate.nextWakeup() { times.append(Date(timeIntervalSinceReferenceDate: t)) }
        if let end = model.caughtUntil, end > now { times.append(end) }
        guard let at = times.min() else { return }
        let delay = max(0, at.timeIntervalSince(now)) + 0.01
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Reduce Motion changed while the app runs: a running motion jumps to its end and a loop stops (or starts).
    private func reduceMotionChanged() {
        if reduceMotion() { stopMotion() }
        refresh()
    }

    // MARK: Motion

    /// Which motion a change of state plays (G-21 "motion"), or nil for an instant change.
    nonisolated static func motion(for mark: MenuBarMarkID, from old: MarkState, to new: MarkState, clipboard: Bool) -> MarkMotion? {
        if mark == .classic {
            // The Classic ring keeps its own motion (G-15): only a dot appearing on, or leaving, the full ring fades.
            guard old.hasFullRing, new.hasFullRing, old.hasDot != new.hasDot else { return nil }
            return new.hasDot ? .updateFade : .dotFadeOut
        }
        if (old == .paused) != (new == .paused) { return .pauseCrossFade }
        switch new {
        case .caught where old != .caught: return clipboard ? .clipboardCleaned : .caught
        case .needsAttention where old != .needsAttention: return .needsYouPop
        case .waiting, .focusHolding:
            return old.hasFullRing && !old.hasDot ? .updateFade : nil
        default:
            if old.hasDot, new.hasFullRing, !new.hasDot { return .dotFadeOut }
            return nil
        }
    }

    private func transition(from old: MarkState, to new: MarkState, at now: Date) {
        stopMotion()
        guard let kind = Self.motion(for: mark, from: old, to: new, clipboard: model.lastCatchFromClipboard) else { return }
        play(kind, from: old, at: now)
    }

    /// Starts `kind`, or under Reduce Motion lets the state show its end at once.
    private func play(_ kind: MarkMotion, from: MarkState, at now: Date) {
        stopMotion()
        guard !reduceMotion() else { return }
        motion = ActiveMotion(kind: kind, start: now, from: from)
        guard schedulesTimers else { return }
        let frame = Duration.seconds(1 / MarkTimeline.fps)
        motionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: frame)
                guard let self, !Task.isCancelled else { return }
                if !self.tickMotion() { return }
            }
        }
    }

    private func stopMotion() {
        motionTask?.cancel()
        motionTask = nil
        motion = nil
    }

    /// One frame of the running motion (the timer's step; tests call it after moving the clock). Returns whether it
    /// is still running.
    @discardableResult
    func tickMotion() -> Bool {
        guard let motion else { return false }
        let elapsed = clock().timeIntervalSince(motion.start)
        if elapsed >= MarkTimeline.duration(motion.kind, pieces: pieces) {
            self.motion = nil
            motionTask = nil
            redraw()
            return false
        }
        redraw()
        return true
    }

    private var pieces: Int { mark.designedPieceCount }

    /// Whether any frame timer is running (a loop or a motion). False whenever nothing moves: the mark has no idle timer.
    var hasRunningTimers: Bool { loopTask != nil || motionTask != nil }

    /// Runs the checking loop while checking shows: the Classic ring's sweep or the scan line, one frame per 1/60 s,
    /// each drawn once and reused; still under Reduce Motion.
    private func runLoop() {
        let turning = state == .checking && !reduceMotion()
        if !turning {
            loopTask?.cancel()
            loopTask = nil
            if state != .checking || reduceMotion() { sweepIndex = 0 }
            return
        }
        guard schedulesTimers, loopTask == nil else { return }
        let frame = Duration.seconds(1 / MarkTimeline.fps)
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: frame)
                guard let self, !Task.isCancelled else { return }
                self.advanceSweep()
            }
        }
    }

    /// One frame of the loop (the timer's step; tests call it directly).
    func advanceSweep() {
        let frames = mark == .classic ? MarkTiming.sweepFrames : MarkTimeline.scanFrames
        sweepIndex = (sweepIndex + 1) % frames
        redraw()
    }

    // MARK: Drawing

    private struct DrawnKey: Hashable {
        var frame: MarkFrame
        var look: MarkLook
    }

    /// The bar's appearance now: what the controller reported, else the app's.
    private var appearance: MarkAppearance {
        barAppearance ?? MarkAppearance(isDark: NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    /// The frame for this moment, and the look it is drawn with.
    func current() -> (MarkFrame, MarkLook) {
        let look = MarkLook(pointSize: 18, count: count, reservesBadgeSpace: MenuBarLabel.reservesBadgeSpace(model.settings),
                            appearance: appearance, pausedColor: model.settings.pausedColor)
        // The lifted cover belongs to the full-ring states; paused, partly and checking have their own looks.
        let liftShows = lifted && mark.takesColourStyle && state.hasFullRing
        var frame = MarkFrame(mark: mark, style: model.settings.menuBarMarkStyle, state: state, pose: .rest(lifted: liftShows))
        if let motion {
            let t = clock().timeIntervalSince(motion.start)
            frame.pose = MarkTimeline.pose(motion.kind, pieces: pieces, at: t, lifted: liftShows)
            switch motion.kind {
            case .dotFadeOut: frame.state = motion.from
            case .pauseCrossFade: frame.crossFrom = motion.from
            default: break
            }
        }
        if state == .checking {
            if mark == .classic { frame.sweep = Double(sweepIndex) / Double(MarkTiming.sweepFrames) }
            else { frame.pose.scanY = reduceMotion() ? nil : MarkTimeline.scanY(frame: sweepIndex) }
        }
        return (frame, look)
    }

    private func redraw() {
        let (frame, look) = current()
        let key = DrawnKey(frame: frame, look: look)
        guard key != drawnKey else { return }
        drawnKey = key
        if frame.state == .checking, frame.crossFrom == nil, motion == nil {
            image = loopFrames.frame(sweepIndex, frame: frame, look: look)
        } else {
            image = MenuBarMarkImage.image(frame, look, scales: Self.scales)
        }
        onChange?(self)
    }

    /// 1× and 2×, so a status item on any screen picks a crisp bitmap.
    static var scales: [CGFloat] { MenuBarMarkImage.scales }
}

/// One checking loop (the Classic sweep or the scan line), drawn once per look and reused every turn, so a long check
/// costs no drawing after its first turn.
struct LoopFrames {
    private var key: Key?
    private var cache: [Int: NSImage] = [:]

    /// What the frames depend on besides their index.
    struct Key: Hashable {
        var mark: MenuBarMarkID
        var style: MenuBarMarkStyle
        var look: MarkLook
        /// The scan line standing still (Reduce Motion) draws a different frame 0.
        var still: Bool
    }

    /// Frames drawn so far for the current look.
    var drawnCount: Int { cache.count }

    @MainActor mutating func frame(_ index: Int, frame: MarkFrame, look: MarkLook) -> NSImage {
        let key = Key(mark: frame.mark, style: frame.style, look: look, still: frame.mark != .classic && frame.pose.scanY == nil)
        if key != self.key { self.key = key; cache.removeAll() }
        if let image = cache[index] { return image }
        let image = MenuBarMarkImage.image(frame, look, scales: MenuBarMarkPresenter.scales)
        cache[index] = image
        return image
    }
}
