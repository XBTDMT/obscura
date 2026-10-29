import AppKit
import Foundation
import Testing
import ObscuraPrefs
@testable import ObscuraUIKit

/// Writes the contact sheets when OBSCURA_UI_RENDER_DIR is set (nothing otherwise), and checks every sheet draws.
@Suite @MainActor struct MarkSheetTests {
    static let keyStates: [MarkState] = [.protected, .checking, .caught, .partlyProtected, .paused, .needsAttention, .waiting, .focusHolding]

    @Test func everyMarkStyleAndStateDrawsASheet() throws {
        for style in MenuBarMarkStyle.allCases {
            for scale in [CGFloat(1), 2] {
                let sheet = MarkSheet.sheet(marks: MenuBarMarkID.allCases, states: Self.keyStates, style: style, scale: scale,
                                            zoom: scale == 1 ? 6 : 3)
                #expect(sheet != nil, "\(style) @\(scale)x")
                try MarkSheet.write(sheet, name: "marks-\(style.rawValue)-\(Int(scale))x")
            }
        }
        // Real size, no zoom: what the menu bar shows, for a side-by-side look.
        try MarkSheet.write(MarkSheet.sheet(marks: MenuBarMarkID.allCases, states: [.protected], style: .warm, scale: 1, zoom: 1),
                            name: "marks-warm-1x-real")
        try MarkSheet.write(MarkSheet.sheet(marks: MenuBarMarkID.allCases, states: [.protected, .caught], style: .warm, scale: 2, zoom: 2,
                                            count: 3), name: "marks-badged-2x")
        try MarkSheet.write(MarkSheet.sheet(marks: MenuBarMarkID.allCases, states: [.protected], style: .warm, scale: 1, zoom: 6,
                                            pointSize: 16), name: "marks-warm-16pt-1x")
        try MarkSheet.write(MarkSheet.sheet(marks: MenuBarMarkID.allCases, states: [.protected], style: .warm, scale: 2, zoom: 3,
                                            pose: .lifted), name: "marks-lifted-2x")
        // The two the gallery flagged as soft at 16 pt (G-21 "legibility"), close up at 1× and 2× in every style.
        for style in MenuBarMarkStyle.allCases {
            try MarkSheet.write(MarkSheet.sheet(marks: [.checkerBand, .shutter], states: [.protected, .paused, .caught], style: style,
                                                scale: 1, zoom: 10), name: "tune-\(style.rawValue)-1x")
        }
        try MarkSheet.write(MarkSheet.sheet(marks: [.checkerBand, .shutter], states: [.protected, .paused, .caught], style: .warm,
                                            scale: 2, zoom: 5), name: "tune-warm-2x")
    }
}
