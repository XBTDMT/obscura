// ObscuraThumbnailUI — the AppKit shell around the card: a non-activating floating panel that never becomes key, on
// the display and the Space in front when the capture was taken, with the card sliding in from the right edge; and the
// host view that turns the pointer into decisions: click, the hover capsule, a file drag (refused while checking), a
// two-finger swipe, and the right-click menu. Every rule lives in the pure types; this file only routes.
//
// How the slide works: the panel window stays still and reaches exactly to the display's right edge
// (`ThumbnailPlacement.windowFrame`); the card moves inside it as a Core Animation translation of the host layer's
// sublayers. The window's bounds clip it at the display edge (never on a display arranged to the right), the render
// server runs the motion off the main thread, and the card draws its own shadow, so the shadow moves with it.
import AppKit
import QuartzCore
import SwiftUI
import ObscuraUIKit

/// A panel that can never take focus from the app in front.
final class ThumbnailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ThumbnailWindow: ThumbnailSurface {
    let panel: ThumbnailPanel
    private let host: ThumbnailHostView
    private let store: ThumbnailStore
    private(set) var screenFrame: CGRect = .zero
    private var visibleFrame: CGRect = .zero
    /// The visible frame the card rests on; nil while hidden or leaving.
    private var restingOn: CGRect?
    /// The visible frame the window is laid out for; kept while the card leaves, so a new shot can turn it around.
    private var placedOn: CGRect?
    private var generation = 0
    /// Set by a swipe just before it dismisses: the finger's rightward speed, points per second.
    var flingSpeed: CGFloat?

    init(controller: ThumbnailController) {
        panel = ThumbnailPanel(contentRect: CGRect(origin: .zero, size: ThumbnailPlacement.panelSize),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // Not on every Space: it joins the Space in front when shown, which is the one the capture was taken on.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The card draws r3-a's shadow itself: a window shadow would stay behind while the card slides inside it.
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.worksWhenModal = true
        panel.title = String(localized: "Screenshot thumbnail")

        store = controller.store
        host = ThumbnailHostView(root: ThumbnailRoot(store: controller.store, actions: controller.actions))
        host.controller = controller
        panel.contentView = host
        host.surface = self
    }

    private var reduceMotion: Bool { OMotion.systemReduceMotion }

    var cardFrame: CGRect { ThumbnailPlacement.cardFrame(in: visibleFrame) }

    func show(at point: CGPoint) {
        let screens = NSScreen.screens
        guard let i = ThumbnailPlacement.screenIndex(containing: point, frames: screens.map(\.frame)) else { return }
        let screen = screens[i]
        let onActiveSpace = panel.isVisible && panel.isOnActiveSpace
        // Already resting there, on the Space in front: an update in place.
        if restingOn == screen.visibleFrame, onActiveSpace { return }
        generation += 1
        let gen = generation
        if placedOn != screen.visibleFrame || !onActiveSpace {
            // Hidden, on another display, or left behind on another Space: leave that place at once and start past
            // this display's edge on the Space in front (ordering out first makes `.moveToActiveSpace` bring it here).
            if panel.isVisible { panel.orderOut(nil) }
            place(on: screen)
            host.setSlide(ThumbnailPlacement.slideDistance(window: panel.frame))
            panel.alphaValue = reduceMotion ? 0 : 1
            panel.orderFrontRegardless()
        }
        // Otherwise the card is leaving on this display and Space: it turns around from where it is, without a jump.
        restingOn = screen.visibleFrame
        let landed: @MainActor () -> Void = { [weak self] in self?.landed(gen) }
        if reduceMotion {
            host.setSlide(0)
            fadePanel(to: 1, timing: .easeOut, completion: landed)
        } else {
            panel.alphaValue = 1
            host.slide(to: 0, duration: OMotion.slideDuration, timing: CAMediaTimingFunction(name: .easeOut), completion: landed)
        }
    }

    /// The card came to rest under a pointer that has not moved: hovering already, so the countdown pauses.
    private func landed(_ gen: Int) {
        guard gen == generation, restingOn != nil, cardFrame.contains(NSEvent.mouseLocation) else { return }
        host.controller?.pointerHover(true)
    }

    private func place(on screen: NSScreen) {
        screenFrame = screen.frame
        visibleFrame = screen.visibleFrame
        placedOn = screen.visibleFrame
        let window = ThumbnailPlacement.windowFrame(in: visibleFrame, screen: screenFrame)
        let area = ThumbnailPlacement.areaRect(in: visibleFrame, window: window)
        panel.setFrame(window, display: false)
        store.areaOrigin = CGPoint(x: area.minX, y: window.height - area.maxY)
        host.areaRect = area
    }

    func hide(animated: Bool, completion: @escaping @MainActor () -> Void) {
        let speed = flingSpeed
        flingSpeed = nil
        guard restingOn != nil else { completion(); return }
        restingOn = nil
        generation += 1
        let gen = generation
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, self.generation == gen else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.placedOn = nil
            completion()
        }
        guard animated, panel.isVisible else { finish(); return }
        if reduceMotion {
            fadePanel(to: 0, timing: .easeIn, completion: finish)
        } else {
            let distance = ThumbnailPlacement.slideDistance(window: panel.frame)
            if let speed {
                // A swipe: the card carries on at the finger's speed, linearly, from where the finger let go.
                let duration = SwipeExit.duration(remaining: distance - host.presentedSlide, speed: speed, slide: OMotion.slideDuration)
                host.slide(to: distance, duration: duration, timing: CAMediaTimingFunction(name: .linear), completion: finish)
            } else {
                host.slide(to: distance, duration: OMotion.slideDuration, timing: CAMediaTimingFunction(name: .easeIn), completion: finish)
            }
        }
    }

    /// Hidden at once while a drag is in flight (the drag image is the card then); back with the one fade.
    func setDragHidden(_ hidden: Bool) {
        if hidden || reduceMotion { panel.alphaValue = hidden ? 0 : 1; return }
        fadePanel(to: 1, timing: .easeOut, completion: {})
    }

    /// Follows a two-finger swipe.
    func setSwipeOffset(_ dx: CGFloat) {
        guard restingOn != nil else { return }
        host.setSlide(dx)
    }

    /// A swipe that did not go far enough goes back with the thumbnail's slide (at once under Reduce Motion).
    func settle() {
        guard restingOn != nil else { return }
        if reduceMotion { host.setSlide(0); return }
        host.slide(to: 0, duration: OMotion.slideDuration, timing: CAMediaTimingFunction(name: .easeOut), completion: {})
    }

    private func fadePanel(to alpha: CGFloat, timing: CAMediaTimingFunctionName, completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = OMotion.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: timing)
            panel.animator().alphaValue = alpha
        }, completionHandler: { Task { @MainActor in completion() } })
    }
}

/// The panel's content: the SwiftUI card in a hosting view, with the pointer handled here in AppKit. SwiftUI gestures
/// do not reliably see the first click of a window that never becomes key, and a drag that must be refused while
/// checking needs its own `NSDraggingSource` (NSHostingView's own conformance cannot be overridden).
final class ThumbnailHostView: NSView, NSDraggingSource {
    weak var controller: ThumbnailController?
    weak var surface: ThumbnailWindow?
    /// The card area (`ThumbnailPlacement.panelSize`) in this view, origin bottom-left. Set when the panel is placed.
    var areaRect = CGRect(origin: .zero, size: ThumbnailPlacement.panelSize) {
        didSet { updateTrackingAreas() }
    }
    private var downPoint: CGPoint?
    private var dragStarted = false
    private var swipe = SwipeTracker()
    private var swiping = false
    private var trackingArea: NSTrackingArea?
    private var menuTargets: [AnyObject] = []
    /// The slide's model value (points right of rest).
    private var slideX: CGFloat = 0

    private let hosting: NSHostingView<ThumbnailRoot>
    private static let slideKey = "obscura.slide"

    init(root: ThumbnailRoot) {
        hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        super.init(frame: CGRect(origin: .zero, size: ThumbnailPlacement.panelSize))
        wantsLayer = true
        layer?.masksToBounds = true
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Slide

    /// Where the card is drawn right now, mid-animation included.
    var presentedSlide: CGFloat {
        layer?.presentation()?.sublayerTransform.m41 ?? slideX
    }

    /// Moves the card at once.
    func setSlide(_ x: CGFloat) {
        slideX = x
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.slideKey)
        layer.sublayerTransform = CATransform3DMakeTranslation(x, 0, 0)
        CATransaction.commit()
    }

    /// Moves the card from where it is drawn now to `x`. A slide already running is replaced (its completion runs, and
    /// the window's generation guard ignores it).
    func slide(to x: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunction, completion: @escaping @MainActor () -> Void) {
        guard let layer, duration > 0 else { setSlide(x); completion(); return }
        let from = presentedSlide
        slideX = x
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { Task { @MainActor in completion() } }
        layer.removeAnimation(forKey: Self.slideKey)
        let animation = CABasicAnimation(keyPath: "sublayerTransform.translation.x")
        animation.fromValue = from
        animation.toValue = x
        animation.duration = duration
        animation.timingFunction = timing
        layer.sublayerTransform = CATransform3DMakeTranslation(x, 0, 0)
        layer.add(animation, forKey: Self.slideKey)
        CATransaction.commit()
    }

    // MARK: Hit testing

    /// The card itself (and the burst edges above it), in this view's coordinates. The transparent rest of the panel
    /// takes no hover and no clicks.
    private var cardRect: CGRect {
        typealias P = ThumbnailPlacement
        let edges: CGFloat = (controller?.store.content?.edges ?? 0) > 0 ? P.marginTop - 3 : 0
        return CGRect(x: areaRect.minX + P.marginSide, y: areaRect.minY + P.marginSide,
                      width: P.cardSize.width, height: P.cardSize.height + edges)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return cardRect.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: cardRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { controller?.pointerHover(true) }
    override func mouseExited(with event: NSEvent) { controller?.pointerHover(false) }

    // MARK: Click and drag

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { showMenu(for: event); return }
        downPoint = convert(event.locationInWindow, from: nil)
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !dragStarted else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        dragStarted = true
        // Refused while checking (and when the file is gone): nothing unscanned leaves.
        guard let controller, let file = controller.dragFile() else { return }
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        item.setDraggingFrame(areaRect, contents: dragImage())
        let session = beginDraggingSession(with: [item], event: event, source: self)
        // A failed drop slides the drag image back to the corner (macOS's own motion), then the card fades in.
        session.animatesToStartingPositionsOnCancelOrFail = !OMotion.systemReduceMotion
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil }
        guard downPoint != nil, !dragStarted else { return }
        let point = areaPoint(convert(event.locationInWindow, from: nil))
        if let frame = controller?.store.hoverActionFrame, frame.contains(point) { controller?.hoverActionClicked() }
        else { controller?.cardClicked() }
    }

    override func rightMouseDown(with event: NSEvent) { showMenu(for: event) }

    /// A point in this view as the card's SwiftUI coordinate space sees it (card area, top-left origin).
    private func areaPoint(_ point: CGPoint) -> CGPoint {
        let flippedY = isFlipped ? areaRect.minY + (bounds.height - point.y) : point.y
        return CGPoint(x: point.x - areaRect.minX, y: areaRect.maxY - flippedY)
    }

    private func dragImage() -> NSImage? {
        guard let content = controller?.store.content else { return nil }
        let view = ThumbnailView(content: ThumbnailContent(displayName: content.displayName, image: content.image, capsule: content.capsule,
                                                           hoverAction: nil, hovering: false, edges: 0))
            .environment(\.colorScheme, effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = window?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy only: a drop into Finder copies the clean file, it never moves the screenshot out of its folder.
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        controller?.dragBegan()
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        // Over the fling zone a let-go dismisses the card, so the drag image must not slide back to the corner first.
        guard let controller else { return }
        session.animatesToStartingPositionsOnCancelOrFail = !OMotion.systemReduceMotion && !controller.isFlingPoint(screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        controller?.dragEnded(at: screenPoint, dropped: !operation.isEmpty)
    }

    // MARK: Swipe

    override func scrollWheel(with event: NSEvent) {
        // A mouse wheel is not a swipe; momentum after the decision is ignored.
        guard event.hasPreciseScrollingDeltas, event.momentumPhase == [] else { return }
        if event.phase == .began {
            swipe.reset()
            swiping = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
        }
        guard swiping else { return }
        switch event.phase {
        case .began, .changed:
            let rightward = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            swipe.changed(by: rightward, at: event.timestamp)
            surface?.setSwipeOffset(swipe.offset)
        case .ended, .cancelled:
            swiping = false
            if swipe.shouldDismiss {
                surface?.flingSpeed = swipe.speed
                controller?.dismiss()
            } else {
                surface?.settle()
            }
            swipe.reset()
        default:
            break
        }
    }

    // MARK: Menu

    /// Opens the card's menu at the pointer. A pop-up menu, not `NSMenu.popUpContextMenu`: a context menu gets the
    /// system's own items (macOS 27 puts a highlighted "Ask Siri" first, under the pointer) and opened ~120 ms late
    /// while they were prepared (measured 2026-10-28 on the installed app).
    private func showMenu(for event: NSEvent) {
        guard let controller else { return }
        let items = controller.menuItems()
        guard !items.isEmpty else { return }
        let phase = controller.stack.front?.phase ?? .checking
        let built = ThumbnailMenuBuilder.menu(items, phase: phase) { [weak controller] item in controller?.perform(menu: item) }
        menuTargets = built.targets
        controller.menuOpen(true)
        built.menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
        controller.menuOpen(false)
    }
}

/// The card's menu: Obscura's items only, no system additions.
enum ThumbnailMenuBuilder {
    @MainActor static func menu(_ items: [ThumbnailMenuItem], phase: CardPhase,
                                perform: @escaping @MainActor (ThumbnailMenuItem) -> Void) -> (menu: NSMenu, targets: [AnyObject]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = false }
        var targets: [AnyObject] = []
        for item in items {
            guard item != .separator else { menu.addItem(.separator()); continue }
            let look = ThumbnailMenuLook(item, phase: phase)
            let target = MenuTarget { perform(item) }
            targets.append(target)
            let menuItem = NSMenuItem(title: look.title, action: #selector(MenuTarget.fire), keyEquivalent: "")
            menuItem.target = target
            menuItem.subtitle = look.subtitle
            menuItem.image = NSImage(systemSymbolName: look.symbol, accessibilityDescription: nil)
            if look.destructive {
                menuItem.attributedTitle = NSAttributedString(string: look.title, attributes: [.foregroundColor: NSColor.systemRed])
            }
            menu.addItem(menuItem)
        }
        return (menu, targets)
    }
}

/// How each menu item reads.
struct ThumbnailMenuLook: Hashable {
    var title: String
    var subtitle: String?
    var symbol: String
    var destructive = false

    init(_ item: ThumbnailMenuItem, phase: CardPhase) {
        switch item {
        case .copy:
            self.init(title: ThumbnailCopy.copy,
                      subtitle: phase.isOriginal ? ThumbnailCopy.copyOriginalSubtitle : ThumbnailCopy.copyCleanSubtitle, symbol: "doc.on.doc")
        case .openInViewer: self.init(title: ThumbnailCopy.openInViewer, symbol: "arrow.up.forward.app")
        case .openInPreview: self.init(title: ThumbnailCopy.openInPreview, symbol: "arrow.up.forward.app")
        case .showInFinder: self.init(title: ThumbnailCopy.showInFinder, symbol: "folder")
        case .openInJournal: self.init(title: ThumbnailCopy.openInJournal, symbol: "list.bullet.rectangle")
        case .undo: self.init(title: ThumbnailCopy.undoMenu, subtitle: ThumbnailCopy.undoSubtitle, symbol: "arrow.uturn.backward")
        case .blackOutAgain: self.init(title: ThumbnailCopy.blackOutAgain, subtitle: ThumbnailCopy.blackOutSubtitle, symbol: "eye.slash")
        case .delete: self.init(title: ThumbnailCopy.delete, symbol: "trash", destructive: true)
        case .close: self.init(title: ThumbnailCopy.close, symbol: "xmark")
        case .separator: self.init(title: "", symbol: "")
        }
    }

    init(title: String, subtitle: String? = nil, symbol: String, destructive: Bool = false) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.destructive = destructive
    }
}

@MainActor
private final class MenuTarget: NSObject {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func fire() { action() }
}
