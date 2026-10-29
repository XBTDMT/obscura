// G-40: spots no reading could read wait in the panel as a quiet row (plain words, the accent tone, Review…), never the
// orange "weren't checked" alarm, and never "needs attention". A picture Vision answered with no text outside that case
// keeps its alarm, in true words. Every file name here is made up.
import Foundation
import CoreGraphics
import Testing
import ObscuraUIKit
import ObscuraCapture
import ObscuraEngine
import ObscuraJournal
import ObscuraPrefs
@testable import ObscuraMenuBarUI

@Suite struct UnreadSpotsPanelTests {
    static let spot = SpotRecord(rect: CGRect(x: 10, y: 10, width: 40, height: 8), coverRect: CGRect(x: 2, y: 2, width: 66, height: 30), state: .pending)

    static func spotFile(_ name: String, spots: Int = 1) -> UncheckedFile {
        let url = TestData.screenshots.appendingPathComponent(name)
        return UncheckedFile(key: CaptureKey(file: url), displayName: name, fileURL: url, origin: .downloads, reason: SkipReason.unreadPatch.rawValue,
                             date: TestData.date(9, 40), spots: Array(repeating: spot, count: spots))
    }

    static func status(_ files: [UncheckedFile]) -> EngineStatus {
        let n = files.reduce(0) { $0 + $1.pendingSpots }
        let problem = Problem(kind: .unreadSpots, messageKey: ShieldEngine.unreadSpotsKey, url: files.first?.fileURL, detail: String(n))
        return EngineStatus(protection: .protected, weekStats: TestData.week(), problems: [problem], unchecked: files)
    }

    @Test func oneSpotIsAQuietRowWithReview() throws {
        let file = Self.spotFile("Photo.png")
        let s = PanelSnapshot.make(TestData.inputs(status: Self.status([file])))
        let banner = try #require(s.banners.first)
        #expect(banner.tone == .accent, "never the orange alarm")
        #expect(banner.title == "1 spot couldn't be read")
        #expect(banner.body == "Obscura couldn't read a small spot in Photo.png. Check it in the viewer.")
        #expect(banner.emphasis == "Photo.png")
        #expect(banner.buttons.map(\.title) == ["Review…", "Open in Journal"])
        #expect(banner.buttons.map(\.action) == [.reviewSpots(file.id), .openJournalNotChecked])
        #expect(s.header.tone == .ok, "protection is not \"needs attention\"")
    }

    @Test func severalSpotsAndFilesAreCountedTogether() throws {
        let files = [Self.spotFile("A.png", spots: 2), Self.spotFile("B.png")]
        let banner = try #require(PanelSnapshot.make(TestData.inputs(status: Self.status(files))).banners.first)
        #expect(banner.title == "3 spots couldn't be read")
        #expect(banner.body == "Obscura couldn't read small spots in 2 images. Check them in the viewer.")
        #expect(banner.emphasis == nil)
    }

    @MainActor @Test func reviewClosesThePanelFirstAndOpensTheSpotViewer() async throws {
        #expect(PanelPresentation.closeTiming(for: .reviewSpots(UUID())) == .beforePerforming)
        let router = RecordingRouter()
        let model = try await SampleData.model(entries: 0, settings: .default)
        model.router = router
        let id = UUID()
        await PanelActionPerformer(model: model, memory: PanelMemory()).perform(.reviewSpots(id))
        #expect(router.calls == ["spots:\(id.uuidString)"])
    }

    @Test func textVisionDidNotReadOutsideTheCaseKeepsItsAlarmInTrueWords() throws {
        let file = UncheckedData.file("Report.png", reason: SkipReason.textNotRead.rawValue)
        let banner = try #require(PanelSnapshot.make(TestData.inputs(status: UncheckedData.status([file]))).banners.first)
        #expect(banner.tone == .needs)
        #expect(banner.body == "Part of Report.png looks like text but couldn't be read. The file is untouched.")
    }
}
