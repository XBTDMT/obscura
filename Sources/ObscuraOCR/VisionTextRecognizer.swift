// On-device OCR through the Swift Vision API (macOS 15). Behavior per ARCHITECTURE.md §4 rows 5–6.
import Foundation
public import CoreGraphics
import Vision
import ObscuraSupport

public struct VisionTextRecognizer: TextRecognizer {
    public init() {}

    public var rereadsPixels: Bool { true }

    public func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine] {
        try await run(image, options: options, regions: false).lines
    }

    /// Recognition plus text-rectangle detection with character boxes, both on one request handler (one image
    /// preparation). The rectangle pass measured 4–7 ms per screenshot (2026-10-27).
    public func read(_ image: CGImage, options: OCROptions) async throws -> OCRReading {
        try await run(image, options: options, regions: true)
    }

    private func run(_ image: CGImage, options: OCROptions, regions: Bool) async throws -> OCRReading {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { throw OCRError.badImage }
        let plan = DownscalePlan(width: width, height: height, options: options)
        let started = ContinuousClock.now
        let reading = try await Deadline.run(timeout: options.timeout) {
            let work = try Downscaler.render(image, to: plan)
            try Task.checkCancellation()
            return try await Self.perform(on: work, plan: plan, options: options, regions: regions)
        }
        let elapsed = ContinuousClock.now - started
        Log.ocr.info("ocr done lines=\(reading.lines.count) regions=\(reading.regions.count) px=\(width * height) downscaled=\(!plan.isIdentity) ms=\(elapsed / .milliseconds(1), format: .fixed(precision: 0))")
        return reading
    }

    /// The recognition request for `options`. Never Vision's automatic language detection (G-31): a caller's languages,
    /// else the user's (`RecognitionLanguages.resolve`, from `preferred`). Internal for tests.
    static func request(for options: OCROptions, preferred: [String] = Locale.preferredLanguages) -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = options.level == .accurate ? .accurate : .fast
        request.usesLanguageCorrection = options.languageCorrection
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = options.languages.isEmpty
            ? RecognitionLanguages.resolve(preferred: preferred, supported: request.supportedRecognitionLanguages)
            : options.languages.map { Locale.Language(identifier: $0) }
        return request
    }

    private static func perform(on image: CGImage, plan: DownscalePlan, options: OCROptions, regions: Bool) async throws -> OCRReading {
        let request = request(for: options)
        let observations: [RecognizedTextObservation]
        var textRegions: [TextRegion] = []
        if regions {
            var rectangles = DetectTextRectanglesRequest()
            rectangles.reportCharacterBoxes = true
            let handler = ImageRequestHandler(image)
            let (recognized, found) = try await handler.perform(request, rectangles)
            observations = recognized
            for region in found {
                let rect = plan.scaledBack(region.boundingBox.toImageCoordinates(plan.workSize, origin: .upperLeft))
                let glyphs = (region.characterBoxes ?? [])
                    .map { plan.scaledBack($0.boundingBox.toImageCoordinates(plan.workSize, origin: .upperLeft)) }
                    .sorted { $0.minX < $1.minX }
                textRegions.append(TextRegion(rect: rect, glyphs: glyphs))
            }
        } else {
            observations = try await request.perform(on: image)
        }
        try Task.checkCancellation()
        var lines: [OCRLine] = []
        lines.reserveCapacity(observations.count)
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let rect = plan.scaledBack(observation.boundingBox.toImageCoordinates(plan.workSize, origin: .upperLeft))
            let provider = VisionGlyphBoxes(candidate: candidate, plan: plan)
            lines.append(OCRLine(index: lines.count, text: candidate.string, rect: rect, candidate: provider))
        }
        return OCRReading(lines: lines, regions: textRegions)
    }
}

/// Wraps the kept `RecognizedText` so BoxMapper can ask Vision for sub-range geometry later.
struct VisionGlyphBoxes: GlyphBoxProvider {
    let candidate: RecognizedText
    let plan: DownscalePlan

    func boundingBox(forUTF16Range range: NSRange) -> CGRect? {
        guard let swiftRange = Range(range, in: candidate.string),
              let observation = candidate.boundingBox(for: swiftRange) else { return nil }
        return plan.scaledBack(observation.boundingBox.toImageCoordinates(plan.workSize, origin: .upperLeft))
    }
}
