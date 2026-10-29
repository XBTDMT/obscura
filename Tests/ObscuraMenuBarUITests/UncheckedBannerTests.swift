// The "N images weren't checked" banner (menubar.html, the needs-attention tile): counted from the files the engine left
// without a verdict, OCR timeouts included; Check Again sends them all back through the engine; Open in Journal is the
// way out. Every file name here is made up.
import Foundation
import CoreGraphics
import Testing
import ObscuraUIKit
import ObscuraCapture
import ObscuraEngine
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSupport
@testable import ObscuraMenuBarUI

enum UncheckedData {
    static func file(_ name: String, reason: String = SkipReason.ocrTimeout.rawValue) -> UncheckedFile {
        let url = TestData.screenshots.appendingPathComponent(name)
        return UncheckedFile(key: CaptureKey(file: url), displayName: name, fileURL: url, origin: .screenshotFolder, reason: reason,
                             date: TestData.date(9, 40))
    }

    static func status(_ files: [UncheckedFile], failures: Int = 0) -> EngineStatus {
        let problem = Problem(kind: .scanFailure, messageKey: "problem.scan.failed", detail: String(files.count + failures))
        return EngineStatus(protection: .needsAttention(problems: [problem]), weekStats: TestData.week(), problems: [problem],
                            unchecked: files)
    }
}

@Suite struct UncheckedBannerTests {
    @Test func oneTimedOutFileIsNamedWithCheckAgainAndOpenInJournal() throws {
        let s = PanelSnapshot.make(TestData.inputs(status: UncheckedData.status([UncheckedData.file("IMG_0412.heic")])))
        let banner = try #require(s.banners.first)
        #expect(banner.tone == .needs)
        #expect(banner.title == "1 image wasn't checked")
        #expect(banner.body == "Reading IMG_0412.heic took longer than 20 s and was stopped. The file is untouched.")
        #expect(banner.emphasis == "IMG_0412.heic")
        #expect(banner.buttons.map(\.title) == ["Check Again", "Open in Journal"])
        #expect(banner.buttons.map(\.action) == [.checkAgain, .openJournalNotChecked])
        #expect(banner.buttons.map(\.role) == [.warn, .quiet], "the fix is the one orange button")
        #expect(s.header.title == "Needs attention")
        #expect(s.header.sentence == "1 image wasn't checked.")
    }

    @Test func severalTimeoutsAreCountedTogether() throws {
        let files = ["A.png", "B.png", "C.png"].map { UncheckedData.file($0) }
        let banner = try #require(PanelSnapshot.make(TestData.inputs(status: UncheckedData.status(files))).banners.first)
        #expect(banner.title == "3 images weren't checked")
        #expect(banner.body == "Reading them took longer than 20 s, so they were stopped. The files are untouched.")
        #expect(banner.emphasis == nil)
        #expect(banner.buttons.map(\.action) == [.checkAgain, .openJournalNotChecked])
    }

    @Test func anOCRFailureThatIsNotATimeoutSaysSo() throws {
        let file = UncheckedData.file("Report.png", reason: "ocrFailed")
        let banner = try #require(PanelSnapshot.make(TestData.inputs(status: UncheckedData.status([file]))).banners.first)
        #expect(banner.body == "Reading Report.png took longer than 20 s or failed, so it was stopped. The file is untouched.")
    }

    /// Fail-open #2: a file whose reading never started (it could not be opened, or a stage failed) is not described as
    /// "took longer or failed"; the words say it was left as it is, secret and all.
    @Test(arguments: ["renderFailed", "decodeFailed", "unreadable", "unsupportedImage", "tooLarge"])
    func aFileThatWasNotReadSaysItWasLeftAsItIs(_ reason: String) throws {
        let file = UncheckedData.file("Report.png", reason: reason)
        let banner = try #require(PanelSnapshot.make(TestData.inputs(status: UncheckedData.status([file]))).banners.first)
        #expect(banner.body == "Report.png couldn't be checked, so it was left as it is. Any secret in it is still there.")
        #expect(banner.emphasis == "Report.png")
        #expect(banner.buttons.map(\.action) == [.checkAgain, .openJournalNotChecked])
    }

    @Test func aTimeoutAndAFailureWithNoFileCountBoth() throws {
        let banner = try #require(PanelSnapshot.make(TestData.inputs(status: UncheckedData.status([UncheckedData.file("A.png")], failures: 1)))
            .banners.first)
        #expect(banner.title == "2 images weren't checked")
        #expect(banner.body == "They couldn't be checked, so they were left as they are. Any secret in them is still there.")
        #expect(banner.buttons.map(\.action) == [.checkAgain, .openJournalNotChecked])
    }

    /// Fail-open #13: a copied image with no file (a timeout, a failed read, a picture that would not open) is counted and
    /// described without claiming it was a file whose reading took too long.
    /// Fail-open #21: shots taken while protection was paused are listed after the resume, with Check Again.
    @Test func shotsTakenWhilePausedAreListedWithCheckAgain() throws {
        let one = try #require(PanelSnapshot.make(TestData.inputs(status: UncheckedData.status([UncheckedData.file("Paused.png", reason: "protectionPaused")])))
            .banners.first)
        #expect(one.title == "1 image wasn't checked")
        #expect(one.body == "Paused.png arrived while protection was paused, so it wasn't checked.")
        #expect(one.buttons.map(\.action) == [.checkAgain, .openJournalNotChecked])
        let two = try #require(PanelSnapshot.make(TestData.inputs(status: UncheckedData.status([UncheckedData.file("A.png", reason: "protectionPaused"),
                                                                                                UncheckedData.file("B.png", reason: "protectionPaused")])))
            .banners.first)
        #expect(two.body == "They arrived while protection was paused, so they weren't checked.")
    }

    @Test func aFailureWithNoFileToCheckAgainHasNoCheckAgain() throws {
        let banner = try #require(PanelSnapshot.make(TestData.inputs(status: UncheckedData.status([], failures: 1))).banners.first)
        #expect(banner.title == "1 image wasn't checked")
        #expect(banner.body == "An image couldn't be checked, so it was left as it is. Any secret in it is still there.")
        #expect(banner.buttons.map(\.action) == [.openJournal])
    }

    @Test func theTimeoutInTheWordsIsTheSettingsOwn() throws {
        let settings = TestData.settings { $0.ocrTimeoutSeconds = 30 }
        let banner = try #require(PanelSnapshot.make(TestData.inputs(status: UncheckedData.status([UncheckedData.file("A.png")]),
                                                                     settings: settings)).banners.first)
        #expect(banner.body.contains("30 s"))
    }
}

@MainActor
@Suite(.serialized) struct CheckAgainPanelTests {
    /// Times out the first `timeouts` reads, then reads the given lines.
    final class TimeoutThenRead: TextRecognizer, @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private let lines: [OCRLine]
        init(timeouts: Int, then lines: [OCRLine]) { remaining = timeouts; self.lines = lines }
        func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine] {
            let timeOut: Bool = lock.withLock { defer { remaining -= 1 }; return remaining > 0 }
            if timeOut { throw OCRError.timeout }
            return lines
        }
    }

    @Test func checkAgainFromTheBannerSendsTheTimedOutFileBackThroughTheEngine() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("obscura-checkagain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SQLiteJournalStore(root: root.appendingPathComponent("journal", isDirectory: true), ruleKeys: InMemoryRuleKeyStore(), clock: SystemClock())
        let store = InMemorySettingsStore(.default)
        let engine = ShieldEngine(sources: [], recognizer: TimeoutThenRead(timeouts: 1, then: [PanelModelTests.keyLine]), journal: journal,
                                  settings: store, clock: SystemClock(), folderWatcher: nil, clipboardGuard: nil)
        let router = RecordingRouter()
        let model = AppModel(engine: engine, journal: journal, settings: store, router: router)
        let memory = TestData.memory(now: Date().addingTimeInterval(-3600))
        PanelMemory.register(memory, for: model)
        model.start()
        defer { model.stop() }

        let file = root.appendingPathComponent("Screenshot 2026-10-26 at 9.44.08 AM.png")
        try SampleData.terminalPNG(covered: false).write(to: file)
        await engine.submit(.file(file, origin: .imported))
        #expect(await eventually { model.status.unchecked.count == 1 }, "the timed-out file is kept as unchecked")

        let snapshot = PanelSnapshot.make(MenuBarPanel.inputs(model: model, memory: memory, now: Date()))
        let banner = try #require(snapshot.banners.first { $0.title == "1 image wasn't checked" })
        #expect(banner.emphasis == file.lastPathComponent)
        let checkAgain = try #require(banner.buttons.first { $0.title == "Check Again" })

        let performer = PanelActionPerformer(model: model, memory: memory)
        await performer.perform(checkAgain.action)
        #expect(await eventually { model.status.unchecked.isEmpty && !model.status.problems.contains { $0.kind == .scanFailure } },
                "checked again, the file reached a verdict and the banner is gone")
        #expect(await eventually { model.entries.count == 1 }, "the second read found the key and made a Journal entry")
        #expect(PanelSnapshot.make(MenuBarPanel.inputs(model: model, memory: memory, now: Date())).banners.isEmpty)

        let journalButton = try #require(banner.buttons.first { $0.title == "Open in Journal" })
        await performer.perform(journalButton.action)
        #expect(router.calls == ["journal:notChecked"], "Open in Journal lands on the Not checked section (G-13)")
    }

    @Test func checkAgainWithNoEngineSendsNothing() async throws {
        let model = AppModel(engine: nil, journal: try SampleData.makeJournal(), settings: InMemorySettingsStore(.default))
        #expect(await model.checkAgain() == 0)
    }
}
