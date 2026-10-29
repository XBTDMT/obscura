import AppKit
import Foundation
import Testing
@testable import ObscuraCapture
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSupport
@testable import ObscuraEngine

// G-18: a screenshot that reaches a verdict puts its final picture on the clipboard, as the guard's own write, so
// ⇧⌘4 then ⌘V pastes the clean picture. Every secret below is made up (the engine fixtures' Stripe-shaped value).

/// One engine wired to a clipboard guard on a private pasteboard (never the general one), and a folder of shots.
@MainActor
struct ClipboardRig {
    let board: NSPasteboard
    let clipboard: ClipboardGuard
    let root: URL
    let folder: URL
    let settings: InMemorySettingsStore
    let engine: ShieldEngine

    init(recognizer: any TextRecognizer = StubTextRecognizer(lines: [Fixture.keyLine, Fixture.plainLine]),
         settings: Settings = .default) throws {
        board = NSPasteboard(name: NSPasteboard.Name("obscura-g18-\(UUID().uuidString)"))
        board.clearContents()
        clipboard = ClipboardGuard(pasteboard: board)
        root = try Fixture.tempDirectory("g18-journal")
        folder = try Fixture.tempDirectory("g18-shots")
        self.settings = InMemorySettingsStore(settings)
        let journal = try SQLiteJournalStore(root: root, ruleKeys: InMemoryRuleKeyStore(), clock: ManualClock())
        // The shots folder is this rig's screenshot folder (F26: the engine reasons about the folders watched now).
        let shots = folder
        engine = ShieldEngine(sources: [], recognizer: recognizer, journal: journal, settings: self.settings, clock: ManualClock(),
                              folderWatcher: nil, clipboardGuard: clipboard,
                              locations: FolderLocations(screenshotFolder: { shots }, downloads: { shots.appendingPathComponent("no-downloads") }))
    }

    /// A shot on disk, as macOS would have saved it.
    func shot(_ name: String = "Screenshot 9.41.12 AM.png") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Fixture.pngData().write(to: url)
        return url
    }

    /// Submits one file event and waits for its report.
    func submit(_ url: URL, origin: FileOrigin) async -> ScanReport? {
        let stream = engine.outcomes
        await engine.submit(.file(url, origin: origin))
        return await collect(stream, count: 1, timeout: .seconds(10)).first
    }

    func tearDown() {
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: folder)
    }
}

@Suite(.serialized) @MainActor struct ScreenshotClipboardTests {
    @Test func theSwitchIsOnByDefault() {
        #expect(Settings.default.copiesCleanImage == true)
    }

    @Test func aCoveredScreenshotPutsTheCoveredPictureOnTheClipboardOnce() async throws {
        let rig = try ClipboardRig()
        defer { rig.tearDown() }
        let file = try rig.shot()
        let before = rig.board.changeCount
        let report = await rig.submit(file, origin: .screenshotFolder)
        guard case .redacted = report?.outcome else { Issue.record("not redacted: \(String(describing: report?.outcome))"); return }

        #expect(rig.board.changeCount == before + 1, "one write, not one per type")
        let png = try #require(rig.board.data(forType: .png))
        #expect(rig.board.data(forType: .tiff) != nil, "PNG and TIFF, as copyToClipboard writes")
        // The clipboard holds the picture now on disk (the covered one), never the original.
        let pasted = try Fixture.decode(png)
        let onDisk = try Fixture.decode(try Data(contentsOf: file))
        #expect(Fixture.differingPixels(pasted, onDisk).isEmpty)
        #expect(!Fixture.differingPixels(pasted, Fixture.whiteImage()).isEmpty, "the original is not what was copied")
    }

    @Test func aCleanScreenshotIsCopiedToo() async throws {
        let rig = try ClipboardRig(recognizer: StubTextRecognizer(lines: [Fixture.plainLine]))
        defer { rig.tearDown() }
        let file = try rig.shot()
        let before = rig.board.changeCount
        let report = await rig.submit(file, origin: .screenshotFolder)
        guard case .clean = report?.outcome else { Issue.record("not clean: \(String(describing: report?.outcome))"); return }
        #expect(rig.board.changeCount == before + 1)
        let pasted = try Fixture.decode(try #require(rig.board.data(forType: .png)))
        #expect(Fixture.differingPixels(pasted, Fixture.whiteImage()).isEmpty, "a clean shot is copied as it is")
    }

    @Test func aKeepBothCatchCopiesTheCleanCopy() async throws {
        var settings = Settings.default
        settings.fileHandling = .keepBoth
        let rig = try ClipboardRig(settings: settings)
        defer { rig.tearDown() }
        let file = try rig.shot("Shot.png")
        let report = await rig.submit(file, origin: .screenshotFolder)
        guard case .redacted = report?.outcome else { Issue.record("not redacted"); return }
        let cleanCopy = rig.folder.appendingPathComponent("Shot (clean).png")
        let pasted = try Fixture.decode(try #require(rig.board.data(forType: .png)))
        #expect(Fixture.differingPixels(pasted, try Fixture.decode(try Data(contentsOf: cleanCopy))).isEmpty)
    }

    @Test(arguments: [FileOrigin.downloads, .watched(URL(fileURLWithPath: "/home/example/Shots")), .imported])
    func otherOriginsWriteNothing(_ origin: FileOrigin) async throws {
        let rig = try ClipboardRig()
        defer { rig.tearDown() }
        let before = rig.board.changeCount
        let report = await rig.submit(try rig.shot(), origin: origin)
        #expect(report != nil)
        #expect(rig.board.changeCount == before, "\(origin) must not touch the clipboard")
    }

    @Test func theSwitchOffWritesNothing() async throws {
        var settings = Settings.default
        settings.copiesCleanImage = false
        let rig = try ClipboardRig(settings: settings)
        defer { rig.tearDown() }
        let before = rig.board.changeCount
        let report = await rig.submit(try rig.shot(), origin: .screenshotFolder)
        guard case .redacted = report?.outcome else { Issue.record("not redacted"); return }
        #expect(rig.board.changeCount == before)
    }

    /// A check that fails leaves the clipboard alone: the uncovered original is never put there.
    @Test func aFailedCheckWritesNothing() async throws {
        let rig = try ClipboardRig(recognizer: ScriptedRecognizer(error: .timeout))
        defer { rig.tearDown() }
        let before = rig.board.changeCount
        let report = await rig.submit(try rig.shot(), origin: .screenshotFolder)
        guard case .skipped = report?.outcome else { Issue.record("not skipped: \(String(describing: report?.outcome))"); return }
        #expect(rig.board.changeCount == before)
    }

    @Test func aPausedScreenshotWritesNothing() async throws {
        var settings = Settings.default
        settings.pausedUntil = .distantFuture
        let rig = try ClipboardRig(settings: settings)
        defer { rig.tearDown() }
        let before = rig.board.changeCount
        let report = await rig.submit(try rig.shot(), origin: .screenshotFolder)
        guard case .skipped(.protectionPaused) = report?.outcome else { Issue.record("not paused"); return }
        #expect(rig.board.changeCount == before)
    }

    /// Check Again is not a new screenshot: it never replaces what the user has on the clipboard now.
    @Test func checkAgainWritesNothing() async throws {
        // The first check times out, so the file is listed as unchecked with its screenshot-folder origin; the second
        // (Check Again) covers it. That second verdict must not touch the clipboard.
        let rig = try ClipboardRig(recognizer: SequenceRecognizer([.error(.timeout), .lines([Fixture.keyLine])]))
        defer { rig.tearDown() }
        let file = try rig.shot()
        let first = await rig.submit(file, origin: .screenshotFolder)
        guard case .skipped(.ocrTimeout) = first?.outcome else { Issue.record("first check did not time out"); return }
        let before = rig.board.changeCount
        let stream = rig.engine.outcomes
        let origin = await rig.engine.retry(file)
        let report = await collect(stream, count: 1, timeout: .seconds(10)).first
        #expect(origin == .screenshotFolder, "the retry keeps the screenshot origin, so only the retry rule can stop the copy")
        guard case .redacted = report?.outcome else { Issue.record("retry not redacted: \(String(describing: report?.outcome))"); return }
        #expect(rig.board.changeCount == before)
    }

    /// The write is the guard's own: its next poll does not catch it as a new image to check. A plain write afterwards
    /// proves the guard is listening.
    @Test func theGuardIgnoresTheWrite() async throws {
        let rig = try ClipboardRig()
        defer { rig.tearDown() }
        try await rig.clipboard.start()
        defer { Task { await rig.clipboard.stop() } }
        var events = rig.clipboard.events.makeAsyncIterator()
        let report = await rig.submit(try rig.shot(), origin: .screenshotFolder)
        guard case .redacted = report?.outcome else { Issue.record("not redacted"); return }
        rig.clipboard.tick()
        rig.board.clearContents()
        rig.board.setData(Fixture.pngData(), forType: .png)
        rig.clipboard.tick()
        let next = await events.next()
        if case .pasteboardImage(_, _, let count, _) = next {
            #expect(count == rig.board.changeCount, "the first event is the plain write, not Obscura's own")
        } else {
            Issue.record("no event")
        }
    }
}
