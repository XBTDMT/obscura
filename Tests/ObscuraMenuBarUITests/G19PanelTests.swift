import AppKit
import Foundation
import SwiftUI
import Testing
import ObscuraEngine
import ObscuraPrefs
import ObscuraUIKit
@testable import ObscuraMenuBarUI

/// G-19 in the panel: Paused shows red by default (#17), the setup card while setup is unfinished (M-19), the pause
/// choices' trigger (M-15a) and the reserved badge width (S-12).
@Suite struct G19PanelSnapshotTests {
    static let paused = EngineStatus(protection: .paused)

    @Test func pausedIsRedByDefault() throws {
        let s = PanelSnapshot.make(TestData.inputs(status: Self.paused, pause: PauseState(since: TestData.date(9, 30), resumesAt: nil)))
        #expect(s.header.tone == .live && !s.header.halo)
        #expect(try #require(s.paused).tone == .live)
    }

    @Test(arguments: [(PausedColor.orange, Tone.needs), (.grey, .quiet), (.red, .live)])
    func pausedFollowsTheColourSetting(_ colour: PausedColor, _ tone: Tone) throws {
        let s = PanelSnapshot.make(TestData.inputs(status: Self.paused, settings: TestData.settings { $0.pausedColor = colour }))
        #expect(s.header.tone == tone)
        #expect(try #require(s.paused).tone == tone)
    }

    @Test func anUnfinishedSetupShowsTheDesignedCard() throws {
        let settings = TestData.settings { $0.hasFinishedSetup = false }
        var input = TestData.inputs(entries: [], settings: settings)
        input.setup = SetupSummary(done: 4, total: 8, next: "Floating thumbnail")
        let s = PanelSnapshot.make(input)
        let card = try #require(s.setup)
        #expect(card.title == "Setup · 4 of 8 done")
        #expect(card.remaining == "4 left")
        #expect(card.progress == 0.5)
        #expect(card.next == "Next: Floating thumbnail")
        #expect(card.button.title == "Continue setup" && card.button.role == .primary && card.button.action == .openSetup)
        // The card carries Continue setup, so the menu has no second way to say it; a finished setup's row comes back.
        #expect(!s.menuTitles.contains("Continue Setup…") && !s.menuTitles.contains("Setup…"))
    }

    @Test func theCardWithoutAKnownCountSaysSoWithoutGuessing() throws {
        let s = PanelSnapshot.make(TestData.inputs(entries: [], settings: TestData.settings { $0.hasFinishedSetup = false }))
        let card = try #require(s.setup)
        #expect(card.title == "Setup is not finished")
        #expect(card.progress == nil && card.remaining == nil && card.next == nil)
        #expect(card.button.action == .openSetup)
    }

    @Test func oneStepLeftAndOutOfRangeCountsAreClamped() throws {
        var input = TestData.inputs(entries: [], settings: TestData.settings { $0.hasFinishedSetup = false })
        input.setup = SetupSummary(done: 7, total: 8, next: "Done")
        #expect(PanelSnapshot.make(input).setup?.remaining == "1 left")
        input.setup = SetupSummary(done: 11, total: 8, next: nil)
        let card = try #require(PanelSnapshot.make(input).setup)
        #expect(card.title == "Setup · 8 of 8 done" && card.progress == 1 && card.remaining == "0 left" && card.next == nil)
    }

    @Test func aFinishedSetupHasNoCardAndKeepsTheSetupRow() {
        var input = TestData.inputs()
        input.setup = SetupSummary(done: 8, total: 8, next: nil)
        let s = PanelSnapshot.make(input)
        #expect(s.setup == nil)
        #expect(s.menuTitles.contains("Setup…"))
    }

    /// A catch made before setup finished keeps its card (and its Undo) under the setup card.
    @Test func aCatchDuringSetupIsStillReachable() {
        let s = PanelSnapshot.make(TestData.inputs(settings: TestData.settings { $0.hasFinishedSetup = false }))
        #expect(s.setup != nil)
        #expect(s.lastCatch != nil)
    }
}

@Suite struct PauseChoicesPresentationTests {
    @Test func hoverModeOpensOnHoverAndClosesOnlyAfterTheGrace() {
        var p = PauseChoicesPresentation(trigger: .hover)
        #expect(Settings.default.pauseChoicesOpen == .hover)
        #expect(p.rowHover(true) == false)
        #expect(p.isOpen, "resting on the row opens the choices")
        // Row → pop: the pop is entered before the grace ends, so nothing closes.
        #expect(p.rowHover(false) == true, "leaving the row starts the grace")
        #expect(p.popHover(true) == false)
        p.graceEnded()
        #expect(p.isOpen)
        // Out of both: the grace closes it.
        #expect(p.popHover(false) == true)
        p.graceEnded()
        #expect(!p.isOpen)
    }

    @Test func comingBackWithinTheGraceKeepsItOpen() {
        var p = PauseChoicesPresentation(trigger: .hover)
        p.rowHover(true)
        p.rowHover(false)
        p.rowHover(true)
        p.graceEnded()
        #expect(p.isOpen)
    }

    @Test func clickModeIgnoresHover() {
        var p = PauseChoicesPresentation(trigger: .click)
        #expect(p.rowHover(true) == false)
        #expect(!p.isOpen, "click only: resting on the row does nothing")
        p.rowClicked()
        #expect(p.isOpen)
        #expect(p.rowHover(false) == false, "leaving never closes a click-opened pop")
        p.graceEnded()
        #expect(p.isOpen)
        p.rowClicked()
        #expect(!p.isOpen, "a second click closes it")
    }

    @Test func aClickWorksInHoverModeTooAndChoosingCloses() {
        var p = PauseChoicesPresentation(trigger: .hover)
        p.rowClicked()
        #expect(p.isOpen)
        p.chose()
        #expect(!p.isOpen)
    }

    @Test func escapeClosesThePopFirst() {
        var p = PauseChoicesPresentation(trigger: .hover)
        #expect(p.escape() == false, "nothing open: Escape goes to the panel")
        p.rowHover(true)
        #expect(p.escape() == true)
        #expect(!p.isOpen)
        p.rowClicked()
        p.reset(trigger: .click)
        #expect(!p.isOpen && p.trigger == .click)
    }

    @Test @MainActor func thePanelMemoryHandsEscapeToTheChoices() {
        let memory = TestData.memory()
        #expect(memory.consumeEscape() == false)
        memory.pauseChoices.rowClicked()
        #expect(memory.consumeEscape() == true)
        #expect(!memory.pauseChoices.isOpen)
    }
}

@Suite @MainActor struct BadgeReservationTests {
    @Test func theSpaceIsReservedOnlyInPanelOnlyModeAndOnlyWhenAsked() {
        var s = Settings.default
        #expect(!MenuBarLabel.reservesBadgeSpace(s), "off by default: let it grow")
        s.reservesBadgeSpace = true
        #expect(!MenuBarLabel.reservesBadgeSpace(s), "with notifications on no badge ever shows")
        s.showsNotifications = false
        #expect(MenuBarLabel.reservesBadgeSpace(s))
    }

    @Test func thePresenterDrawsTheReservedWidth() async throws {
        var settings = Settings.default
        settings.showsNotifications = false
        let model = try await SampleData.model(entries: 0, settings: settings)
        let presenter = MenuBarMarkPresenter(model: model, memory: TestData.memory(), clock: { TestData.now }, busy: { false },
                                             reduceMotion: { true }, schedulesTimers: false)
        #expect(presenter.image.size.width == 18)
        model.updateSettings { $0.reservesBadgeSpace = true }
        presenter.refresh()
        #expect(presenter.image.size.width == ObscuraMarkDrawing.badgedWidth)
    }
}

/// G-19 #11 from the panel: its Undo goes through the confirm-before-Undo gate.
@Suite @MainActor struct PanelUndoConfirmationTests {
    @Test func thePanelsUndoAsksWhenTheSettingIsOn() async throws {
        let store = InMemorySettingsStore(TestData.settings { $0.confirmsUndo = true })
        let model = AppModel(engine: nil, journal: try SampleData.makeJournal(), settings: store, router: RecordingRouter(), ownsRouter: true)
        var asked = 0
        model.confirmUndo = { _ in asked += 1; return false }
        let performer = PanelActionPerformer(model: model, memory: TestData.memory(), calendar: TestData.calendar)
        await performer.perform(.undo(UUID()))
        #expect(asked == 1)
    }
}

/// The new panel pieces drawn: the setup card, red Paused, the pause choices open, and the two waiting marks.
@Suite(.serialized) @MainActor struct G19PanelRenderTests {
    @Test func theNewPanelStatesRender() throws {
        var setupInput = TestData.inputs(entries: [], settings: TestData.settings { $0.hasFinishedSetup = false })
        setupInput.setup = SetupSummary(done: 4, total: 8, next: "Floating thumbnail")
        let paused = TestData.inputs(status: EngineStatus(protection: .paused), pause: PauseState(since: TestData.date(9, 30), resumesAt: nil))
        var open = PauseChoicesPresentation(trigger: .click)
        open.rowClicked()
        let cases: [(String, PanelInputs, PauseChoicesPresentation)] = [
            ("g19-setup-card", setupInput, PauseChoicesPresentation(trigger: .hover)),
            ("g19-paused-red", paused, PauseChoicesPresentation(trigger: .hover)),
            ("g19-pause-choices-open", TestData.inputs(), open),
        ]
        for (name, input, choices) in cases {
            for scheme in [ColorScheme.light, .dark] {
                let view = PanelContent(snapshot: PanelSnapshot.make(input), perform: { _ in }, loadThumbnail: { _ in nil },
                                        pauseChoices: .constant(choices))
                let image = try #require(PanelRenderTests.render(view, scheme: scheme))
                #expect(image.size.width == OMetric.menuBarPanelWidth)
                try PanelRenderTests.write(image, name: "\(name)-\(scheme == .dark ? "dark" : "light")")
            }
        }
        try PanelRenderTests.write(ObscuraMarkDrawing.menuBarImage(.focusHolding, pointSize: 36, scale: 2), name: "g19-mark-focus")
        try PanelRenderTests.write(ObscuraMarkDrawing.menuBarImage(.waiting, pointSize: 36, scale: 2), name: "g19-mark-update")
        try PanelRenderTests.write(ObscuraMarkDrawing.menuBarImage(.paused, pointSize: 36, scale: 2, pausedTint: PausedColor.red.markTint),
                                   name: "g19-mark-paused-red")
    }
}
