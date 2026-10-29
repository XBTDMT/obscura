import AppKit
import Foundation
import SwiftUI
import Testing
import ObscuraEngine
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSupport
import ObscuraUIKit
import ObscuraTestSupport
@testable import ObscuraJournalUI

// The sample Journal (SampleData.seed, 6 entries): index 1 has one finding left visible; index 2 is a clipboard
// image, index 4 an import, the rest screenshots; every entry has four findings and was created just now.

@MainActor
enum Fixtures {
    /// The sample model (no engine: actions that need the engine are no-ops).
    static func sampleController(entries: Int = 6) async throws -> (AppModel, JournalController) {
        let model = try await SampleData.model(entries: entries)
        let controller = JournalController(model: model)
        controller.toastLifetime = .seconds(600)
        return (model, controller)
    }

    /// A model over a real engine (stub recognizer, no sources), so finding toggles and restores really re-render.
    static func engineController(entries: Int = 3) async throws -> (AppModel, JournalController, any JournalStore) {
        let journal = try SampleData.makeJournal()
        try await SampleData.seed(journal, count: entries)
        let settings = InMemorySettingsStore(.default)
        let engine = ShieldEngine(sources: [], recognizer: StubTextRecognizer(lines: []), journal: journal, settings: settings,
                                  clock: SystemClock(), folderWatcher: nil, clipboardGuard: nil)
        let model = AppModel(engine: engine, journal: journal, settings: settings, router: nil)
        await model.reloadEntries()
        let controller = JournalController(model: model)
        controller.toastLifetime = .seconds(600)
        return (model, controller, journal)
    }

    /// Draws a view in an off-screen window, so AppKit-backed controls (segmented pickers, sliders, the search field)
    /// render as they do on screen, and layer shadows fall on the side the screen draws them (ViewSnapshot).
    static func snapshot(_ view: some View, size: CGSize, dark: Bool) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return ViewSnapshot.bitmap(host)
    }

    /// How many distinct colours a coarse sample of the bitmap holds (a blank render has one or two).
    static func distinctColours(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                seen.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
            }
        }
        return seen.count
    }

    /// Writes the PNG when OBSCURA_UI_SNAPSHOT_DIR is set (the visual self-check); never into the repo.
    static func save(_ rep: NSBitmapImageRep, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["OBSCURA_UI_SNAPSHOT_DIR"], let data = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    /// Waits for fire-and-forget work (the model's own Tasks) to land.
    static func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

@Suite @MainActor struct JournalRenderTests {
    @Test(arguments: [JournalView.grid, .list], [false, true])
    func windowRendersWithSampleModel(mode: JournalView, dark: Bool) async throws {
        let (model, controller) = try await Fixtures.sampleController()
        controller.viewMode = mode
        let first = try #require(model.entries.first?.id)
        var selection: Set<UUID> = [first]
        await controller.preload(selection: selection)
        let size = OMetric.journalSize
        let view = JournalContent(controller: controller, selection: Binding(get: { selection }, set: { selection = $0 }), onImport: {})
        let rep = try #require(Fixtures.snapshot(view, size: size, dark: dark))
        #expect(CGFloat(rep.pixelsWide) >= size.width && CGFloat(rep.pixelsHigh) >= size.height)
        #expect(Fixtures.distinctColours(rep) > 20)
        Fixtures.save(rep, "journal-\(mode.rawValue)-\(dark ? "dark" : "light")")
    }

    @Test func multiSelectAndEmptyStatesRender() async throws {
        let (model, controller) = try await Fixtures.sampleController()
        var selection = Set(model.entries.prefix(3).map(\.id))
        await controller.preload(selection: selection)
        let binding = Binding(get: { selection }, set: { selection = $0 })
        let multi = try #require(Fixtures.snapshot(JournalContent(controller: controller, selection: binding, onImport: {}), size: OMetric.journalSize, dark: true))
        #expect(Fixtures.distinctColours(multi) > 20)
        Fixtures.save(multi, "journal-multi-dark")

        let (_, empty) = try await Fixtures.sampleController(entries: 0)
        var none: Set<UUID> = []
        let rep = try #require(Fixtures.snapshot(JournalContent(controller: empty, selection: Binding(get: { none }, set: { none = $0 }), onImport: {}),
                                                 size: OMetric.journalSize, dark: false))
        #expect(Fixtures.distinctColours(rep) > 5)
        #expect(empty.statsLine == "No screenshots yet")
        Fixtures.save(rep, "journal-empty-light")
    }

    @Test func leftVisibleInspectorWithStyleAndPeekRenders() async throws {
        let (model, controller) = try await Fixtures.sampleController()
        let left = try #require(model.entries.first { !model.verdict(for: $0).isSafe })
        var selection: Set<UUID> = [left.id]
        controller.styleExpanded = true
        controller.detailsExpanded = false
        controller.peekLatched = true
        await controller.preload(selection: selection)
        let view = JournalContent(controller: controller, selection: Binding(get: { selection }, set: { selection = $0 }), onImport: {})
        let rep = try #require(Fixtures.snapshot(view, size: OMetric.journalSize, dark: true))
        #expect(Fixtures.distinctColours(rep) > 20)
        Fixtures.save(rep, "journal-left-visible-style-peek-dark")
        #expect(controller.batchSummary(model.entries.filter { model.verdict(for: $0).isSafe }) == "All 5 files are safe to share.")
    }

    @Test func publicEntryPointRenders() async throws {
        let model = try await SampleData.model(entries: 2)
        let renderer = ImageRenderer(content: JournalWindow(model: model, selection: .constant([])).frame(width: 1040, height: 660))
        let image = try #require(renderer.nsImage)
        #expect(image.size == CGSize(width: 1040, height: 660))
    }
}

@Suite @MainActor struct JournalStateTests {
    @Test func verdictCountsPerEntry() async throws {
        let (model, controller) = try await Fixtures.sampleController()
        let counts = controller.stateCounts
        #expect(counts.safe == 5)
        #expect(counts.leftVisible == 1)
        #expect(counts.original == 0)
        // Every entry's badge is the model's verdict for it.
        for entry in model.entries {
            let expected = Verdict(enabled: entry.enabledFindings.count, total: entry.findings.count)
            #expect(model.verdict(for: entry) == expected)
        }
        let left = try #require(model.entries.first { if case .leftVisible = model.verdict(for: $0) { return true } else { return false } })
        #expect(model.verdict(for: left) == .leftVisible(visible: 1, total: 4))
        // Source rows.
        #expect(controller.count(.all) == 6)
        #expect(controller.count(.screenshots) == 4)
        #expect(controller.count(.clipboard) == 1)
        #expect(controller.count(.imported) == 1)
        #expect(controller.count(.testShots) == 0)
    }

    @Test func filtersSearchAndStats() async throws {
        let (_, controller) = try await Fixtures.sampleController()
        #expect(controller.statsLine == "6 screenshots · 24 secrets")
        #expect(controller.groups.count == 1)
        #expect(controller.dayLine(controller.groups[0]) == "6 screenshots · 24 secrets")
        controller.sidebar = .leftVisible
        #expect(controller.visibleEntries.count == 1)
        controller.sidebar = .clipboard
        #expect(controller.visibleEntries.map(\.displayName) == ["Clipboard image"])
        controller.sidebar = .all
        controller.search = "DEPLOY"
        #expect(controller.visibleEntries.map(\.displayName) == ["Imported · deploy-notes.png"])
        #expect(controller.statsLine == "1 screenshot · 4 secrets")
    }

    @Test func clickModifiersSelect() async throws {
        let (model, controller) = try await Fixtures.sampleController()
        let ids = model.entries.map(\.id)
        var s = controller.selection(afterClicking: ids[0], in: [], command: false, shift: false)
        #expect(s == [ids[0]])
        s = controller.selection(afterClicking: ids[3], in: s, command: false, shift: true)
        #expect(s == Set(ids[0...3]))
        s = controller.selection(afterClicking: ids[1], in: s, command: true, shift: false)
        #expect(s == [ids[0], ids[2], ids[3]])
        controller.gridColumns = 3
        controller.viewMode = .grid
        s = controller.selection(moving: 1, vertical: true, from: [ids[0]])
        #expect(s.count == 1)
    }

    @Test func retentionLines() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let cal = Calendar(identifier: .gregorian)
        let tomorrow = cal.date(byAdding: .hour, value: 24, to: now)!
        #expect(JournalFormat.keptUntil(tomorrow, now: now, calendar: cal).hasPrefix("Original kept until tomorrow"))
        #expect(JournalFormat.keptUntil(now.addingTimeInterval(-1), now: now, calendar: cal) == "Original deletes at the next cleanup")
        #expect(JournalFormat.retention(.oneDay) == "24 hours")
        #expect(JournalFormat.screenshots(1) == "1 screenshot")
    }
}

@Suite @MainActor struct JournalActionTests {
    @Test func deleteThenUndoRestores() async throws {
        let (model, controller) = try await Fixtures.sampleController()
        let id = try #require(model.entries.first?.id)
        await controller.delete([id])
        #expect(model.entries.count == 5)
        #expect(!model.entries.contains { $0.id == id })
        // The toast moved onto this window's ladder, with Undo.
        #expect(model.toast == nil)
        let toast = try #require(controller.ladder.first)
        #expect(toast.text == "Screenshot deleted")
        #expect(toast.undo != nil)
        await controller.undoLatest()
        #expect(model.entries.count == 6)
        #expect(model.entries.contains { $0.id == id })
        #expect(controller.ladder.isEmpty)
    }

    @Test func deleteUndoGoesThroughTheWindowsUndoManager() async throws {
        let (model, controller) = try await Fixtures.sampleController()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        controller.undoManager = undoManager
        let ids = model.entries.prefix(2).map(\.id)
        undoManager.beginUndoGrouping()
        await controller.delete(ids)
        undoManager.endUndoGrouping()
        #expect(model.entries.count == 4)
        #expect(controller.ladder.first?.text == "2 screenshots deleted")
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(await Fixtures.eventually { model.entries.count == 6 })
        #expect(controller.ladder.isEmpty)
        #expect(undoManager.canRedo)
        undoManager.redo()
        #expect(await Fixtures.eventually { model.entries.count == 4 })
    }

    @Test func findingToggleCallsThroughTheModel() async throws {
        let (model, controller, journal) = try await Fixtures.engineController()
        // Sample entries share a timestamp, so pick a fully covered one by state rather than by position.
        let entry = try #require(model.entries.first { $0.findings.allSatisfy(\.enabled) })
        let finding = try #require(entry.findings.first)
        #expect(model.verdict(for: entry) == .safeToShare(total: 4))

        await controller.toggleFinding(finding, in: entry.id)
        let stored = try await journal.entry(entry.id)
        #expect(stored.findings.first { $0.id == finding.id }?.enabled == false)
        #expect(stored.revision > entry.revision)
        let updated = try #require(controller.entry(entry.id))
        #expect(model.verdict(for: updated) == .leftVisible(visible: 1, total: 4))

        await controller.toggleFinding(try #require(updated.findings.first { $0.id == finding.id }), in: entry.id)
        #expect(model.verdict(for: try #require(controller.entry(entry.id))) == .safeToShare(total: 4))
    }

    @Test func selectAllAndDeselectAllCallThroughTheModel() async throws {
        let (model, controller, _) = try await Fixtures.engineController()
        let id = try #require(model.entries.first?.id)
        await controller.setAllFindings(in: id, enabled: false)
        #expect(model.verdict(for: try #require(controller.entry(id))) == .originalShowing(total: 4))
        await controller.setAllFindings(in: id, enabled: true)
        #expect(model.verdict(for: try #require(controller.entry(id))) == .safeToShare(total: 4))
    }

    @Test func restoreOriginalThenUndoBlacksOutAgain() async throws {
        let (model, controller, _) = try await Fixtures.engineController()
        let id = try #require(model.entries.first { $0.findings.allSatisfy(\.enabled) }?.id)
        await controller.restoreOriginals([id])
        #expect(model.verdict(for: try #require(controller.entry(id))) == .originalShowing(total: 4))
        let item = try #require(controller.ladder.first)
        #expect(item.text.hasPrefix("Restored original of"))
        await controller.undo(item.id)
        #expect(model.verdict(for: try #require(controller.entry(id))) == .safeToShare(total: 4))

        // Black Out Again from a partly visible entry covers everything; undo leaves the same one visible again.
        let partly = try #require(model.entries.first { !$0.findings.allSatisfy(\.enabled) } ?? model.entries.last)
        let firstFinding = try #require(partly.findings.first)
        if partly.findings.allSatisfy(\.enabled) { await controller.toggleFinding(firstFinding, in: partly.id) }
        let before = try #require(controller.entry(partly.id)).findings.filter { !$0.enabled }.map(\.id)
        await controller.blackOutAll([partly.id])
        #expect(model.verdict(for: try #require(controller.entry(partly.id))).isSafe)
        await controller.undoLatest()
        #expect(try #require(controller.entry(partly.id)).findings.filter { !$0.enabled }.map(\.id) == before)
    }

    @Test func applyingTheDefaultStyleCallsThroughTheModel() async throws {
        let (model, controller, journal) = try await Fixtures.engineController()
        let id = try #require(model.entries.first?.id)
        var mosaic = StyleRecord.builtInDefault
        mosaic.kind = .mosaic
        mosaic.isDefault = false
        await controller.applyStyle(mosaic, to: [id], announce: false)
        #expect(try await journal.entry(id).style.kind == .mosaic)
        await controller.applyDefaultStyle(to: [id])
        #expect(try await journal.entry(id).style.kind == (try await journal.defaultStyle()).kind)
        #expect(controller.ladder.first?.undo != nil)
    }

    @Test func importSkipsFilesAlreadyInTheJournal() async throws {
        let (model, controller) = try await Fixtures.sampleController()
        let id = try #require(model.entries.first?.id)
        let own = try await model.journal.cleanURL(id)
        let added = await controller.importFiles([own])
        #expect(added.isEmpty)
        #expect(controller.ladder.first?.text == "That's already in the Journal.")
        _ = await controller.importFiles([URL(fileURLWithPath: "/tmp/notes.txt")])
        #expect(controller.ladder.first?.text == "Only images can be imported.")
        #expect(controller.ladder.count <= 3)
    }

    @Test func copyCleanIsRefusedWhileSecretsAreVisible() async throws {
        let (model, controller) = try await Fixtures.sampleController()
        let left = try #require(model.entries.first { !model.verdict(for: $0).isSafe })
        await controller.copyClean(left.id)
        #expect(controller.ladder.isEmpty)
    }
}
