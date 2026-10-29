// The shared components the surfaces used to build for themselves (B-6 consolidation): sizes from system.html, the
// roles' colours, the wrapping layout's line breaking, the verdict symbols and the menu bar count badge.
import Testing
import AppKit
import SwiftUI
@testable import ObscuraUIKit

@MainActor
@Suite struct ComponentTests {
    /// The point size a view draws at (renderer scale 1).
    func size(_ view: some View) -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.nsImage?.size ?? .zero
    }

    @Test func pillsAndBadgesHaveTheSystemHeights() {
        #expect(size(Pill("Safe to share", tone: .ok)).height == 22)
        #expect(size(Pill("Safe to share", tone: .ok, symbol: "checkmark")).height == 22)
        #expect(size(Badge("Edited", tone: .accent)).height == 18)
        #expect(size(Badge("Watching", tone: .ok, symbol: "checkmark")).height == 18)
        #expect(size(KeyCap("⌘O")).height == 17)
    }

    @Test func aSymbolWidensThePillAndTheBadge() {
        #expect(size(Pill("Off", tone: .quiet, symbol: "xmark")).width > size(Pill("Off", tone: .quiet)).width)
        #expect(size(Badge("Off", tone: .ok, symbol: "checkmark")).width > size(Badge("Off", tone: .ok)).width)
    }

    @Test func fixedSizeControls() {
        #expect(size(Checkbox(isOn: true)) == CGSize(width: 14, height: 14))
        #expect(size(Checkbox(isOn: false)) == CGSize(width: 14, height: 14))
        #expect(size(IconButton(symbol: "trash", label: "Delete") {}) == OMetric.Control.iconButton)
        #expect(size(IconButton(symbol: "plus.magnifyingglass", label: "Zoom In", size: CGSize(width: 26, height: 22)) {})
                == CGSize(width: 26, height: 22))
        #expect(size(Spinner()) == CGSize(width: 10, height: 10))
        #expect(size(Thumbnail(nil)) == OMetric.thumbSmall)
        #expect(size(ShotImage(image: nil).frame(width: 90, height: 60)) == CGSize(width: 90, height: 60))
        #expect(size(CardCapsule { Text("Checked") }).height == OMetric.FloatingCard.capsuleHeight)
    }

    @Test func aWideImageNeverWidensTheShotChrome() {
        let wide = NSImage(size: NSSize(width: 4000, height: 100))
        #expect(size(ShotImage(image: wide).frame(width: 120, height: 80)) == CGSize(width: 120, height: 80))
        #expect(size(Thumbnail(wide, size: OMetric.thumbLarge)) == OMetric.thumbLarge)
    }

    @Test func smallButtonsAreTwentyOnePointsHighAndRegularOnesAtLeastTwentyFour() {
        for role in [OButtonStyle.Role.primary, .quiet, .warn, .danger, .ghost, .plain] {
            #expect(size(Button("Allow…") {}.buttonStyle(OButtonStyle(role, size: .small))).height == 21, "\(role)")
            #expect(size(Button("Allow…") {}.buttonStyle(OButtonStyle(role))).height >= 24, "\(role)")
        }
        // A small button never wraps or truncates its words: it takes the width they need.
        let short = size(Button("Off") {}.buttonStyle(OButtonStyle(.quiet, size: .small))).width
        let long = size(Button("Open Files and Folders…") {}.buttonStyle(OButtonStyle(.quiet, size: .small))).width
        #expect(long > short)
        #expect(size(Button("Open Files and Folders…") {}.buttonStyle(OButtonStyle(.quiet, size: .small)).frame(width: 40)).height == 21)
    }

    @Test func buttonRolesKeepTheirColours() {
        #expect(OButtonStyle(.primary).background == OColor.accent)
        #expect(OButtonStyle(.warn).background == OColor.needs)
        #expect(OButtonStyle(.quiet).background == OColor.control)
        #expect(OButtonStyle(.danger).background == OColor.control)
        #expect(OButtonStyle(.danger).foreground == OColor.liveText)
        #expect(OButtonStyle(.ghost).background == OColor.fill)
        #expect(OButtonStyle(.ghost).foreground == OColor.text1)
        #expect(OButtonStyle(.plain).background == .clear)
        #expect(OButtonStyle(.plain).foreground == OColor.accentText)
        #expect(OButtonStyle(.primary, size: .small).foreground == .white)
        #expect(OMetric.Control.disabledOpacity == 0.45)
    }

    @Test func verdictSymbolsMatchTheMockups() {
        #expect(Verdict.safeToShare(total: 2).symbol == "checkmark")
        #expect(Verdict.leftVisible(visible: 1, total: 3).symbol == "eye")
        #expect(Verdict.originalShowing(total: 1).symbol == "exclamationmark.triangle")
        for verdict in [Verdict.safeToShare(total: 1), .leftVisible(visible: 1, total: 2), .originalShowing(total: 1)] {
            #expect(NSImage(systemSymbolName: verdict.symbol, accessibilityDescription: nil) != nil)
        }
    }

    @Test func theCountBadgeWidensTheMarkAndSaysWhatItCounts() {
        let plain = ObscuraMarkDrawing.menuBarImage(.protected, count: 0)
        #expect(plain.size == CGSize(width: 18, height: 18))
        #expect(plain.isTemplate)
        let badged = ObscuraMarkDrawing.menuBarImage(.protected, count: 4)
        #expect(badged.size == CGSize(width: ObscuraMarkDrawing.badgedWidth, height: 18))
        #expect(!badged.isTemplate)
        #expect(badged.accessibilityDescription == "Obscura: protected, 4 catches to review")
        #expect(MarkCopy.accessibilityLabel(.paused, count: 1) == "Obscura: paused, 1 catch to review")
        #expect(MarkCopy.accessibilityLabel(.paused, count: 0) == MarkCopy.accessibilityLabel(.paused))
        #expect(CountBadge.text(7) == "7")
        #expect(CountBadge.text(99) == "99")
        #expect(CountBadge.text(100) == "99+")
    }
}

@Suite struct FlowLayoutTests {
    let layout = FlowLayout(spacing: 6)
    func sizes(_ widths: [CGFloat], height: CGFloat = 20) -> [CGSize] { widths.map { CGSize(width: $0, height: height) } }

    @Test func everythingFitsOnOneLine() {
        let lines = layout.arrange(width: 200, sizes: sizes([50, 50, 50]))
        #expect(lines.map(\.indices) == [[0, 1, 2]])
        #expect(lines[0].width == 162)
    }

    @Test func aChildThatWouldPassTheWidthStartsANewLine() {
        let lines = layout.arrange(width: 120, sizes: sizes([50, 50, 50]))
        #expect(lines.map(\.indices) == [[0, 1], [2]])
        #expect(lines.map(\.width) == [106, 50])
    }

    @Test func aChildWiderThanTheLineStillGetsALineOfItsOwn() {
        let lines = layout.arrange(width: 40, sizes: sizes([60, 30]))
        #expect(lines.map(\.indices) == [[0], [1]])
    }

    @Test func aLineIsAsTallAsItsTallestChild() {
        let lines = layout.arrange(width: 500, sizes: [CGSize(width: 40, height: 16), CGSize(width: 40, height: 22)])
        #expect(lines.count == 1)
        #expect(lines[0].height == 22)
    }

    @Test func lineSpacingDefaultsToSpacing() {
        #expect(FlowLayout(spacing: 3).lineSpacing == 3)
        #expect(FlowLayout(spacing: 6, lineSpacing: 10).lineSpacing == 10)
        #expect(FlowLayout(spacing: 6).lineAlignment == .center)
    }

    @Test @MainActor func itReportsTheWidthItsLongestLineNeeds() {
        let view = FlowLayout(spacing: 6) {
            Color.red.frame(width: 50, height: 10)
            Color.red.frame(width: 50, height: 10)
            Color.red.frame(width: 50, height: 10)
        }
        .frame(width: 120, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        // Two lines of 10 pt with 6 pt between them.
        #expect(renderer.nsImage?.size == CGSize(width: 120, height: 26))
    }
}
