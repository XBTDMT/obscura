// ObscuraThumbnailUI — the small pure rules around one card: what its capsule says, what hover offers, what a click
// opens, which file a drag carries, when a swipe or a fling dismisses it, what the right-click menu holds, and where
// the panel sits on a screen.
import CoreGraphics
import Foundation
import ObscuraPrefs

// MARK: - Capsule and hover

/// The capsule on the image's lower-left corner.
enum CapsuleKind: Sendable, Hashable {
    /// Obscura tile, a spinner and "Checking…".
    case checking
    /// Obscura tile, a check and "Checked"; folds to `.folded` after 1.5 s.
    case checked
    /// The Obscura tile alone.
    case folded
    /// Obscura tile, a cover bar and "N covered". Never folds.
    case covered(Int)
    /// Red: an eye and "Original showing". The image also gets the red dashed frame.
    case original(Int)

    init(_ card: ShotCard) {
        switch card.phase {
        case .checking: self = .checking
        case .clean: self = card.folded ? .folded : .checked
        case .covered(_, let n): self = .covered(n)
        case .original(_, let n): self = .original(n)
        }
    }

    var marksOriginal: Bool { if case .original = self { return true } else { return false } }
}

/// The one-click capsule hover adds on the lower-right.
enum HoverAction: Sendable, Hashable {
    case undo
    case blackOutAgain

    init?(_ phase: CardPhase) {
        switch phase {
        case .covered: self = .undo
        case .original: self = .blackOutAgain
        case .checking, .clean: return nil
        }
    }
}

// MARK: - Click

enum ClickTarget: Sendable, Hashable {
    case preview(URL)
    case viewer(UUID)
    /// Still checking: nothing unscanned is opened.
    case nothing

    /// Settings decide Preview or the viewer; a clean shot has no Journal entry, so the viewer falls back to Preview.
    static func resolve(phase: CardPhase, setting: ThumbnailClick, file: URL?) -> ClickTarget {
        if phase.isChecking { return .nothing }
        if setting == .viewer, let id = phase.entryID { return .viewer(id) }
        return file.map(ClickTarget.preview) ?? .nothing
    }
}

// MARK: - Drag

enum DragFile {
    /// The file a drag carries: nothing while checking; the screenshot itself when clean; for a catch, the file the
    /// engine wrote back (the " (clean)" sibling in keep-both mode, else the screenshot, now clean). After Undo it is the
    /// screenshot, which holds the original, as the red marks say: in keep-both mode the " (clean)" sibling went to the
    /// Trash with the Undo (fail-open #17), so it is never what an "original" card carries. A file that is gone is never
    /// offered.
    static func resolve(phase: CardPhase, fileURL: URL, entryFilePath: String?, entryCleanCopyPath: String?,
                        exists: (URL) -> Bool) -> URL? {
        let candidate: URL
        switch phase {
        case .checking: return nil
        case .clean: candidate = fileURL
        case .covered:
            if let clean = entryCleanCopyPath { candidate = URL(fileURLWithPath: clean) }
            else if let path = entryFilePath { candidate = URL(fileURLWithPath: path) }
            else { candidate = fileURL }
        case .original:
            candidate = entryFilePath.map { URL(fileURLWithPath: $0) } ?? fileURL
        }
        return exists(candidate) ? candidate : nil
    }
}

enum DragEnd {
    /// After a drag: a drop that took the file dismisses the thumbnail (as macOS's does); a drag let go at or past the
    /// card's right edge, still on the card's own display, is a fling toward the screen edge and dismisses it too;
    /// anything else (including a failed drop on a display arranged to the right) puts it back.
    static func dismisses(dropped: Bool, endPoint: CGPoint, cardFrame: CGRect, screen: CGRect) -> Bool {
        dropped || isFling(endPoint, cardFrame: cardFrame, screen: screen)
    }

    /// Past the card's right edge, between the card's bottom and top, and on the card's display.
    static func isFling(_ point: CGPoint, cardFrame: CGRect, screen: CGRect) -> Bool {
        point.x >= cardFrame.maxX && point.x <= screen.maxX && point.y >= screen.minY && point.y <= screen.maxY
    }
}

/// A two-finger swipe on the card. Deltas are rightward points (the caller removes natural-scrolling inversion).
struct SwipeTracker: Sendable, Hashable {
    static let dismissDistance: CGFloat = 48
    static let flingDelta: CGFloat = 12
    static let leftRubberBand: CGFloat = 8

    private(set) var offset: CGFloat = 0
    private(set) var lastDelta: CGFloat = 0
    /// Rightward points per second over the last events (0 until two timed events arrived).
    private(set) var speed: CGFloat = 0
    private var lastTime: TimeInterval?

    /// `time` is the event's timestamp (seconds); without it the speed is not tracked.
    mutating func changed(by delta: CGFloat, at time: TimeInterval? = nil) {
        offset = max(-Self.leftRubberBand, offset + delta)
        lastDelta = delta
        if let time {
            if let lastTime, time > lastTime {
                let instant = delta / CGFloat(time - lastTime)
                // Light smoothing: one jittery event does not decide how fast the card leaves.
                speed = speed == 0 ? instant : 0.6 * instant + 0.4 * speed
            }
            lastTime = time
        }
    }

    var shouldDismiss: Bool {
        offset >= Self.dismissDistance || (lastDelta >= Self.flingDelta && offset > Self.leftRubberBand)
    }

    mutating func reset() { offset = 0; lastDelta = 0; speed = 0; lastTime = nil }
}

/// How a swiped card leaves: it carries on at the finger's speed (linear, no ease-in from rest), never slower than the
/// thumbnail's own slide would cover the remaining distance.
enum SwipeExit {
    static let shortest: TimeInterval = 0.06

    static func duration(remaining: CGFloat, speed: CGFloat, slide: TimeInterval) -> TimeInterval {
        guard remaining > 0 else { return 0 }
        guard speed > 0 else { return slide }
        return min(slide, max(shortest, TimeInterval(remaining / speed)))
    }
}

// MARK: - Menu

/// The right-click menu, in r3-a's order. No shortcuts are shown: the thumbnail never has focus, so ⌘C and ⌘Z keep
/// going to the app in front.
enum ThumbnailMenuItem: Sendable, Hashable {
    case copy
    case openInViewer
    case openInPreview
    case showInFinder
    case openInJournal
    case undo
    case blackOutAgain
    case delete
    case close
    case separator

    static func items(for phase: CardPhase, clickOpens: ThumbnailClick) -> [ThumbnailMenuItem] {
        switch phase {
        case .checking:
            // Nothing unscanned may be copied, opened or shown.
            return [.close]
        case .clean:
            // A clean shot has no Journal entry, so the viewer and the Journal have nothing to show.
            let other: [ThumbnailMenuItem] = clickOpens == .viewer ? [.openInPreview] : []
            return [.copy] + other + [.showInFinder, .separator, .delete, .close]
        case .covered, .original:
            let other: ThumbnailMenuItem = clickOpens == .preview ? .openInViewer : .openInPreview
            let flip: ThumbnailMenuItem = phase.isOriginal ? .blackOutAgain : .undo
            return [.copy, other, .showInFinder, .openInJournal, .separator, flip, .separator, .delete, .close]
        }
    }
}

extension CardPhase {
    var isOriginal: Bool { if case .original = self { return true } else { return false } }
}

// MARK: - Placement

/// Sizes from r3-a: the card is macOS's 176 × 110 pt, 16 pt from the bottom-right of the screen. The panel adds a
/// transparent margin for the burst edges (11 pt above), the hover lift (2 pt) and the original's dashed frame (4 pt).
enum ThumbnailPlacement {
    static let cardSize = CGSize(width: 176, height: 110)
    static let screenInset: CGFloat = 16
    static let marginTop: CGFloat = 14
    static let marginSide: CGFloat = 5
    static let panelSize = CGSize(width: cardSize.width + 2 * marginSide, height: cardSize.height + marginTop + marginSide)

    /// The card's frame (AppKit screen coordinates, origin bottom-left) in a screen's visible frame.
    static func cardFrame(in visible: CGRect) -> CGRect {
        CGRect(x: visible.maxX - screenInset - cardSize.width, y: visible.minY + screenInset,
               width: cardSize.width, height: cardSize.height)
    }

    /// The panel's resting frame.
    static func panelFrame(in visible: CGRect) -> CGRect {
        let card = cardFrame(in: visible)
        return CGRect(x: card.minX - marginSide, y: card.minY - marginSide, width: panelSize.width, height: panelSize.height)
    }

    /// Room around the card area for the card's own shadow (r3-a `.timg`: 0 12px 30px), which the card draws itself.
    static let shadowPadSide: CGFloat = 40
    static let shadowPadTop: CGFloat = 12

    /// The panel window. It reaches exactly to this screen's right edge, so the card slides inside a window that ends
    /// there: the slide is clipped at the edge of the capture's display and never shows on a display arranged to the
    /// right. Left and below it leaves room for the shadow, never past the screen.
    static func windowFrame(in visible: CGRect, screen: CGRect) -> CGRect {
        let area = panelFrame(in: visible)
        let minX = area.minX - shadowPadSide
        let maxX = max(screen.maxX, area.maxX)
        let minY = max(screen.minY, area.minY - shadowPadSide)
        let maxY = min(screen.maxY, area.maxY + shadowPadTop)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The card area (`panelSize`) inside the window, in the window's own coordinates (origin bottom-left).
    static func areaRect(in visible: CGRect, window: CGRect) -> CGRect {
        panelFrame(in: visible).offsetBy(dx: -window.minX, dy: -window.minY)
    }

    /// How far right the card is moved to be wholly outside the window, shadow included: the window's width.
    static func slideDistance(window: CGRect) -> CGFloat { window.width }

    /// The screen that held the pointer at capture time; the first screen (the menu bar's) when none does.
    static func screenIndex(containing point: CGPoint, frames: [CGRect]) -> Int? {
        if let i = frames.firstIndex(where: { $0.contains(point) }) { return i }
        // A point on a screen's top or right edge is outside `contains`; take the nearest screen.
        let distance: (CGRect) -> CGFloat = { r in
            let dx = max(r.minX - point.x, 0, point.x - r.maxX), dy = max(r.minY - point.y, 0, point.y - r.maxY)
            return dx * dx + dy * dy
        }
        return frames.indices.min { distance(frames[$0]) < distance(frames[$1]) }
    }
}
