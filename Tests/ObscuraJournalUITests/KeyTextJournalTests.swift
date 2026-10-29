// G-17 in the Journal inspector: a finding left visible shows its key as text with Copy while the Settings switch is
// on; covering it again or turning the switch off clears it. The reader is a stub that answers a made-up key.
import AppKit
import Foundation
import SwiftUI
import Testing
import ObscuraJournal
import ObscuraPrefs
import ObscuraUIKit
@testable import ObscuraJournalUI

private let madeUpKey = "sk_live_gHBJ59jWkyqhEGdgw5UhJjnc"

@MainActor
private func keyTextController(switchOn: Bool) async throws -> (AppModel, JournalController) {
    var settings = Settings.default
    settings.showsUncoveredKeyText = switchOn
    let model = try await SampleData.model(entries: 2, settings: settings)
    let keys = UncoveredKeyText { _, _ in madeUpKey }
    let controller = JournalController(model: model, keyTexts: keys)
    controller.toastLifetime = .seconds(600)
    return (model, controller)
}

@Suite @MainActor struct KeyTextJournalTests {
    /// The sample's second entry has its fourth finding left visible.
    private func leftVisible(_ model: AppModel) throws -> (entry: Entry, finding: ObscuraJournal.Finding) {
        let entry = try #require(model.entries.first { $0.findings.contains { !$0.enabled } })
        return (entry, try #require(entry.findings.first { !$0.enabled }))
    }

    @Test func aLeftVisibleFindingShowsItsKeyOnlyWithTheSwitchOn() async throws {
        let (offModel, off) = try await keyTextController(switchOn: false)
        let hidden = try leftVisible(offModel)
        #expect(off.keyTextState(for: hidden.finding) == nil)

        let (model, controller) = try await keyTextController(switchOn: true)
        let (entry, finding) = try leftVisible(model)
        #expect(controller.keyTextState(for: finding) == .reading)
        for covered in entry.findings where covered.enabled { #expect(controller.keyTextState(for: covered) == nil) }
        controller.requestKeyText(finding, in: entry.id)
        await controller.keyTexts.settle()
        #expect(controller.keyTextState(for: finding) == .text(madeUpKey))

        // The switch turned off in Settings: gone at once, and dropped from memory on the next sync.
        model.updateSettings { $0.showsUncoveredKeyText = false }
        #expect(controller.keyTextState(for: finding) == nil)
        controller.syncKeyTexts(selection: [entry.id])
        #expect(controller.keyTexts.heldIDs.isEmpty)
    }

    @Test func coveringTheFindingAgainClearsItsKey() async throws {
        let (model, controller) = try await keyTextController(switchOn: true)
        let (entry, finding) = try leftVisible(model)
        controller.requestKeyText(finding, in: entry.id)
        await controller.keyTexts.settle()
        #expect(controller.keyTexts.heldIDs == [finding.id])

        // Covered again (the model has no engine here, so the store is written directly, as the engine would).
        try await model.journal.setCovered(finding.id, true, in: entry.id)
        await model.reloadEntries()
        controller.syncKeyTexts(selection: [entry.id])
        #expect(controller.keyTexts.heldIDs.isEmpty)
        let recovered = try #require(model.entries.first { $0.id == entry.id }?.findings.first { $0.id == finding.id })
        #expect(controller.keyTextState(for: recovered) == nil)
    }

    @Test func selectingAnotherEntryDropsTheKey() async throws {
        let (model, controller) = try await keyTextController(switchOn: true)
        let (entry, finding) = try leftVisible(model)
        controller.requestKeyText(finding, in: entry.id)
        await controller.keyTexts.settle()
        controller.syncKeyTexts(selection: [entry.id])
        #expect(controller.keyTexts.heldIDs == [finding.id], "still the inspector's entry: kept")
        let other = try #require(model.entries.first { $0.id != entry.id })
        controller.syncKeyTexts(selection: [other.id])
        #expect(controller.keyTexts.heldIDs.isEmpty)
        controller.requestKeyText(finding, in: entry.id)
        await controller.keyTexts.settle()
        controller.syncKeyTexts(selection: [entry.id, other.id])
        #expect(controller.keyTexts.heldIDs.isEmpty, "several selected: the inspector shows no findings")
    }

    @Test func copyPutsTheKeyOnThePasteboardAndSaysSo() async throws {
        let (model, controller) = try await keyTextController(switchOn: true)
        let (entry, finding) = try leftVisible(model)
        controller.requestKeyText(finding, in: entry.id)
        await controller.keyTexts.settle()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("obscura-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        controller.copyKeyText(finding.id, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == madeUpKey)
        #expect(pasteboard.types?.contains(KeyPasteboard.concealedType) == true)
        #expect(controller.ladder.first?.text == "Key copied.")
        #expect(controller.ladder.first?.isError == false)
        #expect(!(controller.ladder.first?.text.contains(madeUpKey) ?? true), "the toast never carries the key")
    }

    @Test func theInspectorDrawsTheFieldInBothAppearances() async throws {
        let (model, controller) = try await keyTextController(switchOn: true)
        let (entry, finding) = try leftVisible(model)
        controller.requestKeyText(finding, in: entry.id)
        await controller.keyTexts.settle()
        for dark in [false, true] {
            let view = JournalInspector(controller: controller, selection: .constant([entry.id]))
            #expect(Fixtures.snapshot(view, size: CGSize(width: OMetric.journalInspectorWidth, height: 900), dark: dark) != nil)
        }
    }
}

/// A finding's flag changed the only way the Journal allows (G-28): with a picture, in one commit. These tests stand in
/// for the engine, so the picture is the original's bytes; what they check does not read it.
fileprivate extension JournalStore {
    func setCovered(_ findingID: UUID, _ covered: Bool, in entryID: UUID) async throws {
        let entry = try await entry(entryID)
        var set = Set(entry.enabledFindings.map(\.id))
        if covered { set.insert(findingID) } else { set.remove(findingID) }
        try await commitRender(entryID, clean: try await originalData(entryID), enabled: set, style: nil, expectedRevision: entry.revision)
    }
}
