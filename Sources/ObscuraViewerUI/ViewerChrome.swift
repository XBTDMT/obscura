// The window's chrome from viewer.html: the title block, the zoom cluster, the red banner, the floating peek pill, the
// toolbar's short peek pill, and the Space compare panes.
import SwiftUI
import ObscuraUIKit
import ObscuraPrefs

/// The toolbar's leading title: the file name, and the count (or the red warning while Original shows).
struct TitleBlock: View {
    var name: String
    var subtitle: String
    var isLive: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(OColor.text1)
                .lineLimit(1).truncationMode(.middle)
            Text(subtitle).font(.system(size: 11, weight: isLive ? .medium : .regular))
                .foregroundStyle(isLive ? OColor.liveText : OColor.text2).lineLimit(1)
        }
        .frame(maxWidth: 260, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// `.zoom`: out, the level, in, actual size, fit.
struct ZoomCluster: View {
    /// The person's shortcuts, for the tooltips (G-20).
    var keys: KeyBindings
    var label: String
    var enabled: Bool
    var zoomOut: () -> Void
    var zoomIn: () -> Void
    var actual: () -> Void
    var fit: () -> Void
    /// `.zoom .ibtn`: the cluster's buttons are a size down from the toolbar's.
    static let zoomButton = CGSize(width: 26, height: 22)
    var body: some View {
        HStack(spacing: 1) {
            IconButton(symbol: "minus.magnifyingglass", label: String(localized: "Zoom Out"), help: ShortcutText.withChord(String(localized: "Zoom out"), .viewerZoomOut, keys),
                       size: Self.zoomButton, action: zoomOut)
            Text(label).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(OColor.text1)
                .padding(.horizontal, 6).frame(minWidth: 40)
                .accessibilityLabel(Text("Zoom level"))
                .accessibilityValue(Text(label))
                .opacity(enabled ? 1 : OMetric.Control.disabledOpacity)
            IconButton(symbol: "plus.magnifyingglass", label: String(localized: "Zoom In"), help: ShortcutText.withChord(String(localized: "Zoom in"), .viewerZoomIn, keys),
                       size: Self.zoomButton, action: zoomIn)
            IconButton(symbol: "1.magnifyingglass", label: String(localized: "Actual Size"), help: ShortcutText.withChord(String(localized: "Actual size"), .viewerActualSize, keys),
                       size: Self.zoomButton, action: actual)
            IconButton(symbol: "arrow.up.left.and.down.right.magnifyingglass", label: String(localized: "Zoom to Fit"),
                       help: ShortcutText.withChord(String(localized: "Zoom to fit"), .viewerZoomToFit, keys), size: Self.zoomButton, action: fit)
        }
        .padding(1)
        // The icon buttons dim themselves when disabled; the level and the ground dim with them.
        .background(RoundedRectangle(cornerRadius: OMetric.Radius.ml, style: .continuous).fill(OColor.fill)
            .opacity(enabled ? 1 : OMetric.Control.disabledOpacity))
        .disabled(!enabled)
        .fixedSize()
    }
}

/// The toolbar's trailing group: zoom, Copy and the inspector toggle.
struct ToolbarTrailing: View {
    var keys: KeyBindings
    var zoomLabel: String
    var zoomEnabled: Bool
    var inspectorOn: Bool
    var zoomOut: () -> Void
    var zoomIn: () -> Void
    var actual: () -> Void
    var fit: () -> Void
    var copy: () -> Void
    var toggleInspector: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            ZoomCluster(keys: keys, label: zoomLabel, enabled: zoomEnabled, zoomOut: zoomOut, zoomIn: zoomIn, actual: actual, fit: fit)
            Button(action: copy) { IconLabel(String(localized: "Copy"), symbol: "doc.on.doc") }
            .buttonStyle(OButtonStyle(.quiet))
            .help(ShortcutText.withChord(String(localized: "Copy the image as shown, or the selected text"), .viewerCopy, keys))
            IconButton(symbol: "sidebar.right", label: String(localized: "Findings"), help: ShortcutText.withChord(String(localized: "Findings"), .viewerFindings, keys),
                       isOn: inspectorOn, action: toggleInspector)
                .accessibilityValue(Text(inspectorOn ? String(localized: "shown") : String(localized: "hidden")))
        }
    }
}

/// The toolbar's centre: the Redacted / Original control, and the red "Peeking" pill while the original is held.
struct ToolbarCenter: View {
    var mode: ViewerMode
    var originalAvailable: Bool
    var isPeeking: Bool
    var set: (ViewerMode) -> Void
    var body: some View {
        HStack(spacing: 8) {
            ModeSwitch(mode: mode, originalAvailable: originalAvailable, set: set)
            // Instant, with the original it marks (system.html: red means the original is really on screen).
            if isPeeking { Pill(ViewerCopy.peekShort, tone: .live, symbol: "eye") }
        }
    }
}

/// `.vbanner`: the red line under the toolbar while Original shows.
struct OriginalBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 12, weight: .semibold)).accessibilityHidden(true)
            Text(ViewerCopy.originalWarning).font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Text(ViewerCopy.originalBannerTrailing).font(.system(size: 12))
                KeyCap("Tab")
            }
            .lineLimit(1)
        }
        .foregroundStyle(OColor.liveText)
        .padding(.vertical, 6).padding(.horizontal, 12)
        // Over the picture now (T-12), so the soft red sits on the window colour, never on the image beneath it.
        .background { ZStack { OColor.window; OColor.liveSoft } }
        .overlay(alignment: .bottom) { Rectangle().fill(OColor.separator).frame(height: OMetric.hairline) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// `.warnpill`: floats over the canvas while the original is held.
struct PeekPill: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.raised").font(.system(size: 12, weight: .semibold)).accessibilityHidden(true)
            Text(ViewerCopy.peekPill).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Capsule().fill(OColor.live))
        .shadow(color: OColor.live.opacity(0.35), radius: 7, y: 4)
        .fixedSize()
    }
}

/// Space compare: the file you share and the original, side by side, each labelled.
struct ComparePanes: View {
    var clean: NSImage?
    var original: NSImage?
    var body: some View {
        HStack(spacing: 14) {
            pane(clean, label: ViewerCopy.compareRedacted, color: OColor.okText)
            pane(original, label: ViewerCopy.compareOriginal, color: OColor.liveText)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 10)
    }

    @ViewBuilder private func pane(_ image: NSImage?, label: String, color: Color) -> some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .overlay(alignment: .topLeading) {
                        Text(label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.vertical, 2).padding(.horizontal, 8)
                            .background(RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous).fill(color))
                            .padding(8)
                            .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(label))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
