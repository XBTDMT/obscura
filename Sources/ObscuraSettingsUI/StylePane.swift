// Redaction Style: a live sample (the invented terminal from SampleData, rendered through the real Redactor with the
// chosen style), Solid / Erase / Blur / Mosaic, colour, corners, padding, label and Reset. The default style is stored
// with `journal.setDefaultStyle`; screenshots already in the Journal keep the style they were redacted with.
import AppKit
import SwiftUI
import ObscuraUIKit
import ObscuraEngine
import ObscuraJournal
import ObscuraRender

struct StylePane: View {
    let session: SettingsSession
    /// The style being edited; follows the stored one and is stored when a control settles.
    @State private var style: StyleRecord = .builtInDefault
    @State private var preview: NSImage?
    @State private var zoom: CGFloat = 1
    @State private var pending: StyleRecord?

    var body: some View {
        PaneScaffold(String(localized: "Redaction Style")) {
            Lead(tone: .ok, title: StyleCopy.headline(style),
                 detail: String(localized: "Every style replaces the secret’s pixels first. Blur and Mosaic are drawn from made-up text, never from the secret, so they cannot be reversed."))
            sample
            GroupHeading(title: String(localized: "Default style"),
                         link: (String(localized: "Reset to Default"), { commit(.builtInDefault) }))
            Card { controls }
            Text("Used for new catches. Screenshots already in the Journal keep the style they were redacted with; change those from the Journal.")
                .font(.system(size: 11.5)).foregroundStyle(OColor.text2).lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2).padding(.top, -6)
        }
        .onAppear { style = session.defaultStyle }
        .task(id: pending) {
            guard let pending else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await session.setDefaultStyle(pending)
            if self.pending == pending { self.pending = nil }
        }
        .onDisappear {
            if let pending { Task { await session.setDefaultStyle(pending) } }
        }
        .onChange(of: session.defaultStyle) { _, new in if !new.sameAppearance(as: style) { style = new } }
        .task(id: style) {
            let spec = StyleBridge.spec(from: style)
            let image = await Task.detached(priority: .userInitiated) { StyleSample.render(spec) }.value
            if !Task.isCancelled { preview = image.map { NSImage(cgImage: $0, size: .zero) } }
        }
    }

    // MARK: Sample

    private var sample: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView([.horizontal, .vertical], showsIndicators: zoom > 1) {
                Group {
                    if let preview {
                        Image(nsImage: preview).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    } else {
                        OColor.terminal
                    }
                }
                .frame(width: 604 * zoom, height: StyleSample.aspect * 604 * zoom)
            }
            .scrollDisabled(zoom == 1)
            .frame(height: StyleSample.aspect * 604)
            .background(OColor.terminal)
            .clipShape(RoundedRectangle(cornerRadius: OMetric.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.l, style: .continuous).strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Sample terminal with four made-up secrets covered in the \(StyleCopy.kind(style.kind)) style"))
            .accessibilityAddTraits(.isImage)

            HStack(spacing: 2) {
                zoomButton("minus.magnifyingglass", String(localized: "Zoom Out")) { zoom = max(1, zoom - 0.5) }.disabled(zoom <= 1)
                zoomButton("arrow.up.left.and.arrow.down.right", String(localized: "Fit")) { zoom = 1 }
                zoomButton("plus.magnifyingglass", String(localized: "Zoom In")) { zoom = min(3, zoom + 0.5) }.disabled(zoom >= 3)
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.ml, style: .continuous).fill(.white.opacity(0.1)))
            .padding(10)
        }
        .padding(.top, 6).padding(.bottom, 14)
    }

    private func zoomButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        SettingRow(title: String(localized: "Style"), help: StyleCopy.kindHelp(style.kind)) {
            Picker(String(localized: "Style"), selection: Binding(get: { style.kind }, set: { k in var s = style; s.kind = k; commit(s) })) {
                ForEach(StyleKind.allCases, id: \.self) { Text(StyleCopy.kind($0)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        RowDivider()
        SettingRow(title: String(localized: "Colour"),
                   help: style.kind == .solid ? String(localized: "Box colour") : String(localized: "Box colour, used by Solid")) {
            ColorPicker(String(localized: "Box colour"), selection: Binding(get: { StyleColour.color(style.color) },
                                                                          set: { c in var s = style; s.color = StyleColour.string(c); commit(s) }),
                        supportsOpacity: false)
                .labelsHidden()
                .disabled(style.kind != .solid)
        }
        RowDivider()
        SettingRow(title: String(localized: "Corners"), help: String(localized: "From square to fully rounded")) {
            Image(systemName: "square").font(.system(size: 12)).foregroundStyle(OColor.text2).accessibilityHidden(true)
            Slider(value: Binding(get: { style.roundness }, set: { style.roundness = $0 }), in: 0...1) { editing in
                if !editing { commit(style) }
            }
            .frame(width: 140)
            .accessibilityLabel(Text("Corners"))
            Image(systemName: "capsule").font(.system(size: 12)).foregroundStyle(OColor.text2).accessibilityHidden(true)
        }
        RowDivider()
        SettingRow(title: String(localized: "Padding"), help: String(localized: "How far the cover reaches beyond each secret")) {
            Slider(value: Binding(get: { style.padding }, set: { style.padding = $0 }), in: 0...0.6) { editing in
                if !editing { commit(style) }
            }
            .frame(width: 140)
            .accessibilityLabel(Text("Padding"))
        }
        RowDivider()
        SettingRow(title: String(localized: "Label"), help: String(localized: "Text printed on each cover")) {
            Picker(String(localized: "Label"), selection: Binding(get: { style.labelMode }, set: { l in var s = style; s.labelMode = l; commit(s) })) {
                ForEach(LabelMode.allCases, id: \.self) { Text(StyleCopy.label($0)).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
        }
    }

    /// Shows the style at once and stores it once the control settles (a colour drag sends many values).
    private func commit(_ new: StyleRecord) {
        style = new
        pending = new
    }
}

/// "r,g,b,a" ↔ SwiftUI colour, in sRGB.
enum StyleColour {
    static func color(_ string: String) -> Color {
        let c = StyleBridge.rgba(from: string)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    static func string(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return StyleBridge.string(from: RGBA(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: 1))
    }
}

/// The Redaction Style sample: `SampleData.terminalPNG` with its four secret values as findings, rendered through
/// `Redactor`. The geometry is `SampleData.TerminalLayout`, the one layout the PNG is drawn with and the seeded
/// findings are placed by, so the preview's covers sit exactly where the sample's own bars do.
enum StyleSample {
    static let layout = SampleData.TerminalLayout()
    /// Height over width of the sample image.
    static var aspect: CGFloat { layout.height / layout.width }

    static let base: CGImage? = {
        let data = SampleData.terminalPNG(covered: false)
        return try? ImageCodec.decode(data).image
    }()

    /// One finding per secret line of the sample, at the rect `SampleData.seed` stores for it, labelled with the
    /// detector that catches it.
    static func findings() -> [PlacedFinding] {
        SampleData.secretLines.compactMap { item in
            guard let rect = layout.valueRect(line: item.line) else { return nil }
            return PlacedFinding(rect: rect, textHeight: SampleData.TerminalLayout.fontSize * layout.scale,
                                 label: DetectorNames.title(for: item.detectorID))
        }
    }

    static func render(_ spec: StyleSpec) -> CGImage? {
        guard let base else { return nil }
        return try? Redactor.render(base, findings: findings(), style: spec,
                                    environment: RenderEnvironment(redactedWord: String(localized: "REDACTED")))
    }
}
