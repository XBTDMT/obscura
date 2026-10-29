import Foundation
import Testing
import ObscuraCapture
import ObscuraEngine
import ObscuraJournal
import ObscuraPrefs
import ObscuraUIKit
@testable import ObscuraNotifyUI

/// Records what the notifier would hand macOS.
@MainActor
final class RecordingClient: NotificationClient {
    var snapshotValue: DeliverySnapshot
    var grantOnRequest = true
    private(set) var categories: [CategorySpec] = []
    private(set) var added: [NotificationPlan] = []
    private(set) var removed: [String] = []
    private(set) var authorizationRequests = 0

    init(_ authorization: DeliverySnapshot.Authorization = .authorized, onScreen: Bool = true) {
        snapshotValue = DeliverySnapshot(authorization: authorization, showsOnScreen: onScreen, keepsInCentre: true)
    }

    func register(_ categories: [CategorySpec]) { self.categories = categories }
    func snapshot() async -> DeliverySnapshot { snapshotValue }
    func requestAuthorization() async {
        authorizationRequests += 1
        snapshotValue.authorization = grantOnRequest ? .authorized : .denied
    }
    /// The bytes of each plan's picture as they were when it was posted (the notifier deletes the file afterwards).
    private(set) var pictures: [Data?] = []
    func add(_ plan: NotificationPlan) async throws {
        added.append(plan)
        pictures.append(plan.pictureFile.flatMap { try? Data(contentsOf: $0) })
    }
    func removeDelivered(_ identifiers: [String]) { removed += identifiers }
}

@MainActor
@Suite struct NotifierTests {
    func makeNotifier(settings: ObscuraPrefs.Settings = .default, client: RecordingClient,
                      now: Date = Date()) async throws -> (Notifier, AppModel) {
        let model = try await SampleData.model(entries: 3, settings: settings)
        return (Notifier(model: model, client: client, now: { now }), model)
    }

    @Test func registersCategoriesAtInitButAsksPermissionOnlyOnFirstPost() async throws {
        let client = RecordingClient(.notDetermined)
        let (notifier, model) = try await makeNotifier(client: client)
        #expect(client.categories.contains { $0.identifier == NotifyID.catchCategory })
        #expect(client.authorizationRequests == 0)

        let entry = try #require(model.entries.first { $0.source == .file })
        await notifier.process(.caught(entryID: entry.id), displayName: entry.displayName)
        #expect(client.authorizationRequests == 1)
        #expect(client.added.count == 1)
        #expect(client.added.first?.identifier == entry.id.uuidString)
        #expect(client.added.first?.title == "4 secrets blacked out")
    }

    @Test func notificationsOffPostsNothing() async throws {
        var settings = ObscuraPrefs.Settings.default
        settings.showsNotifications = false
        let client = RecordingClient()
        let (notifier, model) = try await makeNotifier(settings: settings, client: client)
        for entry in model.entries { await notifier.process(.caught(entryID: entry.id), displayName: entry.displayName) }
        await notifier.process(.writeFailed(path: "/home/example/Desktop/a.png"), displayName: "a.png")
        await notifier.postProblem(Problem(kind: .folderAccess, messageKey: "problem.folder.denied",
                                           url: URL(fileURLWithPath: "/home/example/Desktop")))
        await notifier.deliver(NotificationCopy.updatePlan(version: "1.1"))
        #expect(client.added.isEmpty)
        #expect(client.authorizationRequests == 0)
    }

    @Test func deniedPermissionPostsNothing() async throws {
        let client = RecordingClient(.denied)
        let (notifier, model) = try await makeNotifier(client: client)
        let entry = try #require(model.entries.first)
        await notifier.process(.caught(entryID: entry.id), displayName: entry.displayName)
        #expect(client.added.isEmpty)
        #expect(model.focusHolding == false)
    }

    @Test func quietDeliverySetsFocusHolding() async throws {
        let client = RecordingClient(.authorized, onScreen: false)
        let (notifier, model) = try await makeNotifier(client: client)
        #expect(model.focusHolding == false)
        _ = await notifier.deliveryMode()
        #expect(model.focusHolding == true)
        client.snapshotValue.showsOnScreen = true
        _ = await notifier.deliveryMode()
        #expect(model.focusHolding == false)
    }

    @Test func aBurstOfThreeBecomesOneSummary() async throws {
        let client = RecordingClient()
        let (notifier, model) = try await makeNotifier(client: client)
        let files = model.entries.filter { $0.source == .file }
        let clip = try #require(model.entries.first { $0.source == .clipboard })
        #expect(files.count == 2)
        for e in files { await notifier.process(.caught(entryID: e.id), displayName: e.displayName) }
        await notifier.process(.caught(entryID: clip.id), displayName: clip.displayName)
        // Two file catches and one clipboard catch: different threads, so three singles.
        #expect(client.added.map(\.kind) == [.catchOne, .catchOne, .catchOne])
        await notifier.process(.caught(entryID: files[0].id), displayName: files[0].displayName)
        #expect(client.added.last?.kind == .summary)
        #expect(client.added.last?.title == "12 secrets blacked out")
        #expect(Set(client.removed) == Set(files.map(\.id.uuidString)))
        #expect(client.added.last?.level == .active, "the summary appears once")

        // S-15: the next catch updates it in place, quietly.
        await notifier.process(.caught(entryID: files[1].id), displayName: files[1].displayName)
        let summaryID = try #require(client.added.last?.identifier)
        #expect(client.added.last?.kind == .summary)
        #expect(client.added.last?.level == .passive)
        #expect(client.added.filter { $0.kind == .summary && $0.level != .passive }.count == 1)

        // S-17: an Undo from a banner takes its catch out of the summary.
        let before = client.added.count
        await notifier.perform(.undo(files[1].id))
        let fixed = try #require(client.added.dropFirst(before).first { $0.kind == .summary })
        #expect(fixed.identifier == summaryID)
        #expect(fixed.level == .passive)
    }

    @Test func theThumbnailHookDecidesTheScreenshotBanner() async throws {
        var settings = ObscuraPrefs.Settings.default
        settings.thumbnailEnabled = true
        let client = RecordingClient()
        let (notifier, model) = try await makeNotifier(settings: settings, client: client)
        let entry = try #require(model.entries.first { $0.source == .file })
        let shot = URL(fileURLWithPath: "/home/example/Desktop/\(entry.displayName)")
        let report = ScanReport(key: CaptureKey(file: shot), displayName: entry.displayName,
                                outcome: .redacted(entryID: entry.id, findings: 4, duration: .milliseconds(100)),
                                fileURL: shot, origin: .screenshotFolder)
        notifier.thumbnailClaims = { _ in false }
        notifier.handle(report)
        await notifier.drain()
        #expect(client.added.map(\.kind) == [.catchOne], "the thumbnail could not show it (another Space, no display, switched on mid-scan): the banner posts")
        notifier.thumbnailClaims = { _ in true }
        notifier.handle(report)
        await notifier.drain()
        #expect(client.added.count == 1, "the thumbnail shows it: no second notice")
    }

    @Test func aProblemAlertsOnceUntilItClears() async throws {
        let client = RecordingClient()
        let (notifier, _) = try await makeNotifier(client: client)
        let p = Problem(kind: .folderAccess, messageKey: "problem.folder.denied", url: URL(fileURLWithPath: "/home/example/Desktop"))
        await notifier.reconcileProblems([p])
        await notifier.reconcileProblems([p])
        #expect(client.added.count == 1)
        #expect(client.added.first?.sound == true)
        await notifier.reconcileProblems([])
        #expect(client.removed == [NotifyID.problemRequest(p.id)])
        await notifier.reconcileProblems([p])
        #expect(client.added.count == 2)
    }

    @Test func publicEntryPointsRunThroughTheSerialQueue() async throws {
        let client = RecordingClient()
        let (notifier, _) = try await makeNotifier(client: client)
        notifier.postUpdateAvailable(version: "1.1")
        notifier.post(problem: Problem(kind: .sourceStart, messageKey: "problem.source.start", detail: "ClipboardGuard"))
        await notifier.drain()
        #expect(client.added.map(\.kind) == [.update, .problem])
    }

    @Test func reviewOpensTheViewerThroughTheRouter() async throws {
        let client = RecordingClient()
        let (notifier, model) = try await makeNotifier(client: client)
        let router = RecordingRouter()   // the model holds its router weakly; the test keeps this one alive
        model.router = router
        let id = UUID()
        await notifier.perform(.review(id))
        await notifier.perform(.openSettings(.customRules))
        await notifier.perform(.installUpdate)
        #expect(router.calls == ["viewer:\(id.uuidString)", "settings:customRules", "installUpdate"])
    }

    @Test func stopWatchingTurnsTheFolderOff() async throws {
        var settings = ObscuraPrefs.Settings.default
        settings.guardsDownloads = true
        settings.extraFolders = ["/home/example/Shots", "/home/example/Other"]
        let client = RecordingClient()
        let (notifier, model) = try await makeNotifier(settings: settings, client: client)
        await notifier.perform(.stopWatchingDownloads)
        await notifier.perform(.stopWatchingFolder("/home/example/Shots"))
        #expect(model.settingsStore.current().guardsDownloads == false)
        #expect(model.settingsStore.current().extraFolders == ["/home/example/Other"])
    }

    @Test func checkAgainUsesTheRescanHook() async throws {
        let client = RecordingClient()
        let (notifier, _) = try await makeNotifier(client: client)
        var asked: [URL] = []
        notifier.rescan = { asked.append($0) }
        await notifier.perform(.checkAgain(path: "/home/example/Desktop/a.png"))
        #expect(asked == [URL(fileURLWithPath: "/home/example/Desktop/a.png")])
    }
}
