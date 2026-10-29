// G-24: the read-only debug report and the Spotlight result activity.
import CoreSpotlight
import Foundation
import Testing
import ObscuraJournal
@testable import ObscuraSearch

@Suite struct SearchReportTests {
    @Test func theReaderIsReadOnlyAndMatchesTheStore() async throws {
        let h = try SearchHarness(); defer { h.tearDown() }
        let missing = h.dir.appendingPathComponent("nothing-here", isDirectory: true)
        #expect(try CoveredFilesReader.read(root: missing).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.path), "reading creates nothing")
        let (entry, file) = try await h.catchFile()
        await h.coordinator.caught(entryID: entry.id, coveredFile: file, findings: entry.findings, isScreenshot: true,
                                   titles: SearchFixture.titles, switches: on)
        let records = try CoveredFilesReader.read(root: h.dir.appendingPathComponent("store", isDirectory: true))
        #expect(records == (try await h.journal.coveredFiles()))
        let report = SearchReport.make(records: records)
        #expect(report.records == 1 && report.taggedIDs == [entry.id.uuidString] && report.spotlightIDs == nil)
    }

    @Test func aFileOnADiskThatIsNotConnectedIsNotGone() async throws {
        let h = try SearchHarness(); defer { h.tearDown() }
        let away = CoveredFileRecord(id: UUID(), filePath: "/Volumes/Obscura-Test-Disk-\(UUID().uuidString)/Screenshot.png", bookmark: nil,
                                     detectorIDs: ["ai.anthropic.api_key"], categories: ["ai"], isScreenshot: true,
                                     caughtAt: Date(), updatedAt: Date())
        try await h.journal.upsertCoveredFile(away)
        #expect(SearchCoordinator.isOnUnmountedVolume(away.filePath))
        #expect(!SearchCoordinator.isOnUnmountedVolume("/home/x/Desktop/a.png"))
        #expect(await h.coordinator.reconcile(full: false, titles: SearchFixture.titles, switches: spotlightOnly) == 0)
        #expect(try await h.journal.coveredFiles().map(\.id) == [away.id])
    }

    @Test func aSpotlightActivityNamesItsEntry() {
        let id = UUID().uuidString
        #expect(SearchResultActivity.identifier(activityType: CSSearchableItemActionType, userInfo: [CSSearchableItemActivityIdentifier: id]) == id)
        #expect(SearchResultActivity.identifier(activityType: "com.example.other", userInfo: [CSSearchableItemActivityIdentifier: id]) == nil)
        #expect(SearchResultActivity.identifier(activityType: CSSearchableItemActionType, userInfo: nil) == nil)
    }
}
