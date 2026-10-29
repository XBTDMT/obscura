import AppKit
import Foundation
import SwiftUI
import Testing
import ObscuraCapture
import ObscuraPrefs
import ObscuraUIKit
@testable import ObscuraSetupUI

/// A Mac that answers from fields, so no test raises a real prompt.
@MainActor
final class FakeMac {
    var screenshotAccess: FolderAccessState = .granted
    var downloadsAccess: FolderAccessState = .granted
    var thumbnail = true
    var notifications: NotificationPermission = .notDetermined
    var notificationsAfterRequest: NotificationPermission = .granted
    /// macOS refusing to ask at all (UNErrorDomain), as an ad-hoc or misregistered bundle can see.
    var notificationsRequestRefused = false
    var login: LoginItemStatus = .disabled
    var loginAfterEnable: LoginItemStatus = .requiresApproval
    var opened: [URL] = []
    var probes: [URL] = []
    var loginItemsOpened = 0

    let desktop = URL(filePath: "/home/example/Desktop", directoryHint: .isDirectory)
    var downloads = URL(filePath: "/home/example/Downloads", directoryHint: .isDirectory)

    var system: SetupSystem {
        SetupSystem(
            screenshotFolder: { self.desktop },
            downloadsFolder: { self.downloads },
            probeFolder: { url in
                self.probes.append(url)
                return url == self.desktop ? self.screenshotAccess : self.downloadsAccess
            },
            floatingThumbnailEnabled: { self.thumbnail },
            notificationPermission: { self.notifications },
            requestNotifications: {
                if self.notificationsRequestRefused { throw CocoaError(.featureUnsupported) }
                self.notifications = self.notificationsAfterRequest
                return self.notifications
            },
            loginItemStatus: { self.login },
            setLoginItem: { on in self.login = on ? self.loginAfterEnable : .disabled },
            openLoginItems: { self.loginItemsOpened += 1 },
            openURL: { self.opened.append($0) },
            bundleIdentifier: "app.obscura.tests"
        )
    }
}

@MainActor
func makeFlow(_ mac: FakeMac, settings: ObscuraPrefs.Settings = .default, demo: (@Sendable (UUID) -> (entryID: UUID, durationMS: Int)?)? = nil)
    async throws -> SetupFlow {
    let model = try await SampleData.model(entries: 1, settings: settings)
    let id = model.entries.first?.id ?? UUID()
    let run: @Sendable () async -> (entryID: UUID, durationMS: Int)? = { demo.map { $0(id) } ?? (entryID: id, durationMS: 212) }
    return SetupFlow(model: model, system: mac.system, runDemo: run)
}

@MainActor
@Suite struct SetupOrderAndResumeTests {
    let snapshot = SetupSnapshot(screenshotFolder: URL(filePath: "/tmp/d"), downloadsFolder: URL(filePath: "/tmp/dl"))

    @Test func stepOrderMatchesTheRail() {
        #expect(SetupStep.allCases == [.theCatch, .welcome, .screenshotFolder, .downloads, .floatingThumbnail,
                                       .notifications, .openAtLogin, .menuBarIcon, .done])
        #expect(SetupGroup.catchFirst.steps == [.theCatch, .welcome])
        #expect(SetupGroup.allow.steps == [.screenshotFolder, .downloads, .floatingThumbnail])
        #expect(SetupGroup.keep.steps == [.notifications, .openAtLogin, .menuBarIcon, .done])
        #expect(SetupStep.allCases.filter(\.isOptional) == [.downloads])
        #expect(SetupStep.openAtLogin.settingsHome == .about)
        #expect(SetupStep.menuBarIcon.settingsHome == .about, "the picker lives in Settings → About afterwards")
        #expect(SetupStep.notifications.settingsHome == .protection)
    }

    @Test func firstRunResumesAtTheCatch() {
        let p = SetupProgress(snapshot: snapshot, settings: .default)
        #expect(p.resumeStep == .theCatch)
        #expect(p.finishedCount == 0)
        #expect(SetupStep.allCases.allSatisfy { p.state($0) == .pending })
    }

    @Test func partlyDoneResumesAtTheFirstUnfinishedRow() {
        var s = snapshot
        s.screenshotAccess = .granted
        let p = SetupProgress(snapshot: s, settings: .default, seen: [.theCatch, .welcome, .screenshotFolder, .downloads])
        #expect(p.state(.downloads) == .skipped)
        #expect(p.resumeStep == .floatingThumbnail)
        #expect(p.finishedCount == 4)  // "4 of 9 done · Next: Floating thumbnail"
    }

    @Test func finishedSetupResumesAtTheFirstRefusalRedBeforeOrange() {
        var settings = ObscuraPrefs.Settings.default
        settings.hasFinishedSetup = true
        var s = snapshot
        s.screenshotAccess = .granted
        s.floatingThumbnailEnabled = false
        s.notifications = .granted
        s.loginItem = .enabled
        #expect(SetupProgress(snapshot: s, settings: settings).resumeStep == .done)

        s.loginItem = .requiresApproval
        #expect(SetupProgress(snapshot: s, settings: settings).resumeStep == .openAtLogin)
        s.screenshotAccess = .denied
        let p = SetupProgress(snapshot: s, settings: settings)
        #expect(p.state(.screenshotFolder) == .unprotected)
        #expect(p.resumeStep == .screenshotFolder)
    }

    @Test func refusalsAreOrangeExceptAnUnreadScreenshotFolder() {
        var s = snapshot
        s.screenshotAccess = .denied
        s.downloadsAccess = .denied
        s.notifications = .denied
        s.loginItem = .requiresApproval
        let seen = Set(SetupStep.allCases)
        let p = SetupProgress(snapshot: s, settings: .default, seen: seen)
        #expect(p.state(.screenshotFolder) == .unprotected)
        #expect(p.state(.downloads) == .declined)
        #expect(p.state(.floatingThumbnail) == .declined)
        #expect(p.state(.notifications) == .declined)
        #expect(p.state(.openAtLogin) == .declined)
        #expect(p.state(.done) == .pending)
    }

    @Test func choosingOffIsSkippedNotRefused() {
        var settings = ObscuraPrefs.Settings.default
        settings.showsNotifications = false
        var s = snapshot
        s.notifications = .denied
        #expect(SetupProgress(snapshot: s, settings: settings, seen: [.notifications]).state(.notifications) == .skipped)
    }

    @Test func aFailedDemoMarksTheCatchOrange() {
        let p = SetupProgress(snapshot: snapshot, settings: .default, seen: [.theCatch], demoFailed: true)
        #expect(p.state(.theCatch) == .declined)
    }
}

@MainActor
@Suite struct SetupFlowTests {
    @Test func startOpensAtTheCatchAndRunsTheDemo() async throws {
        let mac = FakeMac()
        let flow = try await makeFlow(mac)
        await flow.start()
        #expect(flow.current == .theCatch)
        #expect(mac.probes.isEmpty)  // a first run never asks for a folder before its own step
        await flow.runTestShot()
        let result = try #require(flow.demo.result)
        #expect(result.secrets == 4)
        #expect(result.durationMS == 212)
        #expect(result.clean != nil && result.original != nil)
    }

    @Test func demoFailureState() async throws {
        let flow = try await makeFlow(FakeMac(), demo: { _ in nil })
        flow.preset(step: .theCatch)
        await flow.runTestShot()
        guard case .failed(.didNotRun) = flow.demo else { Issue.record("expected the failure state"); return }
        #expect(flow.state(.theCatch) == .declined)
    }

    @Test func demoThatCatchesNothingIsAFailure() async throws {
        let flow = try await makeFlow(FakeMac(), demo: { _ in (entryID: UUID(), durationMS: 90) })
        await flow.runTestShot()
        guard case .failed(.nothingCaught) = flow.demo else { Issue.record("expected nothing caught"); return }
    }

    @Test func reRunResumesFromSettingsAndProbesFolders() async throws {
        let mac = FakeMac()
        mac.screenshotAccess = .denied
        mac.thumbnail = false
        mac.notifications = .granted
        mac.login = .enabled
        var settings = ObscuraPrefs.Settings.default
        settings.hasFinishedSetup = true
        let flow = try await makeFlow(mac, settings: settings)
        await flow.start()
        #expect(mac.probes == [mac.desktop])
        #expect(flow.current == .screenshotFolder)
    }

    @Test func nextWalksTheRailInOrder() async throws {
        let flow = try await makeFlow(FakeMac())
        flow.preset(step: .welcome)
        var visited: [SetupStep] = [.welcome]
        while let c = flow.current, c != .done { flow.advance(); visited.append(flow.current!) }
        #expect(visited == Array(SetupStep.allCases.dropFirst()))
        #expect(flow.state(.welcome) == .done)
    }

    @Test func allowingFoldersWritesTheGuards() async throws {
        let mac = FakeMac()
        // A Downloads folder that exists: allowing it in setup confirms it for Obscura (G-36), which needs a real folder.
        let downloads = FileManager.default.temporaryDirectory.appendingPathComponent("obscura-setup-dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: downloads) }
        mac.downloads = downloads
        let flow = try await makeFlow(mac)
        flow.allowScreenshotFolder()
        await flow.allowDownloads()
        #expect(flow.snapshot.screenshotAccess == .granted)
        #expect(flow.model.settingsStore.current().guardsDownloads)
        #expect(flow.model.unconfirmedFolders.isEmpty)
        mac.downloadsAccess = .denied
        await flow.allowDownloads()
        #expect(flow.state(.downloads) == .declined)
    }

    @Test func notificationsAndLogin() async throws {
        let mac = FakeMac()
        let flow = try await makeFlow(mac)
        await flow.requestNotifications()
        #expect(flow.state(.notifications) == .done)
        flow.setOpenAtLogin(true)
        #expect(flow.snapshot.loginItem == .requiresApproval)
        #expect(flow.state(.openAtLogin) == .declined)
        flow.openLoginItems()
        #expect(mac.loginItemsOpened == 1)
        flow.openNotificationSettings()
        #expect(mac.opened.last?.absoluteString.contains("app.obscura.tests") == true)
    }

    @Test func thumbnailClosureIsCalledAndReadBack() async throws {
        let mac = FakeMac()
        let flow = try await makeFlow(mac)
        var calls: [Bool] = []
        await flow.setFloatingThumbnail(shown: false) { shown in calls.append(shown); mac.thumbnail = shown }
        #expect(calls == [false])
        #expect(flow.state(.floatingThumbnail) == .done)
    }

    @Test func finishSetsHasFinishedSetup() async throws {
        let flow = try await makeFlow(FakeMac())
        #expect(!flow.model.settingsStore.current().hasFinishedSetup)
        flow.preset(step: .done)
        var finished = false
        flow.finish { finished = true }
        #expect(flow.model.settingsStore.current().hasFinishedSetup)
        #expect(finished)
    }
}

@Suite @MainActor struct SetupResumePersistenceTests {
    @Test func passedStepsPersistAndAClosedSetupResumesThere() async throws {
        let model = try await SampleData.model(entries: 0)
        let mac = FakeMac()
        let first = SetupFlow(model: model, system: mac.system, runDemo: { nil })
        first.preset(step: .floatingThumbnail, seen: [.theCatch, .welcome, .screenshotFolder, .downloads])
        #expect(model.settings.setupStepsSeen == ["theCatch", "welcome", "screenshotFolder", "downloads"])

        // A new window (setup closed and reopened) reads the same steps back.
        let reopened = SetupFlow(model: model, system: mac.system, runDemo: { nil })
        #expect(reopened.seen == [.theCatch, .welcome, .screenshotFolder, .downloads])
    }

    @Test func aReopenedSetupRechecksFoldersItAlreadyAskedAndShowsThemGranted() async throws {
        var settings = ObscuraPrefs.Settings.default
        settings.guardsDownloads = true
        settings.setupStepsSeen = ["theCatch", "welcome", "screenshotFolder", "downloads", "floatingThumbnail", "notifications"]
        let mac = FakeMac()
        let flow = try await makeFlow(mac, settings: settings)
        await flow.start()
        #expect(mac.probes == [mac.desktop, mac.downloads])
        #expect(flow.state(.screenshotFolder) == .done)
        #expect(flow.state(.downloads) == .done)
    }

    @Test func aReopenedSetupNeverProbesAFolderNotReachedYet() async throws {
        var settings = ObscuraPrefs.Settings.default
        settings.guardsDownloads = true
        settings.setupStepsSeen = ["theCatch", "welcome"]
        let mac = FakeMac()
        let flow = try await makeFlow(mac, settings: settings)
        await flow.start()
        #expect(mac.probes.isEmpty)
    }
}

/// The notification step never leaves a dead button: macOS's answer, or its refusal to ask, always shows.
@MainActor
@Suite struct SetupNotificationRequestTests {
    @Test func aGrantedRequestTurnsNotificationsOn() async throws {
        let mac = FakeMac()
        let flow = try await makeFlow(mac, settings: { var s = ObscuraPrefs.Settings.default; s.showsNotifications = false; return s }())
        await flow.requestNotifications()
        #expect(flow.snapshot.notifications == .granted)
        #expect(flow.model.settings.showsNotifications)
        #expect(!flow.notificationsAsking)
        #expect(!flow.notificationsRequestFailed)
    }

    @Test func aRefusedRequestIsShownNotSwallowed() async throws {
        let mac = FakeMac()
        mac.notificationsRequestRefused = true
        let flow = try await makeFlow(mac)
        await flow.requestNotifications()
        #expect(flow.snapshot.notifications == .notDetermined)
        #expect(flow.notificationsRequestFailed)
        #expect(flow.notificationsRequestError == "NSCocoaErrorDomain 3328")
        #expect(!flow.notificationsAsking)
        flow.openNotificationSettings()
        #expect(mac.opened == [flow.system.notificationSettingsURL])
    }

    @Test func aRetryThatSucceedsClearsTheFailure() async throws {
        let mac = FakeMac()
        mac.notificationsRequestRefused = true
        let flow = try await makeFlow(mac)
        await flow.requestNotifications()
        mac.notificationsRequestRefused = false
        await flow.requestNotifications()
        #expect(!flow.notificationsRequestFailed)
        #expect(flow.notificationsRequestError == nil)
        #expect(flow.snapshot.notifications == .granted)
    }
}
