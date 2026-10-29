// Fail-open #11: the "Old originals weren't all deleted" banner, with Try Again (the upkeep runs now) and Open in Journal.
import Foundation
import Testing
import ObscuraUIKit
import ObscuraEngine
@testable import ObscuraMenuBarUI

@Suite struct MaintenanceBannerTests {
    @Test func aMaintenanceFailureIsANeedsAttentionBannerWithTryAgain() throws {
        let problem = Problem(kind: .journalMaintenance, messageKey: "problem.journal.maintenance", detail: "prune")
        let status = EngineStatus(protection: .needsAttention(problems: [problem]), weekStats: TestData.week(), problems: [problem])
        let s = PanelSnapshot.make(TestData.inputs(status: status))
        let banner = try #require(s.banners.first)
        #expect(banner.title == "Old originals weren't all deleted")
        #expect(banner.buttons.map(\.action) == [.retryMaintenance, .openJournal])
        #expect(banner.buttons.map(\.role) == [.warn, .quiet])
        #expect(s.header.title == "Needs attention")
        #expect(PanelPresentation.closeTiming(for: .retryMaintenance) == .never)
    }
}
