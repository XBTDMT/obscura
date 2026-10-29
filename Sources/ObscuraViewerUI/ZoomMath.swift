// Zoom arithmetic for the viewer canvas: the step ladder for ⌘+ / ⌘−, fit, clamping, ⌘-scroll factors and the label.
// Pure functions, so the behaviour is tested without a window.
import Foundation
import CoreGraphics

/// How the canvas is zoomed: tracking the window (fit) or at a fixed magnification (1 = actual size).
enum ZoomMode: Equatable, Sendable {
    case fit
    case scale(CGFloat)
}

enum ZoomMath {
    /// The scroll view's magnification bounds.
    static let minimum: CGFloat = 0.05
    static let maximum: CGFloat = 16
    /// Space kept around the image when it is fitted (system.html: viewer canvas padding 22).
    static let canvasPadding: CGFloat = 22
    /// The ⌘+ / ⌘− ladder, as Preview-style round steps.
    static let steps: [CGFloat] = [0.05, 0.1, 0.125, 0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 12, 16]

    static func clamp(_ m: CGFloat) -> CGFloat {
        guard m.isFinite else { return 1 }
        return min(max(m, minimum), maximum)
    }

    /// The magnification that shows all of `content` inside `viewport` with `padding` on every side. A small image is
    /// never enlarged past actual size unless `allowsUpscale`, so a fitted screenshot is never blurred.
    static func fit(content: CGSize, viewport: CGSize, padding: CGFloat = canvasPadding, allowsUpscale: Bool = false) -> CGFloat {
        guard content.width > 0, content.height > 0 else { return 1 }
        let w = max(viewport.width - padding * 2, 1), h = max(viewport.height - padding * 2, 1)
        let m = min(w / content.width, h / content.height)
        return clamp(allowsUpscale ? m : min(m, 1))
    }

    /// The next step strictly above `m` (⌘+).
    static func stepIn(from m: CGFloat) -> CGFloat {
        steps.first { $0 > m * 1.001 } ?? maximum
    }

    /// The next step strictly below `m` (⌘−).
    static func stepOut(from m: CGFloat) -> CGFloat {
        steps.last { $0 < m / 1.001 } ?? minimum
    }

    /// The magnification multiplier for one ⌘-scroll event. Line-based wheels report coarse deltas, trackpads fine ones.
    static func scrollFactor(deltaY: CGFloat, precise: Bool) -> CGFloat {
        let d = max(min(deltaY, 50), -50) * (precise ? 0.01 : 0.1)
        return exp(d)
    }

    /// The new magnification after a ⌘-scroll event.
    static func scrolled(from m: CGFloat, deltaY: CGFloat, precise: Bool) -> CGFloat {
        clamp(m * scrollFactor(deltaY: deltaY, precise: precise))
    }

    /// "Fit" while fitting, else the percentage ("50%").
    static func label(for mode: ZoomMode, locale: Locale = .current) -> String {
        switch mode {
        case .fit: return String(localized: "Fit", comment: "Viewer zoom label while the image is fitted to the window")
        case .scale(let m): return percent(m, locale: locale)
        }
    }

    static func percent(_ m: CGFloat, locale: Locale = .current) -> String {
        Double(m).formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
}
