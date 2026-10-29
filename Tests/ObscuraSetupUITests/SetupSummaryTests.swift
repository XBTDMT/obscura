import Foundation
import Testing
import ObscuraCapture
import ObscuraPrefs
import ObscuraUIKit
@testable import ObscuraSetupUI

/// G-19 M-19: the panel's setup card reads setup's progress by the rail's own rules and asks macOS nothing new.
@Suite @MainActor struct SetupSummaryTests {
    @Test func aFreshSetupIsNoneOfNineAndAsksNothing() async {
        let mac = FakeMac()
        let summary = await SetupSummaryReader.current(settings: .default, system: mac.system)
        #expect(summary == SetupSummary(done: 0, total: 9, next: "The catch"))
        #expect(mac.probes.isEmpty, "no folder is probed before its step: probing is the macOS prompt")
    }

    @Test func partlyDoneMatchesTheRail() async {
        let mac = FakeMac()
        var settings = Settings.default
        settings.setupStepsSeen = [SetupStep.theCatch, .welcome, .screenshotFolder, .downloads].map(\.rawValue)
        let summary = await SetupSummaryReader.current(settings: settings, system: mac.system)
        // The rail's own case: "4 of 9 done · Next: Floating thumbnail" (SetupTests.partlyDoneResumesAtTheFirstUnfinishedRow).
        #expect(summary == SetupSummary(done: 4, total: 9, next: "Floating thumbnail"))
        #expect(mac.probes == [mac.desktop], "only the passed screenshot step is probed again")
    }

    @Test func theWindowAndTheCardReadTheMacTheSameWay() async throws {
        let mac = FakeMac()
        mac.thumbnail = false
        var settings = Settings.default
        settings.setupStepsSeen = [SetupStep.theCatch, .welcome, .screenshotFolder].map(\.rawValue)
        let flow = try await makeFlow(mac, settings: settings)
        await flow.start()
        let summary = await SetupSummaryReader.current(settings: flow.model.settings, system: mac.system)
        #expect(summary.done == flow.progress.finishedCount)
        #expect(summary.next == flow.progress.resumeStep.title)
    }

    @Test func everyRowFinishedNamesNoNextStep() {
        var settings = Settings.default
        settings.hasFinishedSetup = true
        let snapshot = SetupSnapshot(screenshotFolder: URL(filePath: "/home/example/Desktop"), downloadsFolder: URL(filePath: "/home/example/Downloads"),
                                     screenshotAccess: .granted, downloadsAccess: .granted, floatingThumbnailEnabled: false,
                                     notifications: .granted, loginItem: .enabled)
        settings.guardsDownloads = true
        let summary = SetupProgress(snapshot: snapshot, settings: settings).summary
        #expect(summary.done == 9 && summary.total == 9 && summary.next == nil)
    }
}

/// G-21: setup's "Pick your menu bar icon" step: present, counted, resumable, and applied to the menu bar at once.
@Suite @MainActor struct MenuBarIconStepTests {
    let snapshot = SetupSnapshot(screenshotFolder: URL(filePath: "/tmp/d"), downloadsFolder: URL(filePath: "/tmp/dl"),
                                 screenshotAccess: .granted, floatingThumbnailEnabled: false, notifications: .granted, loginItem: .enabled)

    @Test func theStepSitsBeforeDoneAndCountsLikeEveryRow() {
        #expect(SetupStep.menuBarIcon.next == .done)
        #expect(SetupStep.openAtLogin.next == .menuBarIcon)
        #expect(SetupStep.menuBarIcon.title == "Menu bar icon")
        #expect(!SetupStep.menuBarIcon.isOptional)
        let fresh = SetupProgress(snapshot: snapshot, settings: .default)
        #expect(fresh.state(.menuBarIcon) == .pending)
        let passed = SetupProgress(snapshot: snapshot, settings: .default, seen: [.menuBarIcon])
        #expect(passed.state(.menuBarIcon) == .done)
        #expect(passed.finishedCount == fresh.finishedCount + 1)
    }

    @Test func setupResumesAtTheStepUntilItIsPassed() {
        // Every other row before it passed: the window reopens on the icon step.
        let before: Set<SetupStep> = [.theCatch, .welcome, .screenshotFolder, .downloads, .floatingThumbnail, .notifications, .openAtLogin]
        let p = SetupProgress(snapshot: snapshot, settings: .default, seen: before)
        #expect(p.resumeStep == .menuBarIcon)
        #expect(p.summary.next == "Menu bar icon")
        let after = SetupProgress(snapshot: snapshot, settings: .default, seen: before.union([.menuBarIcon]))
        #expect(after.resumeStep == .done)
    }

    @Test func aSetupFinishedBeforeTheStepExistedCountsItDone() {
        var settings = Settings.default
        settings.hasFinishedSetup = true
        #expect(SetupProgress(snapshot: snapshot, settings: settings).state(.menuBarIcon) == .done,
                "a finished setup does not reopen on a new row")
    }

    @Test func passingTheStepIsRememberedAcrossAReopen() async throws {
        let mac = FakeMac()
        let flow = try await makeFlow(mac)
        flow.preset(step: .menuBarIcon)
        flow.advance()
        #expect(flow.current == .done)
        #expect(flow.model.settings.setupStepsSeen.contains(SetupStep.menuBarIcon.rawValue), "setup.stepsSeen keeps it")
        let reopened = SetupFlow(model: flow.model, system: mac.system, runDemo: { nil })
        #expect(reopened.state(.menuBarIcon) == .done)
    }

    @Test func pickingAppliesToTheSettingsAtOnce() async throws {
        let mac = FakeMac()
        let flow = try await makeFlow(mac)
        #expect(flow.model.settings.menuBarMark == .classic, "a fresh install shows the Classic ring until the user picks")
        flow.model.updateSettings { $0.menuBarMark = .pixelatedHalf }
        flow.model.updateSettings { $0.menuBarMarkStyle = .glass }
        #expect(flow.model.settings.menuBarMark == .pixelatedHalf && flow.model.settings.menuBarMarkStyle == .glass)
    }
}
