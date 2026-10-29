// ObscuraNotifyUI — the notifications layer (B-6, pick notifications/r3-a "Native ladder, named and silent").
// A catch is a silent banner that folds into Recent; a problem is a sounded, time-sensitive alert with its fix in view;
// an update is passive. This file is the thin UserNotifications layer: every decision is made by the pure types
// beside it (NotificationCopy, CatchBatcher, ProblemNotice, NotificationRouting, DeliveryMode).
public import Foundation
public import UserNotifications
public import ObscuraUIKit
public import ObscuraEngine
import AppKit
import ImageIO
import UniformTypeIdentifiers
import ObscuraJournal
import ObscuraPrefs
import ObscuraSupport

@MainActor
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let model: AppModel
    private let client: any NotificationClient
    private let now: @MainActor () -> Date
    private var batcher = CatchBatcher()
    private var problemBatcher = ProblemBatcher()
    /// Problems currently delivered, by `Problem.id`, so a repeated status does not re-alert.
    private var postedProblems: [String: String] = [:]
    /// The tail of the serial chain that keeps reports in arrival order across their Journal reads.
    private var tail: Task<Void, Never>?
    /// Checks a file the engine left unchecked again ("Check Again"). The app target wires it to
    /// `ShieldEngine.retry(_:)`, which re-submits the file with the origin it first came from; the model does not
    /// expose the engine.
    public var rescan: (@MainActor (URL) -> Void)?
    /// Asks Obscura's floating thumbnail whether it announces this report's catch (`ThumbnailController.claims`). The
    /// app wires it; unset, the rule falls back to the report's origin and the thumbnail switch.
    public var thumbnailClaims: (@MainActor (ScanReport) -> Bool)?

    public convenience init(model: AppModel, center: UNUserNotificationCenter = .current()) {
        self.init(model: model, client: SystemNotificationClient(center), now: { Date() })
        center.delegate = self
    }

    init(model: AppModel, client: any NotificationClient, now: @escaping @MainActor () -> Date) {
        self.model = model
        self.client = client
        self.now = now
        super.init()
        client.register(NotificationCopy.categories())
    }

    // MARK: Public entry points

    /// One finished scan (`ShieldEngine.events`' `.finished`). Catches become silent banners (or a burst summary); OCR
    /// timeouts and failed writes become problem alerts; everything else stays in the panel. A catch from the
    /// screenshot folder posts no banner while Obscura's thumbnail is on: the thumbnail is the notice. The report
    /// carries its origin, so the decision needs no memory of the scan's start (G-9).
    public func handle(_ report: ScanReport) {
        let triage = ReportTriage.classify(report)
        let name = report.displayName
        let notes = report.notes
        // Fail-open #1: a catch from a partly read picture is also "not checked", and says so whoever announces the
        // catch (the thumbnail or the banner).
        if report.outcome.isRedacted, notes.contains(.partlyRead) {
            let path: String? = { if case .path(let p) = report.key { return p } else { return nil } }()
            let notice = ProblemNotice.partlyRead(path: path, displayName: name, timedOut: notes.contains(.partlyReadTimedOut),
                                                  timeoutSeconds: Int(model.settings.ocrTimeoutSeconds.rounded()), noun: ImageNoun(report.origin))
            enqueue { await $0.postFileProblem(notice) }
        }
        let claimed = thumbnailClaims?(report) ?? (report.origin == .screenshotFolder && model.settings.thumbnailEnabled)
        if !CatchBannerRule.posts(triage, thumbnailClaims: claimed) { return }
        let noun = ImageNoun(report.origin)
        let spots = report.spots
        enqueue { await $0.process(triage, displayName: name, notes: notes, noun: noun, spots: spots) }
    }

    /// A standing engine problem (folder access, a rule, a source). Posts once per problem until it clears;
    /// call `reconcile(problems:)` with each status to withdraw cleared ones so they can alert again later.
    public func post(problem: Problem) {
        enqueue { await $0.postProblem(problem) }
    }

    /// Posts the problems that are new in `problems` and withdraws delivered ones that are no longer present.
    public func reconcile(problems: [Problem]) {
        enqueue { await $0.reconcileProblems(problems) }
    }

    /// A scheduled check found `version`. Passive: no sound, no screen wake; the panel's blue row carries it too.
    public func postUpdateAvailable(version: String) {
        enqueue { await $0.deliver(NotificationCopy.updatePlan(version: version)) }
    }

    /// Re-reads how macOS delivers (call when the app becomes active) and updates `model.focusHolding`.
    public func refreshDeliveryState() {
        enqueue { notifier in _ = await notifier.deliveryMode() }
    }

    // MARK: Serial processing

    private func enqueue(_ work: @escaping @MainActor (Notifier) async -> Void) {
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
    }

    /// Waits for everything queued so far (tests).
    func drain() async { await tail?.value }

    func process(_ triage: ReportTriage, displayName: String, notes: ScanNotes = [], noun: ImageNoun = .screenshot,
                 spots: [SpotRecord] = []) async {
        switch triage {
        case .none:
            return
        case .caught(let entryID):
            guard let entry = try? await model.journal.entry(entryID), var facts = CatchFacts(entry: entry) else { return }
            facts.notes = notes
            facts.pendingSpots = spots.filter { $0.state == .pending }.count
            await postCatch(facts)
        case .unreadSpots(let path):
            // G-40: no alarm. A file waits in the panel and the Journal; a copied image has no row, so one quiet notice.
            guard path == nil else { return }
            await deliver(NotificationCopy.clipboardSpotsPlan(spots: max(1, spots.filter { $0.state == .pending }.count)))
        case .unchecked(let reason, let path):
            let notice = ProblemNotice.unchecked(reason, path: path, displayName: displayName,
                                                 timeoutSeconds: Int(model.settings.ocrTimeoutSeconds.rounded()),
                                                 pixelSize: path.flatMap(Self.pixelSize(atPath:)), noun: noun)
            await postFileProblem(notice)
        case .tooLarge(let path):
            let notice = ProblemNotice.tooLarge(path: path, displayName: displayName, pixelSize: path.flatMap(Self.pixelSize(atPath:)), noun: noun)
            await postFileProblem(notice)
        case .scanFailed(let path):
            await postFileProblem(ProblemNotice.scanFailed(path: path, displayName: displayName, noun: noun))
        case .unreadable(let path):
            await postFileProblem(ProblemNotice.unreadable(path: path, displayName: displayName))
        case .incomplete(let path):
            await postFileProblem(ProblemNotice.incomplete(path: path, displayName: displayName))
        case .severalFrames(let path):
            await postFileProblem(ProblemNotice.severalFrames(path: path, displayName: displayName))
        case .severalFiles:
            await postFileProblem(ProblemNotice.severalFiles())
        case .copiedFileNotGuarded:
            await postFileProblem(ProblemNotice.copiedFileNotGuarded())
        case .writeFailed(let path):
            let entry = await entry(forPath: path, displayName: displayName)
            let facts = entry.flatMap(CatchFacts.init(entry:))
            let secrets: String? = facts.map {
                $0.findingCount == 1 ? String(localized: "the \($0.inSentenceNames.first ?? "")") : String(localized: "\($0.findingCount) secrets")
            }
            let readOnly = path.map { FileManager.default.fileExists(atPath: $0) && !FileManager.default.isWritableFile(atPath: $0) } ?? false
            let notice = ProblemNotice.writeFailed(path: path, displayName: displayName, entryID: entry?.id, secrets: secrets,
                                                   readOnly: readOnly, keepBoth: entry?.cleanCopyPath != nil)
            await postFileProblem(notice)
        }
    }

    func postCatch(_ facts: CatchFacts) async {
        let at = now()
        switch batcher.add(facts, at: at) {
        case .single:
            await deliverCatch(facts, at: at)
        case .summary(let identifier, let items, let since, let withdraw, let first):
            if !withdraw.isEmpty { client.removeDelivered(withdraw) }
            var plan = NotificationCopy.summaryPlan(identifier: identifier, items: items, since: since, now: at, first: first)
            // A new catch folded into the summary is still a catch: it sounds when every catch does (G-19 #8).
            plan.sound = model.settings.catchSound
            await deliver(plan)
        }
    }

    /// One catch's banner: silent unless `Settings.catchSound` (G-19 #8), with the clean crop of the finding as its
    /// picture (G-19 #10). The crop's temporary file goes once the request is handed over, whether or not it was.
    func deliverCatch(_ facts: CatchFacts, at: Date) async {
        var plan = NotificationCopy.catchPlan(facts, retentionHours: model.settings.journalRetention.hours, now: at)
        plan.sound = model.settings.catchSound
        if model.settings.showsNotifications {
            plan.pictureFile = await CatchPicture.write(entryID: facts.entryID, journal: model.journal, directory: pictureDirectory)
        }
        defer { if let file = plan.pictureFile { try? FileManager.default.removeItem(at: file) } }
        await deliver(plan)
    }

    /// Where catch pictures are written before posting (tests point it at their own folder).
    var pictureDirectory = FileManager.default.temporaryDirectory

    /// One file's problem: alone it is its own sounded alert; with others in the same minute, one combined alert.
    func postFileProblem(_ notice: ProblemNotice) async {
        switch problemBatcher.add(notice, at: now()) {
        case .single:
            await deliver(NotificationCopy.problemPlan(notice))
        case .combined(let identifier, let family, let notices, let first, let withdraw):
            if !withdraw.isEmpty { client.removeDelivered(withdraw) }
            await deliver(NotificationCopy.combinedProblemPlan(identifier: identifier, family: family, notices: notices, first: first))
        }
    }

    func postProblem(_ problem: Problem) async {
        guard postedProblems[problem.id] == nil,
              let notice = ProblemNotice.from(problem, downloads: Self.downloadsFolder, extraFolders: model.settings.extraFolders) else { return }
        let plan = NotificationCopy.problemPlan(notice)
        if await deliver(plan) { postedProblems[problem.id] = plan.identifier }
    }

    func reconcileProblems(_ problems: [Problem]) async {
        let current = Set(problems.map(\.id))
        let cleared = postedProblems.filter { !current.contains($0.key) }
        if !cleared.isEmpty {
            client.removeDelivered(Array(cleared.values))
            cleared.keys.forEach { postedProblems.removeValue(forKey: $0) }
        }
        for problem in problems { await postProblem(problem) }
    }

    // MARK: Delivery

    /// Posts one plan if the user wants notifications and macOS will deliver them. Asks permission lazily, the first
    /// time something is actually posted. Returns whether the request was handed to macOS.
    @discardableResult
    func deliver(_ plan: NotificationPlan) async -> Bool {
        guard model.settings.showsNotifications else { return false }
        var snapshot = await deliverySnapshot()
        if DeliveryMode(snapshot) == .undetermined {
            await client.requestAuthorization()
            snapshot = await deliverySnapshot()
        }
        guard DeliveryMode(snapshot).posts else {
            Log.app.info("notification not posted: delivery off")
            return false
        }
        // Obscura's sounds switched off in System Settings: no plan asks for one (macOS would drop it anyway).
        var plan = plan
        if !snapshot.playsSounds { plan.sound = false }
        do {
            try await client.add(plan)
            return true
        } catch {
            Log.app.error("notification add failed")
            return false
        }
    }

    /// Reads the delivery settings and mirrors the quiet state into `model.focusHolding`.
    func deliveryMode() async -> DeliveryMode {
        DeliveryMode(await deliverySnapshot())
    }

    /// The delivery settings, with the quiet state mirrored into `model.focusHolding`.
    private func deliverySnapshot() async -> DeliverySnapshot {
        let snapshot = await client.snapshot()
        let mode = DeliveryMode(snapshot)
        if model.focusHolding != mode.holdsBanners { model.focusHolding = mode.holdsBanners }
        return snapshot
    }

    // MARK: Responses

    func perform(_ response: NotificationResponse) async {
        switch response {
        case .nothing:
            return
        case .undo(let id):
            // Asks first when the user wants that (G-19 #11); a cancelled Undo leaves the banner and summary as they are.
            guard await model.mayUndo([id]) else { return }
            await model.restoreOriginal(id)
            // A summary that named this catch is put right (quietly), or withdrawn if it was the last one.
            switch batcher.remove(entryID: id) {
            case .none:
                break
            case .update(let identifier, let items, let since):
                await deliver(NotificationCopy.summaryPlan(identifier: identifier, items: items, since: since, now: now(), first: false))
            case .withdraw(let identifier):
                client.removeDelivered([identifier])
            }
            if let entry = try? await model.journal.entry(id), let facts = CatchFacts(entry: entry), facts.restoreTargetName != nil {
                await deliver(NotificationCopy.restoredPlan(facts))
            }
        case .blackOutAgain(let id):
            await model.blackOutAll(id)
            if let entry = try? await model.journal.entry(id), let facts = CatchFacts(entry: entry) {
                await deliverCatch(facts, at: now())
            }
        case .review(let id):
            model.router?.openViewer(entryID: id)
        case .openJournal:
            model.router?.openJournal(selecting: nil)
        case .openNotChecked:
            model.router?.openJournal(.notChecked)
        case .openSettings(let pane):
            model.router?.openSettings(pane)
        case .openFilesAndFoldersPrivacy:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                NSWorkspace.shared.open(url)
            }
        case .stopWatchingDownloads:
            model.updateSettings { $0.guardsDownloads = false }
        case .stopWatchingFolder(let folder):
            model.updateSettings { $0.extraFolders.removeAll { $0 == folder } }
        case .checkAgain(let path):
            if let rescan { rescan(URL(fileURLWithPath: path)) }
            else { Log.app.error("check again requested but no rescan hook is wired") }
        case .showInFinder(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .copyClean(let id):
            await model.copy(id, original: false)
        case .installUpdate:
            model.router?.installUpdate()
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Banners show even while an Obscura window is frontmost; a notification sounds only when its plan carried a sound
    /// (problems always, catches when `Settings.catchSound` is on, G-19 #8); a quiet update of a summary or a combined
    /// alert goes to the list only, with no new banner.
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        if content.interruptionLevel == .passive { return [.list] }
        return content.sound != nil ? [.banner, .list, .sound] : [.banner, .list]
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo
        var info: [String: String] = [:]
        for (key, value) in raw { if let k = key as? String, let v = value as? String { info[k] = v } }
        let action = response.actionIdentifier
        let kind = info[NotifyKey.kind].flatMap(NoticeKind.init(rawValue:))
        let route = NotificationRouting.route(kind: kind, action: action, userInfo: info,
                                              defaultAction: UNNotificationDefaultActionIdentifier)
        await perform(route)
    }

    // MARK: Helpers

    static var downloadsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Pixel size from the image header only; nil when it cannot be read.
    nonisolated static func pixelSize(atPath path: String) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// The Journal entry a failed write belongs to: the newest entry for that file.
    private func entry(forPath path: String?, displayName: String) async -> Entry? {
        guard let path else {
            return try? await model.journal.entries(matching: EntryQuery(search: displayName, limit: 1)).first
        }
        let candidates = (try? await model.journal.entries(matching: EntryQuery(search: displayName, limit: 10))) ?? []
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return candidates.first { entry in
            entry.filePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == resolved } ?? false
        }
    }
}

// MARK: - The UserNotifications seam

/// The calls the notifier makes on the notification centre. The system one wraps `UNUserNotificationCenter`; tests
/// substitute a recorder, since a test process cannot post real notifications.
@MainActor
protocol NotificationClient: AnyObject {
    func register(_ categories: [CategorySpec])
    func snapshot() async -> DeliverySnapshot
    func requestAuthorization() async
    func add(_ plan: NotificationPlan) async throws
    func removeDelivered(_ identifiers: [String])
}

@MainActor
final class SystemNotificationClient: NotificationClient {
    private let center: UNUserNotificationCenter

    init(_ center: UNUserNotificationCenter) { self.center = center }

    func register(_ categories: [CategorySpec]) {
        let set = Set(categories.map { spec in
            UNNotificationCategory(identifier: spec.identifier,
                                   actions: spec.actions.map {
                                       UNNotificationAction(identifier: $0.identifier, title: $0.title,
                                                            options: $0.foreground ? [.foreground] : [])
                                   },
                                   intentIdentifiers: [], options: [])
        })
        center.setNotificationCategories(set)
    }

    func snapshot() async -> DeliverySnapshot {
        let s = await center.notificationSettings()
        let auth: DeliverySnapshot.Authorization
        switch s.authorizationStatus {
        case .notDetermined: auth = .notDetermined
        case .denied: auth = .denied
        default: auth = .authorized
        }
        return DeliverySnapshot(authorization: auth,
                                showsOnScreen: s.alertSetting == .enabled && s.alertStyle != .none,
                                keepsInCentre: s.notificationCenterSetting == .enabled,
                                playsSounds: s.soundSetting == .enabled)
    }

    func requestAuthorization() async {
        do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
        catch { Log.app.error("notification authorization request failed") }
    }

    func add(_ plan: NotificationPlan) async throws {
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.body = plan.deliveredBody
        content.threadIdentifier = plan.threadIdentifier
        if let category = plan.categoryIdentifier { content.categoryIdentifier = category }
        content.sound = plan.sound ? .default : nil
        switch plan.level {
        case .passive: content.interruptionLevel = .passive
        case .active: content.interruptionLevel = .active
        // Needs the com.apple.developer.usernotifications.time-sensitive entitlement on the app target; without it
        // macOS delivers the alert as .active.
        case .timeSensitive: content.interruptionLevel = .timeSensitive
        }
        var info: [String: String] = plan.userInfo
        info[NotifyKey.kind] = plan.kind.rawValue
        content.userInfo = info
        // The clean crop (G-19 #10). macOS moves the file into its own store when the request is added; the notifier
        // deletes whatever is left either way. A picture macOS refuses leaves the banner without one.
        if let file = plan.pictureFile {
            do {
                content.attachments = [try UNNotificationAttachment(identifier: "crop", url: file,
                                                                    options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier])]
            } catch {
                Log.app.error("catch picture not attached")
            }
        }
        try await center.add(UNNotificationRequest(identifier: plan.identifier, content: content, trigger: nil))
    }

    func removeDelivered(_ identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
