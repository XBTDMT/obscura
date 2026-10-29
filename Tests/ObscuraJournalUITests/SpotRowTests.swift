// G-40: in the Journal's Not checked section a picture whose only unread parts are spots no reading could read is listed
// apart from the alarms, in plain words, with Review…, Not Text and Cover It; settling it moves it to the record, with an
// Undo. A real engine over a real Journal; every file name is made up and no Finder window is opened.
import AppKit
import CoreGraphics
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

@Suite(.serialized) @MainActor struct SpotRowTests {
    static let spot = SpotRecord(rect: CGRect(x: 100, y: 50, width: 40, height: 8), coverRect: CGRect(x: 92, y: 42, width: 56, height: 24), state: .pending)

    @Test func theReasonIsTrueAndPlain() {
        #expect(JournalFormat.uncheckedReason(.unreadPatch, timeoutSeconds: 20) == "Obscura couldn't read a small spot in this picture. Check it in the viewer.")
        #expect(JournalFormat.uncheckedReason(.textNotRead, timeoutSeconds: 20) == "Part of it looks like text but couldn't be read.")
        #expect(SpotCopy.settledSummary([Self.spot].map { var s = $0; s.state = .notText; return s }) == "You said it isn't text")
    }

    @Test func aSpotRowIsListedApartAndSettlingItKeepsTheRecordWithUndo() async throws {
        let world = try await NotCheckedWorld()
        defer { world.tearDown() }
        let folder = world.root.appendingPathComponent("Downloads", isDirectory: true)
        let file = folder.appendingPathComponent("photo with a mark.png")
        try SampleData.terminalPNG(covered: false).write(to: file)
        _ = try await world.journal.recordUnchecked(path: file.path, origin: .downloads, reason: .unreadPatch, spots: [Self.spot])
        await world.engine.catalogueChanged()
        // The engine loaded its list once; a relaunch reads the new row.
        let engine = ShieldEngine(sources: [], recognizer: StubTextRecognizer(lines: []), journal: world.journal, settings: InMemorySettingsStore(.default),
                                  clock: SystemClock(), folderWatcher: nil, clipboardGuard: nil)
        let model = AppModel(engine: engine, journal: world.journal, settings: InMemorySettingsStore(.default), router: nil)
        model.start()
        defer { model.stop() }
        await engine.catalogueChanged()
        let expected = NotCheckedWorld.specs.count + 1
        #expect(await Fixtures.eventually { model.status.unchecked.count == expected })
        let row = try #require(model.status.unchecked.first { (f: UncheckedFile) in f.isUnreadSpots })
        #expect(row.pendingSpots == 1)
        let failures = model.status.problems.first { (p: Problem) in p.kind == .scanFailure }
        #expect(failures?.detail == String(NotCheckedWorld.specs.count), "the spot row is not counted with the alarms")

        let after = try #require(await model.settleSpots(row, .notText))
        #expect(after.settledAt != nil)
        #expect(model.toast?.text == "Marked as not text")
        let undo = try #require(model.toast?.undo)
        #expect(await Fixtures.eventually { !model.status.unchecked.contains { (f: UncheckedFile) in f.isUnreadSpots } })
        let record = await model.settledSpotFiles()
        #expect(record.map { (f: UncheckedFile) in f.id } == [row.id], "kept as the record")
        undo()
        let id = row.id
        #expect(await Fixtures.eventually { model.status.unchecked.contains { (f: UncheckedFile) in f.id == id && f.pendingSpots == 1 } })
        let back = await model.spotFile(id)
        #expect(back?.settledAt == nil)
    }

    @Test func theSectionDrawsTheSpotRowAndTheRecord() async throws {
        let world = try await NotCheckedWorld()
        defer { world.tearDown() }
        let host = NSHostingView(rootView: JournalNotChecked(controller: world.controller).frame(width: 760, height: 600))
        host.frame = CGRect(x: 0, y: 0, width: 760, height: 600)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
    }
}
