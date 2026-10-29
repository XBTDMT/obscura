// Shared controls and small pieces from design/mockups/unified/system.html that the surfaces first built for themselves
// (B-6 consolidation, redman 2026-10-27): the key cap, the icon button, the checkbox, the status box, the flexible
// screenshot chrome, the wrapping layout, the row card, the checking spinner and the floating card's capsule.
// Surfaces compose these; they do not restyle them.
public import SwiftUI
public import AppKit

/// `.kbd`: a keyboard shortcut drawn as a key cap, in running text or beside a section title.
public struct KeyCap: View {
    public var text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .font(OFont.keyCap)
            .foregroundStyle(OColor.text2)
            .padding(.horizontal, 5)
            .frame(height: OMetric.Control.keyCapHeight)
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.xs, style: .continuous).fill(OColor.fill))
            .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.xs, style: .continuous).strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
    }
}

/// `.ibtn`: a borderless toolbar icon button (28 × 24 unless told otherwise); `isOn` draws the pressed fill of a
/// switch. Dims when disabled, like every control.
public struct IconButton: View {
    public var symbol: String
    public var label: String
    public var help: String?
    public var isOn: Bool
    public var size: CGSize
    public var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    /// `label` is what VoiceOver reads; `help` is the tooltip and defaults to the label.
    public init(symbol: String, label: String, help: String? = nil, isOn: Bool = false,
                size: CGSize = OMetric.Control.iconButton, action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.help = help; self.isOn = isOn; self.size = size; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isOn ? OColor.text1 : OColor.text2)
                .frame(width: size.width, height: size.height)
                .background(RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous).fill(isOn ? OColor.fill2 : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : OMetric.Control.disabledOpacity)
        .help(help ?? label)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// `.ck`: the 14 pt checkbox, filled with the accent and a white tick when on.
public struct Checkbox: View {
    public var isOn: Bool
    public init(isOn: Bool) { self.isOn = isOn }
    public var body: some View {
        RoundedRectangle(cornerRadius: OMetric.Radius.xs, style: .continuous)
            .fill(isOn ? OColor.accent : OColor.control)
            .overlay {
                if isOn {
                    Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.white)
                } else {
                    RoundedRectangle(cornerRadius: OMetric.Radius.xs, style: .continuous).strokeBorder(OColor.hairline, lineWidth: OMetric.hairline)
                }
            }
            .frame(width: OMetric.Control.checkbox, height: OMetric.Control.checkbox)
            .accessibilityHidden(true)
    }
}

/// `.finding`: the one status box — a bold line and what is true of the file, on a tone, led by its symbol.
public struct StatusBox: View {
    public var title: String
    public var detail: String
    public var tone: Tone
    public var symbol: String

    public init(title: String, detail: String, tone: Tone, symbol: String) {
        self.title = title; self.detail = detail; self.tone = tone; self.symbol = symbol
    }

    /// The verdict's own words, tone and symbol.
    public init(_ verdict: Verdict) {
        self.init(title: verdict.title, detail: verdict.detail, tone: verdict.tone, symbol: verdict.symbol)
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).frame(width: 15, height: 15).padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(OFont.callout).opacity(0.85).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(tone.text)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: OMetric.Radius.l, style: .continuous).fill(tone.soft))
        .accessibilityElement(children: .combine)
    }
}

/// The shared screenshot chrome at any size: terminal ground, hairline, rounded corners. The ground takes the proposed
/// size and the image sits in an overlay, so the image can never widen the frame; `alignment` picks which part of a
/// filled image stays in view (the top, where a screenshot's first lines are, unless told otherwise).
public struct ShotImage: View {
    public var image: NSImage?
    public var radius: CGFloat
    public var contentMode: ContentMode
    public var alignment: Alignment

    public init(image: NSImage?, radius: CGFloat = OMetric.Radius.ml, contentMode: ContentMode = .fill, alignment: Alignment = .top) {
        self.image = image; self.radius = radius; self.contentMode = contentMode; self.alignment = alignment
    }

    public var body: some View {
        OColor.terminal
            .overlay(alignment: alignment) {
                if let image {
                    // Keyed by the image, so a swap made under the fade (a new revision replacing the one on screen)
                    // cross-fades; a swap made without an animation stays instant.
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: contentMode)
                        .id(ObjectIdentifier(image))
                        .transition(OMotion.crossFade)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
            .accessibilityHidden(true)
    }
}

/// `.btns`, `.dots` and badge rows: children laid left to right, wrapping to a new line when the width runs out.
/// Reports the width its longest line needs (never more than offered).
public struct FlowLayout: Layout {
    /// Where a child shorter than its line sits.
    public enum LineAlignment: Sendable { case center, top }

    public var spacing: CGFloat
    public var lineSpacing: CGFloat
    public var lineAlignment: LineAlignment

    public init(spacing: CGFloat = 6, lineSpacing: CGFloat? = nil, lineAlignment: LineAlignment = .center) {
        self.spacing = spacing; self.lineSpacing = lineSpacing ?? spacing; self.lineAlignment = lineAlignment
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let dy = lineAlignment == .center ? (line.height - size.height) / 2 : 0
                subviews[index].place(at: CGPoint(x: x, y: y + dy), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    struct Line { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    /// Greedy line breaking: a child goes on the current line unless it would pass `width` and the line already has one.
    func arrange(width: CGFloat, sizes: [CGSize]) -> [Line] {
        var lines: [Line] = [Line()]
        for (index, size) in sizes.enumerated() {
            let last = lines.count - 1
            let needed = lines[last].indices.isEmpty ? size.width : lines[last].width + spacing + size.width
            if needed > width, !lines[last].indices.isEmpty {
                lines.append(Line(indices: [index], width: size.width, height: size.height))
            } else {
                lines[last].indices.append(index)
                lines[last].width = needed
                lines[last].height = max(lines[last].height, size.height)
            }
        }
        return lines.filter { !$0.indices.isEmpty }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        arrange(width: width, sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }
}

/// `.grp` / `.list`: a card of rows separated by hairlines, on the card colour with a separator edge.
public struct RowCard<Content: View>: View {
    @ViewBuilder public var content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).fill(OColor.card))
            .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).strokeBorder(OColor.separator, lineWidth: OMetric.hairline))
            .clipShape(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous))
    }
}

/// `.spn`: the checking ring, one of the two things the system lets move; it stands still under Reduce Motion.
public struct Spinner: View {
    public var size: CGFloat
    public var lineWidth: CGFloat
    public var track: Color
    public var arc: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(size: CGFloat = 10, lineWidth: CGFloat = 1.8, track: Color = OColor.fill2, arc: Color = OColor.accent) {
        self.size = size; self.lineWidth = lineWidth; self.track = track; self.arc = arc
    }

    public var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: OMotion.spinnerPeriod) / OMotion.spinnerPeriod
            ZStack {
                Circle().stroke(track, lineWidth: lineWidth)
                Circle().trim(from: 0, to: 0.28).stroke(arc, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(reduceMotion ? 0 : turn * 360))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// `.cap1`: the floating card's 19 pt capsule in the popover material, with a hairline and a soft drop shadow.
/// `folded` trims it to its leading mark.
public struct CardCapsule<Content: View>: View {
    public var tint: Color
    public var foreground: Color
    public var folded: Bool
    @ViewBuilder public var content: Content

    public init(tint: Color = OColor.popover, foreground: Color = OColor.text1, folded: Bool = false, @ViewBuilder content: () -> Content) {
        self.tint = tint; self.foreground = foreground; self.folded = folded; self.content = content()
    }

    public var body: some View {
        HStack(spacing: 4) { content }
            .font(OFont.capsule)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.leading, folded ? 3 : 5)
            .padding(.trailing, folded ? 3 : 8)
            .frame(height: OMetric.FloatingCard.capsuleHeight)
            .background(Capsule().fill(tint))
            .overlay(Capsule().strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
            .fixedSize()
            .accessibilityHidden(true)
    }
}
