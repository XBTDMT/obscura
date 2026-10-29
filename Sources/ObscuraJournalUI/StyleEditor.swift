// The inspector's Style section: Solid / Erase / Blur / Mosaic, colour, corners, padding, label, Apply Default Style and
// Save as Default…. Edits go to a draft and are applied to the entry when a control is released, so dragging a slider
// re-renders once, not on every step.
import AppKit
import SwiftUI
import ObscuraUIKit
import ObscuraJournal

struct StyleEditor: View {
    @Bindable var controller: JournalController
    let entry: Entry

    var body: some View {
        let style = controller.style(for: entry)
        VStack(alignment: .leading, spacing: 7) {
            Picker(String(localized: "Style"), selection: Binding(
                get: { style.kind },
                set: { k in controller.editStyle(of: entry) { $0.kind = k }; commit() })) {
                Text("Solid").tag(StyleKind.solid)
                Text("Erase").tag(StyleKind.erase)
                Text("Blur").tag(StyleKind.blur)
                Text("Mosaic").tag(StyleKind.mosaic)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            row(String(localized: "Colour")) {
                ColorPicker(String(localized: "Box colour"), selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.mini)
                    .fixedSize()
                    .disabled(style.kind != .solid)
                Text(StyleColor.name(style.color)).font(.system(size: 11)).foregroundStyle(OColor.text3).lineLimit(1)
                Spacer(minLength: 4)
                if style.kind != .solid {
                    Pill(String(localized: "Automatic"), tone: .quiet)
                        .help(String(localized: "Erase, Blur and Mosaic take their colours from the image."))
                }
            }

            row(String(localized: "Corners")) {
                Slider(value: binding(\.roundness), in: 0...1) { editing in if !editing { commit() } }
                    .controlSize(.mini)
                    .tint(OColor.accent)
                    .frame(width: 140)
                    .accessibilityLabel(Text("Corners"))
                    .accessibilityValue(Text(pixels(cornersFor: style)))
                value(pixels(cornersFor: style))
            }

            row(String(localized: "Padding")) {
                Slider(value: binding(\.padding), in: 0...0.6) { editing in if !editing { commit() } }
                    .controlSize(.mini)
                    .tint(OColor.accent)
                    .frame(width: 140)
                    .accessibilityLabel(Text("Padding"))
                    .accessibilityValue(Text(pixels(paddingFor: style)))
                value(pixels(paddingFor: style))
            }

            row(String(localized: "Label")) {
                Toggle(String(localized: "Label"), isOn: Binding(
                    get: { style.labelMode != .none },
                    set: { on in controller.editStyle(of: entry) { $0.labelMode = on ? .redacted : .none }; commit() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(OColor.accent)
                    .labelsHidden()
                if style.labelMode != .none {
                    Menu {
                        Button(String(localized: "“redacted”")) { controller.editStyle(of: entry) { $0.labelMode = .redacted }; commit() }
                        Button(String(localized: "The kind of secret")) { controller.editStyle(of: entry) { $0.labelMode = .kind }; commit() }
                    } label: {
                        Text(style.labelMode == .kind ? String(localized: "The kind of secret") : String(localized: "“redacted”"))
                            .font(.system(size: 12)).foregroundStyle(OColor.text2)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                } else {
                    Text("None").font(.system(size: 12)).foregroundStyle(OColor.text3)
                }
            }

            HStack {
                Button(String(localized: "Apply Default Style")) { Task { await controller.applyDefaultStyle(to: [entry.id]) } }
                    .buttonStyle(OButtonStyle(.ghost, size: .small))
                Spacer()
                Button(String(localized: "Save as Default…")) { controller.confirmingSaveDefault = true }
                    .buttonStyle(OButtonStyle(.plain, size: .small))
            }
            .padding(.top, 2)
        }
        .confirmationDialog(String(localized: "Use this style for new catches?"), isPresented: $controller.confirmingSaveDefault) {
            Button(String(localized: "Save as Default")) { Task { await controller.saveAsDefault(entry) } }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Screenshots Obscura catches from now on are covered this way. You can change it in Settings › Redaction Style.")
        }
    }

    // MARK: Pieces

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(OColor.text2).frame(width: 60, alignment: .leading)
            content()
        }
        .frame(minHeight: 20)
    }

    private func value(_ text: String) -> some View {
        Text(text).font(.system(size: 11).monospacedDigit()).foregroundStyle(OColor.text3).frame(width: 34, alignment: .trailing)
    }

    private func binding<V>(_ key: WritableKeyPath<StyleRecord, V>) -> Binding<V> {
        Binding(get: { controller.style(for: entry)[keyPath: key] },
                set: { v in controller.editStyle(of: entry) { $0[keyPath: key] = v } })
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { StyleColor.color(controller.style(for: entry).color) },
                set: { c in
                    controller.editStyle(of: entry) { $0.color = StyleColor.string(c) }
                    commit()
                })
    }

    private func commit() { Task { await controller.commitStyle(of: entry) } }

    /// The typical finding's text height in image pixels: what padding and roundness are fractions of.
    private var textHeight: Double {
        let heights = entry.findings.map { Double($0.rect.height) }.sorted()
        return heights.isEmpty ? 24 : heights[heights.count / 2]
    }

    private func pixels(paddingFor s: StyleRecord) -> String { String(localized: "\(Int((s.padding * textHeight).rounded())) px") }
    private func pixels(cornersFor s: StyleRecord) -> String { String(localized: "\(Int((s.roundness * textHeight / 2).rounded())) px") }
}

/// "r,g,b,a" ↔ Color, and a plain name for the swatch.
enum StyleColor {
    static func components(_ string: String) -> (Double, Double, Double) {
        let p = string.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard p.count >= 3 else { return (0, 0, 0) }
        return (p[0], p[1], p[2])
    }

    static func color(_ string: String) -> Color {
        let (r, g, b) = components(string)
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    static func string(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return [ns.redComponent, ns.greenComponent, ns.blueComponent, 1].map { String(format: "%.4g", Double($0)) }.joined(separator: ",")
    }

    static func name(_ string: String) -> String {
        let (r, g, b) = components(string)
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let spread = max(r, g, b) - min(r, g, b)
        if spread < 0.08 {
            if lum < 0.12 { return String(localized: "Near-black") }
            if lum > 0.9 { return String(localized: "White") }
            return String(localized: "Grey")
        }
        return String(localized: "Custom")
    }
}
