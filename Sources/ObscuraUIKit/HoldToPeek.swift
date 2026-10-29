// Hold-to-peek, the one rule for every surface that can show the original under the pointer (the Viewer canvas, the
// Journal inspector's preview): the original shows only after a deliberate hold, never on a click or a double-click.
// The red "original showing" marking means the original is really on screen (system.html, "Where the original is
// marked"), so it must not flash during an ordinary click. Recon T-2 (knowledge/recon/motion-2026-10-27).
// Standard library only (Task, Duration, MainActor): the type is UI-framework-free so any surface can drive it.

/// Turns press and release into peek begin and end. A press starts the hold; the peek begins only when the press is
/// still down after `delay`. A release (or a drag, which pans instead) before then cancels it, so a click or a
/// double-click never shows the original.
@MainActor
public final class HoldToPeek {
    /// How long a press must last before the original shows (the Viewer's long-standing 350 ms).
    public static let delay: Duration = .milliseconds(350)

    /// Whether the peek has begun for the current press.
    public private(set) var isPeeking = false
    private let holdDelay: Duration
    private var pending: Task<Void, Never>?
    /// Called when the hold has lasted `delay` (show the original) and when a peek's press ends (hide it).
    public var onBegin: @MainActor () -> Void
    public var onEnd: @MainActor () -> Void

    /// `delay` is injectable for tests only; every surface uses the shared `HoldToPeek.delay`.
    public init(delay: Duration = HoldToPeek.delay, onBegin: @escaping @MainActor () -> Void = {},
                onEnd: @escaping @MainActor () -> Void = {}) {
        self.holdDelay = delay
        self.onBegin = onBegin
        self.onEnd = onEnd
    }

    /// The pointer went down. Starts the hold; a second press while one is pending restarts it.
    public func pressBegan() {
        pending?.cancel()
        let wait = holdDelay
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.isPeeking = true
            self.onBegin()
        }
    }

    /// The press turned into something else (a drag that pans): no peek for this press.
    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// The pointer went up. Ends a peek that began; returns whether this press was a peek, so the caller can treat
    /// a press that was not one as a click.
    @discardableResult
    public func pressEnded() -> Bool {
        cancel()
        guard isPeeking else { return false }
        isPeeking = false
        onEnd()
        return true
    }
}
