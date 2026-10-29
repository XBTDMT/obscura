// Everything a click in the panel can do. Views hold actions as values; `PanelActionPerformer` turns each into one
// AppModel call or one Router call, so the wiring is testable without clicking (and surfaces never import each other).
import Foundation
import ObscuraUIKit

/// A watched folder the user can stop watching from a problem banner.
enum WatchedFolder: Hashable, Sendable {
    case screenshotFolder
    case downloads
    /// An extra folder, as stored in `Settings.extraFolders`.
    case extra(String)
}

enum PanelAction: Hashable, Sendable {
    /// Put the original back (at once by default; asks first with `Settings.confirmsUndo`, G-19 #11).
    case undo(UUID)
    /// Cover every finding again after an undo.
    case blackOutAgain(UUID)
    case copyClean(UUID)
    case review(UUID)
    case pause(PauseChoice)
    case resume
    case openJournal
    /// "N images weren't checked" → Open in Journal: the Journal on its Not checked section (G-13).
    case openJournalNotChecked
    /// G-40 "N spots couldn't be read" → Review…: the spot viewer for one picture (its Not checked row's id).
    case reviewSpots(UUID)
    case openSettings(SettingsPane)
    case openSetup
    case checkForUpdates
    /// The update banner's install button (and the Install Update row): verified install and relaunch (G-33).
    case installUpdate
    /// The update banner's "Later": hidden until the next check reports the update again.
    case dismissUpdate
    case stopWatching(WatchedFolder)
    /// "N images weren't checked" → Check Again: every unchecked file goes back through the engine.
    case checkAgain
    /// "N files still show secrets" → Try Again: each covered picture is written to its file again (fail-open #7).
    case retryNotCovered
    /// "N files still show secrets" → Open in Journal: the Journal on its Not covered on disk section.
    case openJournalNotCovered
    /// "Old originals weren't all deleted" → Try Again: the Journal's upkeep runs now (fail-open #11).
    case retryMaintenance
    case quit
}

@MainActor
struct PanelActionPerformer {
    let model: AppModel
    let memory: PanelMemory
    var calendar: Calendar = .current

    func perform(_ action: PanelAction, now: Date = Date()) async {
        switch action {
        case .undo(let id):
            await model.undo(id)
        case .blackOutAgain(let id):
            await model.blackOutAll(id)
        case .copyClean(let id):
            await model.copy(id, original: false)
        case .review(let id):
            model.router?.openViewer(entryID: id)
        case .pause(let choice):
            memory.choosePause(choice)
            model.pause(until: choice.resumeDate(from: now, calendar: calendar))
        case .resume:
            model.resume()
        case .openJournal:
            model.router?.openJournal(selecting: nil)
        case .openJournalNotChecked:
            model.router?.openJournal(.notChecked)
        case .reviewSpots(let id):
            model.router?.openSpots(fileID: id)
        case .openSettings(let pane):
            model.router?.openSettings(pane)
        case .openSetup:
            model.router?.openSetup()
        case .checkForUpdates:
            model.router?.checkForUpdates()
        case .installUpdate:
            model.router?.installUpdate()
        case .dismissUpdate:
            model.router?.dismissUpdate()
        case .stopWatching(let folder):
            model.updateSettings { settings in
                switch folder {
                case .screenshotFolder: settings.guardsScreenshotFolder = false
                case .downloads: settings.guardsDownloads = false
                case .extra(let raw): settings.extraFolders.removeAll { $0 == raw }
                }
            }
        case .checkAgain:
            await model.checkAgain()
        case .retryNotCovered:
            await model.retryAllNotCovered()
        case .openJournalNotCovered:
            model.router?.openJournal(.notCovered)
        case .retryMaintenance:
            await model.runMaintenance()
        case .quit:
            model.router?.quit()
        }
    }
}
