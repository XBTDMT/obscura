// G-38: what the menu bar keeps in the defaults domain travels with the settings when the bundle identifier changes.
import Testing
import ObscuraPrefs
@testable import ObscuraMenuBarUI

@Suite struct IdentityCarryTests {
    @Test func thePanelsMemoriesAndTheStatusItemPositionAreCarried() {
        #expect(PreviousIdentityDefaults.carries(PanelMemory.Keys.lastSeen))
        #expect(PreviousIdentityDefaults.carries(PanelMemory.Keys.pauseChoice))
        // AppKit stores the status item's place under its autosave name (MenuBarController).
        #expect(PreviousIdentityDefaults.carries("NSStatusItem Preferred Position ObscuraStatusItem"))
    }
}
