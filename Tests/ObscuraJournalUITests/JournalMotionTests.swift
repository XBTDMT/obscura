import AppKit
import Foundation
import SwiftUI
import Testing
import ObscuraJournal
import ObscuraUIKit
@testable import ObscuraJournalUI

// Recon B-6 motion fixes in the Journal (knowledge/recon/motion-2026-10-27/FIXES-in-window.md).
@Suite @MainActor struct JournalMotionTests {
    /// T-1: an edit bumps the revision; the card and the preview keep the previous image until the new one is decoded,
    /// so neither drops to the dark ground in between.
    @Test func anEditKeepsThePreviousImageUntilTheNewOneIsReady() async throws {
        let (model, controller, _) = try await Fixtures.engineController()
        controller.reduceMotion = { true }
        let entry = try #require(model.entries.first { $0.findings.allSatisfy(\.enabled) })
        var selection: Set<UUID> = [entry.id]
        await controller.preload(selection: selection)
        let before = try #require(controller.image(for: entry))
        let original = try #require(controller.image(for: entry, original: true))
        #expect(controller.showsCurrentImage(of: entry))

        await controller.toggleFinding(try #require(entry.findings.first), in: entry.id)
        let edited = try #require(controller.entry(entry.id))
        #expect(edited.revision > entry.revision)
        // Before the new revision is loaded: the previous image, not nil (nil drew the terminal ground).
        #expect(controller.image(for: edited) === before)
        #expect(!controller.showsCurrentImage(of: edited))
        // The original never changes with the revision; it is not dropped or reloaded.
        #expect(controller.image(for: edited, original: true) === original)

        let view = JournalContent(controller: controller, selection: Binding(get: { selection }, set: { selection = $0 }), onImport: {})
        let pending = try #require(Fixtures.snapshot(view, size: OMetric.journalSize, dark: true))
        Fixtures.save(pending, "t1-after-edit-before-decode-dark")

        // The snapshot's own `.task` may already be loading it; either way it lands once.
        await controller.loadImage(for: edited)
        #expect(await Fixtures.eventually { controller.showsCurrentImage(of: edited) })
        let after = try #require(controller.image(for: edited))
        #expect(after !== before)
        #expect(controller.showsCurrentImage(of: edited))

        // A late load of the older revision never puts the old image back.
        await controller.loadImage(for: entry)
        #expect(controller.image(for: edited) === after)
    }

    /// The defect T-1 fixed, for the before/after stills: with nothing loaded for the entry's revision the card and
    /// the preview show the terminal ground (what the old revision-keyed lookup returned after every edit).
    @Test func theOldLookupsDarkCardForComparison() async throws {
        let (model, controller, _) = try await Fixtures.engineController()
        let entry = try #require(model.entries.first { $0.findings.allSatisfy(\.enabled) })
        var selection: Set<UUID> = [entry.id]
        for other in controller.visibleEntries where other.id != entry.id { await controller.loadImage(for: other) }
        #expect(controller.image(for: entry) == nil)
        let view = JournalContent(controller: controller, selection: Binding(get: { selection }, set: { selection = $0 }), onImport: {})
        let rep = try #require(Fixtures.snapshot(view, size: OMetric.journalSize, dark: true))
        Fixtures.save(rep, "t1-old-behaviour-dark-card-dark")
    }

    /// T-2: the preview peeks only after a deliberate hold, on the Viewer's 350 ms rule; a click never shows the
    /// original (the red ring and capsule).
    @Test func thePreviewPeeksOnlyAfterADeliberateHold() async throws {
        let (_, controller) = try await Fixtures.sampleController()
        controller.peekHold.pressBegan()
        controller.peekHold.pressEnded()
        try await Task.sleep(for: .milliseconds(450))
        #expect(!controller.isPeeking)

        let held = ContinuousClock.now
        controller.peekHold.pressBegan()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!controller.isPeeking)               // 0.15 s was the old threshold; not a hold yet
        // A press still down begins the peek, never before the 350 ms rule. Wait for the condition rather than a fixed
        // time: a busy main actor only delays the peek, and an early peek is what the rule forbids (checked below).
        while !controller.isPeeking, ContinuousClock.now - held < .seconds(5) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.isPeeking)
        #expect(ContinuousClock.now - held >= HoldToPeek.delay, "the peek never begins before the hold rule")
        controller.peekHold.pressEnded()
        #expect(!controller.isPeeking)
    }

    /// T-6: one toast lifetime in the ladder too.
    @Test func theLadderUsesTheOneToastLifetime() async throws {
        let model = try await SampleData.model(entries: 1)
        #expect(JournalController(model: model).toastLifetime == .seconds(OMotion.toastSeconds))
    }

    /// T-10: list rows keep their layout when a second row is ⌘-clicked; stills for the visual check.
    @Test(arguments: [1, 2])
    func listRowsKeepTheirLayoutWithTheMultiSelection(selected: Int) async throws {
        let (model, controller) = try await Fixtures.sampleController()
        controller.viewMode = .list
        var selection = Set(model.entries.prefix(selected).map(\.id))
        await controller.preload(selection: selection)
        let view = JournalContent(controller: controller, selection: Binding(get: { selection }, set: { selection = $0 }), onImport: {})
        let rep = try #require(Fixtures.snapshot(view, size: OMetric.journalSize, dark: false))
        #expect(Fixtures.distinctColours(rep) > 20)
        Fixtures.save(rep, "t10-list-\(selected)-selected-light")
    }

    /// T-7: the ladder draws through the shared stack, fade only, newest on top.
    @Test func theLadderIsTheSharedToastStack() async throws {
        let (_, controller) = try await Fixtures.sampleController()
        controller.push("Removed 2 screenshots whose files were deleted")
        controller.push("Screenshot deleted", undo: {})
        let items = UndoLadder(controller: controller).items
        #expect(items.map(\.text) == ["Screenshot deleted", "Removed 2 screenshots whose files were deleted"])
        #expect(items[0].actionTitle == "Undo ⌘Z" && items[1].actionTitle == nil)
    }
}
