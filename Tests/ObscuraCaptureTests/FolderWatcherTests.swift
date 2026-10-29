import Foundation
import Testing
@testable import ObscuraCapture

/// Real FSEvents, real time; every wait is bounded at 2 s.
@Suite(.serialized) struct FolderWatcherTests {
    /// Wait for FSEvents to be fully armed before producing the file (stream start is asynchronous).
    static let armDelay: Duration = .milliseconds(200)

    func makeWatcher(_ dir: URL, origin: FileOrigin = .screenshotFolder) async throws -> FolderWatcher {
        let watcher = FolderWatcher(roots: [WatchedRoot(url: dir, origin: origin)])
        try await watcher.start()
        try await Task.sleep(for: Self.armDelay)
        return watcher
    }

    @Test func screencaptureWriteEmitsExactlyOneEvent() async throws {
        let dir = try TestSupport.makeTempDirectory("one")
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = try await makeWatcher(dir)
        var it = watcher.events.makeAsyncIterator()

        let final = try TestSupport.simulateScreencapture(in: dir)
        let event = await nextEvent(&it)
        #expect(event?.fileURL?.lastPathComponent == "Screenshot.png")
        #expect(event?.fileURL?.resolvingSymlinksInPath().path == final.resolvingSymlinksInPath().path)
        #expect(event?.origin == .screenshotFolder)

        let second = await nextEvent(&it, timeout: .milliseconds(500))
        #expect(second == nil, "Created + Renamed must collapse to one event")
        await watcher.stop()
    }

    @Test func oldFileMovedInIsNotEmitted() async throws {
        let dir = try TestSupport.makeTempDirectory("old")
        let staging = try TestSupport.makeTempDirectory("staging")
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: staging) }
        let watcher = try await makeWatcher(dir)
        var it = watcher.events.makeAsyncIterator()

        let old = staging.appending(path: "Old.png")
        try TestSupport.pngBytes.write(to: old)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)
        try FileManager.default.moveItem(at: old, to: dir.appending(path: "Old.png"))

        // A fresh capture afterwards is the sentinel: the first event must be it, not Old.png.
        try await Task.sleep(for: .milliseconds(300))
        _ = try TestSupport.simulateScreencapture(in: dir, name: "Fresh.png")
        let event = await nextEvent(&it)
        #expect(event?.fileURL?.lastPathComponent == "Fresh.png")
        await watcher.stop()
    }

    @Test func ignoredPathIsNotEmitted() async throws {
        let dir = try TestSupport.makeTempDirectory("ignore")
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = try await makeWatcher(dir)
        var it = watcher.events.makeAsyncIterator()

        let ours = dir.appending(path: "Clean.png")
        await watcher.ignore(ours, for: nil)
        try TestSupport.pngBytes.write(to: ours, options: .atomic)

        try await Task.sleep(for: .milliseconds(300))
        _ = try TestSupport.simulateScreencapture(in: dir, name: "Fresh.png")
        let event = await nextEvent(&it)
        #expect(event?.fileURL?.lastPathComponent == "Fresh.png")
        await watcher.stop()
    }

    /// Fail-open #10: a rewrite under the same name inside the 30 s window used to be ignored (dedupe by path), so the new
    /// picture was never checked. The dedupe is on the file's identity: a rewrite is a new version and is handed over.
    @Test func aRewriteUnderTheSameNameWithinTheDedupeWindowIsHandedOverAgain() async throws {
        let dir = try TestSupport.makeTempDirectory("dedupe")
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = try await makeWatcher(dir)
        var it = watcher.events.makeAsyncIterator()

        let final = try TestSupport.simulateScreencapture(in: dir)
        let first = await nextEvent(&it)
        #expect(first?.fileURL?.lastPathComponent == "Screenshot.png")

        // Modify in place: new bytes under a name handled seconds ago (a PNG with trailing bytes stays whole).
        try (TestSupport.pngBytes + TestSupport.pngBytes).write(to: final)
        let second = await nextEvent(&it)
        #expect(second?.fileURL?.lastPathComponent == "Screenshot.png")
        let third = await nextEvent(&it, timeout: .milliseconds(500))
        #expect(third == nil, "that version is handed over once")
        await watcher.stop()
    }

    @Test func growingFileWaitsForSettle() async throws {
        let dir = try TestSupport.makeTempDirectory("settle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = try await makeWatcher(dir)
        var it = watcher.events.makeAsyncIterator()

        let url = dir.appending(path: "Growing.png")
        let chunk = Data(repeating: 0xAB, count: 64 * 1024)
        try chunk.write(to: url)
        try await Task.sleep(for: .milliseconds(30))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: chunk)
        try handle.close()

        let event = await nextEvent(&it)
        #expect(event?.fileURL?.lastPathComponent == "Growing.png")
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect(size == chunk.count * 2)
        let second = await nextEvent(&it, timeout: .milliseconds(500))
        #expect(second == nil, "the two chunks must produce one event")
        await watcher.stop()
    }

    @Test func updateRootsSwitchesFolders() async throws {
        let a = try TestSupport.makeTempDirectory("rootA")
        let b = try TestSupport.makeTempDirectory("rootB")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let watcher = try await makeWatcher(a)
        var it = watcher.events.makeAsyncIterator()

        try await watcher.update(roots: [WatchedRoot(url: b, origin: .watched(b))])
        try await Task.sleep(for: Self.armDelay)
        _ = try TestSupport.simulateScreencapture(in: a, name: "InA.png")
        _ = try TestSupport.simulateScreencapture(in: b, name: "InB.png")

        let event = await nextEvent(&it)
        #expect(event?.fileURL?.lastPathComponent == "InB.png")
        #expect(event?.origin == .watched(b))
        let second = await nextEvent(&it, timeout: .milliseconds(500))
        #expect(second == nil)
        await watcher.stop()
    }

    @Test func stopAndStartRepeatedly() async throws {
        let dir = try TestSupport.makeTempDirectory("restart")
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = FolderWatcher(roots: [WatchedRoot(url: dir, origin: .downloads)])
        for _ in 0..<3 {
            try await watcher.start()
            try await watcher.start()
            await watcher.stop()
            await watcher.stop()
        }
        try await watcher.start()
        try await Task.sleep(for: Self.armDelay)
        var it = watcher.events.makeAsyncIterator()
        _ = try TestSupport.simulateScreencapture(in: dir)
        let event = await nextEvent(&it)
        #expect(event?.origin == .downloads)
        await watcher.stop()
    }

    @Test func flagFilterAndNonImageExtension() async throws {
        let isFile = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        let isDir = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        #expect(FolderWatcher.isCandidate(flags: isFile | created))
        #expect(!FolderWatcher.isCandidate(flags: isDir | created))
        #expect(!FolderWatcher.isCandidate(flags: isFile))

        let dir = try TestSupport.makeTempDirectory("ext")
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = try await makeWatcher(dir)
        var it = watcher.events.makeAsyncIterator()
        try Data("not an image".utf8).write(to: dir.appending(path: "notes.txt"))
        try await Task.sleep(for: .milliseconds(300))
        _ = try TestSupport.simulateScreencapture(in: dir, name: "Fresh.PNG")
        let event = await nextEvent(&it)
        #expect(event?.fileURL?.lastPathComponent == "Fresh.PNG", "extension match is case-insensitive")
        await watcher.stop()
    }
}
