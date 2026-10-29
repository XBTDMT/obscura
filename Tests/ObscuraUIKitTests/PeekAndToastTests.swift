import SwiftUI
import Testing
@testable import ObscuraUIKit

/// T-2: the one hold-to-peek rule. A click or a double-click never shows the original; a deliberate hold does.
@MainActor
@Suite struct HoldToPeekTests {
    final class Log { var begins = 0; var ends = 0 }

    func make(_ delay: Duration = .milliseconds(80)) -> (HoldToPeek, Log) {
        let log = Log()
        let hold = HoldToPeek(delay: delay, onBegin: { log.begins += 1 }, onEnd: { log.ends += 1 })
        return (hold, log)
    }

    @Test func everySurfaceWaitsTheViewersThreeHundredFiftyMilliseconds() {
        #expect(HoldToPeek.delay == .milliseconds(350))
    }

    @Test func aClickNeverPeeks() async throws {
        let (hold, log) = make()
        hold.pressBegan()
        #expect(hold.pressEnded() == false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(log.begins == 0 && log.ends == 0 && !hold.isPeeking)
    }

    @Test func aDoubleClickNeverPeeks() async throws {
        let (hold, log) = make()
        hold.pressBegan(); hold.pressEnded()
        try await Task.sleep(for: .milliseconds(30))
        hold.pressBegan(); hold.pressEnded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(log.begins == 0 && !hold.isPeeking)
    }

    @Test func aHoldPeeksAfterTheDelayAndTheReleaseEndsIt() async throws {
        let (hold, log) = make()
        hold.pressBegan()
        try await Task.sleep(for: .milliseconds(20))
        #expect(log.begins == 0)
        try await Task.sleep(for: .milliseconds(250))
        #expect(log.begins == 1 && hold.isPeeking)
        #expect(hold.pressEnded() == true)
        #expect(log.ends == 1 && !hold.isPeeking)
    }

    @Test func aDragCancelsThePeek() async throws {
        let (hold, log) = make()
        hold.pressBegan()
        hold.cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(log.begins == 0)
        #expect(hold.pressEnded() == false && log.ends == 0)
    }
}

/// S-13, S-14, T-6: one toast lifetime, one place per surface, and a model toast never waits for a surface to open.
@MainActor
@Suite struct ToastTests {
    @Test func everyToastLivesTheSameTime() async throws {
        let model = try await SampleData.model(entries: 1)
        #expect(model.toastLifetime == .seconds(OMotion.toastSeconds))
    }

    @Test func aModelToastClearsItselfWhetherOrNotAnythingShowedIt() async throws {
        let model = try await SampleData.model(entries: 2)
        model.toastLifetime = .milliseconds(80)
        let id = try #require(model.entries.first?.id)
        await model.trash([id])                      // the thumbnail's Delete with no window or panel open
        #expect(model.toast != nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.toast == nil)                  // nothing left to pop up when the panel next opens
    }

    @Test func aNewerToastGetsItsOwnLifetime() async throws {
        let model = try await SampleData.model(entries: 1)
        model.toastLifetime = .milliseconds(200)
        model.toast = ToastMessage(text: "first")
        try await Task.sleep(for: .milliseconds(120))
        model.toast = ToastMessage(text: "second")
        try await Task.sleep(for: .milliseconds(120))
        #expect(model.toast?.text == "second")       // the first one's timer did not clear the second
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.toast == nil)
    }

    @Test func rewordingAToastKeepsItsLifetime() async throws {
        let model = try await SampleData.model(entries: 1)
        model.toastLifetime = .milliseconds(150)
        model.toast = ToastMessage(text: "Clean copy is on the clipboard.")
        model.toast?.text = "Copied as shown."       // the Journal rewords a copy toast; same toast, same timer
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.toast == nil)
    }

    @Test func aModelToastShowsItsUndoAsUndo() {
        let item = ToastMessage(text: "Screenshot deleted", undo: {}).item
        #expect(item.actionTitle == "Undo" && item.action != nil)
        #expect(ToastMessage(text: "Clean copy is on the clipboard.").item.actionTitle == nil)
    }

    @Test func eachSurfaceHasOnePlace() {
        #expect(ToastPlacement.ladder.alignment == .topTrailing)
        #expect(ToastPlacement.bottom.alignment == .bottom)
    }

    @Test func theRingTurnsAtTheDesignsPaceAndPlaceholdersWait() {
        #expect(OMotion.spinnerPeriod == 1.1)
        #expect(OMotion.progressDelay > OMotion.fadeDuration)
    }
}
