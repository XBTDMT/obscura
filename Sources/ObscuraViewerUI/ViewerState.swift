// The viewer's own view state: which image shows, peek, compare, zoom, the inspector and the loaded images.
// Everything about the screenshot itself (findings, verdict) comes from AppModel; this holds only what the window shows.
import SwiftUI
import Observation
import ObscuraUIKit
import ObscuraJournal

/// Which image the Redacted / Original control has selected.
enum ViewerMode: Sendable, Hashable { case redacted, original }

@MainActor
@Observable
final class ViewerState {
    // MARK: What shows

    private(set) var mode: ViewerMode = .redacted
    /// True while the mouse is held on the image (hold-to-peek).
    private(set) var isPeeking = false
    /// True while Space compare is open (side by side or the wipe, `Settings.compareStyle`).
    private(set) var isComparing = false
    /// The wipe compare's divider, as a fraction of the picture's width showing the covered image (G-19 #15).
    private(set) var wipePosition = WipeGeometry.start
    /// nil until the first entry loads, then the user's choice. The first value comes from `autoOpensInspector`.
    var inspectorChoice: Bool?
    private(set) var zoom: ZoomMode = .fit

    /// The magnification the scroll view last reported (fit resolves to a number here). Not observed: it changes on
    /// every pinch frame and only the next ⌘+ / ⌘− reads it.
    @ObservationIgnored var lastMagnification: CGFloat = 1

    // MARK: Images

    private(set) var cleanImage: NSImage?
    private(set) var originalImage: NSImage?
    /// The original's file, for Live Text (VisionKit analyses from the file).
    private(set) var originalURL: URL?
    /// The stored image's pixel size (finding rects are in these pixels).
    private(set) var pixelSize: CGSize = .zero
    private(set) var loadedRevision: Int?
    /// False when the original is gone (expired, or the file is missing); Original, peek and compare are then off.
    private(set) var originalAvailable = false
    private(set) var loadFailed = false

    init(mode: ViewerMode = .redacted) { self.mode = mode }

    // MARK: Derived

    /// The image the canvas draws: the original in Original mode and while peeking, else the clean file.
    var showsOriginalImage: Bool { mode == .original || isPeeking }

    var showsInspector: Bool { inspectorChoice ?? false }

    /// The window's width for the current layout (system.html: 720, 880 with the inspector).
    var windowWidth: CGFloat { showsInspector ? OMetric.viewerWidthWithInspector : OMetric.viewerWidth }

    var zoomLabel: String { ZoomMath.label(for: zoom) }

    /// The inspector opens by itself when there is something to decide: a finding left visible.
    static func autoOpensInspector(for verdict: Verdict) -> Bool {
        if case .safeToShare = verdict { return false }
        return true
    }

    // MARK: Mode, peek, compare

    /// Tab, and a click on the other segment.
    func toggleMode() { setMode(mode == .redacted ? .original : .redacted) }

    func setMode(_ new: ViewerMode) {
        if new == .original && !originalAvailable { return }
        isPeeking = false
        mode = new
    }

    /// Press-and-hold on the redacted image. Peek is a second image, never an un-redaction of the clean file.
    func beginPeek() {
        guard mode == .redacted, originalAvailable, !isComparing else { return }
        isPeeking = true
    }

    func endPeek() { isPeeking = false }

    /// Space.
    func toggleCompare() {
        if isComparing { isComparing = false; return }
        guard originalAvailable else { return }
        isPeeking = false
        wipePosition = WipeGeometry.start
        isComparing = true
    }

    /// The wipe's divider moved (a drag, or VoiceOver's adjust); always within the picture.
    func setWipePosition(_ position: Double) { wipePosition = WipeGeometry.clamp(position) }

    /// Esc: closes compare first; returns false when there was nothing to close (the window closes instead).
    func handleEscape() -> Bool {
        if isComparing { isComparing = false; return true }
        if isPeeking { isPeeking = false; return true }
        return false
    }

    // MARK: Zoom

    var canZoom: Bool { !isComparing && cleanImage != nil }

    func zoomIn() { setScale(ZoomMath.stepIn(from: lastMagnification)) }
    func zoomOut() { setScale(ZoomMath.stepOut(from: lastMagnification)) }
    func actualSize() { setScale(1) }

    private func setScale(_ m: CGFloat) {
        lastMagnification = m
        zoom = .scale(m)
    }
    func zoomToFit() { zoom = .fit }

    /// Pinch and ⌘-scroll report here.
    func magnificationChangedByUser(_ m: CGFloat) {
        lastMagnification = m
        zoom = .scale(ZoomMath.clamp(m))
    }

    // MARK: Inspector

    func toggleInspector() { inspectorChoice = !showsInspector }

    // MARK: Copy

    /// What ⌘C and Copy put on the clipboard: the Live Text selection when there is one, else the image as shown.
    enum CopyTarget: Equatable { case text(String), clean, original }

    func copyTarget(liveTextSelection: String?) -> CopyTarget {
        if mode == .original, !isComparing, let s = liveTextSelection, !s.isEmpty { return .text(s) }
        return showsOriginalImage && !isComparing ? .original : .clean
    }

    // MARK: Loading

    /// Loads the clean and original images for `entry` (once per revision).
    func load(_ entry: Entry, from journal: any JournalStore) async {
        guard loadedRevision != entry.revision else { return }
        let revision: Int
        do {
            // Bytes and the revision they belong to from one Journal read (G-28).
            let current = try await journal.cleanImage(entry.id)
            revision = current.entry.revision
            guard let image = NSImage(data: current.data) else { loadFailed = true; return }
            cleanImage = image
            pixelSize = Self.pixelSize(of: image) ?? CGSize(width: entry.pixelWidth, height: entry.pixelHeight)
            loadFailed = false
        } catch {
            loadFailed = true
            return
        }
        if originalImage == nil {
            if let url = try? await journal.originalURL(entry.id), let data = try? await journal.originalData(entry.id),
               let image = NSImage(data: data) {
                originalImage = image
                originalURL = url
                originalAvailable = true
            } else {
                originalAvailable = false
                if mode == .original { mode = .redacted }
                isPeeking = false
                isComparing = false
            }
        }
        loadedRevision = revision
    }

    /// For previews and tests: installs images directly.
    func install(clean: NSImage?, original: NSImage?, revision: Int) {
        cleanImage = clean
        originalImage = original
        originalAvailable = original != nil
        pixelSize = clean.flatMap(Self.pixelSize(of:)) ?? .zero
        loadedRevision = revision
    }

    static func pixelSize(of image: NSImage) -> CGSize? {
        if let rep = image.representations.first(where: { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }) {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return nil
    }
}
