// The model's half of two redman gaps (2026-10-27): the pause is persisted and settled at start, and the update offer
// carries its version and install phase and lives and dies by checks, Install and Later (G-33).
import Testing
import Foundation
@testable import ObscuraUIKit
import ObscuraJournal
import ObscuraPrefs

/// A made-up instant; the model's clock is pinned to it.
private let fixedNow = Date(timeIntervalSinceReferenceDate: 815_000_000)

@MainActor
private func model(_ edit: (inout Settings) -> Void = { _ in }) throws -> (AppModel, InMemorySettingsStore, RecordingRouter) {
    var s = Settings.default
    edit(&s)
    let store = InMemorySettingsStore(s)
    let router = RecordingRouter()
    let model = AppModel(engine: nil, journal: try SampleData.makeJournal(), settings: store, router: router, ownsRouter: true,
                         now: { fixedNow })
    return (model, store, router)
}

@Suite @MainActor struct PausedUntilModelTests {
    @Test func startWithAFutureEndKeepsThePauseAndArmsTheResume() throws {
        let until = fixedNow.addingTimeInterval(3600)
        let (m, store, _) = try model { $0.pausedUntil = until }
        m.start()
        defer { m.stop() }
        #expect(store.current().pausedUntil == until)
        #expect(m.resumeScheduledAt == until)
        #expect(m.pause == PauseState(since: nil, resumesAt: until))
    }

    @Test func startWithAPastEndResumes() throws {
        let (m, store, _) = try model { $0.pausedUntil = fixedNow.addingTimeInterval(-1) }
        m.start()
        defer { m.stop() }
        #expect(store.current().pausedUntil == nil)
        #expect(m.settings.protectionPaused == false)
        #expect(m.pause == nil && m.resumeScheduledAt == nil)
    }

    @Test func startPausedUntilResumedStaysPausedWithNoTimer() throws {
        let (m, store, _) = try model { $0.pausedUntil = .distantFuture }
        m.start()
        defer { m.stop() }
        #expect(store.current().pausedUntil == .distantFuture)
        #expect(m.resumeScheduledAt == nil)
        #expect(m.pause == PauseState(since: nil, resumesAt: nil))
    }

    @Test func pauseForADurationWritesItsEnd() throws {
        let (m, store, _) = try model()
        m.pause(for: .seconds(15 * 60))
        #expect(store.current().pausedUntil == fixedNow.addingTimeInterval(900))
        #expect(m.pause == PauseState(since: fixedNow, resumesAt: fixedNow.addingTimeInterval(900)))
        m.pause(for: nil)
        #expect(store.current().pausedUntil == .distantFuture)
        #expect(m.resumeScheduledAt == nil)
        m.resume()
        #expect(store.current().pausedUntil == nil && m.pause == nil)
    }

    @Test func aPauseSetElsewhereMovesTheResume() async throws {
        let (m, store, _) = try model()
        m.start()
        defer { m.stop() }
        let until = fixedNow.addingTimeInterval(600)
        store.update { $0.pausedUntil = until }
        for _ in 0..<100 where m.resumeScheduledAt != until { try await Task.sleep(for: .milliseconds(10)) }
        #expect(m.resumeScheduledAt == until)
        store.update { $0.pausedUntil = nil }
        for _ in 0..<100 where m.resumeScheduledAt != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(m.resumeScheduledAt == nil)
    }
}

/// A stand-in for the app's updater: answers checks and installs from scripted results and records what it was asked.
@MainActor
final class FakeUpdateDriver: UpdateDriver {
    private(set) var calls: [String] = []
    var isAvailable = true
    var lastCheck: Date?
    var checkResult: UpdateCheckResult = .upToDate(version: "1.0")
    var installResult: UpdateInstallResult = .relaunching
    /// While set, install waits here, so a test can look at the "installing" state.
    var installGate: CheckedContinuation<Void, Never>?
    var holdInstall = false

    func recordCheck(at date: Date) { lastCheck = date }
    func check() async -> UpdateCheckResult {
        calls.append("check")
        return checkResult
    }
    func install() async -> UpdateInstallResult {
        calls.append("install")
        if holdInstall { await withCheckedContinuation { installGate = $0 } }
        return installResult
    }
}

@Suite @MainActor struct UpdateCoordinatorTests {
    static let offer = UpdateOffer(version: "1.1", releaseNotesURL: URL(string: "https://example.com/notes/1.1.html"))

    @Test func aScheduledCheckThatFindsAnUpdateShowsTheOfferAndNotifiesOnce() async throws {
        let (m, _, _) = try model()
        let driver = FakeUpdateDriver()
        driver.checkResult = .available(Self.offer)
        let c = UpdateCoordinator(model: m, driver: driver, now: { fixedNow })
        var posted: [String] = []
        c.onOffer = { posted.append($0.version) }
        #expect(await c.scheduledCheck())
        #expect(m.updateOffer == Self.offer)
        #expect(m.updateOffer?.phase == .ready)
        #expect(m.markState == .waiting)
        #expect(posted == ["1.1"])
        #expect(driver.lastCheck == fixedNow)
    }

    @Test func scheduledChecksRunAtMostOnceADay() async throws {
        let (m, _, _) = try model()
        let driver = FakeUpdateDriver()
        var clock = fixedNow
        let c = UpdateCoordinator(model: m, driver: driver, now: { clock })
        #expect(await c.scheduledCheck())
        clock = fixedNow.addingTimeInterval(23 * 3600)
        #expect(!(await c.scheduledCheck()), "within a day: no request")
        clock = fixedNow.addingTimeInterval(24 * 3600 + 1)
        #expect(await c.scheduledCheck())
        #expect(driver.calls == ["check", "check"])
    }

    @Test func scheduledChecksRespectTheSetting() async throws {
        let (m, _, _) = try model { $0.updatesCheckAutomatically = false }
        let driver = FakeUpdateDriver()
        let c = UpdateCoordinator(model: m, driver: driver, now: { fixedNow })
        #expect(!(await c.scheduledCheck()))
        #expect(driver.calls.isEmpty, "automatic checks off: nothing is fetched")
        // Check for Updates… still checks: it is the user asking.
        #expect(await c.checkForUpdates() == .upToDate(version: "1.0"))
        #expect(driver.calls == ["check"])
    }

    @Test func aFailedScheduledCheckChangesNothing() async throws {
        let (m, _, _) = try model()
        m.updateOffer = Self.offer
        let driver = FakeUpdateDriver()
        driver.checkResult = .failed(reason: "Obscura couldn't reach the update server (offline).")
        let c = UpdateCoordinator(model: m, driver: driver, now: { fixedNow })
        #expect(await c.scheduledCheck())
        #expect(m.updateOffer == Self.offer)
    }

    @Test func checkForUpdatesReportsEachOutcomeAndShowsAFoundUpdate() async throws {
        let (m, _, _) = try model()
        let driver = FakeUpdateDriver()
        let c = UpdateCoordinator(model: m, driver: driver, now: { fixedNow })
        var posted = 0
        c.onOffer = { _ in posted += 1 }
        driver.checkResult = .available(Self.offer)
        #expect(await c.checkForUpdates() == .available(Self.offer))
        #expect(m.updateOffer == Self.offer, "the banner holds it, so Install is one click away")
        #expect(posted == 0, "the user is looking at the answer: no notification")
        driver.checkResult = .upToDate(version: "1.1")
        #expect(await c.checkForUpdates() == .upToDate(version: "1.1"))
        #expect(m.updateOffer == nil)
        driver.checkResult = .failed(reason: "x")
        #expect(await c.checkForUpdates() == .failed(reason: "x"))
    }

    @Test func checkForUpdatesWithNoUpdaterSaysSo() async throws {
        let (m, _, _) = try model()
        let driver = FakeUpdateDriver()
        driver.isAvailable = false
        #expect(await UpdateCoordinator(model: m, driver: driver).checkForUpdates() == nil)
        #expect(driver.calls.isEmpty, "an unavailable updater is never asked")
        #expect(await UpdateCoordinator(model: m).checkForUpdates() == nil)
    }

    @Test func installGoesReadyToInstallingToRelaunching() async throws {
        let (m, _, _) = try model()
        let driver = FakeUpdateDriver()
        driver.holdInstall = true
        let c = UpdateCoordinator(model: m, driver: driver)
        m.updateOffer = Self.offer
        let task = Task { await c.install() }
        while driver.installGate == nil { await Task.yield() }
        #expect(m.updateOffer?.phase == .installing)
        await c.install()
        c.dismiss()
        #expect(driver.calls == ["install"], "a second Install while one runs is ignored")
        #expect(m.updateOffer?.phase == .installing, "Later does not interrupt an install")
        driver.installGate?.resume()
        await task.value
        #expect(m.updateOffer?.phase == .installing, "the app quits and relaunches from here")
    }

    @Test func aFailedInstallShowsItsReasonAndCanBeRetried() async throws {
        let (m, _, _) = try model()
        let driver = FakeUpdateDriver()
        driver.installResult = .failed(reason: "The app in the update isn't signed by the same developer as this copy, so Obscura discarded it.")
        let c = UpdateCoordinator(model: m, driver: driver)
        m.updateOffer = Self.offer
        await c.install()
        #expect(m.updateOffer?.phase == .failed(reason: "The app in the update isn't signed by the same developer as this copy, so Obscura discarded it."))
        #expect(m.updateOffer?.version == "1.1")
        driver.installResult = .relaunching
        await c.install()
        #expect(driver.calls == ["install", "install"])
        #expect(m.updateOffer?.phase == .installing)
    }

    @Test func laterClearsTheBannerUntilTheNextCheck() async throws {
        let (m, _, _) = try model()
        let driver = FakeUpdateDriver()
        driver.checkResult = .available(Self.offer)
        var clock = fixedNow
        let c = UpdateCoordinator(model: m, driver: driver, now: { clock })
        var posted = 0
        c.onOffer = { _ in posted += 1 }
        await c.scheduledCheck()
        c.dismiss()
        #expect(m.updateOffer == nil)
        clock = fixedNow.addingTimeInterval(25 * 3600)
        await c.scheduledCheck()
        #expect(m.updateOffer == Self.offer)
        #expect(posted == 2, "shown again after Later, so notified again")
    }

    @Test func withNothingOfferedInstallDoesNothing() async throws {
        let (m, _, _) = try model()
        let driver = FakeUpdateDriver()
        await UpdateCoordinator(model: m, driver: driver).install()
        #expect(driver.calls.isEmpty)
        #expect(m.updateOffer == nil)
    }

    @Test func theNotSetUpWordsAreSpecific() {
        #expect(UpdateCopy.notSetUpTitle.contains("aren't set up"))
        #expect(UpdateCopy.notSetUpBody.contains("Protection works as usual"))
        #expect(UpdateCopy.availableBody.contains("signed by the same developer"))
    }

    @Test func theRecordingRouterNamesBothBannerCalls() {
        let r = RecordingRouter()
        r.installUpdate()
        r.dismissUpdate()
        #expect(r.calls == ["installUpdate", "dismissUpdate"])
    }
}
