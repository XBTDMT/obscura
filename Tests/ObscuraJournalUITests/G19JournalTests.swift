import AppKit
import Foundation
import SwiftUI
import Testing
import ObscuraPrefs
import ObscuraUIKit
@testable import ObscuraJournalUI

/// G-19 in the Journal: the list's selection mark on the thumbnail (T-10), the inspector's motion choice (T-8) and the
/// grid that adds columns as the window grows (#14).
@Suite struct JournalGridTests {
    @Test func aWiderCentreHoldsMoreColumnsAndNeverFewerThanOne() {
        #expect(JournalGrid.columns(forWidth: 0) == 1)
        #expect(JournalGrid.columns(forWidth: .nan) == 1)
        #expect(JournalGrid.columns(forWidth: 185) == 1)
        // Each further column needs one card plus one gap: 150 + 14.
        #expect(JournalGrid.columns(forWidth: 36 + 150 + 164) == 2)
        #expect(JournalGrid.columns(forWidth: 36 + 150 + 164 * 2) == 3)
        var last = 0
        for width in stride(from: CGFloat(0), through: 3000, by: 10) {
            let n = JournalGrid.columns(forWidth: width)
            #expect(n >= last, "never fewer columns in a wider centre")
            last = n
        }
    }

    @Test func theWindowSizesGiveTheColumnsTheDecisionPageDescribes() {
        let defaultWithInspector = JournalGrid.columns(forWidth: JournalGrid.centreWidth(windowWidth: OMetric.journalSize.width, showsInspector: true))
        let minimumWithInspector = JournalGrid.columns(forWidth: JournalGrid.centreWidth(windowWidth: 760, showsInspector: true))
        let thirteenInchFull = JournalGrid.columns(forWidth: JournalGrid.centreWidth(windowWidth: 1470, showsInspector: true))
        #expect(minimumWithInspector == 1)
        #expect(defaultWithInspector == 3)
        #expect(thirteenInchFull > defaultWithInspector, "made larger, the Journal shows more columns (#14)")
        #expect(JournalGrid.columns(forWidth: JournalGrid.centreWidth(windowWidth: 1040, showsInspector: false)) > defaultWithInspector)
    }
}

@Suite struct InspectorMotionRuleTests {
    @Test func instantByDefaultAndTheSlideOnlyWhenChosen() {
        #expect(Settings.default.journalInspectorMotion == .instant)
        #expect(InspectorMotionRule.animation(.instant, reduceMotion: false) == nil)
        #expect(InspectorMotionRule.animation(.instant, reduceMotion: true) == nil)
        #expect(InspectorMotionRule.animation(.slide, reduceMotion: false) != nil)
        #expect(InspectorMotionRule.animation(.slide, reduceMotion: true) == nil, "Reduce Motion: instant")
    }
}

@Suite(.serialized) @MainActor struct G19JournalRenderTests {
    @Test(arguments: [InspectorMotion.instant, .slide])
    func theInspectorTogglesAndPersistsInEitherMode(_ motion: InspectorMotion) async throws {
        let (model, controller) = try await Fixtures.sampleController()
        model.updateSettings { $0.journalInspectorMotion = motion }
        controller.setShowsInspector(false, reduceMotion: false)
        #expect(!controller.showsInspector && model.settings.journalShowsInspector == false)
        controller.setShowsInspector(true, reduceMotion: false)
        #expect(controller.showsInspector && model.settings.journalShowsInspector == true)
    }

    /// The first column with anything drawn in it, in a row rendered on a clear background.
    static func leadingInk(_ view: some View, width: CGFloat) throws -> Int {
        let renderer = ImageRenderer(content: view.frame(width: width).environment(\.colorScheme, .light))
        renderer.scale = 1
        let cg = try #require(renderer.cgImage)
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        for x in 0..<w {
            for y in 0..<h where bytes[(y * w + x) * 4 + 3] > 20 { return x }
        }
        return w
    }

    /// T-10: no row reserves an empty slot before its thumbnail, and picking several rows shifts nothing: the mark
    /// sits on the thumbnail's corner.
    @Test func listRowsHaveNoReservedSlotAndTheMarkSitsOnTheThumbnail() async throws {
        let (model, controller) = try await Fixtures.sampleController()
        let entry = try #require(model.entries.first)
        await controller.loadImage(for: entry)
        let single = try Self.leadingInk(JournalListRow(controller: controller, entry: entry, selected: false, multi: false), width: 700)
        // A row left out of a multi-selection: its empty mark appears (the old design faded a box in, in a reserved slot).
        let picked = try Self.leadingInk(JournalListRow(controller: controller, entry: entry, selected: false, multi: true), width: 700)
        #expect(single <= Int(JournalListRow.horizontalPadding) + 1, "the thumbnail starts at the row's padding: \(single)")
        #expect(picked == single, "the multi-selection mark draws on the thumbnail, so nothing moves: \(picked) vs \(single)")
    }
}
