// Fail-open #7: the "N files still show secrets" banner, from the engine's persisted list of files the covered picture
// could not be written to. Try Again writes them again; Open in Journal goes to the Not covered on disk section. Every
// file name here is made up.
import Foundation
import Testing
import ObscuraUIKit
import ObscuraEngine
import ObscuraJournal
import ObscuraPrefs
@testable import ObscuraMenuBarUI

@Suite struct NotCoveredBannerTests {
    private static func status(_ n: Int) -> EngineStatus {
        let files = (0..<n).map { i in
            UncoveredFile(UncoveredRecord(id: UUID(), filePath: "/home/example/Desktop/Shot \(i).png", sourcePath: "/home/example/Desktop/Shot \(i).png",
                                          entryID: UUID(), firstSeen: TestData.date(9, 40), lastSeen: TestData.date(9, 40), attempts: 1))
        }
        let problem = Problem(kind: .notCovered, messageKey: "problem.disk.notCovered", detail: String(n))
        return EngineStatus(protection: .needsAttention(problems: [problem]), weekStats: TestData.week(), problems: [problem], uncovered: files)
    }

    @Test func oneFileThatStillShowsASecretHasTryAgainAndOpenInJournal() throws {
        let s = PanelSnapshot.make(TestData.inputs(status: Self.status(1)))
        let banner = try #require(s.banners.first)
        #expect(banner.tone == .needs)
        #expect(banner.title == "1 file still shows a secret")
        #expect(banner.buttons.map(\.action) == [.retryNotCovered, .openJournalNotCovered])
        #expect(banner.buttons.map(\.role) == [.warn, .quiet], "the fix is the one orange button")
        #expect(s.header.title == "Needs attention")
        #expect(s.header.sentence == "1 file still shows a secret.")
    }

    @Test func severalAreCountedAndOnlyTheJournalActionClosesThePanel() throws {
        let banner = try #require(PanelSnapshot.make(TestData.inputs(status: Self.status(3))).banners.first)
        #expect(banner.title == "3 files still show secrets")
        #expect(PanelPresentation.closeTiming(for: .openJournalNotCovered) == .beforePerforming)
        #expect(PanelPresentation.closeTiming(for: .retryNotCovered) == .never)
    }

    @Test @MainActor func openInJournalGoesToTheNotCoveredSection() async throws {
        let router = RecordingRouter()
        let model = AppModel(engine: nil, journal: try SampleData.makeJournal(), settings: InMemorySettingsStore(.default), router: router)
        await PanelActionPerformer(model: model, memory: TestData.memory(now: Date())).perform(.openJournalNotCovered)
        #expect(router.calls == ["journal:notCovered"])
    }
}
