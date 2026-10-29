import Foundation
import Testing
import ObscuraPrefs
@testable import ObscuraSettingsUI

/// The Floating thumbnail group's choices (B-9, r3-a's Settings row).
@Suite struct ThumbnailSettingsTests {
    @Test func durationsAreR3asFour() {
        #expect(ThumbnailChoices.durations == [3, 5, 8, 12])
        #expect(ThumbnailChoices.title(5) == "5 seconds")
        #expect(ThumbnailChoices.title(12) == "12 seconds")
    }

    @Test func anUnlistedStoredValueShowsAsTheNearestChoice() {
        #expect(ThumbnailChoices.nearest(5) == 5)
        #expect(ThumbnailChoices.nearest(7) == 8)
        #expect(ThumbnailChoices.nearest(1) == 3)
        #expect(ThumbnailChoices.nearest(300) == 12)
        #expect(ThumbnailChoices.nearest(Settings.default.thumbnailSeconds) == 5)
    }

    @Test func clickChoicesNameBothDestinations() {
        #expect(ThumbnailClick.allCases.map(ThumbnailChoices.title) == ["Preview", "Obscura viewer"])
    }
}
