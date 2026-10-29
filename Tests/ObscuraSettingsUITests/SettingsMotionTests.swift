import Foundation
import Testing
@testable import ObscuraSettingsUI
import ObscuraJournal
import ObscuraUIKit

// Recon B-6 motion fixes in Settings (knowledge/recon/motion-2026-10-27/FIXES-in-window.md): T-14, T-15, the notice
// toast (T-5, T-6).
@Suite @MainActor struct SettingsMotionTests {
    /// T-14: while the write is in flight the switch shows the value it was flipped to, so the knob moves once.
    @Test func aFlippedSwitchShowsItsNewValueUntilTheWriteLands() {
        #expect(AsyncSwitch.shown(stored: false, pending: true) == true)
        #expect(AsyncSwitch.shown(stored: true, pending: false) == false)
        #expect(AsyncSwitch.shown(stored: true, pending: nil) == true)    // landed (or failed): the store decides
    }

    /// T-15: saving the first rule puts it in the list synchronously, in the same frame the editor closes, so the
    /// "no rules" empty state is never drawn in between; the store write follows.
    @Test func savingARuleChangesTheListBeforeTheWrite() async throws {
        let journal = try SampleData.makeJournal()
        let session = SettingsSession(journal: journal)
        await session.load()
        #expect(session.rules.isEmpty)
        let staged = session.stageRule(RuleRecord(action: .blackOut, kind: .exactText, value: "CUS-004213", createdAt: Date(), sortOrder: 0))
        #expect(session.rules.map(\.value) == ["CUS-004213"])           // no await happened yet
        await session.storeRule(staged)
        #expect(try await journal.rules().map { $0.readable?.value } == ["CUS-004213"])

        session.stageDeletion(staged.id)
        #expect(session.rules.isEmpty)
        await session.storeDeletion(staged.id)
        #expect(try await journal.rules().isEmpty)
    }

    /// Each notice is a new toast with its own lifetime, even when the same words come again.
    @Test func eachNoticeIsANewToast() async throws {
        let session = SettingsSession(journal: try SampleData.makeJournal())
        session.notice = "Couldn’t export your rules."
        let first = session.noticeID
        session.notice = nil
        session.notice = "Couldn’t export your rules."
        #expect(session.noticeID != first)
    }
}
