import AppKit
import CoreGraphics
import Foundation
import ObscuraPrefs
@testable import ObscuraUIKit

/// Contact sheets of the menu bar marks for a person to look at (OBSCURA_UI_RENDER_DIR): each mark at real size on the
/// gallery's light and dark bar colours, then blown up pixel for pixel so 1× and 2× pixels can be judged.
@MainActor enum MarkSheet {
    static let outputDirectory: URL? = ProcessInfo.processInfo.environment["OBSCURA_UI_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    static let lightBar = CGColor(srgbRed: 0xEC / 255, green: 0xEC / 255, blue: 0xF0 / 255, alpha: 1)
    static let darkBar = CGColor(srgbRed: 0x20 / 255, green: 0x20 / 255, blue: 0x24 / 255, alpha: 1)

    /// One row per mark, one column per (state, appearance), each cell the frame at `scale` magnified `zoom` times.
    static func sheet(marks: [MenuBarMarkID], states: [MarkState], style: MenuBarMarkStyle, scale: CGFloat, zoom: Int,
                      pointSize: CGFloat = 18, count: Int = 0, pose: MarkPose = MarkPose()) -> CGImage? {
        let look0 = MarkLook(pointSize: pointSize, count: count)
        let cellW = Int((look0.width * scale).rounded(.up)) * zoom + 8, cellH = Int((pointSize * scale).rounded(.up)) * zoom + 8
        let columns = states.count * 2
        let w = columns * cellW, h = marks.count * cellH
        guard let ctx = MarkRenderer.bitmap(w, h) else { return nil }
        ctx.interpolationQuality = .none
        for (row, mark) in marks.enumerated() {
            for (i, state) in states.enumerated() {
                for (j, dark) in [false, true].enumerated() {
                    let x = (i * 2 + j) * cellW, y = h - (row + 1) * cellH
                    ctx.setFillColor(dark ? darkBar : lightBar)
                    ctx.fill(CGRect(x: x, y: y, width: cellW, height: cellH))
                    let look = MarkLook(pointSize: pointSize, count: count, appearance: dark ? .dark : .light)
                    let frame = MarkFrame(mark: mark, style: style, state: state, pose: pose)
                    guard let cg = image(frame, look, scale: scale) else { continue }
                    ctx.draw(cg, in: CGRect(x: x + 4, y: y + 4, width: cg.width * zoom, height: cg.height * zoom))
                }
            }
        }
        return ctx.makeImage()
    }

    /// The frame's bitmap at `scale`: the renderer's own for the new marks, the NSImage's for the Classic ring. A template
    /// image is drawn in the bar's label colour, as the menu bar would tint it.
    static func image(_ frame: MarkFrame, _ look: MarkLook, scale: CGFloat) -> CGImage? {
        let raw: CGImage?
        if frame.mark == .classic {
            let ns = MenuBarMarkImage.image(frame, look, scales: [scale])
            var rect = CGRect(origin: .zero, size: ns.size)
            raw = ns.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: NSAffineTransform(transform: AffineTransform(scale: scale))])
            if ns.isTemplate, let raw { return tinted(raw, MarkPalette.ink(look.appearance)) }
            return raw
        }
        raw = MarkRenderer.render(frame, look, scale: scale)
        if MarkRenderer.isTemplate(frame, look), let raw { return tinted(raw, MarkPalette.ink(look.appearance)) }
        return raw
    }

    static func tinted(_ image: CGImage, _ ink: MarkRGBA) -> CGImage? {
        guard let ctx = MarkRenderer.bitmap(image.width, image.height) else { return nil }
        let r = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.draw(image, in: r)
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(ink.cgColor)
        ctx.fill(r)
        return ctx.makeImage()
    }

    static func write(_ image: CGImage?, name: String) throws {
        guard let dir = outputDirectory, let image else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
