// The menu bar icon picker (G-21): a grid of the sixteen marks with live previews and the colour style picker, shared by
// Settings → About ("Menu bar icon") and setup's "Pick your menu bar icon" step. Each cell shows its mark in the current
// state on a small menu bar chip of the window's appearance; hovering a cell plays that state's motion in place (the
// checking loop, the catch's snap, the pause cross-fade…). Picking writes the setting at once, so the real menu bar
// follows while the person chooses.
public import SwiftUI
public import ObscuraPrefs

/// What a preview cell plays, as a pure function of the time since the pointer arrived.
public enum MarkPreview {
    /// The motion a state plays when its cell is hovered; nil when the state loops (checking) or has nothing to play.
    /// States with no motion of their own (protected, partly protected) play the snap shut on their own look: the motion
    /// that shows each mark's character, without pretending a catch happened.
    public static func motion(for state: MarkState, mark: MenuBarMarkID) -> MarkMotion? {
        if mark == .classic {
            return state.hasDot ? .updateFade : nil
        }
        switch state {
        case .checking: return nil
        case .caught: return .caught
        case .needsAttention: return .needsYouPop
        case .waiting, .focusHolding: return .updateFade
        case .paused: return .pauseCrossFade
        case .protected, .partlyProtected: return .caught
        }
    }

    /// The pause between two plays of a preview.
    public static let rest: TimeInterval = 1.2

    /// The frame a cell shows `elapsed` seconds after the pointer arrived (nil: not hovered), or its resting frame under
    /// Reduce Motion.
    public static func frame(mark: MenuBarMarkID, style: MenuBarMarkStyle, state: MarkState, elapsed: TimeInterval?,
                             reduceMotion: Bool) -> MarkFrame {
        var frame = MarkFrame(mark: mark, style: style, state: state)
        guard let elapsed, !reduceMotion else { return frame }
        if state == .checking {
            if mark == .classic { frame.sweep = (elapsed / MarkTiming.sweepPeriod).truncatingRemainder(dividingBy: 1) }
            else { frame.pose.scanY = MarkTimeline.scanY(at: elapsed) }
            return frame
        }
        guard let motion = motion(for: state, mark: mark) else { return frame }
        let pieces = mark.designedPieceCount
        let cycle = MarkTimeline.duration(motion, pieces: pieces) + rest
        frame.pose = MarkTimeline.pose(motion, pieces: pieces, at: elapsed.truncatingRemainder(dividingBy: cycle))
        if motion == .pauseCrossFade { frame.crossFrom = .protected }
        if motion == .caught, state != .caught { frame.pose.dotOpacity = 1 }
        return frame
    }

    /// The gallery's menu bar colours behind a preview (`.lt` / `.dk` `--kb`).
    public static func barColor(dark: Bool) -> Color {
        dark ? Color(red: 0x20 / 255, green: 0x20 / 255, blue: 0x24 / 255) : Color(red: 0xEC / 255, green: 0xEC / 255, blue: 0xF0 / 255)
    }
}

/// The grid and the style picker.
public struct MarkPicker: View {
    public var selection: MenuBarMarkID
    public var style: MenuBarMarkStyle
    /// The state the previews show: the mark's state right now.
    public var state: MarkState
    public var pausedColor: PausedColor
    public var onPick: (MenuBarMarkID) -> Void
    public var onStyle: (MenuBarMarkStyle) -> Void
    public var columns: Int

    public init(selection: MenuBarMarkID, style: MenuBarMarkStyle, state: MarkState, pausedColor: PausedColor, columns: Int = 4,
                onPick: @escaping (MenuBarMarkID) -> Void, onStyle: @escaping (MenuBarMarkStyle) -> Void) {
        self.selection = selection
        self.style = style
        self.state = state
        self.pausedColor = pausedColor
        self.columns = columns
        self.onPick = onPick
        self.onStyle = onStyle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(rows, id: \.self) { row in
                    GridRow {
                        ForEach(row) { mark in
                            MarkPickerCell(mark: mark, style: style, state: state, pausedColor: pausedColor,
                                           isSelected: mark == selection) { onPick(mark) }
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Text("Colour").font(.system(size: 12.5)).foregroundStyle(OColor.text1)
                Picker(String(localized: "Colour"), selection: Binding(get: { style }, set: { onStyle($0) })) {
                    ForEach(MenuBarMarkStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(!selection.takesColourStyle)
                Text(selection.takesColourStyle ? String(localized: "The coloured part takes the style; the rest follows the menu bar.")
                                                : String(localized: "The Classic ring is one colour."))
                    .font(.system(size: 11.5)).foregroundStyle(OColor.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Menu bar icon"))
    }

    private var rows: [[MenuBarMarkID]] {
        let all = MenuBarMarkID.allCases
        return stride(from: 0, to: all.count, by: columns).map { Array(all[$0..<min($0 + columns, all.count)]) }
    }
}

/// One mark: its live preview on a menu bar chip, and its name.
struct MarkPickerCell: View {
    let mark: MenuBarMarkID
    let style: MenuBarMarkStyle
    let state: MarkState
    let pausedColor: PausedColor
    let isSelected: Bool
    let pick: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoverStart: Date?

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 5) {
                preview
                    .frame(width: 46, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(MarkPreview.barColor(dark: colorScheme == .dark)))
                Text(mark.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? OColor.accentText : OColor.text2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous).fill(isSelected ? OColor.accentSoft : .clear))
            .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous)
                .strokeBorder(isSelected ? OColor.accent : OColor.separator, lineWidth: isSelected ? 1.5 : OMetric.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hoverStart = inside ? Date() : nil }
        .accessibilityLabel(Text(mark.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(Text("Uses this icon in the menu bar"))
    }

    @ViewBuilder private var preview: some View {
        if let hoverStart, !reduceMotion {
            // Frames only while the pointer is on this cell; nothing runs for the others.
            TimelineView(.animation) { context in
                image(elapsed: context.date.timeIntervalSince(hoverStart))
            }
        } else {
            image(elapsed: nil)
        }
    }

    private func image(elapsed: TimeInterval?) -> some View {
        let dark = colorScheme == .dark
        let frame = MarkPreview.frame(mark: mark, style: style, state: state, elapsed: elapsed, reduceMotion: reduceMotion)
        let look = MarkLook(appearance: MarkAppearance(isDark: dark), pausedColor: pausedColor)
        let ns = MenuBarMarkImage.image(frame, look)
        return Image(nsImage: ns)
            .renderingMode(ns.isTemplate ? .template : .original)
            .foregroundStyle(Color(cgColor: MarkPalette.ink(look.appearance).cgColor))
            .accessibilityHidden(true)
    }
}
