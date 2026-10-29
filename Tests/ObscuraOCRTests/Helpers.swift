import CoreGraphics
import Foundation
@testable import ObscuraOCR

func line(_ index: Int, _ text: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
          candidate: (any GlyphBoxProvider)? = nil) -> OCRLine {
    OCRLine(index: index, text: text, rect: CGRect(x: x, y: y, width: w, height: h), candidate: candidate)
}

/// Provider that answers a fixed box for any range (nil when `box` is nil).
struct FixedBoxes: GlyphBoxProvider {
    let box: CGRect?
    func boundingBox(forUTF16Range range: NSRange) -> CGRect? { box }
}

/// A 1×1 image: the stubs ignore pixels, the queue only forwards it.
func blankImage(width: Int = 1, height: Int = 1) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// Records call order by tag, with an optional per-call delay and an optional gate held until released.
actor CallRecorder {
    private(set) var order: [String] = []
    private(set) var concurrent = 0
    private(set) var maxConcurrent = 0
    func enter(_ tag: String) { order.append(tag); concurrent += 1; maxConcurrent = max(maxConcurrent, concurrent) }
    func leave() { concurrent -= 1 }
}

struct RecordingRecognizer: TextRecognizer {
    let recorder: CallRecorder
    let delay: Duration
    /// Tag taken from the image's width so each call is distinguishable without shared state.
    func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine] {
        await recorder.enter("w\(image.width)")
        try await Task.sleep(for: delay)
        await recorder.leave()
        return [OCRLine(index: 0, text: "w\(image.width)", rect: .zero)]
    }
}

/// Blocks until `release()` is called; lets a test fill the queue while the first request is in flight.
actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}

struct GatedRecognizer: TextRecognizer {
    let gate: Gate
    let recorder: CallRecorder
    func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine] {
        await recorder.enter("w\(image.width)")
        await gate.wait()
        await recorder.leave()
        return []
    }
}
