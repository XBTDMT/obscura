// Security scan 2026-10-28, F10: a PDF's page box went through Swift's trapping Int(Double) before any range check, so
// a one-page PDF whose MediaBox is 9e18 points wide crashed the whole app. Every PDF here is a few hundred bytes built in
// the test; nothing is drawn at the hostile sizes.
import CoreGraphics
import Foundation
import Testing
@testable import ObscuraRender

@Suite struct HostilePDFTests {
    /// A one-page PDF with `box` as its MediaBox (and `rotate` as its /Rotate), with a correct cross-reference table.
    static func pdf(box: String, rotate: Int = 0) -> Data {
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>",
                       "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                       "<< /Type /Page /Parent 2 0 R /MediaBox [\(box)] /Rotate \(rotate) >>"]
        for (i, object) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        out += offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    /// The precondition the scan could not run: CoreGraphics hands the box back unclamped, so at 2× it is past Int.max
    /// and the old `Int((width * 2).rounded(.up))` trapped.
    @Test func coreGraphicsReturnsTheBoxUnclamped() throws {
        let provider = try #require(CGDataProvider(data: Self.pdf(box: "0 0 9000000000000000000 792") as CFData))
        let document = try #require(CGPDFDocument(provider))
        let box = try #require(document.page(at: 1)).getBoxRect(.cropBox)
        #expect(box.width * ImageCodec.pdfScale > CGFloat(Int.max))
    }

    @Test(arguments: ["0 0 9000000000000000000 792", "0 0 612 9000000000000000000", "0 0 99999999999 792", "0 0 600000 600"])
    func aPageBoxPastTheCeilingIsTooLargeNotACrash(_ box: String) {
        #expect(throws: ImageCodecError.tooLarge) { try ImageCodec.decode(Self.pdf(box: box)) }
    }

    /// The same box turned a quarter: the height that becomes the width is checked the same way.
    @Test func aRotatedHugePageIsTooLarge() {
        #expect(throws: ImageCodecError.tooLarge) { try ImageCodec.decode(Self.pdf(box: "0 0 612 9000000000000000000", rotate: 90)) }
    }

    /// A page of ordinary size still draws at 2×.
    @Test func anOrdinaryPageStillDecodes() throws {
        let decoded = try ImageCodec.decode(Self.pdf(box: "0 0 300 200"))
        #expect(decoded.pixelSize == CGSize(width: 600, height: 400))
        #expect(decoded.frameCount == 1)
    }
}
