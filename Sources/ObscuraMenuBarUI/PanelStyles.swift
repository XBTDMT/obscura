// Panel-only pieces of design/mockups/unified/system.html: the halo dot, the panel card (.card), the menu row with its
// highlight (.mi / .mi.hl) and the indeterminate progress bar (.prog). The small button (.btn.sm), the wrapping button
// row (.btns) and the menu bar mark's count badge live in ObscuraUIKit.
import SwiftUI
import ObscuraUIKit

/// The panel's type sizes (menubar.html: .hdr .t 13.5, .s 12, .card .ct 11.5, .catch b 13, small 11.5, .mi 13 …).
enum PanelFont {
    static let headerTitle = Font.system(size: 13.5, weight: .semibold)
    static let headerSentence = Font.system(size: 12)
    static let cardTitle = Font.system(size: 11.5, weight: .semibold)
    static let cardTrailing = Font.system(size: 11.5)
    static let itemTitle = Font.system(size: 13, weight: .medium)
    static let itemDetail = Font.system(size: 11.5)
    static let bannerTitle = Font.system(size: 12.5, weight: .semibold)
    static let bannerBody = Font.system(size: 11.5)
    static let menu = Font.system(size: 13)
    static let menuKey = Font.system(size: 12.5)
    static let menuAccessory = Font.system(size: 12)
    static let footer = Font.system(size: 11.5)
    static let statLabel = Font.system(size: 11)
    static let dayInitial = Font.system(size: 9.5)
}

/// A status dot with the soft 3 pt ring the panel header draws (.dot.halo).
struct HaloDot: View {
    var tone: Tone
    var halo: Bool
    var body: some View {
        StatusDot(tone)
            .background(Circle().fill(halo ? tone.soft : .clear).frame(width: 14, height: 14))
            .accessibilityHidden(true)
    }
}

extension PanelSnapshot.ButtonRole {
    var kitRole: OButtonStyle.Role {
        switch self {
        case .quiet: return .quiet
        case .primary: return .primary
        case .warn: return .warn
        }
    }
}

/// .card: the quiet filled card the panel stacks (radius 10, 9 × 10 padding).
struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).fill(OColor.fill))
    }
}

/// .card .ct: the card's small header line with an optional right side.
struct CardTitle<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(PanelFont.cardTitle).foregroundStyle(OColor.text2)
            Spacer(minLength: 6)
            trailing.font(PanelFont.cardTrailing).foregroundStyle(OColor.text2)
        }
        .padding(.bottom, 6)
    }
}

extension EnvironmentValues {
    /// True inside a highlighted menu row, so secondary text turns white with it.
    @Entry var menuRowHighlighted = false
}

/// .mi: a full-width row that fills with the accent while hovered or pressed (.mi.hl).
struct MenuRowButtonStyle: ButtonStyle {
    /// Keeps the row lit while something it opened is showing (the Pause row while its choices are open).
    var lit = false

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, forced: lit)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let forced: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let lit = isEnabled && (hovering || configuration.isPressed || forced)
            configuration.label
                .environment(\.menuRowHighlighted, lit)
                .foregroundStyle(lit ? Color.white : (isEnabled ? OColor.text1 : OColor.text3))
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: OMetric.Radius.ml, style: .continuous).fill(lit ? OColor.accent : .clear))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// .prog: a 4 pt track with a 40 % bar sweeping across while the OCR runs; still under Reduce Motion.
struct IndeterminateBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let period: TimeInterval = 1.6

    var body: some View {
        GeometryReader { geo in
            let barWidth = geo.size.width * 0.4
            ZStack(alignment: .leading) {
                Rectangle().fill(OColor.fill2)
                if reduceMotion {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(OColor.accent).frame(width: barWidth)
                } else {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
                        let eased = 0.5 - cos(t * .pi) / 2
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(OColor.accent)
                            .frame(width: barWidth)
                            .offset(x: barWidth * (-1 + 3.6 * eased))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel(Text("In progress"))
        .accessibilityAddTraits(.updatesFrequently)
    }
}
