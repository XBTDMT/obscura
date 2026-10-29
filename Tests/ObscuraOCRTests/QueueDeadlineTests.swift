import CoreGraphics
import Foundation
import Testing
@testable import ObscuraOCR

/// The queue's deadline starts when an image's recognition starts, never while it waits its turn.
@Suite struct QueueDeadlineTests {
    /// First call sleeps `firstDelay`; later calls return at once.
    final class FirstSlowRecognizer: TextRecognizer, @unchecked Sendable {
        let firstDelay: Duration
        private let lock = NSLock()
        private var calls = 0
        init(firstDelay: Duration) { self.firstDelay = firstDelay }
        func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine] {
            let n = lock.withLock { calls += 1; return calls }
            if n == 1 { try await Task.sleep(for: firstDelay) }
            return [OCRLine(index: 0, text: "call \(n)", rect: .zero)]
        }
    }

    static func image() -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    @Test func waitingBehindASlowImageDoesNotCountAsATimeout() async throws {
        let queue = OCRQueue(recognizer: FirstSlowRecognizer(firstDelay: .milliseconds(1800)))
        let img = Self.image()
        // The slow first image (like the cold-start warm-up) has a generous timeout.
        let slow = Task { try await queue.recognize(img, options: OCROptions(timeout: .seconds(5)), priority: .file) }
        try await Task.sleep(for: .milliseconds(100))
        // The second waits ~1.7 s in the queue, longer than its 0.5 s timeout (+1 s backstop), but recognizes at once.
        let lines = try await queue.recognize(img, options: OCROptions(timeout: .milliseconds(500)), priority: .file)
        #expect(lines.first?.text == "call 2")
        _ = try await slow.value
    }

    @Test func aRecognizerThatNeverReturnsStillTimesOut() async throws {
        let queue = OCRQueue(recognizer: FirstSlowRecognizer(firstDelay: .seconds(60)))
        await #expect(throws: OCRError.self) {
            _ = try await queue.recognize(Self.image(), options: OCROptions(timeout: .milliseconds(200)), priority: .file)
        }
    }
}
