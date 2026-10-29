import CoreGraphics
import Foundation
import Testing
import ObscuraJournal
import ObscuraPrefs
@testable import ObscuraUIKit

/// G-19 #11: Undo acts at once by default; with `Settings.confirmsUndo` every surface's Undo asks first.
@Suite @MainActor struct UndoConfirmationTests {
    /// Records each question and answers with `answer`.
    final class Asker {
        var asked: [UndoConfirmation] = []
        var answer: Bool
        init(answer: Bool) { self.answer = answer }
    }

    static func entry(source: EntrySource = .file, cleanCopy: Bool = false, detectors: [String]) -> Entry {
        let id = UUID()
        let findings = detectors.enumerated().map { i, d in
            Finding(id: UUID(), entryID: id, lineIndex: i, rect: CGRect(x: 10, y: 10 + 30 * i, width: 200, height: 24),
                    detectorIDs: [d], category: "payments", enabled: true)
        }
        return Entry(id: id, createdAt: Date(), source: source, displayName: "Screenshot.png",
                     filePath: source == .clipboard ? nil : "/home/example/Desktop/Screenshot.png",
                     cleanCopyPath: cleanCopy ? "/home/example/Desktop/Screenshot (clean).png" : nil,
                     containerUTI: "public.png", pixelWidth: 480, pixelHeight: 120, revision: 1, style: StyleRecord(),
                     trashedAt: nil, findings: findings)
    }

    @Test func theDefaultActsAtOnceWithoutAsking() async throws {
        let model = try await SampleData.model(entries: 1)
        let asker = Asker(answer: false)
        model.confirmUndo = { request in asker.asked.append(request); return asker.answer }
        #expect(Settings.default.confirmsUndo == false)
        #expect(!UndoConfirmation.isRequired(model.settings))
        let id = try #require(model.entries.first?.id)
        #expect(await model.mayUndo([id]))
        #expect(asker.asked.isEmpty)
    }

    @Test func withTheSettingEveryUndoAsksAndCancelStopsIt() async throws {
        var settings = Settings.default
        settings.confirmsUndo = true
        let model = try await SampleData.model(entries: 2, settings: settings)
        let asker = Asker(answer: false)
        model.confirmUndo = { request in asker.asked.append(request); return asker.answer }
        let id = try #require(model.entries.first?.id)

        #expect(await model.undo(id) == false, "a cancelled Undo does nothing")
        #expect(asker.asked.count == 1)
        #expect(asker.asked.first?.title == "Show the original?")
        #expect(asker.asked.first?.confirmTitle == "Undo" && asker.asked.first?.cancelTitle == "Cancel")

        asker.answer = true
        #expect(await model.mayUndo([id]))
        #expect(asker.asked.count == 2)

        // A selection is one question.
        #expect(await model.mayUndo(model.entries.map(\.id)))
        #expect(asker.asked.count == 3)
        #expect(asker.asked.last?.title == "Show 2 originals?")
    }

    @Test func nothingToAskWithActsAtOnce() async throws {
        var settings = Settings.default
        settings.confirmsUndo = true
        let model = try await SampleData.model(entries: 1, settings: settings)
        #expect(await model.mayUndo([try #require(model.entries.first?.id)]))
    }

    @Test func theWordsNameTheSecretAndWhereTheOriginalGoes() {
        let one = UndoConfirmation(entries: [Self.entry(detectors: ["payments.stripe.secretkey"])])
        #expect(one.message == "The \(DetectorNames.title(for: "payments.stripe.secretkey")) will be visible in the file.")
        let several = UndoConfirmation(entries: [Self.entry(detectors: ["payments.stripe.secretkey", "personal.email.address"])])
        #expect(several.message == "2 secrets will be visible in the file.")
        let clipboard = UndoConfirmation(entries: [Self.entry(source: .clipboard, detectors: ["payments.stripe.secretkey", "ai.openai.apikey"])])
        #expect(clipboard.message == "2 secrets will be visible on the clipboard.")
        let keepBoth = UndoConfirmation(entries: [Self.entry(cleanCopy: true, detectors: ["payments.stripe.secretkey", "ai.openai.apikey"])])
        #expect(keepBoth.message == "2 secrets will be visible in the clean copy.")
        let many = UndoConfirmation(entries: [Self.entry(detectors: ["a"]), Self.entry(detectors: ["b"]), Self.entry(detectors: ["c"])])
        #expect(many.title == "Show 3 originals?")
    }
}
