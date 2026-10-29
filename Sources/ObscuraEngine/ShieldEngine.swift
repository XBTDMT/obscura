// ObscuraEngine — the actor that composes the pipeline (ARCHITECTURE.md §3, §4, §7).
// It owns the state (in-flight scans, compiled catalogue, pause flag, problems) and serializes decisions;
// every heavy stage runs off the actor through `Pipeline`.
public import AppKit
import Foundation
public import ObscuraCapture
import ObscuraDetect
public import ObscuraJournal
public import ObscuraOCR
public import ObscuraPrefs
public import ObscuraRender
public import ObscuraSearch
public import ObscuraSupport
import CoreGraphics
import UniformTypeIdentifiers

/// Identity of an image in flight: a new event for the same key cancels and replaces the older scan.
public enum CaptureKey: Sendable, Hashable {
    case path(String)
    case pasteboard(changeCount: Int)

    public init(file url: URL) { self = .path(url.resolvingSymlinksInPath().path) }
}

/// An image entering the pipeline: which one, and where it came from.
public struct ScanStart: Sendable, Hashable {
    public let key: CaptureKey
    public let displayName: String
    public let fileURL: URL?
    public let origin: FileOrigin?
}

/// What else happened in a scan that its notice must say, beyond the outcome.
public struct ScanNotes: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The clipboard changed after the image was copied (or the screenshot taken), so the covered picture was not
    /// written over the newer copy (fail-open #18). The catch is in the Journal; the clipboard holds what was copied later.
    public static let clipboardChangedMeanwhile = ScanNotes(rawValue: 1 << 0)
    /// The plain text copied with the image held a secret, so the write-back left it out (fail-open #8).
    public static let companionTextRemoved = ScanNotes(rawValue: 1 << 1)
    /// Fail-open #1: part of the picture could not be read (a G-12 re-read band: no time left, a sheet that failed, no
    /// text at any scale). What was found is covered (to the end of the unread band's ink), yet the picture is not
    /// called checked: a file keeps a "Not checked" row (Check Again), the status counts it, the notice says so, and
    /// G-18 does not put it on the clipboard.
    public static let partlyRead = ScanNotes(rawValue: 1 << 2)
    /// With `partlyRead`: the part went unread because the image's OCR deadline ran out (else the read failed).
    public static let partlyReadTimedOut = ScanNotes(rawValue: 1 << 3)
    /// The plain text copied with the image could not be checked in full (too long, or its check was stopped), so the
    /// write-back left it out as if it held a secret (security scan F9).
    public static let companionTextNotChecked = ScanNotes(rawValue: 1 << 4)
    /// G-40: the picture's only unread parts are small spots no reading could read, and at least one waits for the
    /// person (`ScanReport.spots`). Not an alarm: the file is listed under Not checked as `unreadPatch` (a catch's file
    /// too), never called clean and never put on the clipboard until the spots are settled.
    public static let unreadSpots = ScanNotes(rawValue: 1 << 5)
    /// G-40 route B (`Settings.coversUnreadableSpots`): spots no reading could read were covered; the catch's notice says
    /// how many, so the picture is never presented as fully read.
    public static let spotsCovered = ScanNotes(rawValue: 1 << 6)
    /// G-40 route D (`Settings.skipsTinySpots`): spots too small to hold a secret were skipped and recorded.
    public static let spotsSkipped = ScanNotes(rawValue: 1 << 7)

    /// With `partlyRead`: Vision answered every call for the unread part with no text (G-40's true wording): not a failure.
    public static let partlyReadNoText = ScanNotes(rawValue: 1 << 8)

    /// The skip reason a partly read picture is listed under (`ocrTimeout`, `textNotRead` or `ocrFailed`), nil when it was
    /// read whole.
    public var partlyReadReason: SkipReason? {
        guard contains(.partlyRead) else { return nil }
        if contains(.partlyReadTimedOut) { return .ocrTimeout }
        return contains(.partlyReadNoText) ? .textNotRead : .ocrFailed
    }
}

/// One finished scan, as published on `ShieldEngine.events` (`.finished`) and `ShieldEngine.outcomes`.
/// It names the image it is about (file URL and origin; both nil for the clipboard), so a consumer decides from the
/// report alone and keeps no state about starts (G-9).
public struct ScanReport: Sendable {
    public let key: CaptureKey?
    public let displayName: String
    public let outcome: ScanOutcome
    /// The file that was scanned; nil for a clipboard image.
    public let fileURL: URL?
    /// Where the file came from; nil for a clipboard image.
    public let origin: FileOrigin?
    /// What the notice must say besides the outcome.
    public let notes: ScanNotes
    /// G-40: the spots no reading could read, each with how it stands (empty unless the picture is the patch case).
    /// Geometry and states only.
    public let spots: [SpotRecord]

    public init(key: CaptureKey?, displayName: String, outcome: ScanOutcome, fileURL: URL? = nil, origin: FileOrigin? = nil,
                notes: ScanNotes = [], spots: [SpotRecord] = []) {
        self.key = key
        self.displayName = displayName
        self.outcome = outcome
        self.fileURL = fileURL
        self.origin = origin
        self.notes = notes
        self.spots = spots
    }

    /// G-40: spots covered (route B), skipped as too small (route D) and waiting for the person.
    public var coveredSpots: Int { spots.filter { $0.state == .covered }.count }
    public var skippedSpots: Int { spots.filter { $0.state == .tooSmall }.count }
    public var pendingSpots: Int { spots.filter { $0.state == .pending }.count }
}

/// The engine's scan events in the order the engine actor produced them: a scan's `.started` always precedes its
/// `.finished`, because both are yielded from the actor and the finish is a later actor turn than the start (G-9).
public enum ScanEvent: Sendable {
    case started(ScanStart)
    case finished(ScanReport)
}

public actor ShieldEngine {
    // MARK: Dependencies

    private let sources: [any CaptureSource]
    private let recognizer: any TextRecognizer
    private let journal: any JournalStore
    private let settings: any SettingsReader
    private let clock: any WallClock
    private let folderWatcher: FolderWatcher?
    private let clipboardGuard: ClipboardGuard?
    private let ocrQueue: OCRQueue
    private let redactedWord: String
    /// Spotlight entries and Finder tags for covered files (G-24); nil in the CLI and in tests that do not need them.
    private let search: SearchCoordinator?
    /// Where the screenshot folder and Downloads are (the system's in the app; a test's own folders in tests).
    private let locations: FolderLocations
    /// F17 (G-36): the folders the person confirmed in Obscura itself, and their last good read. Downloads and added
    /// folders are watched only when confirmed here; the settings' paths alone are a request.
    private let folderApprovals: any FolderApprovalStore
    private var approvals: [FolderApproval] = []
    private var approvalsLoaded = false

    // MARK: State

    private struct InFlight { let generation: UInt64; let task: Task<Void, Never> }
    private var inFlight: [CaptureKey: InFlight] = [:]
    private var generation: UInt64 = 0
    private var paused = false
    private var catalogue: CompiledCatalogue?
    private var detectorTitles: [String: String] = [:]
    private var catalogueProblems: [Problem] = []
    private var folderProblems: [Problem] = []
    private var sourceProblems: [Problem] = []
    /// The folder watcher could not open its stream (fail-open #10). Set and cleared by every `updateFolders`, so the
    /// next maintenance tick or settings change tries again and the status shows it until one succeeds.
    private var watcherProblem: Problem?
    /// The Journal's upkeep could not finish (fail-open #11); set and cleared by every maintenance tick.
    private var maintenanceProblem: Problem?
    private var warmupProblem: Problem?
    /// Failed scans inside `recentFailureWindow`, by the image they failed on (nil for a one-shot `scan(...)` call),
    /// so a later successful check of the same image clears its failure from the status.
    private var recentFailures: [(key: CaptureKey?, date: Date)] = []
    /// G-40: copied images whose only unread parts are spots no reading could read, inside `recentFailureWindow`: they
    /// have no row to list, so the status counts them, with no alarm (`Problem.Kind.unreadSpots`).
    private var recentSpotImages: [(key: CaptureKey?, date: Date)] = []
    /// Files left without a verdict, kept so "Check Again" can re-submit each with the origin it came from. A write-through
    /// mirror of the Journal's `unchecked` table (G-13), loaded from it once (`loadUnchecked()`), so the list survives a
    /// relaunch.
    private var unchecked: [CaptureKey: UncheckedFile] = [:]
    /// Files on disk that still show what was caught because the covered picture could not be written there, by the
    /// path that should hold it (fail-open #7). A write-through mirror of the Journal's `uncovered_files` table, loaded
    /// with `unchecked`, so the status shows them until a write succeeds, across relaunches, and for this run even when
    /// the Journal cannot be written.
    private var uncovered: [String: UncoveredFile] = [:]
    /// The one load of the persisted lists; every reader of `unchecked` or `uncovered` awaits it first.
    private var uncheckedLoad: Task<Void, Never>?
    private var lastCatch: LastCatch?
    private var warmupMilliseconds: Int?

    private nonisolated let statusBroadcaster = Broadcaster<EngineStatus>(replayLatest: true)
    private nonisolated let eventBroadcaster = Broadcaster<ScanEvent>()
    private nonisolated let outcomeBroadcaster = Broadcaster<ScanReport>()

    /// Every status change. Multi-consumer; a new consumer receives the latest status first.
    public nonisolated var status: AsyncStream<EngineStatus> { statusBroadcaster.makeStream() }
    /// Every scan's start and finish, in engine order: a scan's `.started` always reaches a consumer before its
    /// `.finished` (G-9). The app routes both to the notifier and the floating thumbnail from one task. Multi-consumer;
    /// no replay.
    public nonisolated var events: AsyncStream<ScanEvent> { eventBroadcaster.makeStream() }
    /// Every finished scan, including the ones `run()` started: the `.finished` half of `events`, for consumers that
    /// need no starts (the CLI, the model's mirror). Multi-consumer; no replay.
    public nonisolated var outcomes: AsyncStream<ScanReport> { outcomeBroadcaster.makeStream() }

    public init(sources: [any CaptureSource], recognizer: any TextRecognizer, journal: any JournalStore,
                settings: any SettingsReader, clock: any WallClock, folderWatcher: FolderWatcher?, clipboardGuard: ClipboardGuard?,
                redactedWord: String = PipelineConstants.defaultRedactedWord, search: SearchCoordinator? = nil,
                locations: FolderLocations = .system, folderApprovals: any FolderApprovalStore = InMemoryFolderApprovalStore()) {
        self.sources = sources
        self.recognizer = recognizer
        self.journal = journal
        self.settings = settings
        self.clock = clock
        self.folderWatcher = folderWatcher
        self.clipboardGuard = clipboardGuard
        self.redactedWord = redactedWord
        self.search = search
        self.locations = locations
        self.folderApprovals = folderApprovals
        self.ocrQueue = OCRQueue(recognizer: recognizer, maxQueued: PipelineConstants.maxQueuedScans)
    }

    // MARK: - Run loop

    /// Warms the recognizer, starts every source and consumes their events until the task is cancelled.
    public func run() async {
        await loadUnchecked()
        // G-36: the confirmations store is Obscura's own from the first launch on, then read before anything is watched.
        do { try folderApprovals.prepare() } catch { Log.engine.error("watched-folder confirmations could not be prepared") }
        reloadApprovals()
        // Watch first, warm up second: Vision's warm-up takes 12–26 s cold (76 s seen under load), and a screenshot taken
        // while it runs (say, at login) must still be seen. The sources buffer their events until the task group below
        // consumes them, so a capture made during warm-up waits its turn instead of being missed (fail-open review,
        // 2026-10-28: the folder watcher used to open only after the warm-up and never looked back).
        await startSources()
        await applySettings(settings.current())
        await warmUp()
        await catalogueChanged()
        // G-28: entries from before schema 6 (or whose clean file no longer matches its row) get a trusted picture, drawn
        // with the detector titles the catalogue just loaded (a "kind" label style names them).
        await repairCleanPictures()
        // G-24: every covered file's Spotlight entry and tags checked against the file, and the domain rebuilt.
        await search?.reconcile(full: true, titles: detectorTitles, switches: Self.searchSwitches(settings.current()))
        await maintenanceTick()
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { [weak self] in
                    for await event in source.events {
                        guard let self else { return }
                        await self.submit(event)
                        if Task.isCancelled { return }
                    }
                }
            }
            group.addTask { [weak self, settings] in
                for await changed in settings.changes {
                    guard let self else { return }
                    await self.applySettings(changed)
                    await self.publishStatus()
                }
            }
            // Retention, stale sweep, screenshot-folder re-read and folder re-probe run on a schedule, not only on demand:
            // without this, originals would outlive the retention the app promises.
            group.addTask { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: PipelineConstants.maintenanceInterval,
                                          tolerance: PipelineConstants.maintenanceTolerance)
                    guard let self, !Task.isCancelled else { return }
                    await self.maintenanceTick()
                }
            }
            await group.waitForAll()
        }
    }

    /// Hands one event to the pipeline. One `Task` per image, keyed; an older task for the same key is cancelled.
    /// The scan's `.started` is yielded here, on the actor, before its task exists, so it precedes its `.finished`.
    public func submit(_ event: CaptureEvent) {
        submit(event, isRetry: false)
    }

    /// `isRetry`: a Check Again, which never puts the picture on the clipboard (G-18: only a new screenshot does).
    private func submit(_ event: CaptureEvent, isRetry: Bool) {
        let key: CaptureKey
        let start: ScanStart
        switch event {
        case .file(let url, let origin):
            key = CaptureKey(file: url)
            start = ScanStart(key: key, displayName: url.lastPathComponent, fileURL: url, origin: origin)
        case .pasteboardImage(_, _, let changeCount, _), .pasteboardFiles(_, let changeCount, _):
            key = .pasteboard(changeCount: changeCount)
            start = ScanStart(key: key, displayName: "Clipboard", fileURL: nil, origin: nil)
        }
        if let older = inFlight[key] {
            older.task.cancel()
            Log.engine.info("replaced in-flight scan for a repeated key")
        }
        generation &+= 1
        let gen = generation
        eventBroadcaster.send(.started(start))
        let task = Task { [weak self] in
            guard let self else { return }
            let (name, outcome, notes, spots) = await self.process(event, key: key, isRetry: isRetry)
            await self.finished(start, generation: gen, displayName: name, outcome: outcome, notes: notes, spots: spots)
        }
        inFlight[key] = InFlight(generation: gen, task: task)
    }

    /// Checks a file again ("Check Again" on a scan-failure alert or the panel). The file goes back through `submit`
    /// with the origin it first came from. A file the engine does not list (one dismissed from the Journal's Not checked
    /// section, or one a later check already settled) takes the origin of the watched folder that holds it, or `.imported` (checked
    /// into the Journal, nothing written back) when no watched folder does. Returns the origin used.
    @discardableResult
    public func retry(_ url: URL) async -> FileOrigin {
        await loadUnchecked()
        let key = CaptureKey(file: url)
        let known = unchecked[key]
        let file = known?.fileURL ?? url
        let origin = Self.checkedOrigin(of: file, stored: known?.origin, in: watchedRoots())
        Log.engine.info("check again requested known=\(known != nil)")
        submit(.file(file, origin: origin), isRetry: true)
        return origin
    }

    /// Checks every remembered unchecked file again (a "Check Again" for "N images weren't checked").
    /// Returns how many were re-submitted.
    @discardableResult
    public func retryUnchecked() async -> Int {
        await loadUnchecked()
        let files = unchecked.values.sorted { $0.date < $1.date }
        let roots = watchedRoots()
        for file in files {
            submit(.file(file.fileURL, origin: Self.checkedOrigin(of: file.fileURL, stored: file.origin, in: roots)), isRetry: true)
        }
        Log.engine.info("check again requested for unchecked=\(files.count)")
        return files.count
    }

    /// Loads the Journal's "Not checked" list into the status, once (G-13). `run()` starts with it, and every reader and
    /// writer of the list awaits it first, so a status read before `run()` already shows a relaunch's rows and no verdict
    /// can be overwritten by a stale row. A load that fails is tried again by the next reader.
    public func loadUnchecked() async {
        if uncheckedLoad == nil {
            uncheckedLoad = Task { [weak self] in await self?.performUncheckedLoad() }
        }
        await uncheckedLoad?.value
    }

    private func performUncheckedLoad() async {
        let records: [UncheckedRecord]
        let notCovered: [UncoveredRecord]
        do {
            records = try await journal.uncheckedFiles()
            notCovered = try await journal.uncoveredFiles()
        } catch {
            Log.engine.error("unchecked list load failed; retried on the next read")
            uncheckedLoad = nil
            return
        }
        for record in records where unchecked[.path(record.filePath)] == nil {
            unchecked[.path(record.filePath)] = UncheckedFile(record)
        }
        for record in notCovered where uncovered[record.filePath] == nil {
            uncovered[record.filePath] = UncoveredFile(record)
        }
        Log.engine.info("unchecked loaded count=\(records.count) notCovered=\(notCovered.count)")
    }

    // MARK: - Not covered on disk (fail-open #7)

    /// The covered picture could not be written to `target` (the caught file `source`, or its "(clean)" copy): the file
    /// still shows what was caught. Listed in the status first and then in the Journal, so a Journal that cannot be
    /// written still shows it for this run; it stays until a write there succeeds (never pruned by time).
    private func noteNotCovered(target: URL, source: URL, entryID: UUID?) async {
        await loadUnchecked()
        let path = target.path
        let previous = uncovered[path]
        let now = clock.now()
        let provisional = UncoveredFile(UncoveredRecord(id: previous?.id ?? UUID(), filePath: path, sourcePath: source.path, entryID: entryID,
                                                        firstSeen: previous?.record.firstSeen ?? now, lastSeen: now,
                                                        attempts: (previous?.attempts ?? 0) + 1))
        uncovered[path] = provisional
        do {
            let record = try await journal.recordUncovered(path: path, sourcePath: source.path, entryID: entryID)
            if uncovered[path] == provisional { uncovered[path] = UncoveredFile(record) }
        } catch {
            Log.engine.error("not covered on disk record failed; kept for this run only")
        }
        Log.engine.notice("not covered on disk listed attempts=\(provisional.attempts)")
    }

    /// A write to `path` succeeded, or a check of the caught file `path` reached a verdict: its rows go.
    private func settleNotCovered(path: String) async {
        await loadUnchecked()
        let keys = uncovered.filter { $0.value.record.filePath == path || $0.value.record.sourcePath == path }.map(\.key)
        for key in keys { uncovered.removeValue(forKey: key) }
        do { try await journal.clearUncovered(path: path) } catch { Log.engine.error("not covered on disk clear failed") }
    }

    /// The catch was undone on purpose: its file shows the original because the user asked for it.
    private func settleNotCovered(entryID: UUID) async {
        await loadUnchecked()
        let keys = uncovered.filter { $0.value.entryID == entryID }.map(\.key)
        for key in keys { uncovered.removeValue(forKey: key) }
        do { try await journal.clearUncovered(entryID: entryID) } catch { Log.engine.error("not covered on disk clear failed") }
    }

    /// "Try Again" on a file that still shows what was caught: the entry's covered picture is written there again, or,
    /// when the entry is gone (retention), the caught file is checked again and its verdict settles the row. Never
    /// writes a file outside the watched folders when it has to check again, and never re-creates a caught file that is
    /// gone.
    @discardableResult
    public func retryUncovered(_ file: UncoveredFile) async -> UncoveredRetry {
        await loadUnchecked()
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.sourceURL.path) else {
            Log.engine.notice("not covered on disk retry: the caught file is gone")
            return .fileMissing
        }
        let roots = watchedRoots()
        let origin = Self.origin(of: file.sourceURL, in: roots)
        if let id = file.entryID, let entry = try? await journal.entry(id), !entry.isTrashed {
            // The entry shows every finding now (an Undo or every finding left visible since): there is no covered
            // picture to write, and in keep-both mode a "(clean)" file must never receive the original (#17).
            guard !entry.enabledFindings.isEmpty else {
                await settleNotCovered(path: file.record.filePath)
                await publishStatus()
                return .written
            }
            // F26: the row's path is written only when it is the entry's own file, checked against the folders watched now.
            guard case .file(let target) = diskTarget(of: entry),
                  JournalTargets.checked(file.record.filePath, roots: watchedRoots()) == target else {
                Log.engine.notice("not covered on disk retry refused: the row does not name the entry's file in a watched folder")
                return .notWatched
            }
            do {
                let clean = try await journal.cleanData(id)
                try await writeBack(clean, to: target, onlyIfPresent: !file.isCleanCopy)
            } catch {
                await noteNotCovered(target: file.fileURL, source: file.sourceURL, entryID: id)
                await publishStatus()
                return .failed
            }
            await settleNotCovered(path: file.record.filePath)
            if let search {
                await search.caught(entryID: id, coveredFile: file.fileURL, findings: entry.findings, isScreenshot: origin == .screenshotFolder,
                                    titles: detectorTitles, switches: Self.searchSwitches(settings.current()))
            }
            Log.engine.info("not covered on disk retry wrote the covered picture")
            await publishStatus()
            return .written
        }
        // No entry to write from: the caught file is checked again as it first came in. A file no watched folder holds
        // any more would be checked as an import, which never writes the file, so it is not sent.
        guard origin != .imported else {
            Log.engine.notice("not covered on disk retry: the folder is not watched")
            return .notWatched
        }
        submit(.file(file.sourceURL, origin: origin), isRetry: true)
        return .checkingAgain
    }

    /// "Dismiss" on a file that still shows what was caught: the user knows; it leaves the list and the status.
    public func dismissUncovered(_ file: UncoveredFile) async {
        await loadUnchecked()
        uncovered.removeValue(forKey: file.record.filePath)
        recentFailures.removeAll { $0.key == CaptureKey(file: file.sourceURL) }
        do { try await journal.dismissUncovered(file.id) } catch JournalError.uncoveredNotFound {
            // Already settled meanwhile; the list now agrees.
        } catch {
            Log.engine.error("not covered on disk dismiss failed")
        }
        await publishStatus()
    }

    /// The undo of `dismissUncovered(_:)`.
    public func restoreUncovered(_ file: UncoveredFile) async {
        await loadUnchecked()
        uncovered[file.record.filePath] = file
        do { try await journal.restoreUncovered(file.record) } catch { Log.engine.error("not covered on disk restore failed") }
        await publishStatus()
    }

    /// "Dismiss" in the Journal's Not checked section: the file leaves the list (and the panel's count) without a check.
    public func dismissUnchecked(_ file: UncheckedFile) async {
        await loadUnchecked()
        unchecked.removeValue(forKey: file.key)
        // Its failure leaves the count with it: the user chose to stop hearing about this file.
        recentFailures.removeAll { $0.key == file.key }
        do { try await journal.dismissUnchecked(file.id) } catch JournalError.uncheckedNotFound {
            // Already gone from the Journal (a check landed meanwhile); the list now agrees.
        } catch {
            Log.engine.error("unchecked dismiss failed")
        }
        Log.engine.info("unchecked dismissed")
        await publishStatus()
    }

    /// The undo of `dismissUnchecked(_:)`: the file is listed again exactly as it was.
    public func restoreUnchecked(_ file: UncheckedFile) async {
        await loadUnchecked()
        unchecked[file.key] = file
        if let record = file.record {
            do { try await journal.restoreUnchecked(record) } catch { Log.engine.error("unchecked restore failed") }
        }
        await publishStatus()
    }

    /// F26: the origin a remembered file is checked again with. The Journal's row says where it came from, but any
    /// process can write that row, and the origin decides whether the file is written: an import stays an import (never
    /// written), anything else takes the origin of the folder watched now that holds it, or `.imported` when none does.
    static func checkedOrigin(of url: URL, stored: FileOrigin?, in roots: [WatchedRoot]) -> FileOrigin {
        if stored == .imported { return .imported }
        return origin(of: url, in: roots)
    }

    /// The origin a file in `roots` has: the deepest root that contains it, else `.imported`.
    static func origin(of url: URL, in roots: [WatchedRoot]) -> FileOrigin {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let containing = roots.filter { root in
            let base = root.url.resolvingSymlinksInPath().standardizedFileURL.path
            return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
        return containing.max { $0.url.path.count < $1.url.path.count }?.origin ?? .imported
    }

    private func finished(_ start: ScanStart, generation: UInt64, displayName: String, outcome: ScanOutcome, notes: ScanNotes,
                          spots: [SpotRecord]) async {
        let key = start.key
        if let current = inFlight[key], current.generation == generation { inFlight.removeValue(forKey: key) }
        await rememberVerdict(of: start, outcome: outcome, notes: notes, spots: spots)
        let report = ScanReport(key: key, displayName: displayName, outcome: outcome, fileURL: start.fileURL, origin: start.origin,
                                notes: notes, spots: spots)
        eventBroadcaster.send(.finished(report))
        outcomeBroadcaster.send(report)
        await publishStatus()
    }

    /// Keeps a file that ended without a verdict for "Check Again", in the status and in the Journal's `unchecked` table
    /// (G-13), and forgets it (and its failure) once a later scan of the same image reaches one. A cancelled scan (a newer
    /// one replaced it) leaves both as they are. A file that arrived while protection was paused is listed too, as
    /// "Not checked (paused)" (fail-open #21): while paused the status says Paused, and after the resume (by hand or when
    /// the pause runs out) the panel's "N images weren't checked" and the Journal's Not checked section list it with Check
    /// Again. The status changes first and the Journal follows, so a Journal that cannot be written still leaves the file
    /// listed for this run.
    private func rememberVerdict(of start: ScanStart, outcome: ScanOutcome, notes: ScanNotes, spots: [SpotRecord] = []) async {
        switch outcome {
        case .skipped(.cancelled):
            return
        case .clean, .redacted:
            // A picture covered from a partial read is not a verdict (#1): its failure stays counted.
            if !notes.contains(.partlyRead) && !notes.contains(.unreadSpots) { recentFailures.removeAll { $0.key == start.key } }
        default:
            break
        }
        guard let url = start.fileURL, let origin = start.origin, case .path(let path) = start.key else { return }
        await loadUnchecked()
        // Fail-open #7: a verdict on the caught file settles a "not covered on disk" row for it: clean means the file no
        // longer holds a secret, a catch of a watched file means the covered picture was just written (an import's catch
        // writes nothing, so it settles nothing).
        switch outcome {
        case .clean: await settleNotCovered(path: url.path)
        case .redacted where origin != .imported: await settleNotCovered(path: url.path)
        default: break
        }
        // G-40: a picture whose spots were all settled when it was checked (covered with route B, skipped with route D)
        // has a verdict, and its spots are kept as the record of how (a settled row, not listed).
        if Self.uncheckedReason(for: outcome, notes: notes) == nil, !spots.isEmpty {
            unchecked.removeValue(forKey: start.key)
            do {
                _ = try await journal.recordUnchecked(path: path, origin: UncheckedOrigin(origin), reason: .unreadPatch, spots: spots)
            } catch {
                Log.engine.error("settled spots record failed")
            }
            return
        }
        // A catch from a partly read picture (#1) is written, yet still listed "not checked".
        if let reason = Self.uncheckedReason(for: outcome, notes: notes) {
            let previous = unchecked[start.key]
            let now = clock.now()
            let kept = reason == .unreadPatch ? spots : []
            let provisional = UncheckedFile(id: previous?.id ?? UUID(), key: start.key, displayName: url.lastPathComponent, fileURL: url,
                                            origin: origin, reason: reason.rawValue, date: now, firstSeen: previous?.firstSeen ?? now,
                                            attempts: (previous?.attempts ?? 0) + 1, spots: kept)
            unchecked[start.key] = provisional
            do {
                let record = try await journal.recordUnchecked(path: path, origin: UncheckedOrigin(origin), reason: reason, spots: kept)
                // The Journal's row is the truth (its id, first sighting and count), unless a newer verdict replaced the
                // provisional one while the write ran. The origin stays the one this scan had.
                if unchecked[start.key] == provisional {
                    unchecked[start.key] = UncheckedFile(id: record.id, key: start.key, displayName: url.lastPathComponent, fileURL: url,
                                                         origin: origin, reason: record.reason.rawValue, date: record.lastSeen,
                                                         firstSeen: record.firstSeen, attempts: record.attempts, spots: record.spots)
                }
            } catch {
                Log.engine.error("unchecked record failed; kept for this run only")
            }
        } else if unchecked.removeValue(forKey: start.key) != nil {
            do { try await journal.clearUnchecked(path: path) } catch { Log.engine.error("unchecked clear failed") }
        }
    }

    /// The "Not checked" reason a file keeps after this outcome (G-13), or nil when the outcome is a verdict or needs no
    /// row: every outcome that leaves the picture as it was (`ScanOutcome.needsAttention`), including a picture that could
    /// not be opened or read and one too large to read (fail-open #2), so none of them ends quietly. A failed write-back
    /// is not one: its entry exists and the fix is Copy Clean.
    static func uncheckedReason(for outcome: ScanOutcome, notes: ScanNotes) -> UncheckedReason? {
        // Fail-open #1: covered from a partial read, so still "not checked", under the reason the read stopped for.
        if outcome.isRedacted, let partly = notes.partlyReadReason { return UncheckedReason(rawValue: partly.rawValue) }
        // G-40: covered where something was found, but a spot no reading could read waits for the person.
        if outcome.isRedacted, notes.contains(.unreadSpots) { return .unreadPatch }
        return uncheckedReason(for: outcome)
    }

    static func uncheckedReason(for outcome: ScanOutcome) -> UncheckedReason? {
        if case .failed(let error) = outcome {
            switch error {
            case .writeBack, .entryNotFound: return nil
            case .render, .encode, .journal, .ocr, .catalogue: break
            }
        }
        // Paused is the user's choice, so it raises no alert of its own, but the file still was not checked (#21).
        if case .skipped(.protectionPaused) = outcome { return .protectionPaused }
        guard outcome.needsAttention else { return nil }
        return UncheckedReason(rawValue: outcome.statLabel)
    }

    private func process(_ event: CaptureEvent, key: CaptureKey, isRetry: Bool) async -> (String, ScanOutcome, ScanNotes, [SpotRecord]) {
        var notes: ScanNotes = []
        var spots: [SpotRecord] = []
        switch event {
        case .file(let url, let origin):
            let name = url.lastPathComponent
            // The one quiet skip of a file: its extension is not an image's, so not a byte of it was read.
            guard PipelineConstants.imageExtensions.contains(url.pathExtension.lowercased()) else {
                return (name, await conclude(.skipped(.notAnImage), key: key), notes, spots)
            }
            // G-18: a new screenshot's final picture goes on the clipboard, so ⇧⌘4 then ⌘V pastes the clean one. Only the
            // screenshot folder, and never a Check Again (the user did not just take that screenshot). The clipboard's
            // generation now is the one that write may replace: anything copied during the check is kept (#18).
            let copies = origin == .screenshotFolder && !isRetry
            let generation = copies ? await clipboardGeneration() : nil
            let data: Data?
            do {
                if origin == .imported {
                    data = try await Pipeline.readFile(url, maxBytes: PipelineConstants.maxInputBytes)
                } else {
                    // F19: a watched file is checked again as it is read (not a link, a regular file, inside a watched
                    // folder), so a file swapped after the watcher accepted it never reads something else.
                    let roots = await folderWatcher?.currentRoots.map(\.url)
                    data = try await Pipeline.readWatchedFile(url, roots: roots, maxBytes: PipelineConstants.maxInputBytes)
                }
            } catch {
                // No permission, an I/O error, an iCloud file not downloaded, or it vanished: the file is as it was, so it
                // is "Not checked" (fail-open #2). The log names the error's domain and code only.
                let ns = error as NSError
                Log.engine.notice("file unreadable before decode domain=\(ns.domain, privacy: .public) code=\(ns.code)")
                return (name, await conclude(.skipped(.unreadable), key: key), notes, spots)
            }
            guard let data else { return (name, await conclude(.skipped(.tooLarge), key: key), notes, spots) }
            let source: EntrySource = origin == .imported ? .imported : .file
            let outcome = await scan(imageData: data, source: source, displayName: name, filePath: url, origin: origin,
                                     priority: .file, preservedText: nil, key: key, copiesToClipboard: copies,
                                     clipboardGeneration: generation, notes: &notes, spots: &spots)
            return (name, outcome, notes, spots)
        case .pasteboardImage(let data, _, let changeCount, let preservedText):
            let name = "Clipboard"
            guard settings.current().guardsClipboard else { return (name, await conclude(.skipped(.sourceOff), key: key), notes, spots) }
            // The covered picture replaces the copied one only while the clipboard still holds it (#18).
            let outcome = await scan(imageData: data, source: .clipboard, displayName: name, filePath: nil, origin: nil,
                                     priority: .clipboard, preservedText: preservedText, key: key, copiesToClipboard: false,
                                     clipboardGeneration: changeCount, notes: &notes, spots: &spots)
            return (name, outcome, notes, spots)
        case .pasteboardFiles(let urls, let changeCount, let preservedText):
            // A copied image file is checked like a copied image: its bytes are read, and a catch replaces the file
            // reference on the clipboard with the covered picture (#9). The file on disk is never written.
            let name = "Clipboard"
            guard settings.current().guardsClipboard else { return (name, await conclude(.skipped(.sourceOff), key: key), notes, spots) }
            guard urls.count == 1, let url = urls.first else {
                // One clipboard holds one covered picture; several copied files are left as they are, and said so.
                Log.engine.notice("clipboard holds image files=\(urls.count); not checked")
                return (name, await conclude(.skipped(.severalFiles), key: key), notes, spots)
            }
            // F6/F12 (G-35): any process can put a file reference on the clipboard. Only one inside a folder Obscura
            // already guards is opened (resolved, no link followed, the same file); anything else is never read.
            let data: Data
            switch CopiedFileRead.read(url, roots: watchedRoots(), maxBytes: PipelineConstants.maxInputBytes) {
            case .data(let bytes):
                data = bytes
            case .tooLarge:
                return (name, await conclude(.skipped(.tooLarge), key: key), notes, spots)
            case .notGuarded:
                Log.engine.notice("copied file is outside the guarded folders; not opened")
                return (name, await conclude(.skipped(.copiedFileNotGuarded), key: key), notes, spots)
            case .unreadable(let code):
                Log.engine.notice("copied file unreadable errno=\(code)")
                return (name, await conclude(.skipped(.unreadable), key: key), notes, spots)
            }
            let outcome = await scan(imageData: data, source: .clipboard, displayName: name, filePath: nil, origin: nil,
                                     priority: .clipboard, preservedText: preservedText, key: key, copiesToClipboard: false,
                                     clipboardGeneration: changeCount, notes: &notes, spots: &spots)
            return (name, outcome, notes, spots)
        }
    }

    /// The clipboard's generation, read on the main actor; nil without a clipboard guard (the CLI, most tests).
    private func clipboardGeneration() async -> Int? {
        guard let clipboardGuard else { return nil }
        return await MainActor.run { clipboardGuard.changeCount }
    }

    // MARK: - The pipeline

    /// The whole §4 pipeline for one image. Used by `run()`, imports, the demo and the CLI.
    /// With `filePath` and a non-imported `origin` the clean image is written back per `Settings.fileHandling`.
    public func scan(imageData: Data, source: EntrySource, displayName: String, filePath: URL?, origin: FileOrigin?) async -> ScanOutcome {
        var notes: ScanNotes = []
        var spots: [SpotRecord] = []
        return await scan(imageData: imageData, source: source, displayName: displayName, filePath: filePath, origin: origin,
                          priority: source == .clipboard ? .clipboard : .file, preservedText: nil, key: nil, copiesToClipboard: false,
                          clipboardGeneration: nil, notes: &notes, spots: &spots)
    }

    /// `key` names the image for failure tracking (nil for a one-shot call that has no capture key). `copiesToClipboard`:
    /// a new screenshot whose final picture goes on the clipboard once it has a verdict, when `copiesCleanImage` is on
    /// (G-18). A skip or a failure never reaches that point, so an unchecked original is never put there.
    /// `clipboardGeneration`: the pasteboard generation any clipboard write of this scan may replace (#18); `notes`
    /// collects what the notice must say besides the outcome; `spots` the G-40 spots no reading could read, each with how
    /// it stands (the Journal row keeps them).
    private func scan(imageData: Data, source: EntrySource, displayName: String, filePath: URL?, origin: FileOrigin?,
                      priority: OCRPriority, preservedText: String?, key: CaptureKey?, copiesToClipboard: Bool,
                      clipboardGeneration: Int?, notes: inout ScanNotes, spots: inout [SpotRecord]) async -> ScanOutcome {
        let started = ContinuousClock.now
        let current = settings.current()
        if paused || current.protectionPaused { return await conclude(.skipped(.protectionPaused), key: key) }
        if imageData.count > PipelineConstants.maxInputBytes { return await conclude(.skipped(.tooLarge), key: key) }

        // Row 5 — decode with orientation.
        let prepared: PreparedImage
        do {
            prepared = try await Pipeline.decode(imageData)
        } catch .unsupportedImage {
            return await conclude(.skipped(.unsupportedImage), key: key)
        } catch .incomplete {
            // Part-written or cut short: never judged on the part that is there (fail-open #5). The folder watcher hands
            // the file over again once it changes and is whole.
            return await conclude(.skipped(.incomplete), key: key)
        } catch .tooLarge {
            return await conclude(.skipped(.tooLarge), key: key)
        } catch {
            return await conclude(.skipped(.decodeFailed), key: key)
        }
        if prepared.pixels > PipelineConstants.maxRenderPixels { return await conclude(.skipped(.tooLarge), key: key) }
        if Task.isCancelled { return await conclude(.skipped(.cancelled), key: key) }

        // Row 6 — OCR through the serial queue, with the timeout; the recognizer downscales per the plan and
        // scales every rect back to full resolution (ObscuraOCR invariant 1).
        let options = OCROptions(timeout: .seconds(PipelineConstants.ocrDeadlineSeconds(current)),
                                 pixelBudget: max(1, current.ocrPixelBudget),
                                 maxLongestSide: PipelineConstants.ocrMaxLongestSide)
        let plan = DownscalePlan(width: prepared.width, height: prepared.height, options: options)
        guard let compiled = await currentCatalogue() else { return await conclude(.failed(.catalogue("no catalogue")), key: key) }
        let scanner = ObscuraDetect.Scanner(catalogue: compiled, allowRuleMode: current.allowRuleMode == .trim ? .trim : .containedOnly)
        if prepared.frameCount > 1 {
            return await checkEveryFrame(imageData, first: prepared, options: options, priority: priority, scanner: scanner,
                                         key: key, started: started)
        }
        let reading: RecallReading
        switch await recognize(prepared.image, options: options, priority: priority, scanner: scanner) {
        case .success(let result): reading = result
        case .failure(let outcome): return await conclude(outcome, key: key)
        }
        let lines = reading.lines
        if Task.isCancelled { return await conclude(.skipped(.cancelled), key: key) }

        // Rows 7–13 — reading order, fold, allow rules, detect, merge, block scope (inside Scanner), box mapping; both
        // readings when G-12 re-read anything (RecallPipeline).
        let detection = await Pipeline.detect(reading, image: prepared.image, scanner: scanner, titles: detectorTitles)
        if Task.isCancelled { return await conclude(.skipped(.cancelled), key: key) }

        // Fail-open #1: a re-read band that could not be read leaves part of the picture unread. Its lines are already
        // covered conservatively (RecallPipeline); the picture itself is never called checked. The same holds for lines
        // read but not searched to the end (security scan F9/F14/F23: too long, or over the regex budget).
        var unread = Self.unreadReason(reading.completeness) ?? Self.uncheckedReason(detection)

        // G-40: every unread part is a small spot no reading could read (and every read line was searched to the end).
        // D (opt-in) skips a spot too small to hold the shortest enabled secret; B (opt-in) covers the rest; any left
        // wait for the person, with no alarm. Anything else that went unread keeps the reason above and its alarm.
        var found: [UnreadSpot] = []
        var states: [SpotState] = []
        if detection.isComplete,
           let patch = UnreadSpots.patchCase(reading.completeness, imageSize: CGSize(width: prepared.width, height: prepared.height)) {
            found = patch
            let shortest = compiled.shortestSecretLength
            states = UnreadSpots.decide(patch, skipsTiny: current.skipsTinySpots, covers: current.coversUnreadableSpots, shortestSecret: shortest)
            unread = states.contains(.pending) ? .unreadPatch : nil
            if states.contains(.covered) { notes.insert(.spotsCovered) }
            if states.contains(.tooSmall) { notes.insert(.spotsSkipped) }
            let capacities = patch.map { String(UnreadSpots.capacity(of: $0)) }.joined(separator: ",")
            Log.engine.notice("unread spots=\(patch.count) pending=\(states.filter { $0 == .pending }.count) covered=\(states.filter { $0 == .covered }.count) skipped=\(states.filter { $0 == .tooSmall }.count) capacity=\(capacities, privacy: .public) shortest=\(shortest ?? 0)")
        }
        let spotCovers = zip(found, states).filter { $0.1 == .covered }.map(\.0)

        // Row 14 — short-circuit.
        if detection.findingCount == 0 && spotCovers.isEmpty {
            spots = zip(found, states).map { $0.record(state: $1) }
            if let unread {
                // Nothing found in what was read, but not all of it was read: "not checked", never clean, and not put on
                // the clipboard (G-18). G-40: a picture whose only unread parts are spots waiting for the person says so.
                if unread == .unreadPatch { notes.insert(.unreadSpots) }
                return await conclude(.skipped(unread), key: key)
            }
            // Nothing to cover: the file on disk is the final picture, unchanged.
            if copiesToClipboard && current.copiesCleanImage {
                await putOnClipboard(prepared.image, dpi: prepared.dpi, generation: clipboardGeneration, notes: &notes)
            }
            let duration = ContinuousClock.now - started
            await record(.clean)
            Log.engine.info("clean lines=\(lines.count) rereads=\(reading.rereads.count) skipped-spots=\(found.count) downscaled=\(!plan.isIdentity) ms=\(duration / .milliseconds(1), format: .fixed(precision: 0))")
            return .clean(duration: duration)
        }

        // G-40 route B: each covered spot is one more cover, over its padded rect, labelled as an unreadable spot.
        let mapped = detection.areas.map {
            MappedFinding(placed: $0.placed, lineIndex: $0.lineIndex, detectorIDs: $0.detectorIDs, category: $0.category)
        } + spotCovers.map {
            MappedFinding(placed: PlacedFinding(rect: $0.coverRect, textHeight: $0.rect.height, label: UnreadSpot.title, id: UUID()),
                          lineIndex: -1, detectorIDs: [UnreadSpot.detectorID], category: UnreadSpot.category)
        }
        let secretCount = mapped.count - spotCovers.count
        if mapped.isEmpty {
            // Findings whose rect fell outside the image: nothing to paint, but the user must still know.
            Log.engine.error("findings=\(detection.findingCount) mapped to no paintable rect")
            return await conclude(.failed(.render("no paintable rect for \(detection.findingCount) finding(s)")), key: key)
        }

        // Rows 15–18 — render with the Journal's default style.
        let styleRecord: StyleRecord
        do { styleRecord = try await journal.defaultStyle() } catch { return await conclude(.failed(.journal(String(describing: error))), key: key) }
        let style = StyleBridge.spec(from: styleRecord)
        let rendered: CGImage
        do { rendered = try await Pipeline.render(prepared, findings: mapped.map(\.placed), style: style, redactedWord: redactedWord) }
        catch { return await conclude(.failed(error), key: key) }
        if Task.isCancelled { return await conclude(.skipped(.cancelled), key: key) }

        // Row 19 — encode preserving the container.
        let clean: Data
        do { clean = try await Pipeline.encode(rendered, like: prepared) } catch { return await conclude(.failed(error), key: key) }

        // Row 20 (part) — decide the write-back target before the Journal row so the row can name it.
        let handling = current.fileHandling
        let writesFile = filePath != nil && origin != nil && origin != .imported
        let cleanCopyPath: URL? = (writesFile && handling == .keepBoth) ? filePath.map { Self.cleanSibling(of: $0, output: prepared.outputUTI) } : nil

        // Row 21 — Journal.
        let newFindings = mapped.map {
            NewFinding(lineIndex: $0.lineIndex, rect: $0.placed.rect, detectorIDs: $0.detectorIDs, category: $0.category)
        }
        let entry: Entry
        do {
            entry = try await journal.create(
                NewEntry(source: source, displayName: displayName, filePath: filePath?.path, cleanCopyPath: cleanCopyPath?.path,
                         containerUTI: prepared.outputUTI.identifier, pixelWidth: prepared.width, pixelHeight: prepared.height,
                         findings: newFindings),
                original: imageData, clean: clean)
        } catch {
            return await conclude(.failed(.journal(String(describing: error))), key: key)
        }

        // Row 20 — write-back. A cancellation after this point no longer applies: the entry exists, the file must follow.
        if source == .clipboard {
            if let clipboardGuard {
                do {
                    let png = try await Pipeline.encodePNG(rendered, dpi: prepared.dpi)
                    let tiff = try await Pipeline.encodeTIFF(rendered)
                    // The plain text copied with the image (a spreadsheet's cells, a terminal's lines) goes back only when
                    // the Scanner finds nothing in it; otherwise it is left out and the notice says so (#8).
                    // Checked off this actor (security scan F9): however long the text, the engine keeps serving
                    // other scans and status while it is searched, and a text that cannot be checked in full is left
                    // out as if it held a secret.
                    var keptText = preservedText
                    if let text = preservedText {
                        switch await Self.checkCompanionText(text, scanner: scanner) {
                        case .heldFindings(let found):
                            keptText = nil
                            notes.insert(.companionTextRemoved)
                            Log.engine.notice("companion text held findings=\(found); left out of the write-back")
                        case .notChecked:
                            keptText = nil
                            notes.insert(.companionTextNotChecked)
                            Log.engine.notice("companion text not checked in full (length=\(text.utf16.count)); left out of the write-back")
                        case .empty, .clean:
                            break
                        }
                    }
                    // Compare-and-swap (#18): only while the clipboard still holds the copied image. Otherwise the user
                    // copied something since; that newer copy stays, the catch is in the Journal, and the notice says so.
                    let written = await MainActor.run {
                        clipboardGuard.writeBack(png: png, tiff: tiff, preservedText: keptText, expectedChangeCount: clipboardGeneration)
                    }
                    if !written {
                        notes.insert(.clipboardChangedMeanwhile)
                        Log.engine.notice("clipboard changed during the check; the newer copy was kept")
                    }
                } catch {
                    return await conclude(.failed(error), key: key)
                }
            }
        } else if writesFile, let filePath {
            do {
                switch handling {
                case .replace:
                    await folderWatcher?.ignore(filePath, for: PipelineConstants.ignoredPathTTL)
                    try FileAtomics.replace(contentsOf: filePath, with: clean)
                    await folderWatcher?.adoptOwnWrite(filePath)
                case .keepBoth:
                    if let cleanCopyPath {
                        await folderWatcher?.ignore(cleanCopyPath, for: PipelineConstants.ignoredPathTTL)
                        try FileAtomics.write(clean, to: cleanCopyPath, mode: .default)
                        await folderWatcher?.adoptOwnWrite(cleanCopyPath)
                    }
                }
            } catch {
                // Fail-open #7: the file still shows what was caught; listed until a write there succeeds.
                await noteNotCovered(target: cleanCopyPath ?? filePath, source: filePath, entryID: entry.id)
                return await conclude(.failed(.writeBack(String(describing: error))), key: key)
            }
        }
        // G-18: the covered picture now on disk (the replaced file, or the clean copy beside it) goes on the clipboard,
        // unless part of it went unread (#1): a picture that is not checked is never put there.
        if copiesToClipboard && current.copiesCleanImage && unread == nil {
            await putOnClipboard(rendered, dpi: prepared.dpi, generation: clipboardGeneration, notes: &notes)
        }
        if unread == .unreadPatch {
            // G-40: covered where something was found; a spot no reading could read waits for the person. Listed (its file's
            // row, from the notes) with no alarm; a clipboard image has no row, so it is counted in the status.
            notes.insert(.unreadSpots)
            if filePath == nil { recentSpotImages.append((key: key, date: clock.now())) }
        } else if let unread {
            // Covered where it could be, but not checked: listed (its file's row, from the notes), counted in the status
            // (a clipboard image has no row) and announced.
            notes.insert(.partlyRead)
            if unread == .ocrTimeout { notes.insert(.partlyReadTimedOut) }
            if unread == .textNotRead { notes.insert(.partlyReadNoText) }
            recentFailures.append((key: key, date: clock.now()))
        }
        // G-40: every spot is recorded with the entry the picture is in; a covered one with its cover's finding.
        if !found.isEmpty {
            var covers = entry.findings.filter(\.isSpotCover)
            spots = zip(found, states).map { spot, state in
                guard state == .covered, let i = covers.firstIndex(where: { $0.rect == spot.coverRect }) else {
                    return spot.record(state: state == .covered ? .pending : state, entryID: entry.id)
                }
                return spot.record(state: .covered, entryID: entry.id, findingID: covers.remove(at: i).id)
            }
        }

        // Row 22 — counts and status. A spot's cover is not a secret: it is not counted as one.
        var categories: [String: Int] = [:]
        for f in mapped where !SpotRecord.isCoverDetector(f.detectorIDs) { categories[f.category, default: 0] += 1 }
        if secretCount > 0 { await record(.caught(secrets: secretCount, categories: categories)) } else { await record(.clean) }
        lastCatch = LastCatch(entryID: entry.id, displayName: displayName, findings: mapped.count, date: clock.now())
        let duration = ContinuousClock.now - started
        Log.engine.info("redacted findings=\(secretCount) spot-covers=\(spotCovers.count) lines=\(lines.count) short-reads=\(detection.shortReads) conservative=\(detection.conservativeAreas) unverified=\(detection.unverifiedAreas) unread-bands=\(reading.completeness.incomplete.count) ms=\(duration / .milliseconds(1), format: .fixed(precision: 0))")
        // G-24: last, after the clipboard and the counts, so labelling never delays the covered picture: the covered
        // file on disk (the replaced file, or the clean copy beside it) gets its Spotlight entry and tags. Awaited, not
        // detached, so an Undo that follows always finds the record it must take the labels off.
        if writesFile, let search, let covered = cleanCopyPath ?? filePath {
            await search.caught(entryID: entry.id, coveredFile: covered, findings: entry.findings, isScreenshot: origin == .screenshotFolder,
                                titles: detectorTitles, switches: Self.searchSwitches(current))
        }
        return .redacted(entryID: entry.id, findings: mapped.count, duration: duration)
    }

    /// What the plain text copied beside an image holds.
    enum CompanionText: Equatable {
        case empty
        case clean
        case heldFindings(Int)
        /// Longer than `PipelineConstants.maxCompanionTextLength`, a line longer than the Scanner reads, or a search
        /// stopped by the regex budget or a cancelled scan: not known to be clean, so treated as holding a secret.
        case notChecked
    }

    /// The Scanner's verdict on the plain text copied beside an image, one line per line of text, with the catalogue the
    /// image was checked with (no OCR: the text is exact). Runs off the engine actor (`@concurrent`), under the
    /// Scanner's limits, and never reads more than `PipelineConstants.maxCompanionTextLength` (security scan F9).
    ///
    /// The text is dropped, not covered, when it holds any finding or is not checked in full (#8): the covered picture
    /// is what the guard puts back, a masked text would be a made-up representation pasted into text fields as if it
    /// were the user's own, and a mask that missed part of a secret's range would paste the rest.
    @concurrent
    static func checkCompanionText(_ text: String, scanner: ObscuraDetect.Scanner) async -> CompanionText {
        guard !text.isEmpty else { return .empty }
        guard text.utf16.count <= PipelineConstants.maxCompanionTextLength else { return .notChecked }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .enumerated().map { ScanLine(index: $0.offset, text: String($0.element)) }
        let result = scanner.check(lines)
        if !result.findings.isEmpty { return .heldFindings(result.findings.count) }
        return result.isComplete ? .clean : .notChecked
    }

    /// A picture with several frames (an animated GIF or PNG, a multi-page TIFF, an HEIF sequence), fail-open #6. Every
    /// frame is read, never frame 0 alone: no finding on any frame is a true clean verdict. A covered copy is not made:
    /// the Journal, the viewer, Undo and the encoder hold one frame per entry, so a finding on any frame (or more frames
    /// than `maxCheckedFrames`) ends "not checked" (`multiFrame`) with a notice, and the file is left as it is rather than
    /// flattened to one frame. Nothing goes on the clipboard either way (G-18 would put one frame there).
    private func checkEveryFrame(_ imageData: Data, first: PreparedImage, options: OCROptions, priority: OCRPriority,
                                 scanner: ObscuraDetect.Scanner, key: CaptureKey?, started: ContinuousClock.Instant) async -> ScanOutcome {
        let frames = first.frameCount
        guard frames <= PipelineConstants.maxCheckedFrames else {
            Log.engine.notice("multi-frame image frames=\(frames) over the frame limit; not checked")
            return await conclude(.skipped(.multiFrame), key: key)
        }
        for index in 0..<frames {
            let frame: PreparedImage
            if index == 0 {
                frame = first
            } else {
                do { frame = try await Pipeline.decode(imageData, frame: index) } catch .incomplete {
                    return await conclude(.skipped(.incomplete), key: key)
                } catch .tooLarge {
                    return await conclude(.skipped(.tooLarge), key: key)
                } catch {
                    return await conclude(.skipped(.decodeFailed), key: key)
                }
            }
            if frame.pixels > PipelineConstants.maxRenderPixels { return await conclude(.skipped(.tooLarge), key: key) }
            if Task.isCancelled { return await conclude(.skipped(.cancelled), key: key) }
            let reading: RecallReading
            switch await recognize(frame.image, options: options, priority: priority, scanner: scanner) {
            case .success(let result): reading = result
            case .failure(let outcome): return await conclude(outcome, key: key)
            }
            if Task.isCancelled { return await conclude(.skipped(.cancelled), key: key) }
            let detection = await Pipeline.detect(reading, image: frame.image, scanner: scanner, titles: detectorTitles)
            if detection.findingCount > 0 {
                Log.engine.notice("multi-frame image frames=\(frames) findings=\(detection.findingCount) on frame=\(index); not covered, not checked")
                return await conclude(.skipped(.multiFrame), key: key)
            }
            // A frame part of which could not be read, or searched, is not checked, so neither is the picture (#1).
            if let unread = Self.unreadReason(reading.completeness) ?? Self.uncheckedReason(detection) {
                return await conclude(.skipped(unread), key: key)
            }
        }
        let duration = ContinuousClock.now - started
        await record(.clean)
        Log.engine.info("clean multi-frame frames=\(frames) ms=\(duration / .milliseconds(1), format: .fixed(precision: 0))")
        return .clean(duration: duration)
    }

    /// Puts a checked screenshot's final picture on the clipboard as the guard's own write (PNG + TIFF, as
    /// `copyToClipboard` does), so the guard does not catch and check it again (G-18). Without a guard (the CLI, tests
    /// that pass none) there is no clipboard to write. The verdict already stands, so a picture that will not encode is
    /// logged and left off the clipboard rather than turning the scan into a failure. `generation`: the clipboard
    /// generation when the check started; anything copied since is kept (#18) and the notes say so.
    private func putOnClipboard(_ image: CGImage, dpi: CGSize?, generation: Int?, notes: inout ScanNotes) async {
        guard let clipboardGuard else { return }
        do {
            let png = try await Pipeline.encodePNG(image, dpi: dpi)
            let tiff = try await Pipeline.encodeTIFF(image)
            let written = await MainActor.run {
                clipboardGuard.writeBack(png: png, tiff: tiff, preservedText: nil, expectedChangeCount: generation)
            }
            guard written else {
                notes.insert(.clipboardChangedMeanwhile)
                Log.engine.notice("screenshot not copied: the clipboard changed during the check; the newer copy was kept")
                return
            }
            Log.engine.info("screenshot copied to the clipboard bytes=\(png.count)")
        } catch {
            Log.engine.error("screenshot not copied to the clipboard: encode failed")
        }
    }

    /// Fail-open #1: the reason a picture part of which went unread is "not checked" under: `ocrTimeout` when every
    /// unread band ran out of time; `textNotRead` when Vision answered every call for it with no text (every gap `empty`:
    /// G-40's true wording, no reading failed); else `ocrFailed`. Nil when the re-read read every band it planned. The
    /// small-spot case (`UnreadSpots.patchCase`) is decided after this, by the caller. Counts in the log.
    static func unreadReason(_ completeness: ReadCompleteness) -> SkipReason? {
        guard let timedOut = completeness.timedOut else { return nil }
        // Vision answered: every gap is `empty`, and every last attempt made was answered and none was cut by the deadline.
        let allEmpty = completeness.incomplete.allSatisfy { band in
            band.gaps == [.empty] && completeness.lastAttempts.filter { $0.band == band.band }
                .allSatisfy { $0.answered == $0.calls && !$0.skippedForDeadline }
        }
        let reason: SkipReason = timedOut ? .ocrTimeout : (allEmpty ? .textNotRead : .ocrFailed)
        // The gaps say why: `empty` means Vision answered every call and read no text there (G-40), not that it failed.
        let gaps = Set(completeness.incomplete.flatMap(\.gaps)).sorted().map(\.rawValue).joined(separator: ",")
        Log.engine.notice("picture partly read: bands unread=\(completeness.incomplete.count) of \(completeness.planned) with-lines=\(completeness.incomplete.filter(\.hasLines).count) gaps=\(gaps, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        return reason
    }

    /// Security scan F9/F14/F23: the reason a picture whose read lines were not all searched to the end is "not
    /// checked" under, nil when every line was. The Scanner stops a line that is too long or whose regex work runs past
    /// its budget (a hostile line, a too-slow rule): the check took too long and was stopped, so `ocrTimeout`, the
    /// reason the Journal, the notice and Check Again already know. What was found is covered either way.
    static func uncheckedReason(_ detection: ImageDetection) -> SkipReason? {
        guard !detection.isComplete else { return nil }
        Log.engine.notice("picture partly searched: lines unchecked=\(detection.uncheckedLines) reason=ocrTimeout")
        return .ocrTimeout
    }

    /// OCR through the serial queue (which owns the deadline). `queueFull` is re-submitted once.
    private enum OCRStep { case success(RecallReading); case failure(ScanOutcome) }

    private func recognize(_ image: CGImage, options: OCROptions, priority: OCRPriority, scanner: ObscuraDetect.Scanner) async -> OCRStep {
        var attempts = 0
        while true {
            do {
                // The queue applies the deadline from the moment this image's recognition starts (OCRQueue).
                return .success(try await RecallPipeline.read(image, options: options, queue: ocrQueue, priority: priority, scanner: scanner))
            } catch OCRError.timeout {
                return .failure(.skipped(.ocrTimeout))
            } catch OCRError.cancelled {
                return .failure(.skipped(.cancelled))
            } catch is CancellationError {
                return .failure(.skipped(.cancelled))
            } catch OCRError.badImage {
                return .failure(.skipped(.decodeFailed))
            } catch OCRError.queueFull {
                attempts += 1
                if attempts > PipelineConstants.queueFullRetries { return .failure(.skipped(.queueFull)) }
                Log.engine.notice("ocr queue full, re-submitting attempt=\(attempts)")
            } catch {
                return .failure(.skipped(.ocrFailed))
            }
        }
    }

    /// Logs a non-success outcome with its reason, records the stat and tracks failures for the status. A skip that left
    /// the image as it was (`needsAttention`: a timeout, an OCR failure, a picture that could not be opened or read, one
    /// too large) is tracked like a failure, so one with no file to list (a clipboard image) still counts in the status
    /// (fail-open #13); one with a file is counted once, by its "Not checked" row.
    private func conclude(_ outcome: ScanOutcome, key: CaptureKey?) async -> ScanOutcome {
        switch outcome {
        case .skipped(let reason):
            Log.engine.notice("skipped reason=\(reason.rawValue, privacy: .public)")
            await record(.skipped(reason: reason.rawValue))
            if reason == .unreadPatch {
                // G-40: no alarm. A file is listed by its row; a copied image (no row) is counted as a spot to look at.
                if case .pasteboard = key { recentSpotImages.append((key: key, date: clock.now())) }
            } else if outcome.needsAttention {
                recentFailures.append((key: key, date: clock.now()))
            }
        case .failed(let error):
            Log.engine.error("failed reason=\(error.statLabel, privacy: .public)")
            await record(.skipped(reason: error.statLabel))
            recentFailures.append((key: key, date: clock.now()))
        case .clean, .redacted:
            break
        }
        return outcome
    }

    private func record(_ stat: StatEvent) async {
        do { try await journal.record(stat: stat) } catch {
            Log.engine.error("stat record failed")
        }
    }

    static func cleanSibling(of url: URL, output: UTType) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let original = url.pathExtension
        let keeps = !original.isEmpty && (UTType(filenameExtension: original)?.conforms(to: output) ?? false)
        let ext = keeps ? original : (output.preferredFilenameExtension ?? "png")
        return url.deletingLastPathComponent().appendingPathComponent("\(stem) (clean).\(ext)")
    }

    // MARK: - Journal-driven operations

    /// Re-renders the entry's enabled findings over its original and commits the picture (G-28). With `style` the entry
    /// gets that style as its own row, in the same commit. The on-disk file follows when it still exists.
    public func rerender(_ entryID: UUID, style: StyleSpec?) async throws {
        let entry = try await applyPicture(entryID, style: style) { Set($0.enabledFindings.map(\.id)) }
        Log.engine.info("re-rendered findings=\(entry.enabledFindings.count)")
    }

    /// Undo: every finding becomes visible, the entry's current image is the original again, and the original goes back
    /// where the clean image went (the clean copy for keepBoth, else the file itself; the clipboard for a clipboard catch).
    /// Afterwards the verdict is "Original showing" and `blackOutAll` reverses it exactly.
    public func restoreOriginal(_ entryID: UUID) async throws {
        let (entry, original) = try await commitPicture(entryID, style: nil) { _ in [] }
        // The file shows the original because the user asked: it is no longer "not covered on disk" (#7).
        await settleNotCovered(entryID: entryID)
        try await deliver(original, for: entry)
        await searchEntryChanged(entryID)
        // G-40: a spot this entry covered is uncovered again: it waits for the person.
        await syncSpots(entryID: entryID)
        Log.engine.info("restored original findings=\(entry.findings.count)")
        await publishStatus()
    }

    /// Redo: every finding is covered again; the picture is rendered first and committed with the flags (G-28), then
    /// delivered where the original went. A render that fails leaves the entry as it was ("Original showing").
    public func blackOutAll(_ entryID: UUID) async throws {
        let entry = try await applyPicture(entryID, style: nil) { Set($0.findings.map(\.id)) }
        if diskTarget(of: entry) == .none {
            try await deliver(try await journal.cleanData(entryID), for: entry)
        }
    }

    /// Toggles one finding: the picture is rendered with the finding covered or visible first, then committed with the
    /// flag (G-28).
    public func setFinding(_ id: UUID, enabled: Bool, in entryID: UUID) async throws {
        try await applyPicture(entryID, style: nil) { entry in
            guard entry.findings.contains(where: { $0.id == id }) else { throw EngineError.journal("no finding \(id.uuidString)") }
            var covered = Set(entry.enabledFindings.map(\.id))
            if enabled { covered.insert(id) } else { covered.remove(id) }
            return covered
        }
    }

    /// Commits the picture `change` asks for (G-28), then writes it to the entry's file and updates its search labels.
    @discardableResult
    private func applyPicture(_ entryID: UUID, style: StyleSpec?, change: (Entry) throws -> Set<UUID>) async throws -> Entry {
        let (entry, clean) = try await commitPicture(entryID, style: style, change: change)
        try await writeBackCovered(clean, for: entry, covers: !entry.enabledFindings.isEmpty, onlyIfPresent: true)
        // A keep-both copy re-created after an Undo had its search record retired with it (it went to the Trash): it is
        // labelled again as a new catch of that file (G-24).
        if let copy = entry.cleanCopyPath, !entry.enabledFindings.isEmpty, let search, FileManager.default.fileExists(atPath: copy),
           (try? await journal.coveredFile(entryID)) == nil {
            let isScreenshot = entry.filePath.map {
                Self.origin(of: URL(fileURLWithPath: $0), in: watchedRoots()) == .screenshotFolder
            } ?? false
            await search.caught(entryID: entryID, coveredFile: URL(fileURLWithPath: copy), findings: entry.findings, isScreenshot: isScreenshot,
                                titles: detectorTitles, switches: Self.searchSwitches(settings.current()))
        } else {
            await searchEntryChanged(entryID)
        }
        // G-40: a spot whose cover is one of this entry's findings follows it.
        await syncSpots(entryID: entryID)
        await publishStatus()
        return entry
    }

    /// Renders the entry's picture with exactly the findings `change` picks from its current state covered (and `style`),
    /// then commits picture, flags and style in one Journal call at the revision it started from (G-28, fail-open #4).
    /// Nothing is committed before the picture exists, so a render or encode that fails leaves the Journal exactly as it
    /// was: the flags never claim a cover the clean picture does not have. Another change that landed meanwhile (a
    /// second toggle) is a revision conflict: `change` is applied again on top of it. With nothing covered, the picture
    /// is the original itself.
    private func commitPicture(_ entryID: UUID, style: StyleSpec?, change: (Entry) throws -> Set<UUID>) async throws -> (Entry, Data) {
        for attempt in 1...PipelineConstants.pictureCommitAttempts {
            let entry: Entry
            do { entry = try await journal.entry(entryID) } catch { throw EngineError.entryNotFound(entryID) }
            let covered = try change(entry)
            let original: Data
            do { original = try await journal.originalData(entryID) } catch { throw EngineError.journal(String(describing: error)) }
            let clean = covered.isEmpty ? original : try await renderPicture(original, entry: entry, covered: covered, style: style)
            do {
                let committed = try await journal.commitRender(entryID, clean: clean, enabled: covered,
                                                               style: style.map { StyleBridge.record(from: $0) }, expectedRevision: entry.revision)
                return (committed, clean)
            } catch JournalError.revisionConflict {
                Log.engine.notice("picture change raced another; applying it again attempt=\(attempt)")
            } catch {
                throw EngineError.journal(String(describing: error))
            }
        }
        throw EngineError.journal("the entry kept changing")
    }

    /// The entry's original with `covered` findings covered in `style` (else its own), encoded like the original.
    private func renderPicture(_ original: Data, entry: Entry, covered: Set<UUID>, style: StyleSpec?) async throws -> Data {
        if let renderFault { throw renderFault }
        let prepared: PreparedImage
        do { prepared = try await Pipeline.decode(original) } catch { throw EngineError.render("original does not decode") }
        let spec = style ?? StyleBridge.spec(from: entry.style)
        let rendered = try await Pipeline.render(prepared, findings: placedFindings(entry, covered: covered), style: spec, redactedWord: redactedWord)
        return try await Pipeline.encode(rendered, like: prepared)
    }

    /// The entry's `covered` findings as the renderer draws them; each label comes from `CoverLabels` (scan F4/F5/F7).
    func placedFindings(_ entry: Entry, covered: Set<UUID>) -> [PlacedFinding] {
        entry.findings.filter { covered.contains($0.id) }.map {
            PlacedFinding(rect: $0.rect, textHeight: $0.rect.height, label: CoverLabels.label(for: $0.detectorIDs, titles: detectorTitles), id: $0.id)
        }
    }

    /// Tests: the label every finding of `entry` gets when it is drawn again (the re-render path).
    func coverLabels(for entry: Entry) -> [String] {
        placedFindings(entry, covered: Set(entry.findings.map(\.id))).map(\.label)
    }

    /// Tests: every re-render fails with this error (G-28's render-failure proofs).
    private var renderFault: EngineError?
    func setRenderFault(_ fault: EngineError?) { renderFault = fault }

    /// Entries whose clean picture is not trusted (from before schema 6, or a file that no longer matches its row) are
    /// rendered again from their original and their flags (G-28). When the entry covers something and the file on disk
    /// still holds the original, that file is listed as not covered on disk (#7) rather than silently rewritten.
    func repairCleanPictures() async {
        let ids: [UUID]
        do { ids = try await journal.entriesNeedingRender() } catch {
            Log.engine.error("clean picture check failed")
            return
        }
        guard !ids.isEmpty else { return }
        var repaired = 0
        for id in ids {
            do {
                let (entry, _) = try await commitPicture(id, style: nil) { Set($0.enabledFindings.map(\.id)) }
                repaired += 1
                guard !entry.enabledFindings.isEmpty, case .file(let target) = diskTarget(of: entry), let source = entry.filePath,
                      let onDisk = try? Data(contentsOf: target), let original = try? await journal.originalData(id), onDisk == original
                else { continue }
                await noteNotCovered(target: target, source: URL(fileURLWithPath: source), entryID: id)
            } catch {
                Log.engine.error("clean picture repair failed entry=\(id.uuidString, privacy: .public)")
            }
        }
        Log.engine.info("clean pictures re-rendered=\(repaired) of \(ids.count)")
    }

    /// Copies an entry's current image (or its original) to the clipboard as the app's own write, so the clipboard
    /// guard does not catch and redact it again. Without a guard (the CLI, tests) it writes the pasteboard directly.
    /// The clean image comes with its flags from one Journal read (G-28): the returned entry says what the copied
    /// picture covers, so a caller never calls a picture with visible findings "clean".
    @discardableResult
    public func copyToClipboard(_ entryID: UUID, original: Bool) async throws -> Entry {
        let entry: Entry, data: Data
        if original {
            do { entry = try await journal.entry(entryID) } catch { throw EngineError.entryNotFound(entryID) }
            data = try await journal.originalData(entryID)
        } else {
            let image = try await journal.cleanImage(entryID)
            (entry, data) = (image.entry, image.data)
        }
        let prepared: PreparedImage
        do { prepared = try await Pipeline.decode(data) } catch { throw EngineError.writeBack("image does not decode") }
        let png = try await Pipeline.encodePNG(prepared.image, dpi: prepared.dpi)
        let tiff = try await Pipeline.encodeTIFF(prepared.image)
        if let clipboardGuard {
            await MainActor.run { _ = clipboardGuard.writeBack(png: png, tiff: tiff, preservedText: nil) }
        } else {
            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(png, forType: .png)
                pb.setData(tiff, forType: .tiff)
            }
        }
        return entry
    }

    /// The text of a finding left visible, read again from the entry's original in memory (G-17, option A): the area
    /// around the finding's rect is enlarged on one re-read sheet (`RereadSheet`, as the G-12 recall pass draws it),
    /// read through the OCR queue's turn and the recall reader, and the detector catalogue picks the detector's secret
    /// part (`KeyText.pick`); without a detector match it is the raw text read inside the rect.
    ///
    /// Nothing is stored or logged: no Journal write, no file, no cache; the log line carries ids, the rect and counts.
    /// It refuses (`KeyTextError`) unless Settings' `showsUncoveredKeyText` is on and the finding is uncovered, so a view
    /// cannot read a covered key by mistake. The request goes ahead of queued file scans (`.clipboard` priority):
    /// someone is waiting on it.
    public func readText(of findingID: UUID, in entryID: UUID) async throws -> String {
        let current = settings.current()
        guard current.showsUncoveredKeyText else { throw KeyTextError.switchedOff }
        let entry: Entry
        do { entry = try await journal.entry(entryID) } catch { throw KeyTextError.entryNotFound(entryID) }
        guard let finding = entry.findings.first(where: { $0.id == findingID }) else { throw KeyTextError.findingNotFound(findingID) }
        guard !finding.enabled else { throw KeyTextError.covered }
        // G-40: a spot's cover marks a spot no reading could read; there is no key text to read there.
        guard !finding.isSpotCover else { throw KeyTextError.nothingRead }
        let original: Data
        do { original = try await journal.originalData(entryID) } catch { throw KeyTextError.originalUnavailable }
        let prepared: PreparedImage
        do { prepared = try await Pipeline.decode(original) } catch { throw KeyTextError.originalUnavailable }
        guard let compiled = await currentCatalogue() else { throw KeyTextError.readFailed }

        let started = ContinuousClock.now
        let tuning = RecallTuning()
        guard let strip = KeyText.strip(around: finding.rect, imageSize: CGSize(width: prepared.width, height: prepared.height), tuning: tuning),
              let layout = RereadSheet.layout([strip], maxSide: tuning.sheetMaxSide).first, let slot = layout.slots.first
        else { throw KeyTextError.nothingRead }
        let sheet: CGImage
        do { sheet = try RereadSheet.render(prepared.image, layout: layout, strips: [strip]) } catch { throw KeyTextError.readFailed }

        let scanner = ObscuraDetect.Scanner(catalogue: compiled, allowRuleMode: current.allowRuleMode == .trim ? .trim : .containedOnly)
        // The sheet is read at its own size: it is already the scale the recall pass reads at.
        let options = OCROptions(timeout: .seconds(PipelineConstants.ocrDeadlineSeconds(current)),
                                 pixelBudget: max(current.ocrPixelBudget, sheet.width * sheet.height + 1),
                                 maxLongestSide: max(PipelineConstants.ocrMaxLongestSide, max(sheet.width, sheet.height) + 1),
                                 languages: tuning.rereadLanguages)
        let reading: RecallReading
        do {
            reading = try await RecallPipeline.read(sheet, options: options, queue: ocrQueue, priority: .clipboard, scanner: scanner, tuning: tuning)
        } catch OCRError.timeout {
            throw KeyTextError.timedOut
        } catch OCRError.queueFull {
            throw KeyTextError.timedOut
        } catch OCRError.cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw KeyTextError.readFailed
        }
        let target = KeyText.onSheet(finding.rect, strip: strip, slot: slot.rect)
        let pick = KeyText.pick(reading, image: sheet, target: target, detectorIDs: finding.detectorIDs, scanner: scanner)
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        let r = finding.rect
        guard let pick else {
            Log.engine.notice("key text read nothing finding=\(findingID.uuidString, privacy: .public) rect=\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width))x\(Int(r.height)) lines=\(reading.lines.count) ms=\(ms)")
            throw KeyTextError.nothingRead
        }
        Log.engine.info("key text read finding=\(findingID.uuidString, privacy: .public) rect=\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width))x\(Int(r.height)) detector=\(pick.detectorID ?? "raw", privacy: .public) lines=\(reading.lines.count) rereads=\(reading.rereads.count) ms=\(ms)")
        return pick.text
    }

    /// Puts `data` where this entry's image lives: its disk target, or the clipboard for a clipboard catch.
    private func deliver(_ data: Data, for entry: Entry) async throws {
        switch diskTarget(of: entry) {
        case .file(let target):
            // The original is never written into a "(clean)" copy (#17): in keep-both mode that copy goes instead.
            if entry.cleanCopyPath != nil { await trashCleanCopy(target); return }
            try await writeBack(data, to: target, onlyIfPresent: false)
            return
        case .refused:
            throw Self.refusedTarget()
        case .none:
            break
        }
        guard entry.source == .clipboard else { return }
        // An engine without a clipboard guard (the CLI, tests) has no clipboard to deliver to; the Journal change stands.
        guard let clipboardGuard else { Log.engine.info("no clipboard guard; delivery skipped"); return }
        let prepared: PreparedImage
        do { prepared = try await Pipeline.decode(data) } catch { throw EngineError.writeBack("image does not decode") }
        let png = try await Pipeline.encodePNG(prepared.image, dpi: prepared.dpi)
        let tiff = try await Pipeline.encodeTIFF(prepared.image)
        await MainActor.run { _ = clipboardGuard.writeBack(png: png, tiff: tiff, preservedText: nil) }
    }

    /// Moves a keep-both "(clean)" copy to the Trash (#17), so a file named clean never holds the original. A copy that
    /// will not move is left as it is: it is still covered, and the original is untouched beside it, so nothing is
    /// exposed; the failure is logged.
    private func trashCleanCopy(_ url: URL) async {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        await folderWatcher?.ignore(url, for: PipelineConstants.ignoredPathTTL)
        do {
            try moveToTrash(url)
            Log.engine.info("clean copy moved to the Trash: the entry shows its original")
        } catch {
            let ns = error as NSError
            Log.engine.error("clean copy not moved to the Trash domain=\(ns.domain, privacy: .public) code=\(ns.code); it stays covered")
        }
    }

    /// The Finder Trash; tests point it at a folder of their own so nothing reaches the user's Trash.
    private var moveToTrash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    func setTrash(_ move: @escaping @Sendable (URL) throws -> Void) { moveToTrash = move }

    /// The entry's findings or picture changed: its covered file's Spotlight entry and tags follow (G-24).
    private func searchEntryChanged(_ entryID: UUID) async {
        guard let search, let entry = try? await journal.entry(entryID) else { return }
        await search.entryChanged(entry, titles: detectorTitles, switches: Self.searchSwitches(settings.current()))
    }

    static func searchSwitches(_ settings: Settings) -> SearchSwitches {
        SearchSwitches(spotlight: settings.indexesCatchesInSpotlight, tags: settings.tagsCoveredFiles)
    }

    /// What opening a Spotlight result should show (G-24): the viewer while the entry exists, else the covered file.
    public func searchTarget(for identifier: String) async -> SearchTarget {
        await search?.target(for: identifier) ?? .none
    }

    /// Where the entry's picture goes on disk: its "(clean)" copy in keep-both mode, else the caught file. F26: checked
    /// against the folders watched now (`JournalTargets`); a row naming anything else is refused, never written.
    private func diskTarget(of entry: Entry) -> JournalTargets.Target {
        JournalTargets.target(of: entry, roots: watchedRoots())
    }

    private static func refusedTarget() -> EngineError {
        Log.engine.error("journal file refused: not a caught file in a watched folder; the change stays in the Journal")
        return EngineError.writeBack("the Journal names a file outside the folders Obscura watches")
    }

    /// Writes an entry's new picture to its file on disk (fail-open #7). `covers`: the picture covers at least one
    /// finding, so a failed write leaves the file showing what was caught: it is listed as not covered on disk until a
    /// write succeeds. A write that lands settles any such row for the file.
    ///
    /// Keep-both (fail-open #17): the "(clean)" copy beside the caught file exists only while it covers something. A
    /// picture that covers nothing (Undo, or every finding left visible) is the original, so the copy goes to the Trash
    /// instead of carrying the original under a "(clean)" name; a picture that covers something re-creates it if it is
    /// gone (Black Out Again after an Undo). The caught file itself is never written in keep-both mode.
    private func writeBackCovered(_ data: Data, for entry: Entry, covers: Bool, onlyIfPresent: Bool) async throws {
        let target: URL
        switch diskTarget(of: entry) {
        case .file(let url): target = url
        case .none: return
        case .refused: throw Self.refusedTarget()
        }
        if entry.cleanCopyPath != nil && !covers {
            await trashCleanCopy(target)
            await settleNotCovered(path: target.path)
            return
        }
        let written: Bool
        do {
            written = try await writeBack(data, to: target, onlyIfPresent: onlyIfPresent && entry.cleanCopyPath == nil)
        } catch {
            if covers, let source = entry.filePath {
                await noteNotCovered(target: target, source: URL(fileURLWithPath: source), entryID: entry.id)
            }
            throw error
        }
        if written { await settleNotCovered(path: target.path) }
    }

    /// Returns whether the file was written (false: `onlyIfPresent` and it is not there).
    @discardableResult
    private func writeBack(_ data: Data, to target: URL?, onlyIfPresent: Bool) async throws -> Bool {
        guard let target else { return false }
        let exists = FileManager.default.fileExists(atPath: target.path)
        if onlyIfPresent && !exists { return false }
        await folderWatcher?.ignore(target, for: PipelineConstants.ignoredPathTTL)
        do {
            if exists { try FileAtomics.replace(contentsOf: target, with: data) } else { try FileAtomics.write(data, to: target, mode: .default) }
        } catch {
            throw EngineError.writeBack(String(describing: error))
        }
        await folderWatcher?.adoptOwnWrite(target)
        return true
    }

    // MARK: - Unread spots (G-40)

    /// How the person settles a file's spots in the viewer.
    public enum SpotSettlement: Sendable, Hashable {
        /// "Not text": the person looked; the picture counts as checked by the person, never by Obscura.
        case notText
        /// "Cover it": a normal cover over each waiting spot's padded rect, through the entry's picture path (the
        /// original kept in the Journal, the file rewritten as for any cover, undoable).
        case cover
    }

    /// One spot row by id (listed or settled), as the viewer shows it.
    public func spotFile(_ id: UUID) async throws -> UncheckedFile {
        UncheckedFile(try await journal.uncheckedFile(id))
    }

    /// The spot rows settled (Not text, covered, or skipped as too small), most recently settled first: the record.
    public func settledSpotFiles() async -> [UncheckedFile] {
        ((try? await journal.settledSpotFiles()) ?? []).map(UncheckedFile.init)
    }

    /// The spot rows of the picture in `entryID` (so the viewer can outline them on that entry).
    public func spotFiles(entryID: UUID) async -> [UncheckedFile] {
        ((try? await journal.spotFiles(entryID: entryID)) ?? []).map(UncheckedFile.init)
    }

    /// Settles every waiting spot of `file` (G-40). Never calls the picture clean by itself: Not text records the
    /// person's word; Cover it covers. Returns the row as it now is (settled when no spot waits).
    @discardableResult
    public func settleSpots(_ file: UncheckedFile, _ how: SpotSettlement) async throws -> UncheckedFile {
        let current = try await journal.uncheckedFile(file.id)
        guard current.reason == .unreadPatch, current.spots.contains(where: { $0.state == .pending }) else { return UncheckedFile(current) }
        var spots = current.spots
        switch how {
        case .notText:
            for i in spots.indices where spots[i].state == .pending { spots[i].state = .notText }
        case .cover:
            spots = try await coverSpots(current)
        }
        let record = try await journal.updateSpots(current.id, spots: spots)
        list(record)
        Log.engine.info("spots settled by the person how=\(how == .cover ? "cover" : "notText", privacy: .public) spots=\(spots.count) settled=\(record.settledAt != nil)")
        await publishStatus()
        return UncheckedFile(record)
    }

    /// The undo of `settleSpots`: `before` is the row as it was. A cover it made is taken off through the entry's picture
    /// path (the file gets its original back, the finding stays for a later Cover it); every spot's state goes back.
    @discardableResult
    public func undoSettleSpots(_ before: UncheckedFile) async throws -> UncheckedFile {
        let current = try await journal.uncheckedFile(before.id)
        guard current.spots.count == before.spots.count else { throw EngineError.journal("spot row changed") }
        var uncover: [UUID: Set<UUID>] = [:]
        for (now, was) in zip(current.spots, before.spots) where now.state == .covered && was.state != .covered {
            if let entryID = now.entryID, let findingID = now.findingID { uncover[entryID, default: []].insert(findingID) }
        }
        for (entryID, findings) in uncover {
            try await applyPicture(entryID, style: nil) { Set($0.enabledFindings.map(\.id)).subtracting(findings) }
        }
        // States as they were; the entry and cover a later Cover it can use again are kept.
        let restored = zip(current.spots, before.spots).map { now, was in
            SpotRecord(rect: was.rect, coverRect: was.coverRect, state: was.state, entryID: now.entryID ?? was.entryID,
                       findingID: now.findingID ?? was.findingID)
        }
        let record = try await journal.updateSpots(before.id, spots: restored)
        list(record)
        Log.engine.info("spots settle undone spots=\(restored.count) listed=\(record.settledAt == nil)")
        await publishStatus()
        return UncheckedFile(record)
    }

    /// Cover it: each waiting spot gets a cover finding in the entry its picture is in (made now from the file when it
    /// has none), and the entry's picture is committed with those covers (G-28) and written where it goes. Returns the
    /// spots with the waiting ones covered.
    private func coverSpots(_ row: UncheckedRecord) async throws -> [SpotRecord] {
        let pending = row.spots.indices.filter { row.spots[$0].state == .pending }
        var entry: Entry
        var isNew = false
        if let id = row.spots.compactMap(\.entryID).first, let existing = try? await journal.entry(id) {
            entry = existing
        } else {
            entry = try await entryForSpots(row)
            isNew = true
        }
        var spots = row.spots
        // A spot whose cover is already a finding of the entry (covered before, then undone) uses it again.
        var missing: [Int] = []
        for i in pending {
            if let fid = spots[i].findingID, entry.findings.contains(where: { $0.id == fid }) { continue }
            missing.append(i)
        }
        if !missing.isEmpty {
            let added = missing.map {
                NewFinding(lineIndex: -1, rect: spots[$0].coverRect, detectorIDs: [SpotRecord.coverDetectorID], category: SpotRecord.coverCategory,
                           enabled: false)
            }
            let known = Set(entry.findings.map(\.id))
            entry = try await journal.addVisibleFindings(entry.id, added, expectedRevision: entry.revision)
            var fresh = entry.findings.filter { !known.contains($0.id) }
            for i in missing {
                guard let j = fresh.firstIndex(where: { $0.rect == spots[i].coverRect }) else { throw EngineError.journal("spot cover not stored") }
                spots[i].findingID = fresh.remove(at: j).id
            }
        }
        let covers = Set(pending.compactMap { spots[$0].findingID })
        let committed = try await applyPicture(entry.id, style: nil) { Set($0.enabledFindings.map(\.id)).union(covers) }
        for i in pending {
            spots[i].state = .covered
            spots[i].entryID = committed.id
        }
        // A picture the person covered is labelled like any covered file (G-24), from the file the entry writes.
        if isNew, let search, let path = committed.cleanCopyPath ?? committed.filePath, case .file = diskTarget(of: committed) {
            let isScreenshot = Self.origin(of: URL(fileURLWithPath: committed.filePath ?? path), in: watchedRoots()) == .screenshotFolder
            await search.caught(entryID: committed.id, coveredFile: URL(fileURLWithPath: path), findings: committed.findings,
                                isScreenshot: isScreenshot, titles: detectorTitles, switches: Self.searchSwitches(settings.current()))
        }
        return spots
    }

    /// A Journal entry for a spot row's picture, from the file as it is on disk now (its original kept, nothing covered
    /// yet). Every spot's cover must lie inside the picture: a file that changed since is refused.
    private func entryForSpots(_ row: UncheckedRecord) async throws -> Entry {
        let url = URL(fileURLWithPath: row.filePath)
        let origin = FileOrigin(row.origin)
        let data: Data?
        do {
            if origin == .imported {
                data = try await Pipeline.readFile(url, maxBytes: PipelineConstants.maxInputBytes)
            } else {
                data = try await Pipeline.readWatchedFile(url, roots: await folderWatcher?.currentRoots.map(\.url), maxBytes: PipelineConstants.maxInputBytes)
            }
        } catch {
            throw EngineError.writeBack("the file could not be read")
        }
        guard let data else { throw EngineError.writeBack("the file is too large") }
        let prepared: PreparedImage
        do { prepared = try await Pipeline.decode(data) } catch { throw EngineError.render("the file does not decode") }
        let bounds = CGRect(x: 0, y: 0, width: prepared.width, height: prepared.height)
        guard row.spots.allSatisfy({ bounds.contains($0.coverRect) }) else { throw EngineError.render("the picture changed since it was checked") }
        let writesFile = origin != .imported
        let cleanCopy: String? = writesFile && settings.current().fileHandling == .keepBoth
            ? Self.cleanSibling(of: url, output: prepared.outputUTI).path : nil
        let entry = try await journal.create(
            NewEntry(source: writesFile ? .file : .imported, displayName: url.lastPathComponent, filePath: url.path, cleanCopyPath: cleanCopy,
                     containerUTI: prepared.outputUTI.identifier, pixelWidth: prepared.width, pixelHeight: prepared.height, findings: []),
            original: data, clean: data)
        Log.engine.info("spot entry created for cover it")
        return entry
    }

    /// The person's Undo / Black Out Again / a finding toggled on an entry: a spot whose cover is that entry's finding
    /// follows it (covered while the finding covers, waiting again when it does not), so a picture shown with a spot
    /// uncovered is listed under Not checked again.
    private func syncSpots(entryID: UUID) async {
        guard let rows = try? await journal.spotFiles(entryID: entryID), !rows.isEmpty,
              let entry = try? await journal.entry(entryID) else { return }
        let enabled = Set(entry.enabledFindings.map(\.id))
        let known = Set(entry.findings.map(\.id))
        for row in rows {
            var spots = row.spots
            for i in spots.indices where spots[i].entryID == entryID {
                guard let fid = spots[i].findingID, known.contains(fid) else { continue }
                if enabled.contains(fid) { spots[i].state = .covered } else if spots[i].state == .covered { spots[i].state = .pending }
            }
            guard spots != row.spots, let record = try? await journal.updateSpots(row.id, spots: spots) else { continue }
            list(record)
            Log.engine.info("spots follow the entry listed=\(record.settledAt == nil)")
        }
    }

    /// Keeps the status's Not checked list in step with a spot row: listed while a spot waits, else not.
    private func list(_ record: UncheckedRecord) {
        let key = CaptureKey.path(record.filePath)
        if record.settledAt == nil { unchecked[key] = UncheckedFile(record) } else { unchecked.removeValue(forKey: key) }
    }

    // MARK: - Control

    public func pause() async {
        paused = true
        Log.engine.info("protection paused")
        await publishStatus()
    }

    public func resume() async {
        paused = false
        Log.engine.info("protection resumed")
        await publishStatus()
    }

    public var isPaused: Bool { paused }

    /// Recompiles the catalogue from the Journal's rules, overrides and detector state. Once per change, never per image.
    public func catalogueChanged() async {
        do {
            let result = try await CatalogueBuilder.build(journal: journal)
            catalogue = result.catalogue
            catalogueProblems = result.problems
            // Cover and search labels: built-in titles, one fixed phrase for every custom rule (scan F4/F5/F7).
            detectorTitles = CoverLabels.titles(for: result.catalogue)
        } catch {
            catalogueProblems = [Problem(kind: .ruleCompile, messageKey: "problem.catalogue.failed", detail: String(describing: error))]
            Log.engine.error("catalogue build failed")
        }
        await publishStatus()
    }

    private func currentCatalogue() async -> CompiledCatalogue? {
        if catalogue == nil { await catalogueChanged() }
        return catalogue
    }

    /// Retention prune, stale sweep, screenshot-folder re-read, folder access re-probe (§4 footer).
    public func maintenanceTick() async {
        let current = settings.current()
        // Fail-open #11: each step runs whatever the one before did, and a step that could not finish is a problem the
        // status shows (originals may be kept past the retention the app promises) until a later tick finishes it.
        var failedSteps: [String] = []
        var pruned = 0, swept = 0, orphans = 0
        do { pruned = try await journal.pruneExpired(olderThan: .seconds(current.journalRetentionHours * 3600)) } catch { failedSteps.append("prune") }
        do { swept = try await journal.sweepStale() } catch { failedSteps.append("sweep") }
        do { orphans = try await journal.sweepOrphans() } catch { failedSteps.append("orphans") }
        maintenanceProblem = failedSteps.isEmpty ? nil
            : Problem(kind: .journalMaintenance, messageKey: "problem.journal.maintenance", detail: failedSteps.joined(separator: ","))
        if failedSteps.isEmpty {
            Log.engine.info("maintenance pruned=\(pruned) swept=\(swept) orphans=\(orphans)")
        } else {
            Log.engine.error("maintenance incomplete steps=\(failedSteps.joined(separator: ","), privacy: .public); tried again next tick")
        }
        await repairCleanPictures()
        await search?.reconcile(full: false, titles: detectorTitles, switches: Self.searchSwitches(current))
        await updateFolders(for: current)
        pruneRecent()
        await publishStatus()
    }

    /// Applies capture settings to the sources at once: the clipboard guard runs only while it is switched on, and the
    /// folder watcher follows the folder switches and extra folders without waiting for the maintenance tick.
    func applySettings(_ current: Settings) async {
        await search?.switchesChanged(to: Self.searchSwitches(current), titles: detectorTitles)
        if let clipboardGuard {
            if current.guardsClipboard {
                do { try await clipboardGuard.start() } catch { Log.engine.error("clipboard guard failed to start") }
            } else {
                await clipboardGuard.stop()
            }
        }
        await updateFolders(for: current)
    }

    private func updateFolders(for current: Settings) async {
        // The Keychain is read only when the settings ask for a folder that needs a confirmation.
        if current.guardsDownloads || !current.extraFolders.isEmpty { reloadApprovals() }
        let roots = Self.watchedRoots(from: current, locations: locations, approvals: approvals)
        if let folderWatcher {
            // A failure is a source problem until a later call opens the stream; the watcher keeps the roots, so the
            // next maintenance tick or settings change tries again (fail-open #10).
            do {
                try await folderWatcher.update(roots: roots)
                watcherProblem = nil
            } catch {
                watcherProblem = Self.watcherDown
                Log.engine.error("folder watcher could not watch roots=\(roots.count); retried on the next tick")
            }
        }
        folderProblems = roots.compactMap { root in
            switch FolderAccess.probe(root.url) {
            case .granted: return nil
            case .denied: return Problem(kind: .folderAccess, messageKey: "problem.folder.denied", url: root.url)
            case .missing: return Problem(kind: .folderAccess, messageKey: "problem.folder.missing", url: root.url)
            }
        }
        // G-36: a folder the settings name that the person has not confirmed in Obscura is not watched, and said so.
        let unconfirmed = Self.unconfirmedFolders(from: current, locations: locations, approvals: approvals)
        folderProblems += unconfirmed.map { Problem(kind: .folderAccess, messageKey: Self.unconfirmedFolderKey, url: $0) }
        if !unconfirmed.isEmpty { Log.engine.notice("folders not watched until confirmed count=\(unconfirmed.count)") }
    }

    /// A folder the settings name that the person has not confirmed in Obscura (G-36). `url` is the folder.
    public static let unconfirmedFolderKey = "problem.folder.unconfirmed"
    /// G-40: the quiet "spots couldn't be read" status row (`Problem.Kind.unreadSpots`).
    public static let unreadSpotsKey = "problem.spots.unread"

    /// Reads the confirmations again. A read that fails keeps the last good one (a locked keychain is not "none").
    private func reloadApprovals() {
        do {
            approvals = try folderApprovals.load()
            approvalsLoaded = true
        } catch {
            Log.engine.error("watched-folder confirmations unreadable; kept the last read count=\(self.approvals.count)")
        }
    }

    /// The person confirmed `folder` in Obscura (an open-panel pick, the Downloads switch): it is watched from now on,
    /// while the settings name it. False when it is not a folder that exists, or the confirmation could not be kept.
    @discardableResult
    public func confirmFolder(_ folder: URL) async -> Bool {
        guard let approval = FolderApproval.current(folder, at: clock.now()) else { return false }
        reloadApprovals()
        var next = approvals.filter { $0.path != approval.path }
        next.append(approval)
        do { try folderApprovals.save(next) } catch {
            Log.engine.error("watched-folder confirmation could not be kept")
            return false
        }
        approvals = next
        approvalsLoaded = true
        Log.engine.info("folder confirmed count=\(next.count)")
        await updateFolders(for: settings.current())
        await publishStatus()
        return true
    }

    /// The person stopped watching `folder` in Obscura: its confirmation goes too, so adding the path back by any other
    /// way asks again.
    public func forgetFolder(_ folder: URL) async {
        reloadApprovals()
        let resolved = JournalTargets.realPath(folder.path) ?? folder.standardizedFileURL.path
        let next = approvals.filter { $0.path != resolved }
        guard next.count != approvals.count else { return }
        do { try folderApprovals.save(next); approvals = next } catch { Log.engine.error("watched-folder confirmation could not be removed") }
    }

    /// The folders guarded now, from the current settings, this engine's locations and the confirmations.
    func watchedRoots() -> [WatchedRoot] {
        if !approvalsLoaded { reloadApprovals() }
        return Self.watchedRoots(from: settings.current(), locations: locations, approvals: approvals)
    }

    /// The folders the settings say to guard and Obscura may watch: the screenshot folder (where macOS saves them), and
    /// Downloads and each added folder only when the person confirmed it in Obscura (G-36).
    public static func watchedRoots(from settings: Settings, locations: FolderLocations = .system, approvals: [FolderApproval]) -> [WatchedRoot] {
        var roots: [WatchedRoot] = []
        if settings.guardsScreenshotFolder { roots.append(WatchedRoot(url: locations.screenshotFolder(), origin: .screenshotFolder)) }
        let downloads = locations.downloads()
        if settings.guardsDownloads, isConfirmed(downloads, approvals) { roots.append(WatchedRoot(url: downloads, origin: .downloads)) }
        for url in extraFolderURLs(settings) where isConfirmed(url, approvals) {
            roots.append(WatchedRoot(url: url, origin: .watched(url)))
        }
        return roots
    }

    /// The folders the settings ask for that are not confirmed: they are not watched until the person confirms them.
    public static func unconfirmedFolders(from settings: Settings, locations: FolderLocations = .system, approvals: [FolderApproval]) -> [URL] {
        var out: [URL] = []
        let downloads = locations.downloads()
        if settings.guardsDownloads, !isConfirmed(downloads, approvals) { out.append(downloads) }
        out += extraFolderURLs(settings).filter { !isConfirmed($0, approvals) }
        return out
    }

    static func extraFolderURLs(_ settings: Settings) -> [URL] {
        settings.extraFolders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }

    static func isConfirmed(_ folder: URL, _ approvals: [FolderApproval]) -> Bool { approvals.contains { $0.names(folder) } }

    // MARK: - Warm-up and sources

    /// Loads Vision's models with a tiny recognition so the first real scan does not eat the cold start (12–25 s).
    /// `run()` calls it; one-shot callers (CLI, import before `run()`) call it themselves. Returns the milliseconds.
    @discardableResult
    public func warmUp() async -> Int? {
        guard let image = Pipeline.warmupImage() else {
            warmupProblem = Problem(kind: .ocrWarmup, messageKey: "problem.warmup.noImage")
            return nil
        }
        let started = ContinuousClock.now
        do {
            _ = try await ocrQueue.recognize(image, options: OCROptions(timeout: PipelineConstants.ocrTimeout * 3), priority: .file)
            let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
            warmupMilliseconds = ms
            warmupProblem = nil
            Log.engine.info("ocr warm-up ms=\(ms)")
            return ms
        } catch {
            warmupProblem = Problem(kind: .ocrWarmup, messageKey: "problem.warmup.failed")
            Log.engine.error("ocr warm-up failed")
            return nil
        }
    }

    /// The problem a folder watcher that cannot open its stream raises: the same words as any source that did not start.
    static let watcherDown = Problem(kind: .sourceStart, messageKey: "problem.source.start", detail: String(describing: FolderWatcher.self))

    private func startSources() async {
        var problems: [Problem] = []
        for source in sources {
            do { try await source.start() } catch {
                if let folderWatcher, (source as AnyObject) === folderWatcher {
                    // Tracked as `watcherProblem`, which every folder update sets or clears: retried, never stuck.
                    watcherProblem = Self.watcherDown
                } else {
                    problems.append(Problem(kind: .sourceStart, messageKey: "problem.source.start", detail: String(describing: type(of: source))))
                }
                Log.engine.error("capture source failed to start")
            }
        }
        sourceProblems = problems
    }

    // MARK: - Status

    private func publishStatus() async {
        statusBroadcaster.send(await currentStatus())
    }

    public func currentStatus() async -> EngineStatus {
        await loadUnchecked()
        let current = settings.current()
        pruneRecent()
        var problems = catalogueProblems + folderProblems + sourceProblems
        if let watcherProblem { problems.append(watcherProblem) }
        if let warmupProblem { problems.append(warmupProblem) }
        if let maintenanceProblem { problems.append(maintenanceProblem) }
        // "N images weren't checked": every file left without a verdict (OCR timeouts and failures included, each once),
        // plus the failures and attention-needing skips with no file to check again (a clipboard image that timed out or
        // would not open, a failed write-back), fail-open #13.
        // A failed write-back whose file is listed as not covered on disk (#7) is counted there, once, not here too.
        let listedKeys = Set(unchecked.keys).union(uncovered.values.map { CaptureKey(file: $0.sourceURL) })
        // G-40: a file whose only unread parts are spots waiting for the person is listed quietly, not counted here.
        let spotFiles = unchecked.values.filter(\.isUnreadSpots)
        let notChecked = unchecked.count - spotFiles.count
            + recentFailures.filter { failure in failure.key.map { !listedKeys.contains($0) } ?? true }.count
        if notChecked > 0 {
            problems.append(Problem(kind: .scanFailure, messageKey: "problem.scan.failed", detail: String(notChecked)))
        }
        // G-40: the spots waiting for the person (files listed under Not checked, and copied images), with no alarm: the
        // newest file is the one Review opens. Never makes protection "needs attention".
        let spotCount = spotFiles.reduce(0) { $0 + max(1, $1.pendingSpots) } + recentSpotImages.count
        if spotCount > 0 {
            let newest = spotFiles.max { $0.date < $1.date }
            problems.append(Problem(kind: .unreadSpots, messageKey: Self.unreadSpotsKey, url: newest?.fileURL, detail: String(spotCount)))
        }
        // Fail-open #7: a file on disk that still shows what was caught keeps protection from green until a write lands.
        if !uncovered.isEmpty {
            problems.append(Problem(kind: .notCovered, messageKey: "problem.disk.notCovered", detail: String(uncovered.count)))
        }
        var reasons: [String] = []
        if !current.guardsClipboard { reasons.append("protection.clipboardOff") }
        if !current.guardsScreenshotFolder { reasons.append("protection.screenshotsOff") }
        reasons += sourceProblems.map { _ in "protection.sourceDown" }
        if watcherProblem != nil { reasons.append("protection.sourceDown") }
        // A rule or an edited detector that does not compile changes what is caught: never plain Protected (#3).
        if catalogueProblems.contains(where: { $0.kind == .ruleCompile }) { reasons.append("protection.rulesSkipped") }
        // No catalogue at all (the first build failed): nothing can be caught, so every image would fail.
        let noCatalogue = catalogue == nil && !catalogueProblems.isEmpty

        let protection: ProtectionState
        if paused || current.protectionPaused {
            protection = .paused
        } else if noCatalogue || problems.contains(where: { [.folderAccess, .scanFailure, .notCovered, .journalMaintenance].contains($0.kind) }) {
            protection = .needsAttention(problems: problems)
        } else if !reasons.isEmpty {
            protection = .partlyProtected(reasons: reasons)
        } else {
            protection = .protected
        }
        let week = (try? await journal.weekStats()) ?? []
        return EngineStatus(protection: protection, inFlight: inFlight.count, queueDepth: await ocrQueue.depth, lastCatch: lastCatch,
                            weekStats: week, problems: problems, warmupMilliseconds: warmupMilliseconds,
                            unchecked: unchecked.values.sorted { $0.date > $1.date },
                            uncovered: uncovered.values.sorted { ($0.date, $0.record.filePath) > ($1.date, $1.record.filePath) })
    }

    /// Drops failures older than `recentFailureWindow`. Unchecked files do not age out (G-13): each stays until a later
    /// check of it reaches a verdict or the user dismisses it in the Journal.
    private func pruneRecent() {
        let now = clock.now(), window = PipelineConstants.recentFailureWindow.seconds
        recentFailures.removeAll { now.timeIntervalSince($0.date) > window }
        recentSpotImages.removeAll { now.timeIntervalSince($0.date) > window }
    }
}

extension Duration {
    var seconds: TimeInterval {
        let (s, atto) = components
        return TimeInterval(s) + TimeInterval(atto) / 1e18
    }
}
