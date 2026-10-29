// The Viewer's wipe compare (G-19 #15, ruled 2026-10-27: side by side by default, a setting for the wipe):
// one picture with a divider dragged across it, the covered image on the left of the divider and the original on the
// right (open-calls.html #15, the `.wipe` sketch). It appears and leaves with compare itself (instant, G-15); the
// divider follows the pointer with no animation of its own.
import AppKit
import SwiftUI
import ObscuraUIKit

/// Where the picture sits and where the divider is. Pure, so the clamping is a unit test.
enum WipeGeometry {
    /// Where a new compare starts: the middle.
    static let start: Double = 0.5
    /// One VoiceOver increment or decrement.
    static let step: Double = 0.1

    /// A position is a fraction of the picture's width, 0 (all original) to 1 (all covered); anything else is clamped,
    /// and a value that is not a number is the start.
    static func clamp(_ position: Double) -> Double {
        guard position.isFinite else { return start }
        return min(max(position, 0), 1)
    }

    /// The image fitted inside `container`, keeping its aspect ratio, centred. Empty for an empty image.
    static func fittedRect(imageSize: CGSize, in container: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(x: container.midX, y: container.midY, width: 0, height: 0)
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: container.midX - size.width / 2, y: container.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The position for a pointer at `x`: clamped to the picture, so dragging past either edge holds at that edge.
    static func position(forX x: CGFloat, in picture: CGRect) -> Double {
        guard picture.width > 0 else { return start }
        return clamp(Double((x - picture.minX) / picture.width))
    }

    /// The divider's x for a position.
    static func dividerX(_ position: Double, in picture: CGRect) -> CGFloat {
        picture.minX + picture.width * CGFloat(clamp(position))
    }
}

struct WipeCompare: View {
    var clean: NSImage?
    var original: NSImage?
    var pixelSize: CGSize
    @Binding var position: Double

    /// The same margins as the side-by-side panes.
    static let inset = EdgeInsets(top: 18, leading: 10, bottom: 18, trailing: 10)

    var body: some View {
        GeometryReader { geo in
            let container = CGRect(x: Self.inset.leading, y: Self.inset.top,
                                   width: max(0, geo.size.width - Self.inset.leading - Self.inset.trailing),
                                   height: max(0, geo.size.height - Self.inset.top - Self.inset.bottom))
            let picture = WipeGeometry.fittedRect(imageSize: imageSize, in: container)
            let x = WipeGeometry.dividerX(position, in: picture)
            ZStack(alignment: .topLeading) {
                if let original {
                    image(original).frame(width: picture.width, height: picture.height).offset(x: picture.minX, y: picture.minY)
                }
                if let clean {
                    image(clean).frame(width: picture.width, height: picture.height)
                        .mask(alignment: .leading) { Rectangle().frame(width: max(0, x - picture.minX)) }
                        .offset(x: picture.minX, y: picture.minY)
                }
                // The divider: a white line with a soft shadow, and a grip in the middle.
                Rectangle().fill(.white).frame(width: 2, height: picture.height)
                    .shadow(color: .black.opacity(0.5), radius: 1.5)
                    .offset(x: x - 1, y: picture.minY)
                Circle().fill(.white).frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 10, weight: .bold)).foregroundStyle(OColor.text2))
                    .offset(x: x - 11, y: picture.midY - 11)
                    .accessibilityHidden(true)
                label(ViewerCopy.compareRedacted, color: OColor.okText).offset(x: picture.minX + 8, y: picture.minY + 8)
                    .opacity(position > 0.02 ? 1 : 0)
                label(ViewerCopy.compareOriginal, color: OColor.liveText)
                    .frame(width: max(0, picture.width - 16), alignment: .trailing)
                    .offset(x: picture.minX + 8, y: picture.minY + 8)
                    .opacity(position < 0.98 ? 1 : 0)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                position = WipeGeometry.position(forX: value.location.x, in: picture)
            })
            .onContinuousHover { phase in
                if case .active = phase { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Compare the redacted image with the original"))
        .accessibilityValue(Text(ViewerCopy.wipeValue(position)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: position = WipeGeometry.clamp(position + WipeGeometry.step)
            case .decrement: position = WipeGeometry.clamp(position - WipeGeometry.step)
            @unknown default: break
            }
        }
    }

    private var imageSize: CGSize {
        if pixelSize.width > 0, pixelSize.height > 0 { return pixelSize }
        return (clean ?? original)?.size ?? .zero
    }

    private func image(_ image: NSImage) -> some View {
        Image(nsImage: image).resizable().interpolation(.high)
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 2).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous).fill(color))
            .fixedSize()
            .accessibilityHidden(true)
    }
}
