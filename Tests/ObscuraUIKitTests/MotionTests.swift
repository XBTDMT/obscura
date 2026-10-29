import SwiftUI
import Testing
@testable import ObscuraUIKit

/// G-15: one fade, instant under Reduce Motion; the thumbnail's slide is the only slide.
@Suite struct MotionTests {
    @Test func reduceMotionMakesEveryChangeInstant() {
        #expect(OMotion.fade(reduceMotion: true) == nil)
        #expect(OMotion.slide(reduceMotion: true) == nil)
    }

    @Test func theFadeIsShortAndTheSlideIsTheThumbnails() {
        #expect(OMotion.fade(reduceMotion: false) != nil)
        #expect(OMotion.fadeDuration == 0.15)
        #expect(OMotion.slideDuration == 0.2)
        #expect(OMotion.toastSeconds == 4)
    }
}
