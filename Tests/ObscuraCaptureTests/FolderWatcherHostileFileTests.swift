// Security scan 2026-10-28, F1 and F3: the watcher's "is this file whole?" walk ran synchronously on the FolderWatcher
// actor and read the whole file with no size cap, so one crafted file in a watched folder held up every other capture,
// `ignore`, `update(roots:)` and the engine's maintenance tick. Every file here is made up and small; a slow check is
// simulated by an injected one, never by a large file.
import CoreServices
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ObscuraCapture

/// A container check that holds until the test opens it, or until it is told to stop.
final class HeldCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var _entered = 0
    private var _stopped = false
    var entered: Int { lock.withLock { _entered } }
    var stopped: Bool { lock.withLock { _stopped } }
    func open() { lock.withLock { isOpen = true } }

    var check: WholeCheck {
        { _, _, shouldStop in
            self.lock.withLock { self._entered += 1 }
            while !self.lock.withLock({ self.isOpen }) {
                if shouldStop() {
                    self.lock.withLock { self._stopped = true }
                    return nil
                }
                usleep(1000)
            }
            return true
        }
    }
}

/// True once `condition` holds, false after `timeout`.
func eventually(_ timeout: Duration = .seconds(3), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Whether `work` finishes within `timeout` (it keeps running if not; the test then fails rather than hangs).
func finishes(within timeout: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
    let done = Flag()
    Task { await work(); done.set() }
    return await eventually(timeout) { done.value }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}

@Suite(.serialized) struct FolderWatcherHostileFileTests {
    static let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemCreated)

    static func watcher(_ dir: URL, config: FolderWatcherConfig = .init(), check: @escaping WholeCheck = FolderWatcher.isWhole) async throws -> FolderWatcher {
        let watcher = FolderWatcher(roots: [WatchedRoot(url: dir, origin: .screenshotFolder)], config: config,
                                    streamFactory: { _, _, _ in SilentStream() }, wholeCheck: check)
        try await watcher.start()
        return watcher
    }

    /// While one file's container check runs, the actor answers: another call (`update(roots:)`, which the engine's
    /// maintenance tick awaits) returns at once. The old check ran on the actor, so this call waited for the walk.
    @Test func aSlowContainerCheckDoesNotHoldTheWatcher() async throws {
        let dir = try TestSupport.makeTempDirectory("held")
        defer { try? FileManager.default.removeItem(at: dir) }
        let held = HeldCheck()
        let watcher = try await Self.watcher(dir, check: held.check)
        let log = EventLog(watcher.events)
        defer { log.stop() }
        let roots = await watcher.currentRoots
        let url = dir.appending(path: "Screenshot held.png")
        try TestImageFiles.encoded(.png).write(to: url)
        await watcher.receive(RawBatch(paths: [url.path], flags: [Self.created]))
        #expect(await eventually { held.entered == 1 }, "the check started")

        #expect(await finishes(within: .milliseconds(500)) { try? await watcher.update(roots: roots) },
                "the actor is free while the check runs")
        #expect(log.entries.isEmpty, "nothing is handed over before the check says whole")

        held.open()
        #expect(await log.wait(count: 1, timeout: .seconds(2)))
        await watcher.stop()
    }

    /// Stopping the watcher cancels a check in progress: the walk is told to stop and nothing is handed over.
    @Test func stoppingTheWatcherStopsTheCheck() async throws {
        let dir = try TestSupport.makeTempDirectory("stop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let held = HeldCheck()
        let watcher = try await Self.watcher(dir, check: held.check)
        let log = EventLog(watcher.events)
        defer { log.stop() }
        let url = dir.appending(path: "Screenshot stopped.png")
        try TestImageFiles.encoded(.png).write(to: url)
        await watcher.receive(RawBatch(paths: [url.path], flags: [Self.created]))
        #expect(await eventually { held.entered == 1 })
        await watcher.stop()
        #expect(await eventually { held.stopped }, "the walk was told to stop")
        try await Task.sleep(for: .milliseconds(200))
        #expect(log.entries.isEmpty)
    }

    /// A file larger than the engine reads is handed over without a walk (the engine then lists it "not checked", too
    /// large): the check is never called, and the file does not wait for the bound. Scaled: a 64-byte ceiling.
    @Test func aFileLargerThanTheEngineReadsIsNotWalked() async throws {
        let dir = try TestSupport.makeTempDirectory("cap")
        defer { try? FileManager.default.removeItem(at: dir) }
        var config = FolderWatcherConfig()
        config.maxCheckedBytes = 64
        config.settleMax = 5
        let held = HeldCheck()
        let watcher = try await Self.watcher(dir, config: config, check: held.check)
        let log = EventLog(watcher.events)
        defer { log.stop() }
        let url = dir.appending(path: "Screenshot large.png")
        let whole = TestImageFiles.encoded(.png)
        try whole.prefix(whole.count / 2).write(to: url)       // unfinished, but past the ceiling: not walked
        await watcher.receive(RawBatch(paths: [url.path], flags: [Self.created]))
        #expect(await log.wait(count: 1, timeout: .seconds(2)), "handed over well before the 5 s bound")
        #expect(held.entered == 0)
        await watcher.stop()
    }

    /// The real check stays bounded too: `isWhole` reads no more than its ceiling, and F3's crafted TIFF (scaled, named
    /// .png) is handed over at once as malformed (ImageIO's call), not walked entry by entry.
    @Test func theRealCheckRefusesOversizeAndAnswersAHostileTIFFAtOnce() async throws {
        let dir = try TestSupport.makeTempDirectory("tiff")
        defer { try? FileManager.default.removeItem(at: dir) }
        let unfinished = dir.appending(path: "unfinished.png")
        let whole = TestImageFiles.encoded(.png)
        try whole.prefix(whole.count / 2).write(to: unfinished)
        #expect(FolderWatcher.isWhole(unfinished, maxBytes: whole.count, stopWhen: { false }) == false)
        #expect(FolderWatcher.isWhole(unfinished, maxBytes: 16, stopWhen: { false }) == true, "past the ceiling: not walked")

        // 2,000 StripOffsets entries × 2,000 LONGs over one region: 4,000,000 reads in the old walk.
        var tiff: [UInt8] = Array("II".utf8) + [42, 0, 8, 0, 0, 0]
        func u16(_ v: Int) { tiff += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: Int) { tiff += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        let entries = 2000, count = 2000, region = 8 + 2 + 12 * entries + 4
        u16(entries)
        for _ in 0..<entries { u16(273); u16(4); u32(count); u32(region) }
        u32(0)
        tiff += [UInt8](repeating: 0, count: count * 4)
        let hostile = dir.appending(path: "receipt.png")
        try Data(tiff).write(to: hostile)
        #expect(FolderWatcher.isWhole(hostile, maxBytes: .max, stopWhen: { false }) == true)

        let watcher = try await Self.watcher(dir)
        let log = EventLog(watcher.events)
        defer { log.stop() }
        await watcher.receive(RawBatch(paths: [hostile.path], flags: [Self.created]))
        #expect(await log.wait(count: 1, timeout: .seconds(1)))
        await watcher.stop()
    }
}
