// Building blocks the Settings panes share. Each is a system.html piece only Settings draws (pane header, headline
// lead, icon row, switch, field chrome, sentence token, note box, overview tile, pill tabs). The shared ones Settings
// first built here (the small button, the badge with a symbol, the wrapping layout, the card of rows) live in
// ObscuraUIKit.
import SwiftUI
import ObscuraUIKit

// MARK: - Pane scaffold

/// `.ph` + `.pb`: a 52 pt header with the pane title and its controls, a scrolling body, an optional sticky footer.
struct PaneScaffold<Header: View, Content: View, Footer: View>: View {
    var title: String
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    init(_ title: String, @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title; self.header = header(); self.content = content(); self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(OColor.text1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                header
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            footer
        }
    }
}

extension PaneScaffold where Footer == EmptyView {
    init(_ title: String, @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.init(title, header: header, content: content, footer: { EmptyView() })
    }
}

extension PaneScaffold where Header == EmptyView, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, header: { EmptyView() }, content: content, footer: { EmptyView() })
    }
}

/// `.lead`: the pane's one headline sentence with its state dot.
struct Lead: View {
    var tone: Tone
    var title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            StatusDot(tone, size: 10).padding(.top, 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(OColor.text1)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(OFont.callout).foregroundStyle(OColor.text2)
                        .frame(maxWidth: 560, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 2).padding(.horizontal, 2).padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }
}

/// `.gh`: a group heading with an optional trailing value or link.
struct GroupHeading: View {
    var title: String
    var trailing: String?
    var link: (title: String, action: () -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(OFont.groupHeader).foregroundStyle(OColor.text2).accessibilityAddTraits(.isHeader)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11.5)).foregroundStyle(OColor.text2) }
            if let link {
                Button(link.title, action: link.action).buttonStyle(.plain)
                    .font(.system(size: 11.5)).foregroundStyle(OColor.accentText)
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

/// `.grp`: the kit's card of rows, with the space a settings group leaves under it.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        RowCard { content }.padding(.bottom, 14)
    }
}

/// A hairline between rows of a card.
struct RowDivider: View {
    var leading: CGFloat = 0
    var body: some View { Rectangle().fill(OColor.separator).frame(height: OMetric.hairline).padding(.leading, leading) }
}

/// `.grow`: optional coloured icon tile, title and help, controls on the right.
struct SettingRow<Control: View>: View {
    var icon: (symbol: String, color: Color?)?
    var title: String
    var help: String?
    var titleIsMono = false
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                RoundedRectangle(cornerRadius: OMetric.Radius.ml, style: .continuous)
                    .fill(icon.color ?? OColor.fill)
                    .frame(width: 26, height: 26)
                    .overlay(Image(systemName: icon.symbol).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(icon.color == nil ? OColor.text3 : .white))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(OColor.text1)
                    .lineLimit(1).truncationMode(.middle)
                if let help {
                    Text(help).font(.system(size: 11.5)).foregroundStyle(OColor.text2)
                        .lineSpacing(1).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) { control }.fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 38)
    }
}

// MARK: - Controls

/// The system switch in the accent: `.tg` (small control) on settings and rule rows, `.tg.sm` (mini) on dense
/// detector rows and category headers (CHANGES.md 38).
struct Switch: View {
    var label: String
    @Binding var isOn: Bool
    var dense = false

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(dense ? .mini : .small)
            .tint(OColor.accent)
            .accessibilityLabel(Text(label))
    }
}

/// A switch bound to an async write: shows the new value at once, then stores it. Until the write lands the switch
/// shows the value it was flipped to, so the knob moves once and never bounces back for a frame (recon T-14); when the
/// write lands the stored value takes over again (and a failed write puts the switch back).
struct AsyncSwitch: View {
    var label: String
    var isOn: Bool
    var dense = false
    var set: (Bool) async -> Void
    @State private var pending: Bool?

    var body: some View {
        Switch(label: label, isOn: Binding(get: { Self.shown(stored: isOn, pending: pending) }, set: { v in
            pending = v
            Task {
                await set(v)
                if pending == v { pending = nil }
            }
        }), dense: dense)
    }

    /// What the switch shows: the flip in flight, else the stored value.
    static func shown(stored: Bool, pending: Bool?) -> Bool { pending ?? stored }
}

/// `.fld` chrome around a plain text field: the field colour, a hairline, the accent focus ring, the red ring
/// when invalid.
struct FieldChrome: ViewModifier {
    var focused: Bool
    var invalid: Bool
    var mono = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous).fill(OColor.field))
            .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous)
                .strokeBorder(invalid ? OColor.live : (focused ? OColor.accent : OColor.hairline),
                              lineWidth: invalid || focused ? 1 : OMetric.hairline))
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.m + 3, style: .continuous)
                .fill(invalid ? OColor.liveSoft : (focused ? OColor.accentSoft : .clear))
                .padding(-3))
    }
}

extension View {
    func fieldChrome(focused: Bool, invalid: Bool = false, mono: Bool = false) -> some View {
        modifier(FieldChrome(focused: focused, invalid: invalid, mono: mono))
    }
}

/// `.err`: the inline red sentence under a field.
struct InlineError: View {
    var text: String
    var body: some View {
        Label { Text(text) } icon: { Image(systemName: "exclamationmark.circle") }
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11.5))
            .foregroundStyle(OColor.liveText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `.tok`: a word or value inside a sentence.
struct Token: View {
    enum Kind { case blackOut, allow, value, mono, accent }
    var text: String
    var kind: Kind

    var body: some View {
        Text(text)
            .font(kind == .mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5, weight: kind == .value ? .regular : .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.ml, style: .continuous).fill(background))
    }

    var foreground: Color {
        switch kind {
        case .blackOut: return OColor.markText
        case .allow: return OColor.okText
        case .value, .mono: return OColor.text1
        case .accent: return OColor.accentText
        }
    }

    var background: Color {
        switch kind {
        case .blackOut: return OColor.mark
        case .allow: return OColor.okSoft
        case .value, .mono: return OColor.fill2
        case .accent: return OColor.accentSoft
        }
    }
}

/// `.gnote`: a soft note box, neutral, green or orange.
struct NoteBox: View {
    var text: String
    var tone: Tone = .quiet
    var symbol: String?

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            if let symbol { Image(systemName: symbol).font(.system(size: 12)).padding(.top, 1) }
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(tone == .quiet ? OColor.text2 : tone.text)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: OMetric.Radius.l, style: .continuous).fill(tone == .quiet ? OColor.fill : tone.soft))
        .accessibilityElement(children: .combine)
    }
}

/// `.ctile`: an overview tile with a symbol, a title, a count line and one dot per item.
struct OverviewTile: View {
    var symbol: String
    var title: String
    var shortTitle: String?
    var count: String
    var dots: [Tone]
    var selected: Bool
    var dimmed = false
    var isAdd = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(isAdd ? OColor.accent : OColor.text2)
                    ViewThatFits(in: .horizontal) {
                        Text(title).fixedSize()
                        if let shortTitle { Text(shortTitle).fixedSize() }
                        Text(shortTitle ?? title).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isAdd ? OColor.accentText : OColor.text1)
                }
                Text(count).font(.system(size: 11)).foregroundStyle(OColor.text2).lineLimit(1)
                    .padding(.top, 2).padding(.bottom, 6)
                DotRow(dots: dots)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 62, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).fill(OColor.card))
            .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous)
                .strokeBorder(selected ? OColor.accent : (isAdd ? OColor.accent : OColor.separator),
                              lineWidth: selected ? 2 : (isAdd ? 1 : OMetric.hairline)))
            .contentShape(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous))
            .opacity(dimmed && !selected ? 0.62 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title), \(count)"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// `.dots`: 7 pt rounded squares, wrapping.
struct DotRow: View {
    var dots: [Tone]
    var body: some View {
        FlowLayout(spacing: 3, lineAlignment: .top) {
            ForEach(Array(dots.enumerated()), id: \.offset) { _, tone in
                RoundedRectangle(cornerRadius: 2).fill(tone == .quiet ? OColor.toggleOff : tone.color).frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}

/// `.ptabs`: All / Edited N / Off N.
struct PillTabs<Value: Hashable>: View {
    var items: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let on = item.value == selection
                Button { selection = item.value } label: {
                    Text(item.title)
                        .font(.system(size: 12, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? OColor.text1 : OColor.text2)
                        .padding(.horizontal, 9).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: OMetric.Radius.ml, style: .continuous)
                            .fill(on ? OColor.control : .clear)
                            .shadow(color: on ? .black.opacity(0.12) : .clear, radius: 0.5, y: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

/// The severity legend that sits beside the pill tabs (open decision 9: colours kept with the legend on the line).
struct SeverityLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach([SeverityMark.Level.critical, .high, .medium, .low], id: \.rawValue) { level in
                HStack(spacing: 4) {
                    SeverityMark(level).accessibilityHidden(true)
                    Text(SeverityWords.title(level))
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(OColor.text3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Severity: Critical, High, Medium, Low"))
    }
}

enum SeverityWords {
    static func title(_ level: SeverityMark.Level) -> String {
        switch level {
        case .critical: return String(localized: "Critical")
        case .high: return String(localized: "High")
        case .medium: return String(localized: "Medium")
        case .low: return String(localized: "Low")
        }
    }
}

/// A rounded-rect section over the material colour of the sticky footer.
struct StickyBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .background(OColor.sidebar)
            .overlay(alignment: .top) { Rectangle().fill(OColor.separator).frame(height: OMetric.hairline) }
    }
}
