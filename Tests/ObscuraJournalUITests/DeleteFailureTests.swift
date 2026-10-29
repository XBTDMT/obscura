// Fail-open #12: "Screenshot deleted" (with Undo) used to show even when the Journal's trash failed, and a failed restore
// was silent. Now the toast says what was really deleted or restored, read back from the Journal, and a failure is an
// error with nothing to undo.
import Foundation
import Testing
import ObscuraUIKit
import ObscuraJournal
@testable import ObscuraJournalUI

@Suite(.serialized) @MainActor struct DeleteFailureTests {
    private static func imagesFolder(_ model: AppModel) throws -> URL {
        try #require((model.journal as? SQLiteJournalStore)?.journalRoot)
    }

    @Test func aDeleteThatFailsIsAnErrorWithNoUndoAndNothingIsSaidDeleted() async throws {
        let (model, controller) = try await Fixtures.sampleController()
        let images = try Self.imagesFolder(model)
        let id = try #require(model.entries.first?.id)
        // The images folder will not let an entry's folder move to the trash.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: images.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: images.path) }

        await controller.delete([id])
        #expect(model.entries.count == 6, "nothing was deleted")
        let toast = try #require(controller.ladder.first)
        #expect(toast.text == "Couldn't delete the screenshot.")
        #expect(toast.isError)
        #expect(toast.undo == nil, "nothing to undo")
        #expect(!controller.ladder.contains { $0.text.contains("deleted") && !$0.isError })
    }

    @Test func aPartlyFailedDeleteSaysHowManyAndUndoBringsBackOnlyThose() async throws {
        let model = try await SampleData.model()
        let real = try #require(model.entries.first?.id)
        let unknown = UUID()
        let done = await model.trash([real, unknown])
        #expect(done == [real])
        #expect(model.toast?.text == "Deleted 1 of 2. 1 couldn't be deleted.")
        #expect(model.toast?.isError == true)
        #expect(model.toast?.undo != nil)
        #expect(await model.restore([real]) == [real])
        #expect(model.entries.count == 6)
    }

    @Test func aRestoreThatFailsSaysSo() async throws {
        let model = try await SampleData.model()
        let id = try #require(model.entries.first?.id)
        #expect(await model.trash([id]) == [id])
        model.toast = nil
        let images = try Self.imagesFolder(model)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: images.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: images.path) }
        #expect(await model.restore([id]).isEmpty)
        #expect(model.toast?.text == "Couldn't restore the screenshot.")
        #expect(model.toast?.isError == true)
        #expect(!model.entries.contains { $0.id == id })
    }
}
