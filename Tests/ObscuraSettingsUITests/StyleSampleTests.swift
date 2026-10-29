// The Redaction Style preview takes its geometry from SampleData.TerminalLayout, the layout the sample PNG is drawn
// with and the seeded findings are placed by (redman 2026-10-27).
import CoreGraphics
import Testing
@testable import ObscuraSettingsUI
import ObscuraRender
import ObscuraUIKit

@Suite struct StyleSampleTests {
    /// The preview's covers are the rects `SampleData.seed` stores, so they sit over the bars `terminalPNG` draws.
    @Test func findingsAreTheSampleLayoutsValueRects() {
        let layout = SampleData.TerminalLayout()
        let placed = StyleSample.findings().map(\.rect)
        #expect(placed.count == SampleData.secretLines.count)
        #expect(placed == SampleData.terminalFindings(layout: layout).map(\.rect))
        #expect(placed == SampleData.secretLines.compactMap { layout.valueRect(line: $0.line) })
    }

    @Test func eachFindingIsLabelledByItsDetector() {
        #expect(StyleSample.findings().map(\.label) == SampleData.secretLines.map { DetectorNames.title(for: $0.detectorID) })
    }

    @Test func theAspectIsTheSampleImagesOwn() throws {
        let base = try #require(StyleSample.base)
        #expect(abs(StyleSample.aspect - CGFloat(base.height) / CGFloat(base.width)) < 0.002)
    }

    @Test func aStyleRendersOverTheWholeSample() throws {
        let base = try #require(StyleSample.base)
        let spec = StyleSpec(kind: .solid, color: RGBA(r: 0.07, g: 0.07, b: 0.08, a: 1), roundness: 0.2, padding: 0.2, labelMode: .none)
        let image = try #require(StyleSample.render(spec))
        #expect(image.width == base.width && image.height == base.height)
    }
}
