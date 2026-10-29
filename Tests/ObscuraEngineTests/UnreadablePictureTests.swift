// Fail-open #2 and #13 (knowledge/recon/fail-open-2026-10-27): a picture that cannot be read or opened, or a copied image
// that could not be checked, used to end quietly (no "Not checked" row, no status count, no notice). Each now ends as a
// visible "not checked": a persisted row for a file, a status count for every one. Every byte here is made up.
import CoreGraphics
import ImageIO
import Foundation
import Testing
import ObscuraCapture
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSupport
@testable import ObscuraEngine

@Suite(.serialized) struct UnreadablePictureTests {
    /// Submits one file event and waits for its report.
    private static func submit(_ h: Harness, _ url: URL, origin: FileOrigin = .screenshotFolder) async throws -> ScanReport {
        let stream = h.engine.outcomes
        await h.engine.submit(.file(url, origin: origin))
        return try #require(await collect(stream, count: 1, timeout: .seconds(5)).first)
    }

    /// The status holds the file as "Not checked" with a count of one, and the Journal row says why.
    private static func expectNotChecked(_ h: Harness, _ url: URL, reason: UncheckedReason,
                                         sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let status = await h.engine.currentStatus()
        #expect(status.unchecked.map(\.fileURL.path) == [url.resolvingSymlinksInPath().path], sourceLocation: sourceLocation)
        #expect(status.unchecked.first?.reason == reason.rawValue, sourceLocation: sourceLocation)
        #expect(status.problems.first { $0.kind == .scanFailure }?.detail == "1", "one count, not two", sourceLocation: sourceLocation)
        if case .needsAttention = status.protection {} else {
            Issue.record("a picture left as it was holds needs attention, got \(status.protection)", sourceLocation: sourceLocation)
        }
        #expect(try await h.journal.uncheckedFiles().map(\.reason) == [reason], sourceLocation: sourceLocation)
    }

    @Test func aWatchedFileThatDoesNotDecodeIsNotChecked() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Screenshot 9.41.12 AM.png")
        try Fixture.corruptPNG.write(to: file)
        #expect(try await Self.submit(h, file).outcome.skipReason == .decodeFailed)
        try await Self.expectNotChecked(h, file, reason: .decodeFailed)
    }

    @Test func aWatchedFileWithoutReadPermissionIsNotChecked() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("eperm")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Locked.png")
        try Fixture.pngData().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        #expect(try await Self.submit(h, file).outcome.skipReason == .unreadable)
        try await Self.expectNotChecked(h, file, reason: .unreadable)
    }

    @Test func aFileThatVanishedBeforeItWasReadIsNotChecked() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("vanished")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Gone.png")
        #expect(try await Self.submit(h, file).outcome.skipReason == .unreadable)
        try await Self.expectNotChecked(h, file, reason: .unreadable)
    }

    /// A real image container ImageIO knows (here a Photoshop) behind an image extension: not read, so "Not checked".
    @Test func aFileThatIsAnImageKindObscuraDoesNotReadIsNotChecked() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("unsupported")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Layers.png")
        try Self.photoshop().write(to: file)
        #expect(try await Self.submit(h, file).outcome.skipReason == .unsupportedImage)
        try await Self.expectNotChecked(h, file, reason: .unsupportedImage)
    }

    /// The one quiet skip: an extension the filter excludes is never read and never listed.
    @Test func aFileWhoseExtensionIsNotAnImageStaysSilent() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("text")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.txt")
        try Data("plain words".utf8).write(to: file)
        #expect(try await Self.submit(h, file).outcome.skipReason == .notAnImage)
        let status = await h.engine.currentStatus()
        #expect(status.unchecked.isEmpty)
        #expect(!status.problems.contains { $0.kind == .scanFailure })
        #expect(try await h.journal.uncheckedFiles().isEmpty)
    }

    /// A file that could not be read and then can is cleared by the verdict.
    @Test func checkAgainAfterTheFileBecameReadableClearsTheRow() async throws {
        let h = try Harness(recognizer: StubTextRecognizer(lines: []))
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("fixed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Later.png")
        try Fixture.corruptPNG.write(to: file)
        _ = try await Self.submit(h, file)
        try Fixture.pngData().write(to: file)
        let stream = h.engine.outcomes
        await h.engine.retry(file)
        #expect(try #require(await collect(stream, count: 1, timeout: .seconds(5)).first).outcome.isClean)
        #expect(await h.engine.currentStatus().unchecked.isEmpty)
        #expect(try await h.journal.uncheckedFiles().isEmpty)
    }

    // MARK: Clipboard (#2, #13): no file to list, so the status counts it

    private static func clipboardEvent(_ data: Data, changeCount: Int) -> CaptureEvent {
        .pasteboardImage(data, uti: .png, changeCount: changeCount, preservedText: nil)
    }

    private static func expectClipboardCounted(_ h: Harness, sourceLocation: SourceLocation = #_sourceLocation) async {
        let status = await h.engine.currentStatus()
        #expect(status.unchecked.isEmpty, "a copied image has no file to list", sourceLocation: sourceLocation)
        #expect(status.problems.first { $0.kind == .scanFailure }?.detail == "1", sourceLocation: sourceLocation)
        if case .needsAttention = status.protection {} else {
            Issue.record("an unchecked copied image is not Protected, got \(status.protection)", sourceLocation: sourceLocation)
        }
    }

    @Test func aCopiedImageThatDoesNotDecodeCountsInTheStatus() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let stream = h.engine.outcomes
        await h.engine.submit(Self.clipboardEvent(Fixture.corruptPNG, changeCount: 41))
        #expect(try #require(await collect(stream, count: 1, timeout: .seconds(5)).first).outcome.skipReason == .decodeFailed)
        await Self.expectClipboardCounted(h)
    }

    @Test func aCopiedImageWhoseReadingTimedOutCountsInTheStatus() async throws {
        let h = try Harness(recognizer: ScriptedRecognizer(error: .timeout))
        defer { h.tearDown() }
        let stream = h.engine.outcomes
        await h.engine.submit(Self.clipboardEvent(Fixture.pngData(), changeCount: 42))
        #expect(try #require(await collect(stream, count: 1, timeout: .seconds(5)).first).outcome.skipReason == .ocrTimeout)
        await Self.expectClipboardCounted(h)
    }

    @Test func aCopiedImageWhoseReadingFailedCountsInTheStatus() async throws {
        let h = try Harness(recognizer: ScriptedRecognizer(error: .failed(underlying: CocoaError(.fileReadUnknown))))
        defer { h.tearDown() }
        let stream = h.engine.outcomes
        await h.engine.submit(Self.clipboardEvent(Fixture.pngData(), changeCount: 43))
        #expect(try #require(await collect(stream, count: 1, timeout: .seconds(5)).first).outcome.skipReason == .ocrFailed)
        await Self.expectClipboardCounted(h)
    }

    @Test func aCopiedImageThatIsNotAnImageKindObscuraReadsCountsInTheStatus() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let stream = h.engine.outcomes
        await h.engine.submit(Self.clipboardEvent(try Self.photoshop(), changeCount: 44))
        #expect(try #require(await collect(stream, count: 1, timeout: .seconds(5)).first).outcome.skipReason == .unsupportedImage)
        await Self.expectClipboardCounted(h)
    }

    /// A clean copy after a failed one leaves the failed one counted: it was a different image (its own generation).
    @Test func aLaterCleanCopyDoesNotHideTheEarlierUncheckedOne() async throws {
        let h = try Harness(recognizer: StubTextRecognizer(lines: []))
        defer { h.tearDown() }
        let stream = h.engine.outcomes
        await h.engine.submit(Self.clipboardEvent(Fixture.corruptPNG, changeCount: 50))
        await h.engine.submit(Self.clipboardEvent(Fixture.pngData(), changeCount: 51))
        #expect(await collect(stream, count: 2, timeout: .seconds(5)).count == 2)
        await Self.expectClipboardCounted(h)
    }

    /// The engine's blank fixture as a Photoshop image: ImageIO identifies and decodes it, `ImageCodec.supportedInput` does
    /// not list it.
    static func photoshop() throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "com.adobe.photoshop-image" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, Fixture.whiteImage(), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
