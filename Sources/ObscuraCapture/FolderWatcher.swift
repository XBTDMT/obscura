public import Foundation
public import ObscuraSupport
import CoreServices
import Darwin

/// Constants for the folder watch (spec §4 rows 1 to 3). The defaults are the spec's values.
public struct FolderWatcherConfig: Sendable {
    /// FSEvents coalescing latency. 0.05 s is the lowest sensible value without event storms.
    public var latency: TimeInterval = 0.05
    /// A file whose creation date is older than this is not a new screenshot (old file moved in).
    public var creationAgeCutoff: TimeInterval = 20
    /// How long a path registered with `ignore(_:for:)` stays ignored by default (our own writes). `adoptOwnWrite(_:)`
    /// ends it as soon as the write is done.
    public var ignoreTTL: TimeInterval = 5
    /// How long the version of a file that was handed over is remembered (Created + Renamed + Modified of that one
    /// version emit once). Keyed on the file's identity, so a rewrite under the same name is a new version.
    public var dedupeTTL: TimeInterval = 30
    /// Accepted extensions, compared lowercased.
    public var extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"]
    /// Settle: poll the file's identity (inode, size, modification time) this often ...
    public var settlePoll: TimeInterval = 0.05
    /// ... until unchanged for this long, and the image container is whole ...
    public var settleStable: TimeInterval = 0.12
    /// ... and if it is still changing or unfinished after this long, hand it over anyway (the engine then lists it as
    /// "not checked") and keep watching it.
    public var settleMax: TimeInterval = 2.0
    /// After `settleMax`, how often a still-changing or unfinished file is looked at again. Half a second keeps a slow
    /// download's check close to its end at the cost of one stat call per tick.
    public var settleWatchPoll: TimeInterval = 0.5
    /// How long after `settleMax` such a file is watched for its finished version (handed over again when it is whole).
    /// Ten minutes covers a slow download or network copy; past it the "not checked" row stands, with Check Again.
    public var settleWatchMax: TimeInterval = 600
    /// A file larger than this is handed over without its container being walked: the engine reads no more than this
    /// (`InputLimits.maxInputBytes`) and lists a larger file "not checked" (too large), so walking it would only cost.
    public var maxCheckedBytes: Int = InputLimits.maxInputBytes

    public init() {}
}

/// A folder to watch and the origin its files are tagged with.
public struct WatchedRoot: Sendable, Hashable {
    public var url: URL
    public var origin: FileOrigin

    public init(url: URL, origin: FileOrigin) {
        self.url = url
        self.origin = origin
    }

    /// The form used for comparison and prefix matching: standardized, symlinks resolved, trailing slash.
    var resolvedPath: String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        return path.hasSuffix("/") ? path : path + "/"
    }
}

/// One version of a file on disk: the same file (device and inode) with the same size and modification time. A rewrite
/// under the same name (a new inode, or new bytes) is a different identity, so it is a new version to check.
struct FileIdentity: Sendable, Hashable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    /// The identity of the regular file at `path`, or nil when there is none (vanished, or not a regular file).
    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }
}

/// A live FSEvents stream; released to stop it.
protocol EventStreamHandle: AnyObject, Sendable {}

/// Opens a stream for paths with a latency, feeding raw batches to the continuation. The default is FSEvents; tests
/// pass one that fails, to prove a failed start is reported and retried.
typealias EventStreamFactory = @Sendable ([String], TimeInterval, AsyncStream<RawBatch>.Continuation) throws -> any EventStreamHandle

/// Whether the file at a URL is whole, reading at most the given bytes; nil when the caller stopped it (the closure turned
/// true). The default is `FolderWatcher.isWhole`; tests pass a slow one, to prove it runs off the actor and is cancelled.
typealias WholeCheck = @Sendable (URL, Int, () -> Bool) -> Bool?

/// Watches folders with FSEvents and emits one `.file` event per new image once it has settled.
///
/// Filter, in order (spec §4 row 2): `ItemIsFile && (ItemCreated || ItemRenamed || ItemModified)`; no dot-files;
/// extension in the set; not in `ignoredPaths` (our own writes); not settling already; a regular file with a creation
/// date younger than the cutoff; not the version already handed over (identity dedupe). Then settle (row 3) and emit.
/// A batch whose flags say events were dropped (MustScanSubDirs, UserDropped, KernelDropped, RootChanged) makes the
/// watcher look through the folder for young files itself, so a dropped event never leaves a new screenshot unseen.
public actor FolderWatcher: CaptureSource {
    nonisolated public let events: AsyncStream<CaptureEvent>
    private nonisolated let continuation: AsyncStream<CaptureEvent>.Continuation

    private let config: FolderWatcherConfig
    private let clock: any WallClock
    private let makeStream: EventStreamFactory
    private let wholeCheck: WholeCheck
    private var roots: [WatchedRoot]
    private var stream: (any EventStreamHandle)?
    /// The roots the open stream covers; nil while no stream is open (not started, or opening failed).
    private var openRoots: Set<WatchedRoot>?
    /// An open failed: once a stream opens again, the roots are looked through for files created meanwhile.
    private var missedWhileClosed = false
    private var running = false

    /// path → expiry: our own writes in progress.
    private var ignoredPaths: [String: Date] = [:]
    /// path → the version last handed over (or written by us), and when that memory expires.
    private var handled: [String: (identity: FileIdentity, expiry: Date)] = [:]
    private var settling: [String: Task<Void, Never>] = [:]

    /// Raw FSEvents batches, in arrival order, consumed by one task so filtering stays ordered.
    private nonisolated let rawBatches: AsyncStream<RawBatch>
    private nonisolated let rawContinuation: AsyncStream<RawBatch>.Continuation
    private var consumer: Task<Void, Never>?

    public init(roots: [WatchedRoot], config: FolderWatcherConfig = .init(), clock: any WallClock = SystemClock()) {
        self.init(roots: roots, config: config, clock: clock, streamFactory: { paths, latency, continuation in
            try FSEventsStream(paths: paths, latency: latency, continuation: continuation)
        })
    }

    init(roots: [WatchedRoot], config: FolderWatcherConfig = .init(), clock: any WallClock = SystemClock(), streamFactory: @escaping EventStreamFactory,
         wholeCheck: @escaping WholeCheck = FolderWatcher.isWhole) {
        self.roots = roots
        self.config = config
        self.clock = clock
        self.makeStream = streamFactory
        self.wholeCheck = wholeCheck
        let (stream, continuation) = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = continuation
        let (raw, rawContinuation) = AsyncStream<RawBatch>.makeStream(bufferingPolicy: .unbounded)
        self.rawBatches = raw
        self.rawContinuation = rawContinuation
    }

    deinit {
        // `stream` is released with the actor; its deinit stops, invalidates and releases the FSEventStream.
        rawContinuation.finish()
        continuation.finish()
    }

    public var isRunning: Bool { running }
    public var currentRoots: [WatchedRoot] { roots }
    /// True when every root is covered by an open stream (or there is nothing to watch). False after a failed start or
    /// update until a later `start()`/`update(roots:)` opens the stream (fail-open #10).
    public var isWatching: Bool { roots.isEmpty || (stream != nil && openRoots == Set(roots)) }

    /// Opens the stream for the current roots. Throws `FolderWatcherError.streamCreationFailed` if FSEvents refuses the
    /// roots; the watcher stays started, so the next `start()` or `update(roots:)` tries again.
    public func start() async throws {
        if !running {
            running = true
            if consumer == nil {
                consumer = Task { [weak self, rawBatches] in
                    for await batch in rawBatches {
                        guard let self else { return }
                        await self.receive(batch)
                    }
                }
            }
            Log.capture.info("folder watcher started: \(self.roots.count) roots")
        }
        try openStreamIfNeeded()
    }

    /// Tears the stream down. Pending settles are cancelled; the `events` stream stays open for the next `start()`.
    public func stop() async {
        guard running else { return }
        running = false
        stream = nil
        openRoots = nil
        for task in settling.values { task.cancel() }
        settling.removeAll()
        Log.capture.info("folder watcher stopped")
    }

    /// Suppresses events for `url` while our own write-back runs. `nil` uses `config.ignoreTTL`. Follow a successful write
    /// with `adoptOwnWrite(_:)`.
    public func ignore(_ url: URL, for ttl: Duration? = nil) {
        let seconds = ttl?.seconds ?? config.ignoreTTL
        ignoredPaths[Self.key(for: url)] = clock.now().addingTimeInterval(seconds)
    }

    /// Our write to `url` is done: the version now on disk is ours and is never handed over, and the path stops being
    /// ignored, so a different file saved under the same name a moment later is still seen.
    public func adoptOwnWrite(_ url: URL) {
        let key = Self.key(for: url)
        ignoredPaths[key] = nil
        if let identity = FileIdentity(path: key) {
            handled[key] = (identity, clock.now().addingTimeInterval(config.dedupeTTL))
        }
    }

    /// Replaces the root list and (re)opens the stream when the roots changed or no stream is open. Throws when FSEvents
    /// refuses; the roots are kept, so the next call tries again (fail-open #10: a failure is never remembered as done).
    public func update(roots newRoots: [WatchedRoot]) throws {
        roots = newRoots
        guard running else { return }
        try openStreamIfNeeded()
    }

    // MARK: - Stream

    private func openStreamIfNeeded() throws {
        let wanted = Set(roots)
        if stream != nil, openRoots == wanted { return }
        let reopening = stream != nil
        stream = nil
        openRoots = nil
        guard !roots.isEmpty else { return }
        let paths = roots.map { $0.url.standardizedFileURL.path(percentEncoded: false) }
        do {
            stream = try makeStream(paths, config.latency, rawContinuation)
        } catch {
            missedWhileClosed = true
            Log.capture.error("folder watcher could not open its stream: \(self.roots.count) roots")
            throw error
        }
        openRoots = wanted
        if reopening { Log.capture.info("folder watcher roots changed: \(self.roots.count) roots") }
        if missedWhileClosed {
            missedWhileClosed = false
            Log.capture.info("folder watcher open again; looking through the roots for files created meanwhile")
            rescanRoots()
        }
    }

    // MARK: - Filtering

    /// One FSEvents batch. Internal so tests can deliver flags FSEvents cannot be made to produce on demand.
    func receive(_ batch: RawBatch) {
        guard running else { return }
        let now = clock.now()
        ignoredPaths = ignoredPaths.filter { $0.value > now }
        handled = handled.filter { $0.value.expiry > now }

        var accepted = 0
        var rescanAll = false
        var rescanFolders: Set<String> = []
        for (path, flags) in zip(batch.paths, batch.flags) {
            if Self.droppedEvents(flags) {
                rescanAll = true
                continue
            }
            if Self.mustScanSubDirs(flags) {
                rescanFolders.insert(path)
                continue
            }
            guard Self.isCandidate(flags: flags) else { continue }
            if consider(URL(filePath: path), now: now) { accepted += 1 }
        }
        if rescanAll {
            Log.capture.notice("fsevents dropped events; looking through every root")
            rescanRoots()
        } else {
            for folder in rescanFolders {
                Log.capture.notice("fsevents asked for a folder scan")
                rescan(URL(filePath: folder, directoryHint: .isDirectory))
            }
        }
        Log.capture.debug("fsevents batch: \(batch.paths.count) events, \(accepted) accepted")
    }

    /// The filter of spec §4 row 2 for one file, then a settle task. True when the file was accepted.
    @discardableResult
    private func consider(_ fileURL: URL, now: Date) -> Bool {
        let url = fileURL.standardizedFileURL
        if url.lastPathComponent.hasPrefix(".") { return false }
        if !config.extensions.contains(url.pathExtension.lowercased()) { return false }
        let key = Self.key(for: url)
        if ignoredPaths[key] != nil { return false }
        if settling[key] != nil { return false }           // already settling: that task sees every change
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .creationDateKey]),
              values.isRegularFile == true,
              let created = values.creationDate else { return false }
        if now.timeIntervalSince(created) >= config.creationAgeCutoff { return false }
        guard let origin = origin(forResolvedPath: key) else { return false }
        guard let identity = FileIdentity(path: key) else { return false }
        if handled[key]?.identity == identity { return false }   // this exact version was handed over (or is ours)

        settling[key] = Task { [weak self] in
            await self?.settleAndEmit(url, key: key, origin: origin)
        }
        return true
    }

    /// Dropped events: the kernel or the client fell behind, or the watched root itself moved.
    nonisolated static func droppedEvents(_ flags: FSEventStreamEventFlags) -> Bool {
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
                                              kFSEventStreamEventFlagRootChanged)
        return flags & dropped != 0
    }

    /// Events under this folder were coalesced: its contents must be looked at again.
    nonisolated static func mustScanSubDirs(_ flags: FSEventStreamEventFlags) -> Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
    }

    nonisolated static func isCandidate(flags: FSEventStreamEventFlags) -> Bool {
        let isFile = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let interesting = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified)
        return flags & isFile != 0 && flags & interesting != 0
    }

    nonisolated static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    /// Longest-prefix match of the resolved file path against the resolved roots.
    private func origin(forResolvedPath path: String) -> FileOrigin? {
        roots
            .filter { path.hasPrefix($0.resolvedPath) }
            .max { $0.resolvedPath.count < $1.resolvedPath.count }?
            .origin
    }

    // MARK: - Rescan

    private func rescanRoots() {
        for root in roots { rescan(root.url) }
    }

    /// Looks through `folder` (and below, as FSEvents watches) for image files younger than the creation-age cutoff and
    /// puts each through the same filter as an event. Hidden files and package contents are skipped.
    private func rescan(_ folder: URL) {
        let now = clock.now()
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var accepted = 0
        for case let url as URL in walker where consider(url, now: now) { accepted += 1 }
        Log.capture.info("folder rescan accepted \(accepted) file(s)")
    }

    // MARK: - Settle

    /// Polls the file's identity until it is unchanged for `settleStable` and its image container is whole, then emits.
    /// A file still changing or unfinished at `settleMax` is emitted anyway (the engine lists it "not checked", never
    /// judging a part-written picture) and watched on, every `settleWatchPoll`, for up to `settleWatchMax`: its finished
    /// version is emitted again (fail-open #5). A file that disappears is dropped: there is nothing left on disk to cover.
    private func settleAndEmit(_ url: URL, key: String, origin: FileOrigin) async {
        defer { settling[key] = nil }
        let started = ContinuousClock.now
        let settleMax = Duration.seconds(config.settleMax)
        let watchEnd = settleMax + .seconds(config.settleWatchMax)
        var last: FileIdentity?
        var stableSince = started
        var judged: FileIdentity?
        var handedOver = false
        while !Task.isCancelled, running {
            guard let identity = FileIdentity(path: key) else {
                Log.capture.debug("settle abandoned: file vanished")
                return
            }
            let now = ContinuousClock.now
            if identity != last {
                last = identity
                stableSince = now
            } else if now - stableSince >= .seconds(config.settleStable), identity != judged {
                judged = identity
                // Off the actor (security scan F1, F3): one hostile file's walk never holds up the other files, `ignore`,
                // `update(roots:)` or the engine's maintenance tick. nil: this settle was cancelled (stop).
                guard let whole = await checkWhole(url, size: identity.size) else { return }
                guard !Task.isCancelled, running else { return }
                if whole {
                    // The walk judged the version stat'ed before it; one that changed meanwhile is looked at again.
                    if FileIdentity(path: key) == identity {
                        if !isHandled(key, identity) { emit(url, key: key, identity: identity, origin: origin) }
                        return
                    }
                } else {
                    Log.capture.debug("settle: file looks unfinished")
                }
            }
            if !handedOver, now - started >= settleMax {
                // Still changing or unfinished at the bound: hand it over so it shows as "not checked", and watch on.
                Log.capture.notice("settle hit the bound; handed over and still watching")
                if !isHandled(key, identity) { emit(url, key: key, identity: identity, origin: origin) }
                handedOver = true
            }
            if now - started >= watchEnd {
                Log.capture.notice("stopped watching a file that never looked finished")
                return
            }
            try? await Task.sleep(for: .seconds(now - started >= settleMax ? config.settleWatchPoll : config.settlePoll))
        }
    }

    /// The version on disk is one already handed over, or our own write (adopted, or still being written).
    private func isHandled(_ key: String, _ identity: FileIdentity) -> Bool {
        ignoredPaths[key].map { $0 > clock.now() } == true || handled[key]?.identity == identity
    }

    private func emit(_ url: URL, key: String, identity: FileIdentity, origin: FileOrigin) {
        handled[key] = (identity, clock.now().addingTimeInterval(config.dedupeTTL))
        continuation.yield(.file(url, origin: origin))
        Log.capture.info("file captured after settle")
    }

    /// `wholeCheck` on a detached task, cancelled with this one. A file larger than `maxCheckedBytes` is not walked.
    private func checkWhole(_ url: URL, size: Int64) async -> Bool? {
        let maxBytes = config.maxCheckedBytes
        guard size <= maxBytes else {
            Log.capture.notice("settle: file larger than the engine reads; handed over without a container check")
            return true
        }
        let check = wholeCheck
        let walk = Task.detached(priority: .userInitiated) { check(url, maxBytes) { Task.isCancelled } }
        return await withTaskCancellationHandler { await walk.value } onCancel: { walk.cancel() }
    }

    /// Whether the image container on disk is whole (`ImageContainer`), reading at most `maxBytes` (mapped, never
    /// copied). A file that cannot be read here, or is larger than that, is handed over: the engine's own read reports
    /// it. nil when `shouldStop` ended the walk.
    nonisolated static func isWhole(_ url: URL, maxBytes: Int, stopWhen shouldStop: () -> Bool) -> Bool? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return true }
        guard data.count <= maxBytes else { return true }
        guard let result = ImageContainer.completeness(of: data, stopWhen: shouldStop) else { return nil }
        return result != .truncated
    }
}

public enum FolderWatcherError: Error, Sendable {
    case streamCreationFailed
}

struct RawBatch: Sendable {
    var paths: [String]
    var flags: [FSEventStreamEventFlags]
}

/// Owns one FSEventStream on a private serial queue. Creating it starts it; releasing it stops, invalidates
/// and releases the stream *on the queue*, so no callback can be in flight afterwards.
final class FSEventsStream: EventStreamHandle, @unchecked Sendable {
    /// What the C callback reaches: retained by FSEvents through the context's retain/release callbacks.
    final class Target {
        let continuation: AsyncStream<RawBatch>.Continuation
        init(continuation: AsyncStream<RawBatch>.Continuation) { self.continuation = continuation }
    }

    private let queue = DispatchQueue(label: AppIdentity.current.bundleIdentifier + ".fsevents", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    private let stream: FSEventStreamRef

    init(paths: [String], latency: TimeInterval, continuation: AsyncStream<RawBatch>.Continuation) throws {
        queue.setSpecific(key: queueKey, value: ())
        let target = Target(continuation: continuation)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(target).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                return UnsafeRawPointer(Unmanaged<Target>.fromOpaque(info).retain().toOpaque())
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Target>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        // WatchRoot: a root that is moved or deleted reports RootChanged, which the watcher answers with a rescan.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes |
                                             kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            FSEventsStream.callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            throw FolderWatcherError.streamCreationFailed
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw FolderWatcherError.streamCreationFailed
        }
    }

    deinit {
        let stream = stream
        let teardown = {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            teardown()
        } else {
            queue.sync(execute: teardown)
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let target = Unmanaged<Target>.fromOpaque(info).takeUnretainedValue()
        let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        guard let paths = cfPaths as? [String] else { return }
        let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
        target.continuation.yield(RawBatch(paths: paths, flags: flags))
    }
}
