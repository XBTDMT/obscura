// Obscura's one motion vocabulary (G-15, ruled 2026-10-27): a change is either instant or one short fade.
// Nothing slides except the floating thumbnail's own designed slide (G-8, thumbnail r3-a) and, only when the user turns
// it on, the Journal inspector's system slide (G-19 T-8, `paneSlide`). Under Reduce Motion every
// fade becomes instant. Only the checking ring and the indeterminate progress move continuously (design/mockups/
// unified/system.html, "Motion"), and both stop under Reduce Motion.
public import SwiftUI
import AppKit

/// Motion tokens. Every animated change in the app goes through these, so the whole app moves the same way.
public enum OMotion {
    /// The one fade: panes, toasts, badges, rows appearing or leaving, image swaps.
    public static let fadeDuration: Double = 0.15
    /// The thumbnail's slide in and out (r3-a).
    public static let slideDuration: Double = 0.2
    /// The one opt-in exception to "no slides" (G-19 T-8, 2026-10-27): the Journal inspector's system slide, when
    /// `Settings.journalInspectorMotion` asks for it. The length of a Mac split view's own collapse.
    public static let paneSlideDuration: Double = 0.25
    /// How long an in-window or panel toast stays before it fades (one value for every surface).
    public static let toastSeconds: Double = 4
    /// How long a load must take before its placeholder spinner shows (HIG: show progress only when the wait is
    /// noticeable). A load that finishes sooner goes straight from nothing to the content.
    public static let progressDelay: Double = 0.5
    /// One turn of the checking ring (system.html `.mark .spin`, 1.1 s linear). It stands still under Reduce Motion.
    public static let spinnerPeriod: Double = 1.1

    /// The fade, or nil (instant) under Reduce Motion. Use with `withAnimation` and `.animation(_:value:)`.
    public static func fade(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: fadeDuration)
    }

    /// The thumbnail's slide, or nil under Reduce Motion (the thumbnail then fades with `fade`).
    public static func slide(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: slideDuration)
    }

    /// The Journal inspector's slide, or nil (instant) under Reduce Motion. Only for `InspectorMotion.slide`.
    public static func paneSlide(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: paneSlideDuration)
    }

    /// The transition for a view that appears or leaves: opacity only, never movement.
    public static var appear: AnyTransition { .opacity }

    /// The transition for an image replaced by a newer one: the outgoing image fades out over the incoming one, so the
    /// ground under them never shows through halfway (a symmetric cross-fade dips to the background at its midpoint).
    public static var crossFade: AnyTransition { .asymmetric(insertion: .identity, removal: .opacity) }

    /// The system's Reduce Motion setting, for code outside a view (AppKit controllers, window animations).
    @MainActor public static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Runs `body` with the fade, or without animation under Reduce Motion.
    @MainActor public static func withFade<Result>(reduceMotion: Bool, _ body: () throws -> Result) rethrows -> Result {
        try withAnimation(fade(reduceMotion: reduceMotion), body)
    }
}

public extension View {
    /// Animates changes of `value` with the one fade, or instantly under Reduce Motion.
    func oFade<V: Equatable>(value: V) -> some View {
        modifier(OFadeModifier(value: value))
    }
}

private struct OFadeModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: V
    func body(content: Content) -> some View {
        content.animation(OMotion.fade(reduceMotion: reduceMotion), value: value)
    }
}

/// The small placeholder spinner of a window that is loading, shown only once the wait passes `OMotion.progressDelay`,
/// so a quick load never flashes it (recon T-16). It appears without motion.
public struct DelayedProgress: View {
    @State private var visible = false
    public init() {}
    public var body: some View {
        ProgressView().controlSize(.small)
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(!visible)
            .task {
                try? await Task.sleep(for: .seconds(OMotion.progressDelay))
                if !Task.isCancelled { visible = true }
            }
    }
}
