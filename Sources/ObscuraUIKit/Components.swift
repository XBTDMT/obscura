// Shared components from design/mockups/unified/system.html. Surfaces compose these; they do not restyle them.
public import SwiftUI

/// The meaning a dot, pill or banner carries. One tone per meaning across every surface.
public enum Tone: Sendable, Hashable {
    /// Safe to share, protected, done.
    case ok
    /// Partly protected, left visible, needs you.
    case needs
    /// Original showing, destructive.
    case live
    /// Accent: working, waiting, selected.
    case accent
    /// Paused, idle, off.
    case quiet

    public var color: Color {
        switch self {
        case .ok: return OColor.ok
        case .needs: return OColor.needs
        case .live: return OColor.live
        case .accent: return OColor.accent
        case .quiet: return OColor.text3
        }
    }

    public var text: Color {
        switch self {
        case .ok: return OColor.okText
        case .needs: return OColor.needsText
        case .live: return OColor.liveText
        case .accent: return OColor.accentText
        case .quiet: return OColor.text2
        }
    }

    public var soft: Color {
        switch self {
        case .ok: return OColor.okSoft
        case .needs: return OColor.needsSoft
        case .live: return OColor.liveSoft
        case .accent: return OColor.accentSoft
        case .quiet: return OColor.fill
        }
    }
}

/// An 8 pt status dot.
public struct StatusDot: View {
    public var tone: Tone
    public var size: CGFloat
    public init(_ tone: Tone, size: CGFloat = 8) { self.tone = tone; self.size = size }
    public var body: some View {
        Circle().fill(tone.color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// `.pill`: the one verdict shape (22 pt, radius 11) with a soft fill and toned words, optionally led by a dot or by a
/// symbol, so the state reads in shape as well as colour.
public struct Pill: View {
    public var text: String
    public var tone: Tone
    public var showsDot: Bool
    public var symbol: String?
    public init(_ text: String, tone: Tone, showsDot: Bool = false, symbol: String? = nil) {
        self.text = text; self.tone = tone; self.showsDot = showsDot; self.symbol = symbol
    }
    public var body: some View {
        HStack(spacing: 5) {
            if showsDot { StatusDot(tone, size: 6) }
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).accessibilityHidden(true) }
            Text(text).font(OFont.pill).lineLimit(1)
        }
        .foregroundStyle(tone.text)
        .padding(.horizontal, 9)
        .frame(height: OMetric.Control.pillHeight)
        .background(Capsule().fill(tone.soft))
        .fixedSize()
    }
}

/// `.bdg`: the small rectangular badge (18 pt, radius 5) for row states, corner verdicts and Edited / Off / Opt-in,
/// optionally led by a symbol. `textColor` overrides the tone's words (`.bdg.optin` is quiet with tertiary words).
public struct Badge: View {
    public var text: String
    public var tone: Tone
    public var symbol: String?
    public var textColor: Color?
    public init(_ text: String, tone: Tone = .quiet, symbol: String? = nil, textColor: Color? = nil) {
        self.text = text; self.tone = tone; self.symbol = symbol; self.textColor = textColor
    }
    public var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)).accessibilityHidden(true) }
            Text(text).font(OFont.badge).lineLimit(1)
        }
        .foregroundStyle(textColor ?? tone.text)
        .padding(.horizontal, 7)
        .frame(height: OMetric.Control.badgeHeight)
        .background(RoundedRectangle(cornerRadius: OMetric.Radius.s, style: .continuous).fill(tone.soft))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Detector severity, as a small three-bar signal mark with a colour that ranks (red critical, orange high).
public struct SeverityMark: View {
    public enum Level: Int, Sendable { case low = 1, medium = 2, high = 3, critical = 4 }
    public var level: Level
    public init(_ level: Level) { self.level = level }
    public var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= min(level.rawValue, 3) ? color : OColor.toggleOff)
                    .frame(width: 3, height: CGFloat(3 + i * 3))
            }
        }
        .accessibilityLabel(Text(label))
    }
    var color: Color {
        switch level {
        case .critical: return OColor.live
        case .high: return OColor.needs
        case .medium, .low: return OColor.text2
        }
    }
    var label: String {
        switch level {
        case .critical: return String(localized: "Critical")
        case .high: return String(localized: "High")
        case .medium: return String(localized: "Medium")
        case .low: return String(localized: "Low")
        }
    }
}

/// `.btn` in its roles and two sizes: the 24 pt button and the 21 pt `.btn.sm` used in cards, rows and banners.
/// A disabled button dims to `OMetric.Control.disabledOpacity` (`.btn.dis`) in every role and size.
public struct OButtonStyle: ButtonStyle {
    public enum Role: Sendable { case primary, quiet, warn, danger, ghost, plain }
    public enum Size: Sendable { case regular, small }
    public var role: Role
    public var size: Size
    public init(_ role: Role = .quiet, size: Size = .regular) { self.role = role; self.size = size }

    public func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, style: self)
    }

    /// Reads `isEnabled` so a disabled button looks disabled in every role.
    private struct StyledButton: View {
        let configuration: Configuration
        let style: OButtonStyle
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            switch style.size {
            case .regular:
                style.chrome(configuration.label.font(OFont.button), height: OMetric.Control.buttonHeight, minimum: true,
                             sidePadding: 11, pressed: configuration.isPressed, enabled: isEnabled)
            case .small:
                style.chrome(configuration.label.labelStyle(SmallButtonLabelStyle()).font(OFont.smallButton).lineLimit(1),
                             height: OMetric.Control.smallButtonHeight, minimum: false, sidePadding: 8,
                             pressed: configuration.isPressed, enabled: isEnabled)
                    .fixedSize()
            }
        }
    }

    fileprivate func chrome(_ label: some View, height: CGFloat, minimum: Bool, sidePadding: CGFloat, pressed: Bool,
                            enabled: Bool) -> some View {
        label
            .foregroundStyle(foreground)
            .padding(.horizontal, role == .plain ? 4 : sidePadding)
            .frame(minHeight: minimum ? height : nil)
            .frame(height: minimum ? nil : height)
            .background(
                // `--o-shadow-ctl`: the hairline ring and the 1 pt drop, under the raised roles only (system.html gives
                // .pri, .warn, .ghost and .plain `box-shadow: none`). The drop is cast by the fill, never by the words.
                RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous)
                    .fill(background)
                    .shadow(castsControlShadow ? OShadow.control : OShadow.none)
                    .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous)
                        .strokeBorder(castsControlShadow ? OColor.hairline : .clear, lineWidth: OMetric.hairline))
            )
            .opacity(enabled ? (pressed ? OMetric.Control.pressedOpacity : 1) : OMetric.Control.disabledOpacity)
            .contentShape(Rectangle())
    }

    /// `.btn` and `.btn.danger` sit raised on `--o-shadow-ctl` (hairline + drop); the filled and bare roles do not.
    var castsControlShadow: Bool { role == .quiet || role == .danger }

    var foreground: Color {
        switch role {
        case .primary, .warn: return .white
        case .quiet, .ghost: return OColor.text1
        case .danger: return OColor.liveText
        case .plain: return OColor.accentText
        }
    }

    var background: Color {
        switch role {
        case .primary: return OColor.accent
        case .warn: return OColor.needs
        case .quiet, .danger: return OColor.control
        case .ghost: return OColor.fill
        case .plain: return .clear
        }
    }
}

/// `.btn.sm .ic`: a small button's icon and title, 5 pt apart, the icon a step smaller than the words.
struct SmallButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 10.5, weight: .semibold))
            configuration.title
        }
    }
}

/// A titled group box: header line, then a card holding rows separated by hairlines.
public struct OGroup<Content: View>: View {
    public var title: String?
    public var trailing: String?
    @ViewBuilder public var content: Content
    public init(_ title: String? = nil, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.trailing = trailing; self.content = content()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if title != nil || trailing != nil {
                HStack {
                    if let title { Text(title).font(OFont.groupHeader).foregroundStyle(OColor.text2) }
                    Spacer()
                    if let trailing { Text(trailing).font(OFont.callout).foregroundStyle(OColor.text2) }
                }
                .padding(.horizontal, 2)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).fill(OColor.card))
                .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
        }
    }
}

/// One row inside an `OGroup`: title (and optional help line) on the left, a control on the right.
public struct ORow<Control: View>: View {
    public var title: String
    public var help: String?
    public var showsDivider: Bool
    @ViewBuilder public var control: Control
    public init(_ title: String, help: String? = nil, showsDivider: Bool = true, @ViewBuilder control: () -> Control) {
        self.title = title; self.help = help; self.showsDivider = showsDivider; self.control = control()
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(OFont.body).foregroundStyle(OColor.text1)
                    if let help { Text(help).font(OFont.caption).foregroundStyle(OColor.text2).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            if showsDivider { Rectangle().fill(OColor.separator).frame(height: OMetric.hairline).padding(.leading, 12) }
        }
    }
}

/// A coloured rounded tile holding an SF Symbol, as in the Settings sidebar.
public struct SymbolTile: View {
    public var symbol: String
    public var color: Color
    public var size: CGFloat
    public init(_ symbol: String, color: Color, size: CGFloat = 24) { self.symbol = symbol; self.color = color; self.size = size }
    public var body: some View {
        RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.6, weight: .semibold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

/// A screenshot thumbnail in the shared chrome at a fixed size (one chrome across panel, Journal, viewer, setup and
/// banners); the image fills it from the centre. `ShotImage` is the same chrome at any size.
public struct Thumbnail: View {
    public var image: NSImage?
    public var size: CGSize
    public init(_ image: NSImage?, size: CGSize = OMetric.thumbSmall) { self.image = image; self.size = size }
    public var body: some View {
        ShotImage(image: image, radius: OMetric.Radius.s, alignment: .center)
            .frame(width: size.width, height: size.height)
    }
}

/// A transient toast with an optional action (Undo, Show), used for deletes, stale sweeps and restores.
public struct Toast: View {
    public var message: String
    public var actionTitle: String?
    public var action: (() -> Void)?
    public init(_ message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.message = message; self.actionTitle = actionTitle; self.action = action
    }
    public var body: some View {
        HStack(spacing: 12) {
            Text(message).font(OFont.body).foregroundStyle(OColor.text1)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(OButtonStyle(.plain))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
        .shadow(color: .black.opacity(0.18), radius: 17, y: 12)
    }
}

// MARK: - The one toast presentation (G-15; recon T-5, T-6, T-7, S-13)

/// One toast as a surface shows it.
public struct ToastItem: Identifiable {
    public let id: UUID
    public var text: String
    public var actionTitle: String?
    public var action: (() -> Void)?

    public init(id: UUID, text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.id = id; self.text = text; self.actionTitle = actionTitle; self.action = action
    }
}

/// Where a surface's toasts sit. Each surface has exactly one place.
public enum ToastPlacement: Sendable {
    /// The Journal's undo ladder (system.html `.ladder`): up to three, newest on top, right-aligned under the toolbar.
    case ladder
    /// The bottom centre of a window's content or of the menu bar panel, clear of the toolbar and its banners.
    case bottom

    public var alignment: Alignment { self == .ladder ? .topTrailing : .bottom }
    var stackAlignment: HorizontalAlignment { self == .ladder ? .trailing : .center }
    var insets: EdgeInsets {
        switch self {
        // Under the Journal's 52 pt toolbar, level with the content's trailing margin.
        case .ladder: return EdgeInsets(top: 64, leading: 0, bottom: 0, trailing: 16)
        case .bottom: return EdgeInsets(top: 0, leading: 0, bottom: 14, trailing: 0)
        }
    }
}

/// The toasts of one surface: the shared `Toast` look, one place, one lifetime and one motion. A toast appears and
/// leaves with the one fade (instant under Reduce Motion) and never slides; nothing animates when the surface first
/// appears with a toast already up. The lifetime is `OMotion.toastSeconds` everywhere: a host that keeps its toasts in
/// a model (the app model, the Journal's ladder) expires them there; a host that keeps them in view state passes
/// `expire`, and the stack calls it when the toast's time is up.
public struct ToastStack: View {
    public var items: [ToastItem]
    public var placement: ToastPlacement
    public var expire: (@MainActor (UUID) -> Void)?

    public init(_ items: [ToastItem], placement: ToastPlacement, expire: (@MainActor (UUID) -> Void)? = nil) {
        self.items = items; self.placement = placement; self.expire = expire
    }

    public var body: some View {
        VStack(alignment: placement.stackAlignment, spacing: 6) {
            ForEach(items) { item in
                Toast(item.text, actionTitle: item.actionTitle, action: item.action)
                    .transition(OMotion.appear)
                    .task(id: item.id) {
                        guard let expire else { return }
                        try? await Task.sleep(for: .seconds(OMotion.toastSeconds))
                        guard !Task.isCancelled else { return }
                        expire(item.id)
                    }
            }
        }
        .oFade(value: items.map(\.id))
        .padding(placement.insets)
    }
}

public extension View {
    /// Lays a surface's toasts over it in that surface's one place (see `ToastStack`).
    func oToasts(_ items: [ToastItem], placement: ToastPlacement, expire: (@MainActor (UUID) -> Void)? = nil) -> some View {
        overlay(alignment: placement.alignment) { ToastStack(items, placement: placement, expire: expire) }
    }
}

public extension ToastMessage {
    /// The app model's toast as a surface shows it, its undo labelled Undo.
    var item: ToastItem {
        ToastItem(id: id, text: text, actionTitle: undo == nil ? nil : String(localized: "Undo"), action: undo)
    }
}
