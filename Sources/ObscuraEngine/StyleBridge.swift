// ObscuraEngine — StyleRecord (Journal row) ↔ StyleSpec (renderer). The raw values of kind and label mode
// are identical in both packages; the colour is "r,g,b,a" in the row and RGBA in the spec.
public import ObscuraJournal
public import ObscuraRender

public enum StyleBridge {
    public static func spec(from record: StyleRecord) -> StyleSpec {
        StyleSpec(
            kind: StyleSpec.Kind(rawValue: record.kind.rawValue) ?? .solid,
            color: rgba(from: record.color),
            roundness: record.roundness,
            padding: record.padding,
            labelMode: StyleSpec.LabelMode(rawValue: record.labelMode.rawValue) ?? .none
        )
    }

    /// `isDefault` is a row property, not an appearance one; the caller sets it.
    public static func record(from spec: StyleSpec, id: Int64? = nil, isDefault: Bool = false) -> StyleRecord {
        StyleRecord(
            id: id,
            kind: StyleKind(rawValue: spec.kind.rawValue) ?? .solid,
            color: string(from: spec.color),
            roundness: spec.roundness,
            padding: spec.padding,
            labelMode: LabelMode(rawValue: spec.labelMode.rawValue) ?? .none,
            isDefault: isDefault
        )
    }

    /// "r,g,b,a" → RGBA. A malformed string falls back to opaque black (the built-in default) rather than throwing:
    /// a style row can never stop a redaction.
    public static func rgba(from string: String) -> RGBA {
        let parts = string.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let r = parts[0], let g = parts[1], let b = parts[2], let a = parts[3] else {
            return RGBA(r: 0, g: 0, b: 0, a: 1)
        }
        return RGBA(r: r, g: g, b: b, a: a).clamped
    }

    public static func string(from color: RGBA) -> String {
        let c = color.clamped
        return [c.r, c.g, c.b, c.a].map { Self.format($0) }.joined(separator: ",")
    }

    private static func format(_ v: Double) -> String {
        var s = String(format: "%.4f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s.isEmpty ? "0" : s
    }
}
