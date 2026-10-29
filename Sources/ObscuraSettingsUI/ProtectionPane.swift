// Protection: every capture path in one list (screenshot folder, Downloads, clipboard, extra folders with their access
// state), what happens when a secret is found, notifications, what follows a screenshot (the clipboard copy, G-18, and the
// floating thumbnail: macOS's advice and Obscura's own,
// B-9), and Pause. While paused,
// the Pause group leads the pane with Resume as the one accent button (CHANGES.md 27).
import AppKit
import SwiftUI
import ObscuraUIKit
import ObscuraCapture
import ObscuraEngine
import ObscuraPrefs

struct ProtectionPane: View {
    let model: AppModel
    let system: SystemSnapshot
    let services: SystemServices
    let refresh: () async -> Void
    @State private var thumbnailBusy = false

    private var s: ObscuraPrefs.Settings { model.settings }

    private var isPaused: Bool {
        if case .paused = model.status.protection { return true }
        return s.protectionPaused
    }

    var body: some View {
        PaneScaffold(String(localized: "Protection")) {
            lead
            if isPaused { pauseGroup }
            GroupHeading(title: String(localized: "Capture paths"),
                         trailing: String(localized: "\(ProtectionFacts.sourcesOn(s)) of 4 on"))
            Card { capturePaths }
            GroupHeading(title: String(localized: "When a secret is found"))
            Card { whenFound }
            GroupHeading(title: SpotCopy.settingsGroup)
            Card { unreadSpots }
            GroupHeading(title: String(localized: "After a screenshot"))
            Card { clipboardRow; RowDivider(); thumbnailRow }
            if !isPaused { pauseGroup }
        }
    }

    // MARK: Headline

    private var lead: some View {
        let needing = ProtectionFacts.foldersNeedingYou(s, system, unconfirmed: model.unconfirmedFolders)
        let needs = needing == 1 ? String(localized: "One folder needs you.") : String(localized: "\(needing) folders need you.")
        if isPaused {
            return Lead(tone: s.pausedColor.tone, title: String(localized: "Protection is paused"),
                        detail: needing > 0 ? String(localized: "Resume below or from the menu bar. \(needs)")
                                            : String(localized: "Resume below or from the menu bar."))
        }
        if needing > 0 {
            return Lead(tone: .needs, title: needing == 1 ? String(localized: "One capture path needs you")
                                                          : String(localized: "\(needing) capture paths need you"),
                        detail: String(localized: "Images saved there are not checked until you allow access again."))
        }
        if ProtectionFacts.sourcesOn(s) == 0 {
            return Lead(tone: .needs, title: String(localized: "Nothing is being watched"),
                        detail: String(localized: "Turn on at least one capture path below."))
        }
        let folders = s.extraFolders.count + (s.guardsDownloads ? 1 : 0)
        let watched: String
        switch folders {
        case 0: watched = String(localized: "Screenshots and the clipboard are watched; nothing is checked anywhere but here.")
        case 1: watched = String(localized: "Screenshots, one folder and the clipboard are watched; nothing is checked anywhere but here.")
        default: watched = String(localized: "Screenshots, \(folders) folders and the clipboard are watched; nothing is checked anywhere but here.")
        }
        let all = s.guardsScreenshotFolder && s.guardsClipboard
        return Lead(tone: all ? .ok : .needs,
                    title: all ? String(localized: "Every capture path is guarded") : String(localized: "Some capture paths are off"),
                    detail: all ? watched : String(localized: "Screenshots or copied images can reach other apps unchecked."))
    }

    // MARK: Capture paths

    @ViewBuilder private var capturePaths: some View {
        SettingRow(icon: ("camera", OColor.SettingsTile.detectors), title: String(localized: "Screenshot folder"),
                   help: String(localized: "\(PathCopy.abbreviated(system.screenshotFolder)) — follows the Screenshot app (⇧⌘5 ▸ Options)")) {
            if s.guardsScreenshotFolder { accessBadge(system.screenshotAccess, granted: String(localized: "Access granted")) }
            if s.guardsScreenshotFolder, system.screenshotAccess != .granted {
                Button(String(localized: "Allow…")) { allow(system.screenshotFolder) }.buttonStyle(OButtonStyle(.warn, size: .small)).controlSize(.small)
            }
            AsyncSwitch(label: String(localized: "Screenshot folder"), isOn: s.guardsScreenshotFolder) { on in
                model.updateSettings { $0.guardsScreenshotFolder = on }
            }
        }
        RowDivider()
        SettingRow(icon: ("arrow.down.to.line", OColor.SettingsTile.protection), title: String(localized: "Downloads"),
                   help: s.guardsDownloads
                       ? String(localized: "\(PathCopy.abbreviated(system.downloads)) — images landing here are checked the moment they appear")
                       : String(localized: "\(PathCopy.abbreviated(system.downloads)) — turning this on asks macOS for access; images landing here are checked the moment they appear")) {
            if s.guardsDownloads, isUnconfirmed(system.downloads) {
                // G-36: switched on outside Obscura; this click in Obscura is the person's confirmation.
                Badge(String(localized: "Not confirmed"), tone: .needs, symbol: "exclamationmark.triangle")
                Button(String(localized: "Confirm")) { Task { await model.confirmFolder(system.downloads); await refresh() } }
                    .buttonStyle(OButtonStyle(.warn, size: .small))
            } else if s.guardsDownloads, system.downloadsAccess != .granted {
                accessBadge(system.downloadsAccess, granted: "")
                Button(String(localized: "Allow…")) { allow(system.downloads) }.buttonStyle(OButtonStyle(.warn, size: .small))
            }
            AsyncSwitch(label: String(localized: "Downloads"), isOn: s.guardsDownloads) { on in
                // G-36: the switch in Obscura is the confirmation; it is kept before the setting changes.
                if on { await model.confirmFolder(system.downloads) } else { await model.forgetFolder(system.downloads) }
                model.updateSettings { $0.guardsDownloads = on }
                await refresh()   // the first probe of Downloads is what asks macOS for access
            }
        }
        RowDivider()
        SettingRow(icon: ("doc.on.clipboard", OColor.SettingsTile.rules), title: String(localized: "Clipboard"),
                   help: String(localized: "⌃⇧⌘4 captures and images copied from other apps. They never touch the disk")) {
            AsyncSwitch(label: String(localized: "Clipboard"), isOn: s.guardsClipboard) { on in
                model.updateSettings { $0.guardsClipboard = on }
            }
        }
        ForEach(s.extraFolders, id: \.self) { path in
            RowDivider()
            folderRow(path)
        }
        RowDivider()
        SettingRow(icon: ("plus", nil), title: String(localized: "Add folder…"),
                   help: String(localized: "New images saved to these folders are checked the moment they appear. PNG, JPEG, HEIC, TIFF, GIF, BMP and WebP")) {
            Button { addFolder() } label: { Label(String(localized: "Add…"), systemImage: "plus") }
                .buttonStyle(OButtonStyle(.quiet, size: .small))
        }
    }

    private func folderRow(_ path: String) -> some View {
        let access = system.folderAccess[path] ?? .granted
        let unconfirmed = isUnconfirmed(URL(fileURLWithPath: path))
        let help: String
        switch access {
        case _ where unconfirmed:
            help = String(localized: "Added outside Obscura. Nothing saved here is checked until you confirm it")
        case .granted: help = String(localized: "Watching · access granted")
        case .denied: help = String(localized: "macOS refused access. Nothing saved here is checked until you allow it again")
        case .missing: help = String(localized: "Access lost after the folder moved. Nothing saved here is checked until you allow it again")
        }
        return SettingRow(icon: ("folder", OColor.SettingsTile.style), title: PathCopy.abbreviated(path), help: help) {
            if unconfirmed {
                Badge(String(localized: "Not confirmed"), tone: .needs, symbol: "exclamationmark.triangle")
                Button(String(localized: "Confirm…")) { reselect(path) }.buttonStyle(OButtonStyle(.warn, size: .small))
            } else if access == .granted {
                Badge(String(localized: "Watching"), tone: .ok, symbol: "checkmark")
            } else {
                Badge(String(localized: "Needs attention"), tone: .needs, symbol: "exclamationmark.triangle")
                Button(String(localized: "Allow access…")) { reselect(path) }.buttonStyle(OButtonStyle(.warn, size: .small))
            }
            Button(String(localized: "Stop watching")) { stopWatching(path) }.buttonStyle(OButtonStyle(.quiet, size: .small))
        }
    }

    @ViewBuilder private func accessBadge(_ state: FolderAccessState, granted: String) -> some View {
        switch state {
        case .granted: Badge(granted, tone: .ok, symbol: "checkmark")
        case .denied: Badge(String(localized: "Needs access"), tone: .needs, symbol: "exclamationmark.triangle")
        case .missing: Badge(String(localized: "Folder missing"), tone: .needs, symbol: "exclamationmark.triangle")
        }
    }

    // MARK: When a secret is found

    @ViewBuilder private var whenFound: some View {
        radioRow(.replace, title: String(localized: "Replace with clean copy"),
                 help: String(localized: "The screenshot file itself becomes clean. The original is kept only in the Journal"))
        RowDivider()
        radioRow(.keepBoth, title: String(localized: "Save clean copy next to it"),
                 help: String(localized: "The original stays where it is; a “(clean)” copy is written beside it"))

        RowDivider()
        SettingRow(title: String(localized: "Show a notification"),
                   help: String(localized: "Each catch posts a silent banner with Undo and Review")) {
            if s.showsNotifications, system.notificationsDenied == true {
                Badge(String(localized: "Off in System Settings"), tone: .needs, symbol: "bell.slash")
                Button(String(localized: "Open System Settings…")) { services.open(SystemLinks.notifications) }
                    .buttonStyle(OButtonStyle(.warn, size: .small))
            }
            AsyncSwitch(label: String(localized: "Show a notification"), isOn: s.showsNotifications) { on in
                model.updateSettings { $0.showsNotifications = on }
            }
        }
        RowDivider()
        SettingRow(title: String(localized: "Play a sound for every catch"),
                   help: String(localized: "Off, catches arrive quietly and a sound always means a problem needs you")) {
            AsyncSwitch(label: String(localized: "Play a sound for every catch"), isOn: s.catchSound) { on in
                model.updateSettings { $0.catchSound = on }
            }
            .disabled(!s.showsNotifications)
        }
        RowDivider()
        SettingRow(title: String(localized: "Keep room for the catch count in the menu bar"),
                   help: s.showsNotifications
                       ? String(localized: "Only with notifications off, when catches are counted on the menu bar icon")
                       : String(localized: "The icon keeps the count's width, so the icons beside it never move")) {
            AsyncSwitch(label: String(localized: "Keep room for the catch count in the menu bar"), isOn: s.reservesBadgeSpace) { on in
                model.updateSettings { $0.reservesBadgeSpace = on }
            }
            .disabled(s.showsNotifications)
        }
    }

    // MARK: When a spot can't be read (G-40)

    /// Both off by default: a small spot no reading could read waits for the person in the viewer. B covers it instead;
    /// D skips one too small to hold a secret (and decides first). Neither ever calls such a picture fully read.
    @ViewBuilder private var unreadSpots: some View {
        SettingRow(title: SpotCopy.coverSwitch, help: SpotCopy.coverSwitchDetail) {
            AsyncSwitch(label: SpotCopy.coverSwitch, isOn: s.coversUnreadableSpots) { on in
                model.updateSettings { $0.coversUnreadableSpots = on }
            }
        }
        RowDivider()
        SettingRow(title: SpotCopy.skipSwitch, help: SpotCopy.skipSwitchDetail) {
            AsyncSwitch(label: SpotCopy.skipSwitch, isOn: s.skipsTinySpots) { on in
                model.updateSettings { $0.skipsTinySpots = on }
            }
        }
    }

    private func radioRow(_ value: FileHandling, title: String, help: String) -> some View {
        let on = s.fileHandling == value
        return Button {
            model.updateSettings { $0.fileHandling = value }
        } label: {
            SettingRow(title: title, help: help) { RadioMark(on: on) }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(help))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: After a screenshot

    /// G-18: each checked screenshot's final picture goes on the clipboard, so ⇧⌘4 then ⌘V pastes it, like macOS's own
    /// clipboard capture. Only the screenshot folder; a file that could not be checked is never copied.
    private var clipboardRow: some View {
        SettingRow(title: String(localized: "Copy screenshots to the clipboard"),
                   help: String(localized: "Once checked, each new screenshot is on the clipboard, covered where needed, so ⌘V pastes the safe version. It replaces what you copied before")) {
            AsyncSwitch(label: String(localized: "Copy screenshots to the clipboard"), isOn: s.copiesCleanImage) { on in
                model.updateSettings { $0.copiesCleanImage = on }
            }
        }
    }

    // MARK: Floating thumbnail

    /// r3-a's Settings row (B-9, G-8): macOS's own thumbnail (the existing advice), then Obscura's thumbnail, how long
    /// it stays, what a click opens, and the banner rule it implies.
    @ViewBuilder private var thumbnailRow: some View {
        if system.floatingThumbnail {
            SettingRow(title: String(localized: "macOS screenshot thumbnail"),
                       help: String(localized: "While the thumbnail floats the file is not saved yet, and dragging it sends the unscanned original. Off is safer")) {
                Badge(String(localized: "Skips the check"), tone: .needs, symbol: "exclamationmark.triangle")
                Button(String(localized: "Turn off floating thumbnail")) { setThumbnail(false) }
                    .buttonStyle(OButtonStyle(.warn, size: .small)).disabled(thumbnailBusy)
            }
        } else {
            SettingRow(title: String(localized: "macOS screenshot thumbnail"),
                       help: String(localized: "Off, so captures are saved, and checked, right away")) {
                Badge(String(localized: "Off"), tone: .ok, symbol: "checkmark")
                Button(String(localized: "Show thumbnail again")) { setThumbnail(true) }
                    .buttonStyle(OButtonStyle(.quiet, size: .small)).disabled(thumbnailBusy)
            }
        }
        RowDivider()
        SettingRow(title: String(localized: "Show Obscura's thumbnail after each screenshot"),
                   help: String(localized: "In the same corner once the check is done. Drag, click and swipe it as before; it shows what was covered")) {
            AsyncSwitch(label: String(localized: "Show Obscura's thumbnail after each screenshot"), isOn: s.thumbnailEnabled) { on in
                model.updateSettings { $0.thumbnailEnabled = on }
            }
        }
        RowDivider()
        SettingRow(title: String(localized: "Stays on screen"), help: String(localized: "Hovering keeps it until you move away")) {
            Picker(String(localized: "Stays on screen"),
                   selection: Binding(get: { ThumbnailChoices.nearest(s.thumbnailSeconds) },
                                      set: { v in model.updateSettings { $0.thumbnailSeconds = v } })) {
                ForEach(ThumbnailChoices.durations, id: \.self) { Text(ThumbnailChoices.title($0)).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
            .disabled(!s.thumbnailEnabled)
        }
        RowDivider()
        SettingRow(title: String(localized: "Clicking it opens")) {
            Picker(String(localized: "Clicking it opens"),
                   selection: Binding(get: { s.thumbnailClickOpens }, set: { v in model.updateSettings { $0.thumbnailClickOpens = v } })) {
                ForEach(ThumbnailClick.allCases, id: \.self) { Text(ThumbnailChoices.title($0)).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
            .disabled(!s.thumbnailEnabled)
        }
        RowDivider()
        SettingRow(title: String(localized: "Catch banner for screenshots"),
                   help: s.thumbnailEnabled ? String(localized: "Only while this thumbnail is off; the thumbnail is the notice")
                                            : String(localized: "On, because this thumbnail is off")) {
            Text("Automatic").font(.system(size: 11.5)).foregroundStyle(OColor.text3)
        }
    }

    private func setThumbnail(_ on: Bool) {
        thumbnailBusy = true
        Task {
            await services.setFloatingThumbnail(on)
            await refresh()
            thumbnailBusy = false
        }
    }

    // MARK: Pause

    @ViewBuilder private var pauseGroup: some View {
        GroupHeading(title: String(localized: "Pause"))
        Card {
            pauseRow
            RowDivider()
            SettingRow(title: String(localized: "Paused colour"),
                       help: String(localized: "How Paused shows on the menu bar icon, in its panel and here")) {
                Picker(String(localized: "Paused colour"), selection: Binding(get: { s.pausedColor },
                                                                            set: { c in model.updateSettings { $0.pausedColor = c } })) {
                    ForEach(PausedColor.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            RowDivider()
            SettingRow(title: String(localized: "Pause choices in the menu bar open"),
                       help: String(localized: "Picking a length always takes a click")) {
                Picker(String(localized: "Pause choices in the menu bar open"),
                       selection: Binding(get: { s.pauseChoicesOpen }, set: { t in model.updateSettings { $0.pauseChoicesOpen = t } })) {
                    Text("On hover").tag(PauseChoicesTrigger.hover)
                    Text("On click").tag(PauseChoicesTrigger.click)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
    }

    @ViewBuilder private var pauseRow: some View {
        if isPaused {
            SettingRow(title: String(localized: "Protection is paused"),
                       help: String(localized: "New screenshots are not checked until you resume")) {
                Badge(String(localized: "Paused"), tone: s.pausedColor.tone)
                Button(String(localized: "Resume protection")) { model.resume() }
                    .buttonStyle(OButtonStyle(.primary, size: .small))
                    .keyboardShortcut(.defaultAction)
            }
        } else {
            SettingRow(title: String(localized: "Pause protection"),
                       help: String(localized: "Stops every guard until you resume. The menu bar icon shows the pause")) {
                Menu {
                    Button(String(localized: "For 15 Minutes")) { model.pause(for: .seconds(15 * 60)) }
                    Button(String(localized: "For 1 Hour")) { model.pause(for: .seconds(60 * 60)) }
                    Button(String(localized: "Until I Resume")) { model.pause(for: nil) }
                } label: {
                    Label(String(localized: "Pause…"), systemImage: "pause")
                }
                .menuStyle(.button)
                .buttonStyle(OButtonStyle(.quiet, size: .small))
                .fixedSize()
                .accessibilityLabel(Text("Pause protection"))
            }
        }
    }

    // MARK: Folder actions

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Watch")
        panel.message = String(localized: "Choose folders whose new images Obscura should check.")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            // G-36: the pick in Obscura's own panel is the confirmation, kept before the setting names the folder.
            var confirmed: [String] = []
            for url in urls where await model.confirmFolder(url) { confirmed.append(url.standardizedFileURL.path) }
            let paths = confirmed
            model.updateSettings { settings in
                for p in paths where !settings.extraFolders.contains(p) { settings.extraFolders.append(p) }
            }
            await refresh()
        }
    }

    /// Asks again for a folder macOS stopped letting us read: the open panel at that folder is the user's grant.
    private func reselect(_ path: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Allow")
        panel.directoryURL = URL(filePath: path, directoryHint: .isDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let new = url.standardizedFileURL.path
        Task {
            // G-36: the pick is also the confirmation (of the folder picked, which may be another one).
            guard await model.confirmFolder(url) else { return }
            model.updateSettings { settings in
                if let i = settings.extraFolders.firstIndex(of: path) {
                    if settings.extraFolders.contains(new), new != path { settings.extraFolders.remove(at: i) }
                    else { settings.extraFolders[i] = new }
                }
            }
            await refresh()
        }
    }

    private func stopWatching(_ path: String) {
        model.updateSettings { $0.extraFolders.removeAll { $0 == path } }
        Task { await model.forgetFolder(URL(fileURLWithPath: path, isDirectory: true)) }
    }

    /// G-36: named in the settings but not confirmed in Obscura, so not watched.
    private func isUnconfirmed(_ folder: URL) -> Bool { model.unconfirmedFolders.contains(folder.standardizedFileURL.path) }

    /// Probing a folder is what asks macOS; when it still refuses, the Files and Folders pane is where to allow it.
    private func allow(_ url: URL) {
        if FolderAccess.probe(url) != .granted { services.open(SystemLinks.filesAndFolders) }
        Task { await refresh() }
    }
}

/// The choices the Floating thumbnail group offers (r3-a: 3, 5, 8, 12 seconds; Preview or the viewer).
enum ThumbnailChoices {
    static let durations: [Double] = [3, 5, 8, 12]

    /// A stored value the menu does not list shows as the nearest choice; nothing is written until the user picks.
    static func nearest(_ seconds: Double) -> Double {
        durations.min { abs($0 - seconds) < abs($1 - seconds) } ?? 5
    }

    static func title(_ seconds: Double) -> String { String(localized: "\(Int(seconds)) seconds") }

    static func title(_ click: ThumbnailClick) -> String {
        switch click {
        case .preview: return String(localized: "Preview")
        case .viewer: return String(localized: "Obscura viewer")
        }
    }
}

/// `.radio`: a 14 pt radio mark.
struct RadioMark: View {
    var on: Bool
    var body: some View {
        ZStack {
            Circle().fill(on ? OColor.accent : OColor.control)
            if on { Circle().fill(.white).frame(width: 5, height: 5) }
            else { Circle().strokeBorder(OColor.hairline, lineWidth: OMetric.hairline) }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}
