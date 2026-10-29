import AppKit
import Foundation
import Testing
import ObscuraCapture
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSupport
import ObscuraUIKit
@testable import ObscuraEngine
@testable import ObscuraThumbnailUI

// Every key below is made up (an EXAMPLE-shaped Stripe test value, the same one the engine fixtures use).

@MainActor
final class FakeSurface: ThumbnailSurface {
    var shows: [CGPoint] = []
    var hides = 0
    /// How each hide was asked for, in order.
    var hideAnimations: [Bool] = []
    var dragHidden = false
    var cardFrame = CGRect(x: 1248, y: 96, width: 176, height: 110)
    var screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// The running hide's completion: the test decides when the slide-out ends.
    private var pendingHide: (@MainActor () -> Void)?
    func show(at point: CGPoint) {
        shows.append(point)
        pendingHide = nil  // a show turns a leaving card around; its hide never completes
    }
    func hide(animated: Bool, completion: @escaping @MainActor () -> Void) {
        hides += 1
        hideAnimations.append(animated)
        if animated { pendingHide = completion } else { completion() }
    }
    func setDragHidden(_ hidden: Bool) { dragHidden = hidden }
    /// The slide-out (or the Reduce Motion fade) ends.
    func finishHide() {
        let completion = pendingHide
        pendingHide = nil
        completion?()
    }
}

@MainActor
final class FakeMac: ThumbnailSystem {
    var pointer = CGPoint(x: 2000, y: 600)
    var opened: [URL] = []
    var revealed: [URL] = []
    var copied: [URL] = []
    var trashed: [URL] = []
    var hasDisplay = true
    var decodedOnTheSide = 0
    func mouseLocation() -> CGPoint { pointer }
    func fileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func openInPreview(_ url: URL) { opened.append(url) }
    func showInFinder(_ url: URL) { revealed.append(url) }
    func copyFile(_ url: URL) { copied.append(url) }
    func moveToTrash(_ urls: [URL]) { trashed += urls }
    func loadImage(_ url: URL) async -> NSImage? { ThumbnailImage.downsample(url).map { NSImage(cgImage: $0.cgImage, size: .zero) } }
    func decodeImage(_ data: Data) async -> NSImage? {
        decodedOnTheSide += 1
        return ThumbnailImage.downsample(data).map { NSImage(cgImage: $0.cgImage, size: .zero) }
    }
}

/// One controller on a real engine and Journal, with the panel and the Mac faked and the clock in the test's hands.
@MainActor
final class Rig {
    static let keyLine = OCRLine(index: 0, text: "STRIPE_SECRET_KEY=sk_live_gHBJ59jWkyqhEGdgw5UhJjnc",
                                 rect: CGRect(x: 20, y: 20, width: 440, height: 28))

    let dir: URL
    let journal: SQLiteJournalStore
    let settings: InMemorySettingsStore
    let engine: ShieldEngine
    let router = RecordingRouter()
    let model: AppModel
    let surface = FakeSurface()
    let mac = FakeMac()
    var now: TimeInterval = 100
    var controller: ThumbnailController!
    private var eventsIterator: AsyncStream<ScanEvent>.Iterator

    init(settings: ObscuraPrefs.Settings = .default, secret: Bool = true) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("obscura-thumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        journal = try SQLiteJournalStore(root: dir.appendingPathComponent("journal", isDirectory: true), ruleKeys: InMemoryRuleKeyStore(), clock: SystemClock())
        self.settings = InMemorySettingsStore(settings)
        // The rig's folder is its screenshot folder and its Downloads (F26: the engine writes only into watched folders).
        let shots = dir
        engine = ShieldEngine(sources: [], recognizer: StubTextRecognizer(lines: secret ? [Self.keyLine] : []), journal: journal,
                              settings: self.settings, clock: SystemClock(), folderWatcher: nil, clipboardGuard: nil,
                              locations: FolderLocations(screenshotFolder: { shots }, downloads: { shots }))
        model = AppModel(engine: engine, journal: journal, settings: self.settings, router: router)
        eventsIterator = engine.events.makeAsyncIterator()
        controller = ThumbnailController(model: model, system: mac, clock: { [unowned self] in self.now },
                                         schedulesTimers: false, makeSurface: { [unowned self] _ in self.surface })
    }

    func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// Writes a screenshot, runs it through the engine and feeds the start and the report to the controller.
    @discardableResult
    func capture(_ name: String = "Screenshot 2026-10-26 at 9.41.12 AM.png", origin: FileOrigin = .screenshotFolder,
                 checkingFor seconds: TimeInterval = 0.1) async throws -> (URL, Data) {
        let file = dir.appendingPathComponent(name)
        let original = SampleData.terminalPNG(covered: false)
        try original.write(to: file)
        await engine.submit(.file(file, origin: origin))
        guard case .started(let start)? = await nextEvent() else { Issue.record("expected the scan's start first"); return (file, original) }
        controller.handle(start: start)
        now += seconds
        controller.tick()
        guard case .finished(let report)? = await nextEvent() else { Issue.record("expected the scan's report"); return (file, original) }
        controller.handle(report: report)
        await controller.drain()
        return (file, original)
    }

    /// The engine's next scan event, in the order the app's one routing task receives them (G-9).
    func nextEvent() async -> ScanEvent? {
        var events = eventsIterator
        let next = await events.next(isolation: #isolation)
        eventsIterator = events
        return next
    }

    func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

@Suite(.serialized) @MainActor struct ThumbnailControllerTests {
    @Test func aCoveredScreenshotShowsOnTheCaptureScreenWithItsCount() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let (file, original) = try await rig.capture()
        #expect(rig.surface.shows == [rig.mac.pointer])
        let content = try #require(rig.controller.store.content)
        #expect(content.capsule == .covered(1))
        #expect(content.hoverAction == .undo)
        #expect(content.image != nil)
        let image = try #require(content.image)
        #expect(max(image.size.width, image.size.height) <= CGFloat(ThumbnailImage.maxPixelSize),
                "the covered shot is decoded at card size, not full resolution")
        #expect(rig.mac.decodedOnTheSide >= 1, "through the off-main decode")
        #expect(content.displayName == "Screenshot 2026-10-26 at 9.41.12 AM.png")
        #expect(rig.controller.dragFile() == file, "replace mode: the screenshot, now clean")
        #expect(try Data(contentsOf: file) != original)
    }

    @Test func aCleanScreenshotSaysChecked() async throws {
        let rig = try Rig(secret: false)
        defer { rig.tearDown() }
        let (file, original) = try await rig.capture()
        #expect(rig.controller.store.content?.capsule == .checked)
        #expect(rig.controller.store.content?.hoverAction == nil)
        #expect(rig.controller.dragFile() == file)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func otherOriginsAndTheSwitchOffShowNothing() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.capture("download.png", origin: .downloads)
        try await rig.capture("watched.png", origin: .watched(rig.dir))
        rig.model.updateSettings { $0.thumbnailEnabled = false }
        try await rig.capture("off.png")
        #expect(rig.surface.shows.isEmpty)
        #expect(rig.controller.store.content == nil)
    }

    @Test func keepBothDragsTheCleanSibling() async throws {
        var settings = ObscuraPrefs.Settings.default
        settings.fileHandling = .keepBoth
        let rig = try Rig(settings: settings)
        defer { rig.tearDown() }
        let (file, original) = try await rig.capture()
        let dragged = try #require(rig.controller.dragFile())
        #expect(dragged.lastPathComponent == "Screenshot 2026-10-26 at 9.41.12 AM (clean).png")
        #expect(try Data(contentsOf: file) == original, "keep both leaves the screenshot as taken")
    }

    @Test func whileCheckingNothingCanBeDraggedOpenedOrCopied() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let file = rig.dir.appendingPathComponent("slow.png")
        try SampleData.terminalPNG(covered: false).write(to: file)
        rig.controller.handle(start: ScanStart(key: CaptureKey(file: file), displayName: "slow.png", fileURL: file, origin: .screenshotFolder))
        rig.now += 0.4
        rig.controller.tick()
        #expect(rig.controller.store.content?.capsule == .checking)
        #expect(rig.surface.shows.count == 1)
        #expect(rig.controller.dragFile() == nil, "the drag is refused")
        rig.controller.cardClicked()
        #expect(rig.mac.opened.isEmpty)
        #expect(rig.controller.menuItems() == [.close])
    }

    @Test func aSkippedCheckRemovesTheCheckingCard() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let file = rig.dir.appendingPathComponent("slow.png")
        let key = CaptureKey(file: file)
        rig.controller.handle(start: ScanStart(key: key, displayName: "slow.png", fileURL: file, origin: .screenshotFolder))
        rig.now += 0.4
        rig.controller.tick()
        rig.controller.handle(report: ScanReport(key: key, displayName: "slow.png", outcome: .skipped(.ocrTimeout)))
        await rig.controller.drain()
        #expect(rig.surface.hides == 0, "a checking card younger than its minimum stays until it has been seen")
        rig.now += ThumbnailStack.checkingMinimum
        rig.controller.tick()
        #expect(rig.surface.hides == 1)
        // S-1: the card keeps its content while it slides out, and is cleared once the slide has ended.
        #expect(rig.controller.store.content?.capsule == .checking)
        rig.surface.finishHide()
        #expect(rig.controller.store.content == nil)
    }

    @Test func aCheckingCardWithNoReportLeavesAtTheCeilingTheSettingsGive() async throws {
        var settings = ObscuraPrefs.Settings.default
        settings.ocrTimeoutSeconds = 3
        let rig = try Rig(settings: settings)
        defer { rig.tearDown() }
        let file = rig.dir.appendingPathComponent("never.png")
        rig.controller.handle(start: ScanStart(key: CaptureKey(file: file), displayName: "never.png", fileURL: file, origin: .screenshotFolder))
        let startedAt = rig.now
        rig.now += 0.4
        rig.controller.tick()
        #expect(rig.controller.store.content?.capsule == .checking)
        let ceiling = ThumbnailStack.checkingCeiling(ocrDeadline: 3)
        #expect(rig.controller.stack.nextWakeup() == startedAt + ceiling, "the ceiling follows the OCR deadline in Settings")
        rig.now = startedAt + ceiling
        rig.controller.tick()
        #expect(rig.surface.hides == 1)
        // S-1: what slides out is the card, not an empty panel; it is cleared when the slide ends.
        #expect(rig.controller.store.content?.capsule == .checking)
        rig.surface.finishHide()
        #expect(rig.controller.store.content == nil)
    }

    @Test func clickOpensPreviewByDefaultAndTheViewerWhenChosen() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let (file, _) = try await rig.capture()
        rig.controller.cardClicked()
        #expect(rig.mac.opened == [file])
        #expect(rig.surface.hides == 1, "clicking hands the shot over and the thumbnail leaves")

        rig.model.updateSettings { $0.thumbnailClickOpens = .viewer }
        try await rig.capture("Second.png")
        let id = try #require(rig.controller.stack.front?.phase.entryID)
        rig.controller.cardClicked()
        #expect(rig.router.calls == ["viewer:\(id.uuidString)"])
    }

    @Test func undoPutsTheOriginalBackAndMarksItThenBlackOutAgainReverses() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let (file, original) = try await rig.capture()
        rig.controller.pointerHover(true)
        #expect(rig.controller.store.content?.hovering == true)
        rig.controller.hoverActionClicked()
        await rig.waitFor { rig.controller.store.content?.capsule == .original(1) }
        #expect(rig.controller.store.content?.capsule == .original(1))
        #expect(rig.controller.store.content?.hoverAction == .blackOutAgain)
        #expect(try Data(contentsOf: file) == original, "the original is back on disk")
        #expect(rig.controller.dragFile() == file, "and a drag now sends it, as the red marks say")
        #expect(rig.controller.menuItems().contains(.blackOutAgain))

        rig.controller.hoverActionClicked()
        await rig.waitFor { rig.controller.store.content?.capsule == .covered(1) }
        #expect(rig.controller.store.content?.capsule == .covered(1))
        #expect(try Data(contentsOf: file) != original)
    }

    @Test func undoDoneElsewhereTurnsTheCardRed() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let (file, original) = try await rig.capture()
        let id = try #require(rig.controller.stack.front?.phase.entryID)
        // The panel's (or the Journal's) Undo, not the card's.
        #expect(await rig.model.restoreOriginal(id))
        await rig.waitFor { rig.controller.store.content?.capsule == .original(1) }
        #expect(rig.controller.store.content?.capsule == .original(1))
        #expect(rig.controller.store.content?.hoverAction == .blackOutAgain)
        #expect(try Data(contentsOf: file) == original)
        #expect(await rig.model.blackOutAll(id))
        await rig.waitFor { rig.controller.store.content?.capsule == .covered(1) }
        #expect(rig.controller.store.content?.capsule == .covered(1))
    }

    @Test func aDropDismissesAndADragLetGoOverItselfComesBack() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.capture()
        rig.controller.dragBegan()
        #expect(rig.surface.dragHidden)
        #expect(rig.controller.stack.isPaused)
        rig.controller.dragEnded(at: CGPoint(x: 1300, y: 150), dropped: false)
        #expect(!rig.surface.dragHidden)
        #expect(rig.controller.stack.isVisible)
        rig.controller.dragBegan()
        rig.controller.dragEnded(at: CGPoint(x: 400, y: 500), dropped: true)
        #expect(!rig.controller.stack.isVisible)
        #expect(rig.surface.hides == 1)
        #expect(rig.surface.hideAnimations == [false], "the dragged card is invisible: it leaves at once, never reappearing to slide out")
        #expect(rig.surface.dragHidden, "and it is not made visible again first")
        #expect(rig.controller.store.content == nil)
    }

    @Test func aFlingOnlyCountsOnTheCardsOwnDisplay() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.capture()
        rig.controller.dragBegan()
        // Let go past the card's right edge but over a display arranged to the right: a failed drop, it comes back.
        rig.controller.dragEnded(at: CGPoint(x: 1600, y: 150), dropped: false)
        #expect(rig.controller.stack.isVisible)
        #expect(!rig.surface.dragHidden)
        rig.controller.dragBegan()
        rig.controller.dragEnded(at: CGPoint(x: 1435, y: 150), dropped: false)
        #expect(!rig.controller.stack.isVisible, "flung toward this display's edge")
    }

    @Test func everyExitKeepsTheCardUntilItHasLeft() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.capture()
        let shown = try #require(rig.controller.store.content)
        rig.controller.dismiss()
        #expect(rig.surface.hideAnimations == [true])
        #expect(rig.controller.store.content?.displayName == shown.displayName, "Close and swipe slide the card itself out")
        rig.surface.finishHide()
        #expect(rig.controller.store.content == nil)
    }

    @Test func aNewShotDuringTheSlideOutTurnsTheCardAround() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.capture("One.png")
        rig.controller.dismiss()
        try await rig.capture("Two.png")
        #expect(rig.surface.shows.count == 2)
        rig.surface.finishHide()  // the old slide-out's completion never comes; nothing clears the new card
        #expect(rig.controller.store.content?.displayName == "Two.png")
    }

    @Test func aCatchIsClaimedOnlyWhenTheThumbnailSawItsStartAndCanShowIt() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let file = rig.dir.appendingPathComponent("claimed.png")
        try SampleData.terminalPNG(covered: false).write(to: file)
        let key = CaptureKey(file: file)
        let report = ScanReport(key: key, displayName: "claimed.png", outcome: .clean(duration: .milliseconds(90)), origin: .screenshotFolder)
        #expect(!rig.controller.claims(report), "no start seen (the switch was off when it began)")
        rig.controller.handle(start: ScanStart(key: key, displayName: "claimed.png", fileURL: file, origin: .screenshotFolder))
        #expect(rig.controller.claims(report))
        rig.mac.hasDisplay = false
        #expect(!rig.controller.claims(report), "no display to show it on: the banner must post")
    }

    @Test func aCheckingCardIsNeverAnEmptyFill() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let file = rig.dir.appendingPathComponent("slow.png")
        try SampleData.terminalPNG(covered: false).write(to: file)
        rig.controller.handle(start: ScanStart(key: CaptureKey(file: file), displayName: "slow.png", fileURL: file, origin: .screenshotFolder))
        // The read starts with the scan, before the 0.3 s reveal.
        await rig.waitFor { rig.controller.stack.liveKeys.isEmpty == false && rig.controller.hasImage(for: CaptureKey(file: file)) }
        rig.now += 0.4
        rig.controller.tick()
        #expect(rig.controller.store.content?.capsule == .checking)
        #expect(rig.controller.store.content?.image != nil, "the blurred shot is ready when the checking card slides in")
    }

    @Test func menuActionsReachTheModelTheRouterAndTheMac() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let (file, _) = try await rig.capture()
        let id = try #require(rig.controller.stack.front?.phase.entryID)
        rig.controller.perform(menu: .showInFinder)
        rig.controller.perform(menu: .openInJournal)
        rig.controller.perform(menu: .openInViewer)
        #expect(rig.mac.revealed == [file])
        #expect(rig.router.calls == ["journal:\(id.uuidString)", "viewer:\(id.uuidString)"])

        try await rig.capture("Second.png")
        let second = rig.dir.appendingPathComponent("Second.png")
        let secondID = try #require(rig.controller.stack.front?.phase.entryID)
        rig.controller.perform(menu: .delete)
        #expect(rig.mac.trashed == [second])
        var trashed = false
        for _ in 0..<400 where !trashed {
            trashed = (try? await rig.journal.entry(secondID).isTrashed) ?? false
            if !trashed { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(trashed, "the Journal row went to the Journal's trash")
        #expect(!rig.controller.stack.isVisible)
    }

    @Test func aCleanShotCopiesItsFile() async throws {
        let rig = try Rig(secret: false)
        defer { rig.tearDown() }
        let (file, _) = try await rig.capture()
        rig.controller.perform(menu: .copy)
        #expect(rig.mac.copied == [file])
    }

    @Test func aBurstStacksEdgesBehindTheNewest() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try await rig.capture("One.png")
        try await rig.capture("Two.png")
        try await rig.capture("Three.png")
        #expect(rig.controller.store.content?.edges == 2)
        #expect(rig.controller.store.content?.displayName == "Three.png")
    }

    @Test func theDurationComesFromSettings() async throws {
        var settings = ObscuraPrefs.Settings.default
        settings.thumbnailSeconds = 3
        let rig = try Rig(settings: settings)
        defer { rig.tearDown() }
        try await rig.capture()
        let shown = rig.now
        rig.now = shown + 2.9
        rig.controller.tick()
        #expect(rig.controller.stack.isVisible)
        rig.now = shown + 3
        rig.controller.tick()
        #expect(!rig.controller.stack.isVisible)
    }
}
