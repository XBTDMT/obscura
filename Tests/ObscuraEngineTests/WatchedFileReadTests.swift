// Security scan 2026-10-28, F19: the folder watcher checks "a regular file inside a watched folder" once, when the event
// arrives; the engine then read the path with Data(contentsOf:), which follows links. A file swapped for a symbolic link
// (or a folder above it swapped for one) after the watcher accepted it made Obscura read, and journal, a picture outside
// every watched folder with its own folder permissions. Every file here is made up; the "outside" folder stands in for a
// folder another process cannot read.
import Darwin
import Foundation
import Testing
import ObscuraCapture
import ObscuraOCR
@testable import ObscuraEngine

@Suite(.serialized) struct WatchedFileReadTests {
    /// A watched folder, a folder outside it holding a made-up "private" picture, and an engine whose folder watcher
    /// watches only the first (never started: the test hands the event in, as the watcher would after accepting it).
    struct Rig {
        let watched: URL
        let outside: URL
        let secretPicture: URL
        let h: Harness

        init() throws {
            watched = try Fixture.tempDirectory("watched")
            outside = try Fixture.tempDirectory("outside")
            secretPicture = outside.appendingPathComponent("Private.png")
            try Fixture.pngData().write(to: secretPicture)
            let watcher = FolderWatcher(roots: [WatchedRoot(url: watched, origin: .watched(watched))])
            h = try Harness(folderWatcher: watcher)
        }

        func submit(_ url: URL) async -> ScanOutcome? {
            let reports = h.engine.outcomes
            await h.engine.submit(.file(url, origin: .watched(watched)))
            return await collect(reports, count: 1, timeout: .seconds(5)).first?.outcome
        }

        func tearDown() {
            h.tearDown()
            try? FileManager.default.removeItem(at: watched)
            try? FileManager.default.removeItem(at: outside)
        }
    }

    /// The scan's swap: the accepted name is now a link to a picture outside. It is not read: "not checked", nothing
    /// journaled, the picture outside untouched. The old read followed the link, found the made-up key in the outside
    /// picture and put that picture, as the original, into the Journal.
    @Test func aNameSwappedForALinkIsNotRead() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let link = rig.watched.appendingPathComponent("Screenshot.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: rig.secretPicture)
        let before = try Data(contentsOf: rig.secretPicture)

        let outcome = try #require(await rig.submit(link))
        #expect(outcome.skipReason == .unreadable, "\(outcome)")
        #expect(try await rig.h.journal.entries(matching: .live).isEmpty, "nothing from outside reached the Journal")
        #expect(try Data(contentsOf: rig.secretPicture) == before)
    }

    /// The same through a folder: a subfolder of the watched folder swapped for a link to the outside folder. The last
    /// name is a regular file, so only the descriptor's real path shows where it is.
    @Test func aFolderSwappedForALinkIsNotRead() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let sub = rig.watched.appendingPathComponent("sub")
        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: rig.outside)

        let outcome = try #require(await rig.submit(sub.appendingPathComponent("Private.png")))
        #expect(outcome.skipReason == .unreadable, "\(outcome)")
        #expect(try await rig.h.journal.entries(matching: .live).isEmpty)
    }

    /// A FIFO swapped in under the accepted name is refused at once (the old read would wait on it for ever).
    @Test func aFIFOIsRefusedNotWaitedOn() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let fifo = rig.watched.appendingPathComponent("Screenshot.png")
        #expect(mkfifo(fifo.path, 0o600) == 0)

        let outcome = try #require(await rig.submit(fifo))
        #expect(outcome.skipReason == .unreadable, "\(outcome)")
    }

    /// A regular file inside the watched folder is read and covered as before.
    @Test func aRegularFileInsideIsReadAsBefore() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let file = rig.watched.appendingPathComponent("Screenshot.png")
        try Fixture.pngData().write(to: file)

        let outcome = try #require(await rig.submit(file))
        #expect(outcome.isRedacted, "\(outcome)")
        #expect(try await rig.h.journal.entries(matching: .live).count == 1)
    }

    /// The read itself, without the engine: inside reads, a link is refused, outside every root is refused, and with no
    /// roots to compare (no folder watcher) only the link and file-type checks apply.
    @Test func theReadChecksTheDescriptor() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let inside = rig.watched.appendingPathComponent("In.png")
        try Data("made-up bytes".utf8).write(to: inside)
        let roots = [rig.watched]
        #expect(try await Pipeline.readWatchedFile(inside, roots: roots, maxBytes: 1024) == Data("made-up bytes".utf8))
        #expect(try await Pipeline.readWatchedFile(inside, roots: roots, maxBytes: 4) == nil, "past the ceiling: too large")

        let link = rig.watched.appendingPathComponent("Link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: rig.secretPicture)
        await #expect(throws: WatchedFileRefusal.symbolicLink) { try await Pipeline.readWatchedFile(link, roots: roots, maxBytes: 1 << 20) }
        await #expect(throws: WatchedFileRefusal.symbolicLink) { try await Pipeline.readWatchedFile(link, roots: nil, maxBytes: 1 << 20) }
        await #expect(throws: WatchedFileRefusal.outsideWatchedFolders) {
            try await Pipeline.readWatchedFile(rig.secretPicture, roots: roots, maxBytes: 1 << 20)
        }
        await #expect(throws: WatchedFileRefusal.notRegularFile) { try await Pipeline.readWatchedFile(rig.watched, roots: roots, maxBytes: 1 << 20) }
        #expect(try await Pipeline.readWatchedFile(rig.secretPicture, roots: nil, maxBytes: 1 << 20) != nil)
    }
}
