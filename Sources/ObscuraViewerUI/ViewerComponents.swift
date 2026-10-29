// Viewer-only components from system.html (.chip, .num, .fnd, .step, .seg, the h5 section label and the icon label).
// The shared ones the viewer first built here (the pill with its icon, .finding, .ck, .kbd, .ibtn, .btn.ghost) now live
// in ObscuraUIKit.
import SwiftUI
import ObscuraUIKit

/// `.chip`: a finding named in the strip, with a swatch of the cover; `visible` is the orange left-visible form.
struct FindingChip: View {
    var name: String
    var visible: Bool
    var body: some View {
        HStack(spacing: 6) {
            if visible {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(OColor.needs, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                    .frame(width: 14, height: 8)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(OColor.mark).frame(width: 14, height: 8)
            }
            Text(name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            if visible { Image(systemName: "eye").font(.system(size: 10.5, weight: .medium)) }
        }
        .foregroundStyle(visible ? OColor.needsText : OColor.text1)
        .padding(.leading, 6).padding(.trailing, 9)
        .frame(height: 24)
        .background(Capsule().fill(visible ? OColor.needsSoft : OColor.card))
        .overlay(Capsule().strokeBorder(visible ? OColor.needs : OColor.hairline, lineWidth: OMetric.hairline))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text(ViewerCopy.findingState(enabled: !visible)))
    }
}

/// `.num`: the numbered badge on a bar and beside its row; orange when the finding is left visible.
struct NumberBadge: View {
    var number: Int
    var visible: Bool
    var body: some View {
        Text("\(number)")
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(visible ? OColor.needs : OColor.accent))
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
    }
}

/// `.fnd`: a finding row in the inspector's Black out list. The whole row is the toggle.
struct FindingToggleRow: View {
    var name: String
    var on: Bool
    /// The trailing word: "blacked out" / "left visible", or "on" in the test shot.
    var stateText: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Checkbox(isOn: on)
                Text(name).font(.system(size: 12.5)).foregroundStyle(OColor.text1).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text(stateText).font(.system(size: 11)).foregroundStyle(on ? OColor.text3 : OColor.needsText)
            }
            .padding(.vertical, 5).padding(.horizontal, 7)
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.ml, style: .continuous).fill(on ? Color.clear : OColor.needsSoft))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text(stateText))
        .accessibilityAddTraits(.isToggle)
    }
}

/// `.step`: one done step of the first-run story.
struct StepRow: View {
    var text: String
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(OColor.ok).frame(width: 16, height: 16)
                .overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white))
                .accessibilityHidden(true)
            Text(text).font(.system(size: 12)).foregroundStyle(OColor.text1).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The inspector's small uppercase section label (h5).
struct SectionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.55)
            .foregroundStyle(OColor.text2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A button label: a 12 pt symbol and one line of text that never wraps (`.btn .ic`).
struct IconLabel: View {
    var title: String
    var symbol: String
    init(_ title: String, symbol: String) { self.title = title; self.symbol = symbol }
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12, weight: .regular)).accessibilityHidden(true)
            Text(title).lineLimit(1)
        }
        .fixedSize()
    }
}

/// `.seg`: the Redacted / Original control. The Original cell turns red when selected; Tab toggles (handled by the
/// window). Exposed to VoiceOver as a picker.
struct ModeSwitch: View {
    var mode: ViewerMode
    var originalAvailable: Bool
    var set: (ViewerMode) -> Void

    var body: some View {
        HStack(spacing: 1) {
            segment(.redacted, ViewerCopy.redacted)
            segment(.original, ViewerCopy.original)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: OMetric.Radius.ml, style: .continuous).fill(OColor.fill))
        .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.ml, style: .continuous).strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
        .fixedSize()
        .help(String(localized: "Switch between the redacted file and the original (Tab). Hold the image to peek; Space compares."))
        .accessibilityRepresentation {
            Picker(String(localized: "Show"), selection: Binding(get: { mode }, set: { set($0) })) {
                Text(ViewerCopy.redacted).tag(ViewerMode.redacted)
                Text(ViewerCopy.original).tag(ViewerMode.original)
            }
            .pickerStyle(.segmented)
        }
    }

    private func segment(_ m: ViewerMode, _ title: String) -> some View {
        let selected = mode == m
        let red = selected && m == .original
        return Button { set(m) } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(red ? OColor.liveText : OColor.text1)
                .padding(.horizontal, 10)
                .frame(minHeight: 20)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: OMetric.Radius.s, style: .continuous)
                            .fill(OColor.segmentSelected)
                            .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                            .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.s, style: .continuous).strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(m == .original && !originalAvailable)
        .opacity(m == .original && !originalAvailable ? 0.45 : 1)
    }
}
