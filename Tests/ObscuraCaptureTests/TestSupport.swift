import Foundation
import Testing
@testable import ObscuraCapture

enum TestSupport {
    /// A fresh, real directory (symlinks resolved so FSEvents paths and ours agree).
    static func makeTempDirectory(_ label: String) throws -> URL {
        let base = URL(filePath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let dir = base.appending(path: "obscura-capture-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A tiny valid 1x1 PNG (made up, carries no secret).
    static let pngBytes = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    ])

    /// Simulates `screencapture`: write a dot-prefixed temp file, then rename it to the final name.
    static func simulateScreencapture(in dir: URL, name: String = "Screenshot.png", bytes: Data = pngBytes) throws -> URL {
        let temp = dir.appending(path: ".\(name).tmp-\(UUID().uuidString.prefix(6))")
        try bytes.write(to: temp)
        let final = dir.appending(path: name)
        try FileManager.default.moveItem(at: temp, to: final)
        return final
    }
}

/// Waits for the next event or returns nil after `timeout`.
func nextEvent(_ iterator: inout AsyncStream<CaptureEvent>.Iterator, timeout: Duration = .seconds(2)) async -> CaptureEvent? {
    let box = IteratorBox(iterator)
    defer { iterator = box.iterator }
    return await nextEvent(from: box, timeout: timeout)
}

/// Same, for an iterator that lives in a box (actor-isolated fixtures cannot pass `inout` across `await`).
func nextEvent(from box: IteratorBox, timeout: Duration = .seconds(2)) async -> CaptureEvent? {
    let deadline = ContinuousClock.now + timeout
    box.reset()
    let task = Task { await box.next() }
    while ContinuousClock.now < deadline {
        if box.done { return box.result }
        try? await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()
    return box.result
}

/// Lets a non-Sendable iterator be driven by one task and observed by another. Access is single-writer.
final class IteratorBox: @unchecked Sendable {
    var iterator: AsyncStream<CaptureEvent>.Iterator
    private(set) var result: CaptureEvent?
    private(set) var done = false
    init(_ iterator: AsyncStream<CaptureEvent>.Iterator) { self.iterator = iterator }
    func reset() { result = nil; done = false }
    func next() async {
        result = await iterator.next()
        done = true
    }
}

extension CaptureEvent {
    var fileURL: URL? {
        if case let .file(url, _) = self { return url }
        return nil
    }
    var origin: FileOrigin? {
        if case let .file(_, origin) = self { return origin }
        return nil
    }
    var pasteboardChangeCount: Int? {
        if case let .pasteboardImage(_, _, count, _) = self { return count }
        return nil
    }
    var preservedText: String? {
        if case let .pasteboardImage(_, _, _, text) = self { return text }
        return nil
    }
}
