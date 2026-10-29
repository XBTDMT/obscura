import Foundation
import Testing
@testable import ObscuraDetect

/// The per-detector PNG fixtures (DETECTORS.md §9) without Vision: every built-in detector has a PNG and a sidecar, and the
/// sidecar's ground truth still equals what the Scanner finds on the drawn text. A pattern change that moves a secret range
/// fails here, in the default suite, and is fixed with `obscura fixtures render`. The OCR end-to-end run on the PNGs is
/// opt-in: `obscura fixtures verify --images` (real Vision, ~25 s cold start), never part of `swift test`.
@Suite("Image fixtures (DETECTORS.md §9, ground truth only)")
struct ImageFixtureTests {
    struct Sidecar: Decodable {
        struct Expected: Decodable {
            let line: Int
            let range: [Int]
            let wholeLine: Bool
            let detectors: [String]
            let rect: [Int]
        }
        let detector: String
        let width: Int
        let height: Int
        let lines: [String]
        let expected: [Expected]
    }

    /// The images are not copied into the test bundle (84 PNGs, ~3.5 MB); the sidecars are read from the source tree.
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/images", isDirectory: true)

    static func sidecar(_ id: String) throws -> Sidecar? {
        let url = directory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Sidecar.self, from: Data(contentsOf: url))
    }

    @Test func everyDetectorHasAnImageAndSidecar() throws {
        for d in Catalogue.builtIn {
            let png = Self.directory.appendingPathComponent("\(d.id).png")
            #expect(FileManager.default.fileExists(atPath: png.path), "Tests/Fixtures/images/\(d.id).png is missing — run `obscura fixtures render`")
            let sidecar = try #require(try Self.sidecar(d.id), "Tests/Fixtures/images/\(d.id).json is missing")
            #expect(sidecar.detector == d.id)
            #expect(!sidecar.expected.isEmpty, "\(d.id): the image must contain a secret")
        }
    }

    @Test("ground truth matches the Scanner", arguments: Catalogue.builtIn.map(\.id))
    func groundTruthMatchesScanner(id: String) throws {
        let sidecar = try #require(try Self.sidecar(id))
        let scanner = Scanner(catalogue: try Catalogue.resolved(state: [id: true]))
        let findings = scanner.scan(sidecar.lines.enumerated().map { ScanLine(index: $0.offset, text: $0.element) })
        struct Key: Hashable { let line: Int, location: Int, length: Int, whole: Bool, detectors: [String] }
        let actual = Set(findings.map { Key(line: $0.lineIndex, location: $0.secretRange.location, length: $0.secretRange.length,
                                            whole: $0.wholeLine, detectors: $0.detectorIDs.sorted()) })
        let expected = Set(sidecar.expected.map { Key(line: $0.line, location: $0.range[0], length: $0.range[1], whole: $0.wholeLine, detectors: $0.detectors) })
        #expect(actual == expected, "\(id): the sidecar is stale — run `obscura fixtures render`")
        #expect(findings.count == sidecar.expected.count)
        for e in sidecar.expected {
            #expect(e.detectors.contains(id), "\(id): every ground-truth finding belongs to the detector under test")
            #expect(e.rect.count == 4 && e.rect[2] > 0 && e.rect[3] > 0, "\(id): the secret has ink")
            #expect(e.rect[0] >= 0 && e.rect[1] >= 0 && e.rect[0] + e.rect[2] <= sidecar.width && e.rect[1] + e.rect[3] <= sidecar.height)
        }
    }
}
