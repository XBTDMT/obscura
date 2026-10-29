// The one observable model every surface reads. It mirrors the engine's status stream, the Journal and the settings,
// and turns user actions into engine and store calls. Surfaces hold no state of their own beyond view state.
public import SwiftUI
public import Observation
public import ObscuraEngine
public import ObscuraJournal
public import ObscuraPrefs
import ObscuraSupport

@MainActor
@Observable
public final class AppModel {
    // MARK: Mirrored state

    /// The latest engine status (replayed on subscribe).
    public private(set) var status: EngineStatus = EngineStatus()
    /// Live (not trashed) Journal entries, newest first.
    public private(set) var entries: [Entry] = []
    /// Current settings.
    public private(set) var settings: ObscuraPrefs.Settings
    /// An update a check found (G-33), with its install phase (ready, installing, failed with a reason); `nil` when none
    /// is waiting or the banner was dismissed until the next check. Set by `UpdateCoordinator`.
    public var updateOffer: UpdateOffer?
    /// When the current pause began. Only the end is persisted (`Settings.pausedUntil`), so after a relaunch this is
    /// `nil` and the panel says "Paused" without a start time.
    public private(set) var pausedSince: Date?
    /// When the armed auto-resume fires; `nil` while protecting or paused until resumed.
    public private(set) var resumeScheduledAt: Date?
    /// Focus mode is holding catch notifications (set by the notifier).
    public var focusHolding = false
    /// Setup's progress for the panel's setup card while setup is unfinished (set by the app from ObscuraSetupUI's
    /// `SetupProgress`, G-19 M-19); nil until it has been read.
    public var setupSummary: SetupSummary?
    /// The last scan report, for the brief "caught just now" mark.
    public private(set) var lastReportDate: Date?
    /// Whether the last catch came from the clipboard: the menu bar mark wipes for it instead of snapping shut (G-21).
    public private(set) var lastCatchFromClipboard = false
    /// The latest Copy Clean that worked, for the menu bar mark's pulse (G-21); a new value on every copy.
    public private(set) var copiedClean: MarkCue?
    /// The entry whose Undo put its original back, while that original still shows (every finding uncovered). The menu
    /// bar mark's cover stays lifted meanwhile (G-21); Redo, re-covering a finding, or the entry leaving ends it.
    public private(set) var originalShowingEntryID: UUID?
    /// An Undo's original is showing (see `originalShowingEntryID`).
    public var showsOriginal: Bool { originalShowingEntryID != nil }
    /// A message the visible surface shows as a toast. It lives `toastLifetime` from the moment it is raised and then
    /// clears itself, whether or not anything showed it: a toast raised while no window or panel is on screen (a Delete
    /// or Copy from the floating thumbnail) is dropped rather than popping up minutes later when a surface next opens
    /// (recon S-14). The action itself already happened where the user was looking.
    public var toast: ToastMessage? {
        didSet { if toast?.id != oldValue?.id { scheduleToastExpiry() } }
    }
    /// How long a model toast lives: `OMotion.toastSeconds`, like every toast. Tests shorten it.
    public var toastLifetime: Duration = .seconds(OMotion.toastSeconds)
    @ObservationIgnored private var toastExpiry: Task<Void, Never>?

    // MARK: Dependencies

    public let journal: any JournalStore
    public let settingsStore: any SettingsWriter
    public weak var router: (any Router)?
    /// Holds a router nothing else owns (previews and tests); the app's router is owned by the app and stays weak here.
    private var ownedRouter: (any Router)?
    private let engine: ShieldEngine?
    private var tasks: [Task<Void, Never>] = []
    private var thumbnails: [ThumbKey: NSImage] = [:]
    /// The wall clock; tests pass a fixed one.
    private let now: @Sendable () -> Date
    private var resumeTask: Task<Void, Never>?

    public init(engine: ShieldEngine?, journal: any JournalStore, settings: any SettingsWriter, router: (any Router)? = nil,
                ownsRouter: Bool = false, now: @escaping @Sendable () -> Date = { Date() }) {
        if ownsRouter { self.ownedRouter = router }
        self.engine = engine
        self.journal = journal
        self.settingsStore = settings
        self.settings = settings.current()
        self.router = router
        self.now = now
    }

    /// Starts mirroring. Call once from the app (or a preview), before the engine runs. Safe to call again; it
    /// restarts the subscriptions.
    public func start() {
        stop()
        // A pause outlives the app. Settle it before the engine's first scan: one that ran out while the app was not
        // running resumes now, a timed one re-arms its resume, one until resumed stays. The engine skips every source
        // while `Settings.protectionPaused` (derived from `pausedUntil`) is true, so nothing is checked meanwhile.
        settings = settingsStore.current()
        armResume()
        if let engine {
            tasks.append(Task { [weak self] in
                for await s in engine.status { self?.status = s }
            })
            tasks.append(Task { [weak self] in
                for await report in engine.outcomes {
                    guard let self else { return }
                    if report.outcome.isRedacted {
                        var clipboard = false
                        if case .pasteboard = report.key { clipboard = true }
                        self.recordCatch(fromClipboard: clipboard, at: Date())
                    }
                    await self.reloadEntries()
                }
            })
        }
        // Subscribed here, not inside the task, so a change made right after start() is never missed.
        let settingChanges = settingsStore.changes
        tasks.append(Task { [weak self] in
            for await s in settingChanges {
                guard let self else { return }
                let pauseChanged = s.pausedUntil != self.settings.pausedUntil
                self.settings = s
                // A pause set or cleared elsewhere (Settings, the defaults domain) moves the resume with it.
                if pauseChanged { self.armResume() }
            }
        })
        Task { await reloadEntries() }
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        resumeTask?.cancel()
        resumeTask = nil
        resumeScheduledAt = nil
    }

    // MARK: Derived state

    /// The menu bar mark's state right now, by precedence: needs attention, paused, checking, caught
    /// (`MarkTiming.caughtSeconds`), partly, Focus holding, update waiting, protected. Checking here is raw (any image in flight); the menu bar
    /// shows it through `MarkCheckingGate`, so a warm ~0.1 s scan never blinks the mark.
    public var markState: MarkState { markState(showingChecking: isChecking, at: Date()) }

    /// An image is being read or waits in the queue.
    public var isChecking: Bool { status.inFlight > 0 || status.queueDepth > 0 }

    /// The mark's state with checking decided by the caller (the gated value): while checking is not shown, the state
    /// under it (a recent catch's dot, say) stays.
    public func markState(showingChecking: Bool, at date: Date) -> MarkState {
        switch status.protection {
        case .needsAttention: return .needsAttention
        case .paused: return .paused
        default: break
        }
        if showingChecking { return .checking }
        if let end = caughtUntil, date < end { return .caught }
        if case .partlyProtected = status.protection { return .partlyProtected }
        // Two marks (G-19 #18): Focus holding catches is the moon, an update the dot. Focus leads: it is about catches
        // happening now, while an update can wait days; the panel names both.
        if focusHolding { return .focusHolding }
        if updateOffer != nil { return .waiting }
        return .protected
    }

    /// When the brief "caught" dot ends; nil when no catch was reported.
    public var caughtUntil: Date? { lastReportDate?.addingTimeInterval(MarkTiming.caughtSeconds) }

    // MARK: What the menu bar mark answers (G-21)
    // The model records these itself (a scan report, Copy Clean, Undo); previews and tests drive the mark with them.

    /// A catch was reported: the caught dot starts its 4 s, and the mark snaps shut (a file) or wipes (the clipboard).
    public func recordCatch(fromClipboard: Bool, at date: Date) {
        lastCatchFromClipboard = fromClipboard
        lastReportDate = date
    }

    /// A Copy Clean worked: the mark pulses once.
    public func recordCopiedClean() { copiedClean = MarkCue() }

    /// An Undo put `entryID`'s original back: the mark's cover lifts until it is covered again.
    public func recordOriginalShowing(_ entryID: UUID?) { originalShowingEntryID = entryID }

    /// The verdict for one entry.
    public func verdict(for entry: Entry) -> Verdict {
        Verdict(enabled: entry.enabledFindings.count, total: entry.findings.count)
    }

    // MARK: Actions

    public func reloadEntries() async {
        do { entries = try await journal.entries(matching: .live) }
        catch { Log.app.error("journal entries reload failed"); return }
        // The undone entry's original stops showing once any finding is covered again or the entry is gone.
        if let id = originalShowingEntryID,
           entries.first(where: { $0.id == id }).map({ !$0.enabledFindings.isEmpty }) ?? true {
            originalShowingEntryID = nil
        }
    }

    /// The current pause, from the persisted end and the in-memory start; `nil` while protecting.
    public var pause: PauseState? {
        guard let until = settings.pausedUntil else { return nil }
        return PauseState(since: pausedSince, resumesAt: settings.isPausedUntilResumed ? nil : until)
    }

    /// Pauses every guard until `end`; `nil` pauses until the user resumes. The end is persisted
    /// (`Settings.pausedUntil`), so a relaunch keeps the pause and its auto-resume.
    public func pause(until end: Date?) {
        pausedSince = now()
        settingsStore.update { $0.pausedUntil = end ?? .distantFuture }
        settings = settingsStore.current()
        Task { await engine?.pause() }
        armResume()
    }

    /// Pauses for `duration` from now; `nil` pauses until the user resumes.
    public func pause(for duration: Duration?) {
        pause(until: duration.map { d in
            now().addingTimeInterval(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        })
    }

    public func resume() {
        resumeTask?.cancel()
        resumeTask = nil
        resumeScheduledAt = nil
        pausedSince = nil
        settingsStore.update { $0.pausedUntil = nil }
        settings = settingsStore.current()
        Task { await engine?.resume() }
    }

    /// Arms (or disarms) the auto-resume for the stored pause: past ends resume at once, a timed end sleeps until it,
    /// a pause until resumed (or none) arms nothing.
    private func armResume() {
        resumeTask?.cancel()
        resumeTask = nil
        resumeScheduledAt = nil
        guard let until = settings.pausedUntil else { pausedSince = nil; return }
        guard !settings.isPausedUntilResumed else { return }
        let wait = until.timeIntervalSince(now())
        guard wait > 0 else {
            Log.app.info("a timed pause ended while Obscura was not running; protection resumed")
            resume()
            return
        }
        resumeScheduledAt = until
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.resumeIfDue()
        }
    }

    /// The timer fired: resume if the stored end has passed (re-reading it, so a newer pause wins), else re-arm, as
    /// when the wall clock moved back while the timer slept.
    private func resumeIfDue() {
        settings = settingsStore.current()
        guard let until = settings.pausedUntil, !settings.isPausedUntilResumed else { return armResume() }
        if now() >= until { resume() } else { armResume() }
    }

    public func updateSettings(_ transform: @Sendable (inout ObscuraPrefs.Settings) -> Void) {
        settingsStore.update(transform)
        // Mirror at once: the change stream arrives later, and a view reading right after its own change must see it.
        settings = settingsStore.current()
    }

    /// Asks before an Undo shows original(s) (G-19 #11); the app sets it to `UndoAlert.confirm`. Nil (previews, tests
    /// without one) acts at once, as the default setting does.
    @ObservationIgnored public var confirmUndo: (@MainActor (UndoConfirmation) async -> Bool)?

    /// Every surface's Undo (the panel, a notification, the floating thumbnail, the Journal): asks first when
    /// `Settings.confirmsUndo` is on, then restores. Returns whether the original is now showing.
    @discardableResult
    public func undo(_ entryID: UUID) async -> Bool {
        guard await mayUndo([entryID]) else { return false }
        return await restoreOriginal(entryID)
    }

    /// The confirm-before-Undo gate for one or several entries: true at once unless `Settings.confirmsUndo` is on, then
    /// whatever the user answers. One question covers a whole selection.
    public func mayUndo(_ entryIDs: [UUID]) async -> Bool {
        guard UndoConfirmation.isRequired(settings), !entryIDs.isEmpty else { return true }
        guard let confirmUndo else {
            Log.app.notice("confirm before undo is on but nothing can ask; acting at once")
            return true
        }
        var found: [Entry] = []
        for id in entryIDs {
            if let entry = entries.first(where: { $0.id == id }) { found.append(entry) }
            else if let entry = try? await journal.entry(id) { found.append(entry) }
        }
        let answer = await confirmUndo(UndoConfirmation(entries: found))
        Log.app.info("undo confirmation answered=\(answer) entries=\(entryIDs.count)")
        return answer
    }

    /// Undo: shows every finding again and puts the original back where the clean image went. Returns whether it
    /// worked, so callers (the notifier, the panel) never report an undo that did not happen. Surfaces call `undo(_:)`,
    /// which asks first when the user wants that; this is the act itself.
    @discardableResult
    public func restoreOriginal(_ entryID: UUID) async -> Bool {
        defer { Task { await reloadEntries() } }
        guard let engine else { return false }
        do {
            try await engine.restoreOriginal(entryID)
            recordOriginalShowing(entryID)
            await reloadEntries()
            return true
        }
        catch { show(String(localized: "Couldn't restore the original."), error: true); return false }
    }

    /// Redo: covers every finding again and puts the clean image back. Returns whether it worked.
    @discardableResult
    public func blackOutAll(_ entryID: UUID) async -> Bool {
        guard let engine else { return false }
        do {
            try await engine.blackOutAll(entryID)
            if originalShowingEntryID == entryID { originalShowingEntryID = nil }
            await reloadEntries()
            return true
        }
        catch { show(String(localized: "Couldn't black out the image again."), error: true); await reloadEntries(); return false }
    }

    public func setFinding(_ findingID: UUID, enabled: Bool, in entryID: UUID) async {
        do { try await engine?.setFinding(findingID, enabled: enabled, in: entryID) } catch { show(String(localized: "Couldn't update the image."), error: true) }
        await reloadEntries()
    }

    public func setStyle(_ style: StyleRecord, for entryID: UUID) async {
        do { try await engine?.rerender(entryID, style: StyleBridge.spec(from: style)) } catch { show(String(localized: "Couldn't apply the style."), error: true) }
        await reloadEntries()
    }

    /// Moves entries to the Journal's trash and says what really happened (fail-open #12): the entries that moved are
    /// read back from the Journal, so "Screenshot deleted" (with its Undo) is shown only for what was deleted, and a
    /// failure is an error toast. Returns the ids that are in the trash now.
    @discardableResult
    public func trash(_ ids: [UUID]) async -> [UUID] {
        var failed = false
        do { try await journal.trash(ids) } catch {
            failed = true
            Log.app.error("journal trash failed count=\(ids.count)")
        }
        await reloadEntries()
        let done = await entries(ids, trashed: true)
        let n = done.count, missed = ids.count - done.count
        if !failed && missed == 0 {
            toast = ToastMessage(text: n == 1 ? String(localized: "Screenshot deleted") : String(localized: "\(n) screenshots deleted"),
                                 undo: { [weak self] in Task { await self?.restore(done) } })
        } else if done.isEmpty {
            toast = ToastMessage(text: ids.count == 1 ? String(localized: "Couldn't delete the screenshot.")
                                                     : String(localized: "Couldn't delete the screenshots."), isError: true)
        } else {
            toast = ToastMessage(text: String(localized: "Deleted \(n) of \(ids.count). \(missed) couldn't be deleted."),
                                 undo: { [weak self] in Task { await self?.restore(done) } }, isError: true)
        }
        return done
    }

    /// Which of `ids` the Journal holds in (or out of) its trash now: what a trash or restore really did.
    private func entries(_ ids: [UUID], trashed: Bool) async -> [UUID] {
        var out: [UUID] = []
        for id in ids { if let entry = try? await journal.entry(id), entry.isTrashed == trashed { out.append(id) } }
        return out
    }

    /// Puts entries back from the Journal's trash. A failure is an error toast, never silence (fail-open #12). Returns
    /// the ids that are back.
    @discardableResult
    public func restore(_ ids: [UUID]) async -> [UUID] {
        var failed = false
        do { try await journal.restore(ids) } catch {
            failed = true
            Log.app.error("journal restore failed count=\(ids.count)")
        }
        await reloadEntries()
        let back = await entries(ids, trashed: false)
        if failed || back.count < ids.count {
            toast = ToastMessage(text: back.isEmpty
                                    ? (ids.count == 1 ? String(localized: "Couldn't restore the screenshot.") : String(localized: "Couldn't restore the screenshots."))
                                    : String(localized: "Restored \(back.count) of \(ids.count). \(ids.count - back.count) couldn't be restored."),
                                 isError: true)
        }
        return back
    }

    /// Puts the clean image (or the original) on the clipboard through the engine, marked as the app's own write so
    /// the clipboard guard does not redact it again.
    public func copy(_ entryID: UUID, original: Bool) async {
        guard let engine else { return }
        do {
            let entry = try await engine.copyToClipboard(entryID, original: original)
            if original {
                show(String(localized: "Original copied. It contains every secret."), error: true)
                return
            }
            // The copied picture's own flags, read with its bytes (G-28): it is called clean only when it covers every
            // finding; a picture with findings left visible (or the original after an Undo) is said to be one.
            let visible = entry.findings.count - entry.enabledFindings.count
            if visible == 0 {
                recordCopiedClean()
                show(String(localized: "Clean copy is on the clipboard."), error: false)
            } else if entry.enabledFindings.isEmpty {
                show(String(localized: "Copied as shown: the original, with every secret visible."), error: true)
            } else {
                show(visible == 1 ? String(localized: "Copied as shown: 1 secret is visible.")
                                  : String(localized: "Copied as shown: \(visible) secrets are visible."), error: true)
            }
        } catch { show(String(localized: "Couldn't copy the image."), error: true) }
    }

    /// The text of a finding left visible, read again from the original in memory (G-17). The engine refuses unless the
    /// Settings switch is on and the finding is uncovered; the text is never stored or logged. Without an engine
    /// (previews) there is nothing to read with.
    public func readKeyText(_ findingID: UUID, in entryID: UUID) async throws -> String {
        guard let engine else { throw KeyTextError.readFailed }
        return try await engine.readText(of: findingID, in: entryID)
    }

    /// "Check Again" for "N images weren't checked": every file the engine left without a verdict (`EngineStatus.unchecked`,
    /// OCR timeouts included) goes back through it with the origin it first came from. Returns how many were sent.
    @discardableResult
    public func checkAgain() async -> Int {
        guard let engine else { return 0 }
        return await engine.retryUnchecked()
    }

    /// G-36: the person confirmed `folder` in Obscura (an open-panel pick, the Downloads switch), so it may be watched.
    /// Call before the setting that names it changes. False when it could not be kept (it is then not watched). Without
    /// an engine (previews, UI tests) nothing is watched, so there is nothing to confirm and the change goes ahead.
    @discardableResult
    public func confirmFolder(_ folder: URL) async -> Bool {
        guard let engine else { return true }
        return await engine.confirmFolder(folder)
    }

    /// G-36: the person stopped watching `folder` in Obscura; its confirmation goes with it.
    public func forgetFolder(_ folder: URL) async {
        await engine?.forgetFolder(folder)
    }

    /// G-36: the folders the settings name that the person has not confirmed in Obscura (not watched until they do), by
    /// standardized path.
    public var unconfirmedFolders: Set<String> {
        Set(status.problems.filter { $0.messageKey == ShieldEngine.unconfirmedFolderKey }.compactMap { $0.url?.standardizedFileURL.path })
    }

    /// "Check Again" on one file in the Journal's Not checked section: it goes back through the engine with the origin
    /// it first came from, and leaves the list when that check reaches a verdict.
    public func checkAgain(_ file: UncheckedFile) async {
        guard let engine else { return }
        await engine.retry(file.fileURL)
    }

    // MARK: Unread spots (G-40)

    /// One spot row (listed or settled), from the engine, or the Journal itself without one (previews, UI tests).
    public func spotFile(_ id: UUID) async -> UncheckedFile? {
        if let engine { return try? await engine.spotFile(id) }
        return (try? await journal.uncheckedFile(id)).map(UncheckedFile.init)
    }

    /// The spot rows of the picture in an entry.
    public func spotFiles(entryID: UUID) async -> [UncheckedFile] {
        if let engine { return await engine.spotFiles(entryID: entryID) }
        return ((try? await journal.spotFiles(entryID: entryID)) ?? []).map(UncheckedFile.init)
    }

    /// The record of settled spot rows, most recently settled first.
    public func settledSpotFiles() async -> [UncheckedFile] {
        if let engine { return await engine.settledSpotFiles() }
        return ((try? await journal.settledSpotFiles()) ?? []).map(UncheckedFile.init)
    }

    /// Not Text / Cover It on a picture's waiting spots, with an Undo toast. Returns the row as it now is; nil when it
    /// could not be done (said in an error toast) or there is no engine.
    @discardableResult
    public func settleSpots(_ file: UncheckedFile, _ how: ShieldEngine.SpotSettlement) async -> UncheckedFile? {
        guard let engine else { return nil }
        let waiting = file.pendingSpots
        do {
            let after = try await engine.settleSpots(file, how)
            await reloadEntries()
            toast = ToastMessage(text: SpotCopy.settled(how, spots: max(1, waiting)),
                                 undo: { [weak self] in Task { await self?.undoSettleSpots(file) } })
            return after
        } catch {
            show(how == .cover ? SpotCopy.coverFailed : SpotCopy.settleFailed, error: true)
            return nil
        }
    }

    /// The undo of `settleSpots`: `before` is the row as it was.
    public func undoSettleSpots(_ before: UncheckedFile) async {
        guard let engine else { return }
        do { _ = try await engine.undoSettleSpots(before) } catch { show(SpotCopy.undoFailed, error: true) }
        await reloadEntries()
    }

    /// "Dismiss" in the Not checked section: the file leaves the list (and the panel's count) without being checked.
    public func dismissUnchecked(_ file: UncheckedFile) async {
        await engine?.dismissUnchecked(file)
    }

    /// The undo of `dismissUnchecked(_:)`.
    public func restoreUnchecked(_ file: UncheckedFile) async {
        await engine?.restoreUnchecked(file)
    }

    /// "Try Again" on a file that still shows what was caught (fail-open #7): the covered picture is written there again,
    /// or the file is checked again when its entry is gone. Says what happened; nil without an engine.
    @discardableResult
    public func retryNotCovered(_ file: UncoveredFile) async -> UncoveredRetry? {
        guard let engine else { return nil }
        let result = await engine.retryUncovered(file)
        switch result {
        case .written: show(String(localized: "\(file.displayName) is covered now."), error: false)
        case .checkingAgain: show(String(localized: "Checking \(file.sourceURL.lastPathComponent) again"), error: false)
        case .failed: show(String(localized: "Couldn't write to \(file.displayName). It still shows what was caught."), error: true)
        case .fileMissing: show(String(localized: "Couldn't find \(file.sourceURL.lastPathComponent). It was moved or deleted."), error: true)
        case .notWatched: show(String(localized: "Its folder isn't watched any more, so Obscura won't write to it."), error: true)
        }
        await reloadEntries()
        return result
    }

    /// "Try Again" for every file that still shows what was caught. Returns how many are covered now.
    @discardableResult
    public func retryAllNotCovered() async -> Int {
        guard let engine else { return 0 }
        var written = 0, left = 0
        for file in status.uncovered {
            switch await engine.retryUncovered(file) {
            case .written: written += 1
            case .checkingAgain: break
            case .failed, .fileMissing, .notWatched: left += 1
            }
        }
        if left > 0 {
            show(String(localized: "\(left) still not covered on disk."), error: true)
        } else if written > 0 {
            show(written == 1 ? String(localized: "1 file is covered now.") : String(localized: "\(written) files are covered now."), error: false)
        }
        await reloadEntries()
        return written
    }

    /// "Dismiss" on a file that still shows what was caught: it leaves the list and the status, the file stays as it is.
    public func dismissNotCovered(_ file: UncoveredFile) async {
        await engine?.dismissUncovered(file)
    }

    /// The undo of `dismissNotCovered(_:)`.
    public func restoreNotCovered(_ file: UncoveredFile) async {
        await engine?.restoreUncovered(file)
    }

    /// Runs the Journal's upkeep now (retention, sweeps): "Try Again" on "Old originals weren't all deleted" (#11).
    public func runMaintenance() async {
        await engine?.maintenanceTick()
        await reloadEntries()
    }

    /// Call after adding, editing or removing a rule, override or detector switch, so the next image uses it.
    public func rulesChanged() async {
        await engine?.catalogueChanged()
    }

    /// Imports image files the user dropped or chose; originals are never changed.
    public func importImages(_ urls: [URL]) async {
        guard let engine else { return }
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            _ = await engine.scan(imageData: data, source: .imported, displayName: url.lastPathComponent, filePath: nil, origin: nil)
        }
        await reloadEntries()
    }

    // MARK: Images

    /// A cached thumbnail of an entry's clean (or original) image.
    public func thumbnail(for entry: Entry, original: Bool = false) async -> NSImage? {
        let key = ThumbKey(id: entry.id, revision: entry.revision, original: original)
        if let cached = thumbnails[key] { return cached }
        if original {
            guard let data = try? await journal.originalData(entry.id), let image = NSImage(data: data) else { return nil }
            thumbnails[key] = image
            return image
        }
        // The clean picture with the revision it belongs to, from one Journal read (G-28): cached under that revision,
        // never under an older entry's.
        guard let clean = try? await journal.cleanImage(entry.id), let image = NSImage(data: clean.data) else { return nil }
        thumbnails[ThumbKey(id: entry.id, revision: clean.entry.revision, original: false)] = image
        return image
    }

    private func show(_ text: String, error: Bool) {
        toast = ToastMessage(text: text, undo: nil, isError: error)
    }

    /// Clears the current toast once its lifetime is up, unless a newer one replaced it first.
    private func scheduleToastExpiry() {
        toastExpiry?.cancel()
        toastExpiry = nil
        guard let id = toast?.id else { return }
        let lifetime = toastLifetime
        toastExpiry = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, let self, self.toast?.id == id else { return }
            self.toast = nil
        }
    }
}

/// A pause as the model knows it.
public struct PauseState: Equatable, Sendable {
    /// When it began; `nil` after a relaunch (only the end is persisted).
    public var since: Date?
    /// When protection comes back by itself; `nil` = paused until the user resumes.
    public var resumesAt: Date?

    public init(since: Date?, resumesAt: Date?) {
        self.since = since; self.resumesAt = resumesAt
    }
}

/// A moment the menu bar mark answers with a motion (G-21): a new value every time, so the same action twice plays twice.
public struct MarkCue: Equatable, Sendable {
    public let id = UUID()
    public init() {}
}

/// A toast the current window shows once.
public struct ToastMessage: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public var text: String
    public var undo: (() -> Void)?
    public var isError = false

    public init(text: String, undo: (() -> Void)? = nil, isError: Bool = false) {
        self.text = text; self.undo = undo; self.isError = isError
    }
}

struct ThumbKey: Hashable { let id: UUID; let revision: Int; let original: Bool }

