// Setup-only pieces of system.html, built here as internal views: the toned callout, the list row, the promise row,
// the sample terminal frame, the drawn notification banner and the drawn desk. The shared pieces setup first built
// here (the pill with a leading symbol, the list card, the small button, the desk and terminal-chrome colours) now live
// in ObscuraUIKit.
import AppKit
import SwiftUI
import ObscuraUIKit

// MARK: - Type

enum SetupFont {
    /// The setup window's own two title sizes (CHANGES.md §15: 24 and 19, kept inside this window).
    static let title = Font.system(size: 24, weight: .bold)
    static let stepTitle = Font.system(size: 19, weight: .bold)
    static let lead = Font.system(size: 14)
    static let paragraph = Font.system(size: 13)
}

// MARK: - Callout

/// `.callout2`: a toned box with a symbol, a bold line, a sentence and optional buttons.
struct Callout<Buttons: View>: View {
    var tone: Tone
    var symbol: String
    var title: String
    var message: String?
    @ViewBuilder var buttons: Buttons

    init(_ tone: Tone, symbol: String, title: String, message: String? = nil, @ViewBuilder buttons: () -> Buttons = { EmptyView() }) {
        self.tone = tone; self.symbol = symbol; self.title = title; self.message = message; self.buttons = buttons()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tone.color)
                .frame(width: 16, height: 16).padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(tone.text)
                if let message {
                    Text(message).font(.system(size: 12)).foregroundStyle(OColor.text2).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) { buttons }.padding(.top, Buttons.self == EmptyView.self ? 0 : 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: OMetric.Radius.l, style: .continuous).fill(tone.soft))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - List row

/// `.lrow`: leading symbol, a bold title over a help line, trailing content.
struct ListRow<Trailing: View>: View {
    var symbol: String?
    var title: String
    var help: String?
    var bold = true
    var showsDivider = false
    var highlighted = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            if showsDivider { Rectangle().fill(OColor.separator).frame(height: OMetric.hairline) }
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(OColor.text2).frame(width: 18).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: bold ? .semibold : .regular)).foregroundStyle(OColor.text1)
                    if let help { Text(help).font(.system(size: 11.5)).foregroundStyle(OColor.text2) }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(highlighted ? OColor.accentSoft : .clear)
        }
    }
}

// MARK: - Promise

/// One of the three promises on the welcome step.
struct PromiseRow: View {
    var symbol: String
    var title: String
    var message: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).fill(OColor.accentSoft)
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(OColor.accent))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(OColor.text1)
                Text(message).font(.system(size: 12.5)).foregroundStyle(OColor.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sample terminal frame

/// `.term`: the fake terminal's window chrome around a real image from the pipeline.
struct TerminalFrame: View {
    var image: NSImage?
    var width: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(OColor.terminalChromeDot).frame(width: 9, height: 9) }
                Spacer()
                Text(verbatim: "zsh — acme-api").font(.system(size: 11)).foregroundStyle(OColor.terminalChrome)
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(OColor.terminalChromeBar)
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    Color.clear.frame(height: width * 0.27)
                }
            }
            .frame(width: width)
        }
        .frame(width: width)
        .background(OColor.terminal)
        .clipShape(RoundedRectangle(cornerRadius: OMetric.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.l, style: .continuous).strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
    }
}

// MARK: - App tile

/// The app icon tile: the mark in white on the accent.
struct AppTile: View {
    var size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(OColor.accent)
            .frame(width: size, height: size)
            .overlay(ObscuraMark(.protected).frame(width: size * 0.62, height: size * 0.62).environment(\.colorScheme, .dark))
            .accessibilityHidden(true)
    }
}

// MARK: - Drawn notification banner

/// The catch banner as macOS will show it (notifications.html chrome), drawn so the step can show what it asks for.
struct BannerSample: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppTile(size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: "\(ProtectionCopy.secrets(2)) blacked out")).font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text("now").font(.system(size: 11)).foregroundStyle(OColor.text3)
                }
                Text("In Screenshot 2026-10-26 at 9.41.02 AM.png, in 180 ms. The file is clean; the original is in the Journal until tomorrow 9:41.")
                    .font(.system(size: 12)).foregroundStyle(OColor.text2).fixedSize(horizontal: false, vertical: true)
                Pill(Verdict.safeToShare(total: 2).title, tone: Verdict.safeToShare(total: 2).tone, symbol: Verdict.safeToShare(total: 2).symbol)
                    .scaleEffect(0.9, anchor: .leading)
                    .padding(.top, 2)
            }
            .foregroundStyle(OColor.text1)
            VStack(spacing: 0) {
                Text("Undo").font(.system(size: 12, weight: .semibold)).foregroundStyle(OColor.accentText).frame(maxHeight: .infinity)
                Rectangle().fill(OColor.hairline).frame(height: OMetric.hairline)
                Text("Review").font(.system(size: 12, weight: .medium)).foregroundStyle(OColor.text2).frame(maxHeight: .infinity)
            }
            .frame(width: 98)
            .overlay(alignment: .leading) { Rectangle().fill(OColor.hairline).frame(width: OMetric.hairline) }
            .padding(.vertical, -10)
            .padding(.trailing, -12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: OMetric.bannerWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: OMetric.Radius.banner, style: .continuous).fill(OColor.popover))
        .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.banner, style: .continuous).strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Example notification: 2 secrets blacked out, with Undo and Review"))
    }
}

// MARK: - Drawn desk with the floating thumbnail

/// The floating-thumbnail drawing: a small desk, the thumbnail in its corner and the drag that skips the scan.
struct ThumbnailDesk: View {
    var image: NSImage?
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: OColor.deskStops, startPoint: UnitPoint(x: 0.25, y: 0), endPoint: UnitPoint(x: 0.75, y: 1))
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(OColor.text1.opacity(0.85)).frame(width: 6, height: 6)
                    Text(verbatim: "Finder").font(.system(size: 9, weight: .bold))
                    Spacer()
                    ObscuraMark(.protected).frame(width: 12, height: 12)
                }
                .foregroundStyle(OColor.text1)
                .padding(.horizontal, 8)
                .frame(height: 18)
                .background(OColor.deskMenuBar)
                Spacer()
            }
            Thumbnail(image, size: OMetric.thumbLarge)
                .shadow(color: .black.opacity(0.35), radius: 9, y: 6)
                .position(x: 260 - 14 - OMetric.thumbLarge.width / 2, y: 156 - 14 - OMetric.thumbLarge.height / 2)
            HStack(spacing: 5) {
                Image(systemName: "hand.point.up.left.fill").font(.system(size: 11, weight: .semibold))
                Text("Drag = unscanned original").font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(OColor.accent))
            .shadow(color: .black.opacity(0.3), radius: 9, y: 6)
            .fixedSize()
            .position(x: 104, y: 118)
        }
        .frame(width: 260, height: 156)
        .clipShape(RoundedRectangle(cornerRadius: OMetric.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.l, style: .continuous).strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Drawing: the floating thumbnail in the corner of the screen; dragging it sends the unscanned original"))
    }
}
