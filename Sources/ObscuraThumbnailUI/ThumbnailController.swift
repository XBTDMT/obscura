// ObscuraThumbnailUI — Obscura's own floating screenshot thumbnail (B-9, ruling G-8, design r3-a). The controller feeds
// the engine's ordered scan events (starts, then reports; G-9) into `ThumbnailStack`, loads what each card shows, runs the countdown, and turns
// the card's gestures into model and router calls. The panel itself is `ThumbnailWindow`; side effects on the Mac go
// through `ThumbnailSystem`, so tests drive everything here without a window or a real file system action.
public import ObscuraEngine
public import ObscuraUIKit
import AppKit
import Observation
import SwiftUI
import ObscuraJournal
import ObscuraPrefs
import ObscuraSupport

/// The observable state the hosted view reads.
@MainActor
@Observable
final class ThumbnailStore {
    /// What the card draws. It stays while the card slides (or fades) out and is cleared only once it is gone.
    var content: ThumbnailContent?
    var colorScheme: ColorScheme?
    /// Where the card area (`ThumbnailPlacement.panelSize`) sits in the panel window, top-left origin.
    var areaOrigin: CGPoint = .zero
    /// Set by the view while the hover capsule shows (panel coordinates, top-left origin).
    var hoverActionFrame: CGRect?
}

/// The panel, as the controller sees it.
@MainActor
protocol ThumbnailSurface: AnyObject {
    /// Shows the panel on the screen holding `point` and the active Space; slides it in when it was not resting there.
    func show(at point: CGPoint)
    /// Slides the panel away (or hides it at once). `completion` runs once it is gone, and not at all when a `show`
    /// brought it back first.
    func hide(animated: Bool, completion: @escaping @MainActor () -> Void)
    /// The corner is empty while a drag is in flight; it fades back if the drop did not take the file.
    func setDragHidden(_ hidden: Bool)
    /// The card's frame on screen, for the fling rule.
    var cardFrame: CGRect { get }
    /// The frame of the display the card is on.
    var screenFrame: CGRect { get }
}

/// What the thumbnail does to the Mac outside Obscura.
@MainActor
protocol ThumbnailSystem: AnyObject {
    func mouseLocation() -> CGPoint
    /// At least one display is attached, so the card can be seen.
    var hasDisplay: Bool { get }
    func fileExists(_ url: URL) -> Bool
    /// Opens the file in Preview (the one action that takes focus, on purpose).
    func openInPreview(_ url: URL)
    func showInFinder(_ url: URL)
    /// Puts a clean file that has no Journal entry on the clipboard.
    func copyFile(_ url: URL)
    func moveToTrash(_ urls: [URL])
    func loadImage(_ url: URL) async -> NSImage?
    /// Decodes image bytes at card size, off the main thread.
    func decodeImage(_ data: Data) async -> NSImage?
}

@MainActor
public final class ThumbnailController {
    private let model: AppModel
    private let system: any ThumbnailSystem
    private let clock: @MainActor () -> TimeInterval
    private let schedulesTimers: Bool
    private let makeSurface: @MainActor (ThumbnailController) -> any ThumbnailSurface
    private var surfaceStorage: (any ThumbnailSurface)?

    let store = ThumbnailStore()
    private(set) var stack = ThumbnailStack()
    /// Journal entries of covered cards (where the clean file is), by capture key.
    private var entries: [CaptureKey: Entry] = [:]
    private var images: [CaptureKey: NSImage] = [:]
    private var tail: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    /// Bumped on every hide; a hide's completion clears the card only if it is still the latest.
    private var hideGeneration = 0

    /// The app's thumbnail: a real panel, the real Mac, the system uptime clock.
    public convenience init(model: AppModel) {
        self.init(model: model, system: LiveThumbnailSystem(), clock: { ProcessInfo.processInfo.systemUptime },
                  schedulesTimers: true, makeSurface: { ThumbnailWindow(controller: $0) })
    }

    init(model: AppModel, system: any ThumbnailSystem, clock: @escaping @MainActor () -> TimeInterval, schedulesTimers: Bool,
         makeSurface: @escaping @MainActor (ThumbnailController) -> any ThumbnailSurface) {
        self.model = model
        self.system = system
        self.clock = clock
        self.schedulesTimers = schedulesTimers
        self.makeSurface = makeSurface
        observeEntries()
    }

    /// Keeps a covered card in step with the Journal: Undo or Black Out Again done in the panel, the Journal or the
    /// viewer while the card is up changes what it says and shows ("red in three places", r3-a).
    private func observeEntries() {
        withObservationTracking { _ = model.entries } onChange: { [weak self] in
            Task { @MainActor in
                self?.entriesChanged()
                self?.observeEntries()
            }
        }
    }

    private func entriesChanged() {
        for card in stack.cards {
            guard let id = card.phase.entryID, let known = entries[card.key],
                  let entry = model.entries.first(where: { $0.id == id }), entry.revision != known.revision else { continue }
            entries[card.key] = entry
            let original = entry.enabledFindings.isEmpty
            let phase: CardPhase = original ? .original(entryID: id, findings: entry.findings.count)
                                            : .covered(entryID: id, findings: entry.enabledFindings.count)
            let key = card.key
            Task { [weak self] in
                guard let self else { return }
                if let image = await self.cardImage(for: entry, original: original) { self.images[key] = image }
                self.perform(self.stack.setPhase(phase, for: key))
                self.render()
            }
        }
    }

    private var surface: any ThumbnailSurface {
        if let surfaceStorage { return surfaceStorage }
        let made = makeSurface(self)
        surfaceStorage = made
        return made
    }

    // MARK: Engine events

    /// An image entered the pipeline. Only new screenshot-folder files are tracked, and only while the thumbnail is on.
    public func handle(start: ScanStart) {
        guard let url = start.fileURL,
              ThumbnailStack.accepts(origin: start.origin, hasFile: true, enabled: model.settings.thumbnailEnabled) else { return }
        let ceiling = ThumbnailStack.checkingCeiling(ocrDeadline: PipelineConstants.ocrDeadlineSeconds(model.settings))
        stack.start(key: start.key, displayName: start.displayName, fileURL: url, screenPoint: system.mouseLocation(), at: clock(),
                    ceiling: ceiling)
        prefetch(key: start.key, url: url)
        reschedule()
    }

    /// Whether this report's catch is announced by the thumbnail: it saw the scan start (so the switch was on then)
    /// and a display can show it. The notifier asks this, so a catch gets exactly one notice: the card, or else the
    /// banner. Call before `handle(report:)`, which ends the tracking.
    public func claims(_ report: ScanReport) -> Bool {
        guard let key = report.key else { return false }
        return stack.isTracking(key) && system.hasDisplay
    }

    /// Starts reading the screenshot as soon as its scan starts, so a checking card never slides in as an empty fill
    /// and a clean result needs no second read.
    private func prefetch(key: CaptureKey, url: URL) {
        guard images[key] == nil else { return }
        Task { [weak self] in
            guard let self, let image = await self.system.loadImage(url) else { return }
            // A result's own image (the clean one, for a catch) may have landed first; it wins.
            guard self.images[key] == nil, self.stack.liveKeys.contains(key) else { return }
            self.images[key] = image
            if self.stack.front?.key == key { self.render() }
        }
    }

    /// A scan ended. Clean and covered screenshots show; skipped or failed ones show nothing and remove a checking card.
    public func handle(report: ScanReport) {
        guard let key = report.key, stack.isTracking(key) else { return }
        let result = ShotResult(report.outcome)
        enqueue { await $0.apply(key: key, result: result) }
    }

    /// Waits for every queued report (tests).
    func drain() async { await tail?.value }

    /// Whether the card's image for `key` is loaded (tests).
    func hasImage(for key: CaptureKey) -> Bool { images[key] != nil }

    private func enqueue(_ work: @escaping @MainActor (ThumbnailController) async -> Void) {
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
    }

    /// Loads what the card shows before it appears, so it never slides in empty.
    private func apply(key: CaptureKey, result: ShotResult) async {
        switch result {
        case .redacted(let id, _):
            if let entry = try? await model.journal.entry(id) {
                entries[key] = entry
                if let image = await cardImage(for: entry, original: false) { images[key] = image }
            } else {
                Log.app.error("thumbnail: journal entry missing for a covered screenshot")
            }
        case .clean:
            // The file is the screenshot as taken; the prefetch at the start already read it, unless it is still going.
            if images[key] == nil, let url = stack.pending[key]?.fileURL { images[key] = await system.loadImage(url) }
        case .dropped:
            break
        }
        perform(stack.report(key: key, result: result, duration: duration, at: clock()))
    }

    private var duration: TimeInterval { max(1, model.settings.thumbnailSeconds) }

    /// The clean (or original) image of a covered shot, read from the Journal and decoded at card size off the main
    /// thread: a full-resolution `NSImage(data:)` would decode lazily on the main thread at the first frame of the slide.
    private func cardImage(for entry: Entry, original: Bool) async -> NSImage? {
        // The clean picture is read with its flags (G-28); the card shows it only while it is the picture they describe.
        let data = try? await (original ? model.journal.originalData(entry.id) : model.journal.cleanImage(entry.id).data)
        guard let data else { return nil }
        return await system.decodeImage(data)
    }

    // MARK: Time

    /// Runs the state machine's clock: reveal a slow check, drop one past its ceiling, fold "Checked", end the countdown.
    func tick() {
        perform(stack.tick(at: clock()))
    }

    private func reschedule() {
        timer?.cancel()
        timer = nil
        guard schedulesTimers, let wake = stack.nextWakeup() else { return }
        let delay = max(0, wake - clock()) + 0.01
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.tick()
        }
    }

    /// `animated: false` hides at once (a drop or a fling, while the card is already invisible).
    private func perform(_ change: StackChange, animated: Bool = true) {
        switch change {
        case .none:
            break
        case .appear, .update:
            render()
            if let front = stack.front { surface.show(at: front.screenPoint) }
        case .hide:
            // The card keeps what it shows while it slides (or fades) out; it is cleared once it is gone.
            hideGeneration += 1
            let generation = hideGeneration
            surface.hide(animated: animated) { [weak self] in self?.hidden(generation) }
            forgetUnused()
        }
        reschedule()
    }

    private func hidden(_ generation: Int) {
        guard generation == hideGeneration, stack.front == nil else { return }
        store.content = nil
    }

    /// Rebuilds what the view draws from the stack. With nothing in the stack the last content stays (it may be
    /// sliding out); `hidden` clears it.
    private func render() {
        store.colorScheme = model.settings.appearance.colorScheme
        guard let front = stack.front else { return }
        store.content = ThumbnailContent(displayName: front.displayName, image: images[front.key], capsule: CapsuleKind(front),
                                         hoverAction: HoverAction(front.phase), hovering: stack.holds.contains(.hover),
                                         edges: stack.edges)
    }

    private func forgetUnused() {
        let live = stack.liveKeys
        entries = entries.filter { live.contains($0.key) }
        images = images.filter { live.contains($0.key) }
    }

    // MARK: Pointer (from the panel)

    func pointerHover(_ inside: Bool) {
        guard stack.isVisible else { return }
        stack.setHold(.hover, inside, at: clock())
        render()
        reschedule()
    }

    func menuOpen(_ open: Bool) {
        stack.setHold(.menu, open, at: clock())
        reschedule()
    }

    /// A click on the card: Preview or the viewer, per Settings. Nothing while checking.
    func cardClicked() {
        guard let card = stack.front else { return }
        switch ClickTarget.resolve(phase: card.phase, setting: model.settings.thumbnailClickOpens, file: dragFile()) {
        case .nothing: return
        case .preview(let url): system.openInPreview(url)
        case .viewer(let id): model.router?.openViewer(entryID: id)
        }
        dismiss()
    }

    /// A click on the hover capsule: Undo or Black Out Again.
    func hoverActionClicked() {
        guard let card = stack.front else { return }
        switch card.phase {
        case .covered: undo(card)
        case .original: blackOutAgain(card)
        case .checking, .clean: break
        }
    }

    /// The file a drag would carry right now; nil refuses the drag (checking, or the file is gone).
    func dragFile() -> URL? {
        guard let card = stack.front else { return nil }
        let entry = entries[card.key]
        return DragFile.resolve(phase: card.phase, fileURL: card.fileURL, entryFilePath: entry?.filePath,
                                entryCleanCopyPath: entry?.cleanCopyPath, exists: system.fileExists)
    }

    func dragBegan() {
        stack.setHold(.drag, true, at: clock())
        surface.setDragHidden(true)
        reschedule()
    }

    func dragEnded(at point: CGPoint, dropped: Bool) {
        stack.setHold(.drag, false, at: clock())
        if DragEnd.dismisses(dropped: dropped, endPoint: point, cardFrame: surface.cardFrame, screen: surface.screenFrame) {
            // The card is invisible while dragged: it leaves at once, so it never reappears in the corner to slide out.
            perform(stack.dismiss(), animated: false)
        } else {
            surface.setDragHidden(false)
            reschedule()
        }
    }

    /// A drag let go at this point would be a fling (so its drag image should not slide back to the corner).
    func isFlingPoint(_ point: CGPoint) -> Bool {
        DragEnd.isFling(point, cardFrame: surface.cardFrame, screen: surface.screenFrame)
    }

    /// Swipe right, Close, or after a click opened the file.
    func dismiss() {
        perform(stack.dismiss())
    }

    // MARK: Menu

    func menuItems() -> [ThumbnailMenuItem] {
        guard let card = stack.front else { return [] }
        return ThumbnailMenuItem.items(for: card.phase, clickOpens: model.settings.thumbnailClickOpens)
    }

    func perform(menu item: ThumbnailMenuItem) {
        guard let card = stack.front else { return }
        let file = dragFile()
        switch item {
        case .copy:
            if let id = card.phase.entryID { Task { await model.copy(id, original: false) } }
            else if let file { system.copyFile(file) }
        case .openInViewer:
            if let id = card.phase.entryID { model.router?.openViewer(entryID: id); dismiss() }
        case .openInPreview:
            if let file { system.openInPreview(file); dismiss() }
        case .showInFinder:
            if let target = file ?? (system.fileExists(card.fileURL) ? card.fileURL : nil) { system.showInFinder(target) }
        case .openInJournal:
            model.router?.openJournal(selecting: card.phase.entryID)
        case .undo:
            undo(card)
        case .blackOutAgain:
            blackOutAgain(card)
        case .delete:
            delete(card)
        case .close:
            dismiss()
        case .separator:
            break
        }
    }

    // MARK: Actions

    private func undo(_ card: ShotCard) {
        guard case .covered(let id, let n) = card.phase else { return }
        let key = card.key
        Task { [weak self] in
            guard let self, await self.model.undo(id) else { return }
            await self.reload(key: key, entryID: id, original: true)
            self.perform(self.stack.setPhase(.original(entryID: id, findings: n), for: key))
        }
    }

    private func blackOutAgain(_ card: ShotCard) {
        guard case .original(let id, let n) = card.phase else { return }
        let key = card.key
        Task { [weak self] in
            guard let self, await self.model.blackOutAll(id) else { return }
            await self.reload(key: key, entryID: id, original: false)
            self.perform(self.stack.setPhase(.covered(entryID: id, findings: n), for: key))
        }
    }

    /// Re-reads the entry and the image the card now shows (the original after Undo, the clean image after Redo).
    private func reload(key: CaptureKey, entryID: UUID, original: Bool) async {
        guard let entry = try? await model.journal.entry(entryID) else { return }
        entries[key] = entry
        if let image = await cardImage(for: entry, original: original) { images[key] = image }
    }

    /// Delete: the screenshot (and its clean copy) go to the Finder Trash, its Journal row to the Journal's trash;
    /// both can be put back.
    private func delete(_ card: ShotCard) {
        var files = [card.fileURL]
        if let clean = entries[card.key]?.cleanCopyPath { files.append(URL(fileURLWithPath: clean)) }
        system.moveToTrash(files.filter(system.fileExists))
        if let id = card.phase.entryID { Task { await model.trash([id]) } }
        dismiss()
    }

    /// The closures the view's VoiceOver actions and hover button call.
    var actions: ThumbnailActions {
        ThumbnailActions(open: { [weak self] in self?.cardClicked() },
                         hoverAction: { [weak self] in self?.hoverActionClicked() },
                         copy: { [weak self] in self?.perform(menu: .copy) },
                         showInFinder: { [weak self] in self?.perform(menu: .showInFinder) },
                         close: { [weak self] in self?.dismiss() })
    }
}
