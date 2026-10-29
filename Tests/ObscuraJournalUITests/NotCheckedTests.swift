// G-13: the Journal's Not checked section over a real engine and a real Journal whose `unchecked` rows were written
// before the engine started (what a relaunch looks like). Every file name and folder here is made up; no Finder window
// is ever opened (Show in Finder is only exercised on a file that is gone).
import AppKit
import Foundation
import SwiftUI
import Testing
import ObscuraCapture
import ObscuraEngine
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSupport
import ObscuraUIKit
@testable import ObscuraJournalUI

@MainActor
final class NotCheckedWorld {
    let root: URL
    let journal: SQLiteJournalStore
    let engine: ShieldEngine
    let model: AppModel
    let controller: JournalController

    /// One file per entry, written into `<root>/<folder>/<name>` and recorded as unchecked `attempts` times.
    struct Spec { var name: String; var folder: String; var origin: UncheckedOrigin; var reason: UncheckedReason; var attempts = 1 }

    static let specs: [Spec] = [
        Spec(name: "Screenshot 2026-10-27 at 9.44.08 AM.png", folder: "Desktop", origin: .screenshotFolder, reason: .ocrTimeout),
        Spec(name: "IMG_0412.heic", folder: "Downloads", origin: .downloads, reason: .ocrFailed, attempts: 2),
        Spec(name: "invoice-draft.png", folder: "Projects", origin: .imported, reason: .renderFailed),
    ]

    init(_ specs: [Spec] = NotCheckedWorld.specs, entries: Int = 2) async throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("obscura-notchecked-\(UUID().uuidString)", isDirectory: true)
        journal = try SQLiteJournalStore(root: root.appendingPathComponent("journal", isDirectory: true), ruleKeys: InMemoryRuleKeyStore())
        try await SampleData.seed(journal, count: entries)
        for spec in specs {
            let folder = root.appendingPathComponent(spec.folder, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(spec.name)
            try SampleData.terminalPNG(covered: false).write(to: file)
            for _ in 0..<spec.attempts { _ = try await journal.recordUnchecked(path: file.path, origin: spec.origin, reason: spec.reason) }
        }
        let settings = InMemorySettingsStore(.default)
        engine = ShieldEngine(sources: [], recognizer: StubTextRecognizer(lines: []), journal: journal, settings: settings,
                              clock: SystemClock(), folderWatcher: nil, clipboardGuard: nil)
        model = AppModel(engine: engine, journal: journal, settings: settings, router: nil)
        model.start()
        await model.reloadEntries()
        // Any status publish carries the rows the engine loaded from the Journal.
        await engine.catalogueChanged()
        controller = JournalController(model: model)
        controller.toastLifetime = .seconds(600)
        _ = await Fixtures.eventually { self.model.status.unchecked.count == specs.count }
    }

    func file(_ name: String) -> UncheckedFile? { model.status.unchecked.first { $0.displayName == name } }

    func tearDown() {
        model.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite(.serialized) @MainActor struct NotCheckedSectionTests {
    @Test func theRowIsThereOnlyWhileThereIsSomethingToShow() async throws {
        let (_, sample) = try await Fixtures.sampleController()
        #expect(!sample.showsNotChecked, "no unchecked file, no row")

        let world = try await NotCheckedWorld()
        defer { world.tearDown() }
        let c = world.controller
        #expect(c.showsNotChecked)
        #expect(c.count(.notChecked) == 3, "the rows written before the engine started (a relaunch) are listed")
        #expect(c.count(.all) == 2, "catches are not counted as unchecked, nor the other way round")
        #expect(SidebarItem.notChecked.tone == .needs)
        #expect(SidebarItem.notChecked.symbol == "clock.badge.exclamationmark")
        #expect(NSImage(systemSymbolName: SidebarItem.notChecked.symbol, accessibilityDescription: nil) != nil)
        #expect(c.allEntries.allSatisfy { !SidebarItem.notChecked.matches($0, verdict: c.model.verdict(for: $0)) })
    }

    @Test func aRouterRequestOpensTheSectionAndCatchesLeaveIt() async throws {
        let world = try await NotCheckedWorld()
        defer { world.tearDown() }
        let c = world.controller
        c.sidebar = .safe
        c.open(.notChecked)
        #expect(c.sidebar == .notChecked)
        #expect(c.statsLine == "3 images not checked")
        #expect(c.visibleUnchecked.count == 3)
        c.search = "img_"
        #expect(c.visibleUnchecked.map(\.displayName) == ["IMG_0412.heic"], "the search narrows the files by name")
        c.search = ""
        c.open(.catches(selecting: nil))
        #expect(c.sidebar == .all)
        c.sidebar = .original
        let first = try #require(world.model.entries.first)
        c.open(.catches(selecting: first.id))
        #expect(c.sidebar == .all, "a filter that would hide the entry asked for gives way")
    }

    @Test func dismissRemovesTheFileAndUndoListsItAgainExactly() async throws {
        let world = try await NotCheckedWorld()
        defer { world.tearDown() }
        let c = world.controller
        c.open(.notChecked)
        let file = try #require(world.file("invoice-draft.png"))
        let row = try #require(try await world.journal.uncheckedFiles().first { $0.id == file.id })

        await c.dismiss(file)
        #expect(await Fixtures.eventually { world.model.status.unchecked.count == 2 })
        #expect(try await world.journal.uncheckedFiles().count == 2)
        let toast = try #require(c.ladder.first)
        #expect(toast.text == "Dismissed invoice-draft.png")
        #expect(toast.undo != nil)

        await c.undo(toast.id)
        #expect(await Fixtures.eventually { world.model.status.unchecked.count == 3 })
        #expect(try await world.journal.uncheckedFiles().first { $0.id == file.id } == row, "the row comes back as it was")
    }

    @Test func checkAgainThatReachesAVerdictEmptiesTheSectionIntoItsQuietState() async throws {
        let spec = NotCheckedWorld.Spec(name: "Screenshot 2026-10-27 at 9.44.08 AM.png", folder: "Desktop", origin: .screenshotFolder,
                                        reason: .ocrTimeout)
        let world = try await NotCheckedWorld([spec])
        defer { world.tearDown() }
        let c = world.controller
        c.open(.notChecked)
        let file = try #require(world.file(spec.name))
        await c.checkAgain(file)
        #expect(c.ladder.first?.text == "Checking \(spec.name) again")
        #expect(await Fixtures.eventually { world.model.status.unchecked.isEmpty }, "the clean verdict clears it")
        #expect(try await world.journal.uncheckedFiles().isEmpty)
        #expect(c.showsNotChecked, "the row stays while its section is on screen")
        #expect(c.statsLine == "Nothing left to check")
        c.sidebar = .all
        #expect(!c.showsNotChecked, "and goes once another section is chosen")
    }

    @Test func checkAllAgainSendsEveryFile() async throws {
        let world = try await NotCheckedWorld()
        defer { world.tearDown() }
        await world.controller.checkAllAgain()
        #expect(world.controller.ladder.first?.text == "Checking 3 images again")
        #expect(await Fixtures.eventually { world.model.status.unchecked.isEmpty })
    }

    @Test func aMovedFileCanOnlyBeDismissed() async throws {
        let world = try await NotCheckedWorld()
        defer { world.tearDown() }
        let c = world.controller
        let file = try #require(world.file("IMG_0412.heic"))
        try FileManager.default.removeItem(at: file.fileURL)
        #expect(!c.fileExists(file))
        await c.checkAgain(file)
        #expect(c.ladder.first?.text == "Couldn't find IMG_0412.heic. It was moved or deleted.")
        #expect(c.ladder.first?.isError == true)
        c.showInFinder(file)
        #expect(c.ladder.count == 2 && c.ladder.allSatisfy(\.isError))
        #expect(world.model.status.unchecked.count == 3, "a file that is gone is not forgotten silently either")
        await c.dismiss(file)
        #expect(await Fixtures.eventually { world.model.status.unchecked.count == 2 })
    }

    @Test func theReasonIsInPlainWordsForEveryKind() {
        for reason in UncheckedReason.allCases {
            let words = JournalFormat.uncheckedReason(reason, timeoutSeconds: 20)
            #expect(!words.isEmpty && !words.contains(reason.rawValue), "\(reason.rawValue) is said in words, not as its label")
        }
        #expect(JournalFormat.uncheckedReason(.ocrTimeout, timeoutSeconds: 20) == "Reading it took longer than 20 s, so it was stopped.")
        #expect(JournalFormat.notChecked(1) == "1 image not checked")
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(JournalFormat.uncheckedMeta(folder: "Downloads", date: now, attempts: 2, now: now, calendar: cal).hasSuffix("· tried 2 times"))
        #expect(!JournalFormat.uncheckedMeta(folder: "Downloads", date: now, attempts: 1, now: now, calendar: cal).contains("tried"))
    }
}

@Suite(.serialized) @MainActor struct NotCheckedRenderTests {
    @Test(arguments: [false, true])
    func theSectionRenders(dark: Bool) async throws {
        let world = try await NotCheckedWorld()
        defer { world.tearDown() }
        // One file gone, so the moved-or-deleted row is in the picture too.
        try FileManager.default.removeItem(at: try #require(world.file("invoice-draft.png")).fileURL)
        let c = world.controller
        c.open(.notChecked)
        var selection: Set<UUID> = []
        let view = JournalContent(controller: c, selection: Binding(get: { selection }, set: { selection = $0 }), onImport: {})
        let rep = try #require(Fixtures.snapshot(view, size: OMetric.journalSize, dark: dark))
        #expect(Fixtures.distinctColours(rep) > 20)
        Fixtures.save(rep, "journal-notchecked-\(dark ? "dark" : "light")")
    }

    @Test func theQuietEmptyStateRenders() async throws {
        let world = try await NotCheckedWorld([])
        defer { world.tearDown() }
        let c = world.controller
        c.open(.notChecked)
        var selection: Set<UUID> = []
        let view = JournalContent(controller: c, selection: Binding(get: { selection }, set: { selection = $0 }), onImport: {})
        let rep = try #require(Fixtures.snapshot(view, size: OMetric.journalSize, dark: false))
        #expect(Fixtures.distinctColours(rep) > 5)
        Fixtures.save(rep, "journal-notchecked-empty-light")
    }

    @Test func theSidebarRowRendersBesideTheCatches() async throws {
        let world = try await NotCheckedWorld()
        defer { world.tearDown() }
        let c = world.controller
        let first = try #require(world.model.entries.first?.id)
        var selection: Set<UUID> = [first]
        await c.preload(selection: selection)
        let view = JournalContent(controller: c, selection: Binding(get: { selection }, set: { selection = $0 }), onImport: {})
        let rep = try #require(Fixtures.snapshot(view, size: OMetric.journalSize, dark: false))
        #expect(Fixtures.distinctColours(rep) > 20)
        Fixtures.save(rep, "journal-all-with-notchecked-row-light")
    }
}
