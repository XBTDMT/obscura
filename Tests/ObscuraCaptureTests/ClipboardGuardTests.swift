import AppKit
import Foundation
import Testing
import ObscuraSupport
@testable import ObscuraCapture

/// Drives `tick()` directly on a private named pasteboard; the general pasteboard is never touched.
@Suite(.serialized) @MainActor struct ClipboardGuardTests {
    @MainActor final class Fixture {
        let pasteboard: NSPasteboard
        let clock = ManualClock()
        let guardian: ClipboardGuard
        let box: IteratorBox
        init() {
            pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.xbtdmt.obscura.tests.\(UUID().uuidString)"))
            guardian = ClipboardGuard(pasteboard: pasteboard, config: .init(), clock: clock)
            box = IteratorBox(guardian.events.makeAsyncIterator())
        }
        func tearDown() { pasteboard.releaseGlobally() }

        func next(timeout: Duration = .seconds(2)) async -> CaptureEvent? {
            await nextEvent(from: box, timeout: timeout)
        }

        func setImage() -> Int {
            pasteboard.clearContents()
            pasteboard.setData(TestSupport.pngBytes, forType: .png)
            return pasteboard.changeCount
        }
    }

    @Test func imageProducesOneEvent() async {
        let f = Fixture()
        defer { f.tearDown() }
        let count = f.setImage()
        f.guardian.tick()
        f.guardian.tick()
        let event = await f.next()
        #expect(event?.pasteboardChangeCount == count)
        #expect(event?.preservedText == nil)
        let second = await f.next(timeout: .milliseconds(200))
        #expect(second == nil)
    }

    /// Fail-open #18: a write-back for an older generation is refused and leaves the newer content alone.
    @Test func aWriteBackForAnOlderGenerationLeavesTheNewerContent() {
        let f = Fixture()
        defer { f.tearDown() }
        let older = f.setImage()
        f.pasteboard.clearContents()
        f.pasteboard.setString("newer", forType: .string)
        #expect(!f.guardian.writeBack(png: TestSupport.pngBytes, tiff: Data([1, 2, 3]), preservedText: nil, expectedChangeCount: older))
        #expect(f.pasteboard.string(forType: .string) == "newer")
        #expect(f.pasteboard.data(forType: .png) == nil)
        let current = f.pasteboard.changeCount
        #expect(f.guardian.writeBack(png: TestSupport.pngBytes, tiff: Data([1, 2, 3]), preservedText: nil, expectedChangeCount: current))
        #expect(f.pasteboard.data(forType: .png) == TestSupport.pngBytes)
    }

    @Test func ownWriteBackProducesNoEvent() async {
        let f = Fixture()
        defer { f.tearDown() }
        f.guardian.writeBack(png: TestSupport.pngBytes, tiff: Data([1, 2, 3]), preservedText: "kept")
        f.guardian.tick()
        #expect(f.pasteboard.string(forType: .string) == "kept")
        #expect(f.pasteboard.data(forType: .png) == TestSupport.pngBytes)
        let sentinel = f.setImage()
        f.guardian.tick()
        let event = await f.next()
        #expect(event?.pasteboardChangeCount == sentinel)
    }

    /// Fail-open #9: a file reference used to make the guard return silently. A copied image file is checked as the
    /// file itself (what a paste hands over), not the icon or thumbnail beside it.
    @Test func aCopiedImageFileIsCheckedAsTheFileNotItsIcon() async {
        let f = Fixture()
        defer { f.tearDown() }
        f.pasteboard.clearContents()
        f.pasteboard.setString("file:///home/example/Desktop/Screenshot%201.png", forType: .fileURL)
        f.pasteboard.setData(Data([0x4D, 0x4D, 0x00, 0x2A]), forType: .tiff)    // the icon an app puts beside it
        let generation = f.pasteboard.changeCount
        f.guardian.tick()
        let event = await f.next()
        guard case let .pasteboardFiles(urls, changeCount, _)? = event else { Issue.record("expected the file, got \(String(describing: event))"); return }
        #expect(urls.map(\.path) == ["/home/example/Desktop/Screenshot 1.png"])
        #expect(changeCount == generation)
    }

    /// A file reference to something that is not an image no longer hides the image data beside it.
    @Test func aFileReferenceToSomethingElseDoesNotHideTheImageData() async {
        let f = Fixture()
        defer { f.tearDown() }
        f.pasteboard.clearContents()
        f.pasteboard.setString("file:///home/example/notes.txt", forType: .fileURL)
        f.pasteboard.setData(TestSupport.pngBytes, forType: .png)
        f.guardian.tick()
        let event = await f.next()
        if case let .pasteboardImage(data, uti, _, _)? = event {
            #expect(uti == .png && data == TestSupport.pngBytes)
        } else {
            Issue.record("expected the image data, got \(String(describing: event))")
        }
    }

    /// Fail-open #9: JPEG, HEIC and PDF payloads (and the other decoded containers) used to be ignored.
    @Test(arguments: ["public.jpeg", "public.heic", "com.adobe.pdf", "com.compuserve.gif", "org.webmproject.webp"])
    func otherImagePayloadsAreRead(_ identifier: String) async {
        let f = Fixture()
        defer { f.tearDown() }
        f.pasteboard.clearContents()
        f.pasteboard.setData(Data([1, 2, 3, 4]), forType: NSPasteboard.PasteboardType(identifier))
        f.guardian.tick()
        let event = await f.next()
        if case let .pasteboardImage(_, uti, _, _)? = event {
            #expect(uti.identifier == identifier)
        } else {
            Issue.record("expected a \(identifier) pasteboard event, got \(String(describing: event))")
        }
    }

    @Test func aCopyWithNoImageProducesNoEvent() async {
        let f = Fixture()
        defer { f.tearDown() }
        f.pasteboard.clearContents()
        f.pasteboard.setString("just words", forType: .string)
        f.guardian.tick()
        let sentinel = f.setImage()
        f.guardian.tick()
        let event = await f.next()
        #expect(event?.pasteboardChangeCount == sentinel)
    }

    @Test func concealedAndTransientProduceNoEvent() async {
        let f = Fixture()
        defer { f.tearDown() }
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
            f.pasteboard.clearContents()
            f.pasteboard.setData(TestSupport.pngBytes, forType: .png)
            f.pasteboard.setString("", forType: NSPasteboard.PasteboardType(marker))
            f.guardian.tick()
        }
        let sentinel = f.setImage()
        f.guardian.tick()
        let event = await f.next()
        #expect(event?.pasteboardChangeCount == sentinel)
    }

    @Test func trustWindowSuppressesThenExpires() async {
        let f = Fixture()
        defer { f.tearDown() }
        f.guardian.trust(for: .seconds(2))
        _ = f.setImage()
        f.guardian.tick()
        f.clock.advance(by: 2.5)
        let sentinel = f.setImage()
        f.guardian.tick()
        let event = await f.next()
        #expect(event?.pasteboardChangeCount == sentinel)
    }

    @Test func preservedTextComesThrough() async {
        let f = Fixture()
        defer { f.tearDown() }
        f.pasteboard.clearContents()
        f.pasteboard.setData(TestSupport.pngBytes, forType: .png)
        f.pasteboard.setString("caption", forType: .string)
        f.guardian.tick()
        let event = await f.next()
        #expect(event?.preservedText == "caption")
    }

    @Test func tiffFallbackWhenNoPNG() async {
        let f = Fixture()
        defer { f.tearDown() }
        f.pasteboard.clearContents()
        f.pasteboard.setData(Data([0x4D, 0x4D, 0x00, 0x2A]), forType: .tiff)
        f.guardian.tick()
        let event = await f.next()
        if case let .pasteboardImage(_, uti, _, _)? = event {
            #expect(uti == .tiff)
        } else {
            Issue.record("expected a TIFF pasteboard event")
        }
    }

    @Test func startStopRepeatedly() async throws {
        let f = Fixture()
        defer { f.tearDown() }
        try await f.guardian.start()
        try await f.guardian.start()
        #expect(f.guardian.isRunning)
        await f.guardian.stop()
        await f.guardian.stop()
        #expect(!f.guardian.isRunning)
    }
}
