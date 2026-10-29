// The app's window rules (recon M-6, M-7, M-8): Dock presence, focus after the last window closes, and reopen.
import Foundation
import Testing
import ObscuraUIKit

@Suite struct WindowFlowTests {
    typealias W = WindowFlow.WindowInfo
    static let journal = W(isVisible: true, isMiniaturized: false, isTitled: true, isPanel: false)
    static let minimized = W(isVisible: false, isMiniaturized: true, isTitled: true, isPanel: false)
    static let closed = W(isVisible: false, isMiniaturized: false, isTitled: true, isPanel: false)
    static let thumbnail = W(isVisible: true, isMiniaturized: false, isTitled: false, isPanel: true)
    static let menuBarPanel = W(isVisible: true, isMiniaturized: false, isTitled: false, isPanel: true)
    static let titledPanel = W(isVisible: true, isMiniaturized: false, isTitled: true, isPanel: true)
    static let own: pid_t = 100
    static let slack: pid_t = 200

    @Test func aVisibleWindowKeepsTheDockIcon() {
        #expect(WindowFlow.wantsDockIcon([Self.journal, Self.thumbnail]))
    }

    @Test func aMinimizedWindowKeepsTheDockIconSoItCanComeBack() {
        #expect(WindowFlow.wantsDockIcon([Self.minimized]))
    }

    @Test func panelsAndClosedWindowsDoNotCount() {
        #expect(!WindowFlow.wantsDockIcon([Self.closed, Self.thumbnail, Self.menuBarPanel, Self.titledPanel]))
        #expect(!WindowFlow.wantsDockIcon([]))
    }

    @Test func closingTheLastWindowHandsFocusBack() {
        #expect(WindowFlow.focusReturnAfterLastWindowClosed(windows: [Self.closed, Self.thumbnail], appIsActive: true,
                                                            panelIsOpen: false, previousApp: Self.slack, ownPID: Self.own) == Self.slack)
    }

    @Test func focusStaysWhileAWindowIsStillOpen() {
        for windows in [[Self.journal], [Self.minimized]] {
            #expect(WindowFlow.focusReturnAfterLastWindowClosed(windows: windows, appIsActive: true, panelIsOpen: false,
                                                                previousApp: Self.slack, ownPID: Self.own) == nil)
        }
    }

    @Test func focusIsNotTakenWhenObscuraIsNotActiveOrThePanelIsUp() {
        #expect(WindowFlow.focusReturnAfterLastWindowClosed(windows: [], appIsActive: false, panelIsOpen: false,
                                                            previousApp: Self.slack, ownPID: Self.own) == nil)
        #expect(WindowFlow.focusReturnAfterLastWindowClosed(windows: [], appIsActive: true, panelIsOpen: true,
                                                            previousApp: Self.slack, ownPID: Self.own) == nil)
        #expect(WindowFlow.focusReturnAfterLastWindowClosed(windows: [], appIsActive: true, panelIsOpen: false,
                                                            previousApp: nil, ownPID: Self.own) == nil)
        #expect(WindowFlow.focusReturnAfterLastWindowClosed(windows: [], appIsActive: true, panelIsOpen: false,
                                                            previousApp: Self.own, ownPID: Self.own) == nil)
    }

    @Test func reopeningShowsSomething() {
        #expect(WindowFlow.reopen(hasVisibleWindows: true, hasFinishedSetup: true) == .bringWindowsForward)
        #expect(WindowFlow.reopen(hasVisibleWindows: false, hasFinishedSetup: true) == .openPanel)
        #expect(WindowFlow.reopen(hasVisibleWindows: false, hasFinishedSetup: false) == .openSetup)
    }
}
