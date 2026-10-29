// The zooming image canvas (ARCHITECTURE §8): an NSScrollView with magnification (pinch, ⌘-scroll, ⌘+ ⌘− ⌘0 ⌘9),
// drag to pan, press-and-hold to peek, the numbered finding badges that toggle a finding on click, and the VisionKit
// Live Text overlay over the original. AppKit because SwiftUI has no magnifying scroll view or VisionKit overlay; the
// badges live in the document view so they follow every zoom and scroll frame exactly.
import SwiftUI
import AppKit
import ObscuraUIKit
import ObscuraJournal

struct ImageCanvas: NSViewRepresentable {
    let state: ViewerState
    let image: NSImage
    /// Pixel size of the stored image; finding rects are in these pixels, top-left origin.
    let pixelSize: CGSize
    let findings: [Finding]
    let names: [UUID: String]
    /// Badges and bar hit areas show on the redacted image only.
    let showsMarks: Bool
    let liveText: LiveTextController
    /// Live Text is active over the original only, and not while peeking.
    let liveTextActive: Bool
    let onToggle: @MainActor (Finding) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> ZoomingScrollView {
        let scroll = ZoomingScrollView()
        scroll.contentView = CenteringClipView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = ZoomMath.minimum
        scroll.maxMagnification = ZoomMath.maximum
        scroll.usesPredominantAxisScrolling = false
        let doc = CanvasDocumentView()
        scroll.documentView = doc
        doc.mouse = context.coordinator
        doc.marksView.mouse = context.coordinator
        doc.imageView.mouse = context.coordinator
        doc.marksView.magnification = { [weak scroll] in scroll?.magnification ?? 1 }
        liveText.attach(to: doc.imageView)

        let c = context.coordinator
        c.scrollView = scroll
        c.document = doc
        scroll.onCommandScroll = { [weak c] event in c?.commandScroll(event) }
        scroll.onViewportChange = { [weak c] in c?.viewportChanged() }
        scroll.contentView.postsBoundsChangedNotifications = true
        c.observe()
        return scroll
    }

    func updateNSView(_ scroll: ZoomingScrollView, context: Context) {
        let c = context.coordinator
        c.state = state
        c.onToggle = onToggle
        guard let doc = scroll.documentView as? CanvasDocumentView else { return }
        var imageChanged = false
        if doc.imageView.image !== image {
            doc.setImage(image)
            imageChanged = true
        }
        doc.marksView.update(findings: findings, names: names, pixelSize: pixelSize, documentSize: doc.frame.size)
        doc.marksView.isHidden = !showsMarks
        liveText.setActive(liveTextActive)
        doc.imageView.setAccessibilityLabel(state.showsOriginalImage ? String(localized: "Original image") : String(localized: "Redacted image"))
        if imageChanged || c.appliedZoom != state.zoom { c.apply(state.zoom) }
    }

    static func dismantleNSView(_ nsView: ZoomingScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, CanvasMouseHandling {
        var state: ViewerState
        var onToggle: (@MainActor (Finding) -> Void)?
        weak var scrollView: ZoomingScrollView?
        weak var document: CanvasDocumentView?
        private(set) var appliedZoom: ZoomMode?
        private var observers: [any NSObjectProtocol] = []

        // Press state: a click toggles a finding, a drag pans, a hold peeks.
        private var pressStart: NSPoint?
        private var pressedFinding: Finding?
        private var dragging = false
        /// The shared hold-to-peek rule (ObscuraUIKit), the same one the Journal preview uses.
        private lazy var hold = HoldToPeek(onBegin: { [weak self] in
            guard let self, !self.dragging else { return }
            self.state.beginPeek()
        })
        static let dragThreshold: CGFloat = 3

        init(state: ViewerState) { self.state = state }

        func observe() {
            guard let scroll = scrollView else { return }
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.userMagnified() }
            })
            observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.document?.marksView.needsDisplay = true }
            })
        }

        func stopObserving() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            hold.cancel()
        }

        // MARK: Zoom

        func apply(_ zoom: ZoomMode) {
            guard let scroll = scrollView, let doc = document, doc.frame.width > 0 else { return }
            let target: CGFloat
            switch zoom {
            case .fit: target = ZoomMath.fit(content: doc.frame.size, viewport: scroll.frame.size)
            case .scale(let m): target = ZoomMath.clamp(m)
            }
            if abs(scroll.magnification - target) > 0.0001 {
                // Keep what is in the middle of the window in the middle (the image centre when it fits).
                let visible = scroll.contentView.bounds
                let bounds = doc.bounds
                let focus = NSPoint(x: min(max(visible.midX, bounds.minX), bounds.maxX), y: min(max(visible.midY, bounds.minY), bounds.maxY))
                scroll.magnification = target
                center(scroll, on: focus)
            }
            appliedZoom = zoom
            state.lastMagnification = target
            doc.marksView.needsDisplay = true
        }

        private func center(_ scroll: NSScrollView, on point: NSPoint) {
            let clip = scroll.contentView
            let size = clip.bounds.size
            let proposed = NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
            clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
            scroll.reflectScrolledClipView(clip)
        }

        func viewportChanged() {
            if appliedZoom == .fit { apply(.fit) }
        }

        private func userMagnified() {
            guard let scroll = scrollView else { return }
            let m = scroll.magnification
            appliedZoom = .scale(ZoomMath.clamp(m))
            state.magnificationChangedByUser(m)
            document?.marksView.needsDisplay = true
        }

        func commandScroll(_ event: NSEvent) {
            guard let scroll = scrollView, let doc = document else { return }
            let m = ZoomMath.scrolled(from: scroll.magnification, deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
            let point = doc.convert(event.locationInWindow, from: nil)
            scroll.setMagnification(m, centeredAt: point)
            userMagnified()
        }

        // MARK: Mouse

        func canvasMouseDown(_ event: NSEvent, finding: Finding?) {
            pressStart = event.locationInWindow
            pressedFinding = finding
            dragging = false
            hold.pressBegan()
        }

        func canvasMouseDragged(_ event: NSEvent) {
            guard let start = pressStart else { return }
            if !dragging, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > Self.dragThreshold {
                dragging = true
                hold.cancel()
                NSCursor.closedHand.push()
            }
            guard dragging, !state.isPeeking, let scroll = scrollView else { return }
            let clip = scroll.contentView
            let m = max(scroll.magnification, 0.0001)
            var origin = clip.bounds.origin
            origin.x -= event.deltaX / m
            origin.y -= (clip.isFlipped ? event.deltaY : -event.deltaY) / m
            let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
            clip.scroll(to: constrained.origin)
            scroll.reflectScrolledClipView(clip)
        }

        func canvasMouseUp(_ event: NSEvent) {
            hold.pressEnded()
            if state.isPeeking {
                state.endPeek()
            } else if !dragging, let finding = pressedFinding {
                onToggle?(finding)
            }
            if dragging { NSCursor.pop() }
            dragging = false
            pressStart = nil
            pressedFinding = nil
        }

        func toggleFromAccessibility(_ finding: Finding) { onToggle?(finding) }
    }
}

// MARK: - AppKit pieces

@MainActor
protocol CanvasMouseHandling: AnyObject {
    func canvasMouseDown(_ event: NSEvent, finding: Finding?)
    func canvasMouseDragged(_ event: NSEvent)
    func canvasMouseUp(_ event: NSEvent)
    func toggleFromAccessibility(_ finding: Finding)
}

/// The scroll view: ⌘-scroll zooms around the cursor; a resize refits when the canvas is in Fit.
final class ZoomingScrollView: NSScrollView {
    var onCommandScroll: ((NSEvent) -> Void)?
    var onViewportChange: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let onCommandScroll {
            onCommandScroll(event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onViewportChange?() }
    }
}

/// Keeps the image centred when it is smaller than the viewport.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        let frame = doc.frame
        if rect.width > frame.width { rect.origin.x = (frame.width - rect.width) / 2 }
        if rect.height > frame.height { rect.origin.y = (frame.height - rect.height) / 2 }
        return rect
    }
}

/// The document: the image at its point size, the badge layer above it.
final class CanvasDocumentView: NSView {
    let imageView = PanningImageView()
    let marksView = FindingMarksView()
    weak var mouse: (any CanvasMouseHandling)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageFrameStyle = .none
        imageView.isEditable = false
        imageView.animates = false
        imageView.wantsLayer = true
        imageView.autoresizingMask = [.width, .height]
        marksView.autoresizingMask = [.width, .height]
        addSubview(imageView)
        addSubview(marksView)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    func setImage(_ image: NSImage) {
        let size = image.size.width > 0 && image.size.height > 0 ? image.size : NSSize(width: 1, height: 1)
        setFrameSize(size)
        imageView.frame = bounds
        marksView.frame = bounds
        imageView.image = image
    }
}

/// The image view: forwards presses to the coordinator (pan, peek) and hosts the Live Text overlay.
final class PanningImageView: NSImageView {
    weak var mouse: (any CanvasMouseHandling)?
    override func mouseDown(with event: NSEvent) { mouse?.canvasMouseDown(event, finding: nil) }
    override func mouseDragged(with event: NSEvent) { mouse?.canvasMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { mouse?.canvasMouseUp(event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

/// The numbered badges, the left-visible outlines and the hover ring, drawn in document coordinates and sized by
/// 1 / magnification so they stay 18 pt on screen at every zoom. Hit-testable only on a finding.
final class FindingMarksView: NSView {
    weak var mouse: (any CanvasMouseHandling)?
    var magnification: () -> CGFloat = { 1 }
    private(set) var findings: [Finding] = []
    private var names: [UUID: String] = [:]
    private var scale: CGFloat = 1
    private var documentSize: CGSize = .zero
    private var hovered: UUID?
    private var trackingArea: NSTrackingArea?
    /// The badge frames for the last magnification they were laid out at.
    private var badgeCache: (m: CGFloat, frames: [CGRect])?

    /// On-screen distances from a finding's ink box to the marks drawn around it. A finding's box hugs its glyphs, so a
    /// line drawn on the box itself lies on the letters; every mark sits outside it: the left-visible outline, its dashed
    /// ring, and the hover ring.
    nonisolated static let outlineGap: CGFloat = 3, ringGap: CGFloat = 5.5, hoverGap: CGFloat = 7.5

    /// The badge's on-screen diameter (system.html `.num`), and the on-screen space it keeps from a bar's ends and from
    /// every other bar and badge (clears the hover ring, the outermost mark, and its stroke).
    nonisolated static let badgeDiameter: CGFloat = 18, badgeInset: CGFloat = 3, badgeGap: CGFloat = 9

    override var isFlipped: Bool { true }

    func update(findings: [Finding], names: [UUID: String], pixelSize: CGSize, documentSize: CGSize) {
        let newScale = pixelSize.width > 0 ? documentSize.width / pixelSize.width : 1
        guard findings != self.findings || names != self.names || newScale != scale || documentSize != self.documentSize else { return }
        self.findings = findings
        self.names = names
        scale = newScale
        self.documentSize = documentSize
        badgeCache = nil
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// A finding's rect in document points.
    func documentRect(_ f: Finding) -> CGRect {
        CGRect(x: f.rect.minX * scale, y: f.rect.minY * scale, width: f.rect.width * scale, height: f.rect.height * scale)
    }

    /// Every finding's badge frame in document points at magnification `m`, laid out by `BadgeLayout` so no badge
    /// covers another bar, another badge or the text beside its own bar.
    func badgeFrames(m: CGFloat) -> [CGRect] {
        if let badgeCache, badgeCache.m == m, badgeCache.frames.count == findings.count { return badgeCache.frames }
        let d = Self.badgeDiameter / m
        let items = findings.map { BadgeLayout.Item(rect: documentRect($0), badgeSize: CGSize(width: d, height: d), covered: $0.enabled) }
        let size = documentSize.width > 0 ? documentSize : bounds.size
        let frames = BadgeLayout.place(imageSize: size, items: items, gap: Self.badgeGap / m, inset: Self.badgeInset / m).map(\.frame)
        badgeCache = (m, frames)
        return frames
    }

    func finding(at point: CGPoint) -> Finding? {
        let m = max(magnification(), 0.0001)
        let badges = badgeFrames(m: m)
        // Badges first: one may sit on its own bar, and the topmost wins.
        for (i, f) in findings.enumerated().reversed() {
            let b = badges[i]
            if hypot(point.x - b.midX, point.y - b.midY) <= b.width / 2 + 1 / m { return f }
        }
        for f in findings.reversed() where documentRect(f).insetBy(dx: -Self.hoverGap / m, dy: -Self.hoverGap / m).contains(point) { return f }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let local = convert(point, from: superview)
        return finding(at: local) == nil ? nil : self
    }

    override func draw(_ dirtyRect: NSRect) {
        let m = max(magnification(), 0.0001)
        let accent = NSColor(OColor.accent), needs = NSColor(OColor.needs)
        let badges = badgeFrames(m: m)
        for (i, f) in findings.enumerated() {
            let r = documentRect(f)
            if !f.enabled {
                // Left visible: an orange outline and a dashed ring around the text that shows, clear of its letters.
                let inner = NSBezierPath(roundedRect: r.insetBy(dx: -Self.outlineGap / m, dy: -Self.outlineGap / m), xRadius: 3 / m, yRadius: 3 / m)
                inner.lineWidth = 1.5 / m
                needs.setStroke(); inner.stroke()
                let outer = NSBezierPath(roundedRect: r.insetBy(dx: -Self.ringGap / m, dy: -Self.ringGap / m), xRadius: 4 / m, yRadius: 4 / m)
                outer.lineWidth = 1.5 / m
                outer.setLineDash([4 / m, 3 / m], count: 2, phase: 0)
                outer.stroke()
            }
            if f.isSpotCover && f.enabled {
                // G-40: a spot no reading could read keeps its outline (the dashed ring) whether it is covered or not, so the
                // picture is never shown as if it were fully read.
                let spot = NSBezierPath(roundedRect: r.insetBy(dx: -Self.ringGap / m, dy: -Self.ringGap / m), xRadius: 4 / m, yRadius: 4 / m)
                spot.lineWidth = 1.5 / m
                spot.setLineDash([4 / m, 3 / m], count: 2, phase: 0)
                needs.setStroke(); spot.stroke()
            }
            if hovered == f.id {
                let ring = NSBezierPath(roundedRect: r.insetBy(dx: -Self.hoverGap / m, dy: -Self.hoverGap / m), xRadius: 5 / m, yRadius: 5 / m)
                ring.lineWidth = 2 / m
                accent.setStroke(); ring.stroke()
            }
            let circle = badges[i]
            let c = CGPoint(x: circle.midX, y: circle.midY)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            shadow.shadowBlurRadius = 3 / m
            shadow.shadowOffset = NSSize(width: 0, height: -1 / m)
            shadow.set()
            (f.enabled ? accent : needs).setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSGraphicsContext.restoreGraphicsState()
            let text = NSAttributedString(string: "\(i + 1)", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5 / m, weight: .bold),
                .foregroundColor: NSColor.white,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: c.x - size.width / 2, y: c.y - size.height / 2))
        }
    }

    // MARK: Hover, tooltip, cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isHidden else { return }
        let f = finding(at: convert(event.locationInWindow, from: nil))
        guard f?.id != hovered else { return }
        hovered = f?.id
        if let f, let i = findings.firstIndex(of: f) {
            toolTip = ViewerCopy.findingTip(number: i + 1, name: names[f.id] ?? "", enabled: f.enabled)
            NSCursor.pointingHand.set()
        } else {
            toolTip = nil
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        toolTip = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        mouse?.canvasMouseDown(event, finding: finding(at: convert(event.locationInWindow, from: nil)))
    }
    override func mouseDragged(with event: NSEvent) { mouse?.canvasMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { mouse?.canvasMouseUp(event) }

    // MARK: Accessibility: each finding is a button

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityChildren() -> [Any]? {
        guard !isHidden else { return [] }
        return findings.enumerated().map { i, f in
            let element = FindingAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(ViewerCopy.findingAccessibility(number: i + 1, name: names[f.id] ?? "", enabled: f.enabled))
            element.setAccessibilityParent(self)
            element.setAccessibilityFrame(NSAccessibility.screenRect(fromView: self, rect: documentRect(f)))
            element.press = { [weak self] in self?.mouse?.toggleFromAccessibility(f) }
            return element
        }
    }
}

final class FindingAccessibilityElement: NSAccessibilityElement {
    var press: (@MainActor @Sendable () -> Void)?
    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        MainActor.assumeIsolated { press() }
        return true
    }
}
