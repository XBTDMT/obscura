// Setup's progress for the menu bar panel's setup card (G-19 M-19): "Setup · 4 of 8 done · Next: Floating thumbnail",
// computed by the same rules as the setup window's rail (`SetupProgress`) from the same reading of the Mac
// (`SetupSystem.read`), so the card and the window can never disagree.
public import ObscuraPrefs
public import ObscuraUIKit

public extension SetupProgress {
    /// The panel's summary: finished rows, all rows, and the row setup resumes at (none once every row is finished).
    var summary: SetupSummary {
        let total = SetupStep.allCases.count
        let done = finishedCount
        return SetupSummary(done: done, total: total, next: done >= total ? nil : resumeStep.title)
    }
}

@MainActor
public enum SetupSummaryReader {
    /// Reads the Mac as the setup window does when it opens, and summarises it. Asks nothing new: a folder is probed
    /// only once its step was passed (its prompt was answered then), exactly as `SetupFlow.start()` does.
    public static func current(settings: Settings) async -> SetupSummary {
        await current(settings: settings, system: .live)
    }

    static func current(settings: Settings, system: SetupSystem) async -> SetupSummary {
        let seen = Set(settings.setupStepsSeen.compactMap(SetupStep.init(rawValue:)))
        let snapshot = await system.read(settings: settings, seen: seen)
        return SetupProgress(snapshot: snapshot, settings: settings, seen: seen).summary
    }
}

extension SetupSystem {
    /// What the Mac says before anything is asked: the folders, the floating thumbnail, the login item.
    func baseSnapshot() -> SetupSnapshot {
        SetupSnapshot(screenshotFolder: screenshotFolder(), downloadsFolder: downloadsFolder(),
                      floatingThumbnailEnabled: floatingThumbnailEnabled(), loginItem: loginItemStatus())
    }

    /// Fills in folder access and the notification permission. A folder whose step was already passed (or any, on a
    /// finished setup) is probed again, since its prompt was answered then; one not reached yet is asked only from
    /// its own step, never from here.
    func refreshed(_ snapshot: SetupSnapshot, settings: Settings, seen: Set<SetupStep>) async -> SetupSnapshot {
        var s = snapshot
        let finished = settings.hasFinishedSetup
        if settings.guardsScreenshotFolder, finished || seen.contains(.screenshotFolder) {
            s.screenshotAccess = probeFolder(s.screenshotFolder)
        }
        if settings.guardsDownloads, finished || seen.contains(.downloads) {
            s.downloadsAccess = probeFolder(s.downloadsFolder)
        }
        s.notifications = await notificationPermission()
        return s
    }

    /// `baseSnapshot()` then `refreshed(_:settings:seen:)`.
    func read(settings: Settings, seen: Set<SetupStep>) async -> SetupSnapshot {
        await refreshed(baseSnapshot(), settings: settings, seen: seen)
    }
}
