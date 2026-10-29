import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ObscuraRender

/// Rendered scenes compared against committed PNGs. Record with `OBSCURA_RECORD_GOLDEN=1 swift test ...`.
/// Tolerance: 2/255 per channel, at most 0.1 % of pixels over it.
@Suite struct GoldenTests {
    static let goldenRoot: URL = {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/golden", isDirectory: true)
    }()
    static let record = ProcessInfo.processInfo.environment["OBSCURA_RECORD_GOLDEN"] == "1"

    static let findings = [
        PlacedFinding(rect: CGRect(x: 40, y: 20, width: 110, height: 14), textHeight: 14, label: "API key", id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
        PlacedFinding(rect: CGRect(x: 16, y: 80, width: 180, height: 14), textHeight: 14, label: "Password", id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
        PlacedFinding(rect: CGRect(x: 236, y: 60, width: 70, height: 40), textHeight: 16, label: "IBAN", id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!),
    ]

    static func style(_ kind: StyleSpec.Kind, label: StyleSpec.LabelMode) -> StyleSpec {
        var s = StyleSpec.defaultStyle
        s.kind = kind; s.labelMode = label
        return s
    }

    static let cases: [(name: String, style: StyleSpec)] = [
        ("solid", style(.solid, label: .none)),
        ("solid-redacted", style(.solid, label: .redacted)),
        ("erase", style(.erase, label: .none)),
        ("blur", style(.blur, label: .none)),
        ("mosaic", style(.mosaic, label: .kind)),
    ]

    @Test(arguments: cases.map(\.name))
    func matchesGolden(name: String) throws {
        let style = try #require(Self.cases.first { $0.name == name }?.style)
        let rendered = try Redactor.render(TestImages.page(), findings: Self.findings, style: style, environment: TestImages.env)
        let dir = Self.goldenRoot.appendingPathComponent(name, isDirectory: true)
        let file = dir.appendingPathComponent("page.png")
        if Self.record {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try ImageCodec.encode(rendered, as: .png, dpi: nil, quality: nil).write(to: file, options: .atomic)
        }
        let golden = try ImageCodec.decode(try Data(contentsOf: file)).image
        let a = TestImages.pixels(rendered), b = TestImages.pixels(golden)
        #expect(a.width == b.width && a.height == b.height)
        let over = TestImages.differingPixels(a, b, tolerance: 2)
        #expect(Double(over) <= 0.001 * Double(a.width * a.height), "\(over) pixels over tolerance in \(name)")
    }
}
