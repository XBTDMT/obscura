// How the Journal's inspector shows and hides (G-19 T-8, ruled 2026-10-27: instant by default, a setting for
// the system slide). Pure, so the choice is a unit test.
import SwiftUI
import ObscuraPrefs
import ObscuraUIKit

enum InspectorMotionRule {
    /// The animation the change runs in: none for instant (G-15), the pane slide for `.slide`, none under Reduce Motion.
    static func animation(_ motion: InspectorMotion, reduceMotion: Bool) -> Animation? {
        switch motion {
        case .instant: return nil
        case .slide: return OMotion.paneSlide(reduceMotion: reduceMotion)
        }
    }
}
