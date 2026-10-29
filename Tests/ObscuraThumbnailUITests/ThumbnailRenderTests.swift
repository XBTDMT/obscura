import AppKit
import Foundation
import SwiftUI
import Testing
import ObscuraUIKit
@testable import ObscuraThumbnailUI

/// Renders every r3-a state of the card, light and dark, at the panel's size. Asserts the size and that pixels were
/// drawn; with OBSCURA_UI_RENDER_DIR set, writes the PNGs (on a desk-coloured backdrop) for the visual check.
@MainActor
@Suite struct ThumbnailRenderTests {
    static let name = "Screenshot 2026-10-26 at 9.41.12 AM.png"
    static let clean = NSImage(data: SampleData.terminalPNG(covered: true, width: 560))
    static let original = NSImage(data: SampleData.terminalPNG(covered: false, width: 560))

    static let states: [(String, ThumbnailContent)] = [
        ("01-checked", ThumbnailContent(displayName: name, image: clean, capsule: .checked, hoverAction: nil, hovering: false, edges: 0)),
        ("02-folded", ThumbnailContent(displayName: name, image: clean, capsule: .folded, hoverAction: nil, hovering: false, edges: 0)),
        ("03-covered", ThumbnailContent(displayName: name, image: clean, capsule: .covered(2), hoverAction: .undo, hovering: false, edges: 0)),
        ("04-checking", ThumbnailContent(displayName: name, image: original, capsule: .checking, hoverAction: nil, hovering: false, edges: 0)),
        ("05-hover", ThumbnailContent(displayName: name, image: clean, capsule: .covered(2), hoverAction: .undo, hovering: true, edges: 0)),
        ("06-burst", ThumbnailContent(displayName: name, image: clean, capsule: .covered(2), hoverAction: .undo, hovering: false, edges: 2)),
        ("07-original", ThumbnailContent(displayName: name, image: original, capsule: .original(2), hoverAction: .blackOutAgain, hovering: false, edges: 0)),
        ("08-original-hover", ThumbnailContent(displayName: name, image: original, capsule: .original(2), hoverAction: .blackOutAgain, hovering: true, edges: 0)),
    ]

    @Test(arguments: [ColorScheme.light, .dark])
    func everyStateRendersAtPanelSize(scheme: ColorScheme) throws {
        let dir = ProcessInfo.processInfo.environment["OBSCURA_UI_RENDER_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        for (name, content) in Self.states {
            let view = ThumbnailView(content: content)
                .background(scheme == .dark ? Color(white: 0.16) : Color(red: 0.86, green: 0.88, blue: 0.94))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            var image: NSImage?
            (scheme == .dark ? NSAppearance(named: .darkAqua)! : NSAppearance(named: .aqua)!).performAsCurrentDrawingAppearance {
                image = renderer.nsImage
            }
            let rendered = try #require(image, "\(name) did not render")
            #expect(rendered.size == ThumbnailPlacement.panelSize, "\(name)")
            let tiff = try #require(rendered.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            #expect(Self.distinctColours(bitmap) > 8, "\(name) drew almost nothing")
            if let dir, let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: dir.appending(path: "\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    static func distinctColours(_ bitmap: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                seen.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
                if seen.count > 64 { return seen.count }
            }
        }
        return seen.count
    }
}
