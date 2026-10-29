// The panel's clicks: each action reaches the model or the router, and nothing else.
import Foundation
import Testing
import ObscuraUIKit
import ObscuraJournal
import ObscuraPrefs
import ObscuraTestSupport
@testable import ObscuraMenuBarUI

@MainActor
@Suite struct PanelActionTests {
    /// A model with no engine; the router is held here because AppModel keeps it weakly.
    @MainActor
    struct Fixture {
        let router = RecordingRouter()
        let store: InMemorySettingsStore
        let model: AppModel
        let memory: PanelMemory

        @MainActor
        init(settings: ObscuraPrefs.Settings = TestData.settings()) throws {
            store = InMemorySettingsStore(settings)
            model = AppModel(engine: nil, journal: try SampleData.makeJournal(), settings: store, router: router,
                             now: { TestData.now })
            memory = TestData.memory()
            PanelMemory.register(memory, for: model)
        }

        var performer: PanelActionPerformer { PanelActionPerformer(model: model, memory: memory, calendar: TestData.calendar) }
    }

    @Test func routerActionsAreRecorded() async throws {
        let f = try Fixture()
        let id = UUID()
        for action: PanelAction in [.review(id), .openJournal, .openJournalNotChecked, .openSettings(.protection), .openSettings(.customRules), .openSetup,
                                    .checkForUpdates, .installUpdate, .quit] {
            await f.performer.perform(action)
        }
        #expect(f.router.calls == ["viewer:\(id.uuidString)", "journal:-", "journal:notChecked", "settings:protection", "settings:customRules", "setup",
                                   "updates", "installUpdate", "quit"])
    }

    @Test func everyMenuRowReachesTheRouter() async throws {
        let f = try Fixture()
        let snapshot = PanelSnapshot.make(TestData.inputs())
        for item in snapshot.menu {
            if case .row(let row) = item, case .action(let action) = row.kind { await f.performer.perform(action) }
        }
        #expect(f.router.calls == ["journal:-", "settings:protection", "setup", "updates", "quit"])
    }

    @Test func pausePersistsItsEndAndResumeClearsIt() async throws {
        let f = try Fixture()
        await f.performer.perform(.pause(.oneHour), now: TestData.now)
        #expect(f.store.current().pausedUntil == TestData.now.addingTimeInterval(3600))
        #expect(f.memory.pauseChoice == .oneHour)
        #expect(f.model.pause == PauseState(since: TestData.now, resumesAt: TestData.now.addingTimeInterval(3600)))
        #expect(f.model.resumeScheduledAt == TestData.now.addingTimeInterval(3600))

        await f.performer.perform(.resume)
        #expect(f.store.current().pausedUntil == nil)
        #expect(f.model.pause == nil && f.model.resumeScheduledAt == nil)

        await f.performer.perform(.pause(.untilResumed), now: TestData.now)
        #expect(f.store.current().pausedUntil == .distantFuture)
        #expect(f.model.pause == PauseState(since: TestData.now, resumesAt: nil))
        #expect(f.model.resumeScheduledAt == nil)
        #expect(f.memory.pauseChoice == .untilResumed)
    }

    @Test func thePauseChoiceIsRememberedAcrossLaunches() {
        let defaults = TestDefaults("panel-memory").defaults
        let first = PanelMemory(defaults: defaults, now: TestData.now)
        first.choosePause(.untilTomorrow)
        first.markSeen(TestData.date(9, 50))
        let second = PanelMemory(defaults: defaults, now: TestData.date(11, 0))
        #expect(second.pauseChoice == .untilTomorrow)
        #expect(second.lastSeen == TestData.date(9, 50))
    }

    @Test func stopWatchingTurnsOffOnlyThatFolder() async throws {
        let f = try Fixture()
        await f.performer.perform(.stopWatching(.extra("~/Projects/example")))
        #expect(f.store.current().extraFolders.isEmpty)
        #expect(f.store.current().guardsDownloads && f.store.current().guardsScreenshotFolder)
        await f.performer.perform(.stopWatching(.downloads))
        #expect(!f.store.current().guardsDownloads)
        await f.performer.perform(.stopWatching(.screenshotFolder))
        #expect(!f.store.current().guardsScreenshotFolder)
    }

    @Test func theUpdateBannerButtonsReachTheRouter() async throws {
        let f = try Fixture()
        f.model.updateOffer = UpdateOffer(version: "1.1")
        let banner = try #require(PanelSnapshot.make(TestData.inputs(updateOffer: f.model.updateOffer)).banners.first)
        for button in banner.buttons { await f.performer.perform(button.action) }
        #expect(f.router.calls == ["installUpdate", "dismissUpdate"])
    }

    @Test func checkingPeakFollowsTheQueue() {
        let memory = TestData.memory()
        memory.observeChecking(3)
        memory.observeChecking(2)
        #expect(memory.checkingPeak == 3)
        memory.observeChecking(0)
        #expect(memory.checkingPeak == 0)
    }

    @Test func theCountBadgeCountsUnseenCatchesOnlyWhenNotificationsAreOff() async throws {
        let f = try Fixture(settings: TestData.settings { $0.showsNotifications = false })
        try await SampleData.seed(f.model.journal, count: 3)
        await f.model.reloadEntries()
        f.memory.markSeen(.distantPast)
        f.model.start()
        #expect(await eventually { !f.model.settings.showsNotifications })
        #expect(MenuBarLabel.badgeCount(model: f.model, memory: f.memory) == 3)
        f.memory.isPanelOpen = true
        #expect(MenuBarLabel.badgeCount(model: f.model, memory: f.memory) == 0)
        f.memory.isPanelOpen = false
        f.memory.markSeen(Date().addingTimeInterval(1))
        #expect(MenuBarLabel.badgeCount(model: f.model, memory: f.memory) == 0)
        f.model.stop()
    }
}
