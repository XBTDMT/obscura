// Journal-only views from system.html: SelectionMark (the grid's round selection mark), SectionHeader (.isec) and
// CategoryTile (.fi). The shared pieces the Journal first built here (the verdict badge, the status box, the checkbox,
// the key cap, the flexible screenshot chrome, the icon button, the small button and the wrapping layout) now live in
// ObscuraUIKit.
import AppKit
import SwiftUI
import ObscuraUIKit

/// The round selection mark on a grid card while several are selected.
struct SelectionMark: View {
    var isOn: Bool
    var body: some View {
        Circle()
            .fill(isOn ? OColor.accent : OColor.control.opacity(0.9))
            .overlay {
                if isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white) }
                else { Circle().strokeBorder(OColor.hairline, lineWidth: 1) }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }
}

/// An inspector section header: icon, title, optional key cap and trailing controls.
struct SectionHeader<Trailing: View>: View {
    var title: String
    var symbol: String
    var shortcut: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, symbol: String, shortcut: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.symbol = symbol; self.shortcut = shortcut; self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(OColor.text3).frame(width: 12)
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(OColor.text2)
            if let shortcut { KeyCap(shortcut).accessibilityHidden(true) }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.bottom, -4)
    }
}

/// A detector's tile: category colour, white symbol.
struct CategoryTile: View {
    var category: String
    var detectorID: String
    var body: some View {
        RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous)
            .fill(OColor.category(category))
            .frame(width: 22, height: 22)
            .overlay(Image(systemName: DetectorGlyph.symbol(category: category, detectorID: detectorID))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}
