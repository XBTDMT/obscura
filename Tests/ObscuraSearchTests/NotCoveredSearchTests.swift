// G-28 / fail-open #7: a covered file the Journal lists as not covered on disk (a write that did not land) shows what was
// caught, so no "covered" Spotlight item, thumbnail or tag is published for it, whatever its record last said.
import Foundation
import Testing
import ObscuraJournal
import ObscuraSupport
@testable import ObscuraSearch

@Suite(.serialized) struct NotCoveredSearchTests {
    @Test func aFileListedAsNotCoveredOnDiskGetsNoItemNoThumbnailAndNoTagsUntilSettled() async throws {
        let h = try SearchHarness(); defer { h.tearDown() }
        let (entry, file) = try await h.catchFile()
        await h.coordinator.caught(entryID: entry.id, coveredFile: file, findings: entry.findings, isScreenshot: true,
                                   titles: SearchFixture.titles, switches: on)
        #expect(await h.index.items[entry.id.uuidString] != nil)

        _ = try await h.journal.recordUncovered(path: file.standardizedFileURL.path, sourcePath: file.standardizedFileURL.path, entryID: entry.id)
        await h.coordinator.reconcile(full: true, titles: SearchFixture.titles, switches: on)
        #expect(await h.index.items[entry.id.uuidString] == nil, "no item (and so no thumbnail) for a file that shows the secret")
        #expect(try FinderTagFiles().tags(of: file).isEmpty, "no 'covered' tags on it either")
        #expect(try await h.journal.coveredFile(entry.id)?.covered == true, "the record stays for when the write lands")

        try await h.journal.clearUncovered(path: file.standardizedFileURL.path)
        await h.coordinator.reconcile(full: true, titles: SearchFixture.titles, switches: on)
        #expect(await h.index.items[entry.id.uuidString] != nil)
    }
}
