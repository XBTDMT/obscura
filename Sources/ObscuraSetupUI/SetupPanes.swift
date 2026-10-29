// One pane per rail row, each with its footer (where the setting lives afterwards, then the step's buttons).
import AppKit
import SwiftUI
import ObscuraCapture
import ObscuraPrefs
import ObscuraUIKit

struct StepPane: View {
    let step: SetupStep
    let flow: SetupFlow
    let setFloatingThumbnail: (@MainActor (Bool) async -> Void)?
    let finish: () -> Void

    var body: some View {
        switch step {
        case .theCatch: CatchPane(flow: flow)
        case .welcome: WelcomePane(flow: flow)
        case .screenshotFolder: ScreenshotFolderPane(flow: flow)
        case .downloads: DownloadsPane(flow: flow)
        case .floatingThumbnail: ThumbnailPane(flow: flow, action: setFloatingThumbnail)
        case .notifications: NotificationsPane(flow: flow)
        case .openAtLogin: LoginPane(flow: flow)
        case .menuBarIcon: MenuBarIconPane(flow: flow)
        case .done: DonePane(flow: flow, setFloatingThumbnail: setFloatingThumbnail, finish: finish)
        }
    }
}

// MARK: - Page shell

/// What the footer says on its left.
enum FooterLead {
    /// Lock + "On-device only · free and open source".
    case privacy
    /// "Afterwards in Settings → <pane>", the pane name a link.
    case home(SettingsPane)
}

struct StepPage<Content: View, Buttons: View>: View {
    let flow: SetupFlow
    let lead: FooterLead
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 8) {
                switch lead {
                case .privacy:
                    Image(systemName: "lock").font(.system(size: 12)).accessibilityHidden(true)
                    Text("On-device only · free and open source")
                case .home(let pane):
                    Text("Afterwards in Settings →")
                    Button(PaneNames.title(pane)) { flow.model.router?.openSettings(pane) }
                        .buttonStyle(.plain)
                        .foregroundStyle(OColor.accentText)
                        .accessibilityHint(Text("Opens this setting in Settings"))
                }
                Spacer(minLength: 8)
                buttons
            }
            .font(.system(size: 11.5))
            .foregroundStyle(OColor.text3)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(OColor.separator).frame(height: OMetric.hairline) }
        }
    }
}

struct Paragraph: View {
    let text: String
    var body: some View {
        Text(text).font(SetupFont.paragraph).foregroundStyle(OColor.text2).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }
}

enum PaneNames {
    static func title(_ pane: SettingsPane) -> String {
        switch pane {
        case .protection: return String(localized: "Protection")
        case .detectors: return String(localized: "Detectors")
        case .redactionStyle: return String(localized: "Redaction Style")
        case .customRules: return String(localized: "Custom Rules")
        case .journalPrivacy: return String(localized: "Journal & Privacy")
        case .shortcuts: return String(localized: "Keyboard Shortcuts")
        case .about: return String(localized: "About")
        }
    }
}

enum Retention {
    /// "24 hours", "7 days": how long originals are kept.
    static func phrase(_ r: JournalRetention) -> String {
        switch r {
        case .oneHour: return String(localized: "1 hour")
        case .oneDay: return String(localized: "24 hours")
        case .oneWeek: return String(localized: "7 days")
        case .thirtyDays: return String(localized: "30 days")
        }
    }
}

@MainActor
enum FolderWords {
    static func name(_ url: URL) -> String { FileManager.default.displayName(atPath: url.path) }
    static func path(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

    /// The trailing pill for a folder row that has been asked.
    @ViewBuilder static func pill(_ access: FolderAccessState, optional: Bool) -> some View {
        switch access {
        case .granted: Pill(String(localized: "Allowed"), tone: .ok, symbol: "checkmark")
        case .denied: Pill(String(localized: "Not allowed"), tone: optional ? .needs : .live, symbol: "xmark")
        case .missing: Pill(String(localized: "Not found"), tone: optional ? .quiet : .live, symbol: "questionmark")
        }
    }
}

// MARK: - 1 · The catch

struct CatchPane: View {
    let flow: SetupFlow

    var body: some View {
        StepPage(flow: flow, lead: .privacy) {
            switch flow.demo {
            case .idle, .running: running
            case .succeeded(let result): flow.showsOriginal ? AnyView(original(result)) : AnyView(caught(result))
            case .failed(let failure): failed(failure)
            }
        } buttons: {
            if let result = flow.demo.result {
                Button(flow.showsOriginal ? String(localized: "Back to redacted") : String(localized: "Show the original")) {
                    flow.showsOriginal.toggle()
                }
                .buttonStyle(OButtonStyle(.quiet))
                .accessibilityValue(Text(verbatim: ProtectionCopy.secrets(result.secrets)))
            }
            Button("Next") { flow.advance() }.buttonStyle(OButtonStyle(.primary)).keyboardShortcut(.defaultAction)
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Checking a fake .env file…").font(SetupFont.title)
            Paragraph(text: String(localized: "Obscura is running its real detector on a made-up .env file, on this Mac. It takes a moment."))
            HStack(alignment: .center, spacing: 12) {
                TerminalFrame(image: SampleImages.original, width: 295)
                ProgressView().controlSize(.small).accessibilityLabel(Text("Checking"))
            }
        }
    }

    private func caught(_ r: DemoResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Obscura just caught \(ProtectionCopy.secrets(r.secrets))").font(SetupFont.title)
            Paragraph(text: String(localized: "It ran the real detector on this fake .env file, on this Mac, before you read a word. Every screenshot you take gets the same treatment. The entry is in your Journal as “\(r.displayName)”; you can undo it there like any catch."))
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Label { Text("Before · the original (kept in the Journal)") } icon: { Image(systemName: "eye") }
                        .font(.system(size: 11)).foregroundStyle(OColor.text3)
                    TerminalFrame(image: r.original ?? SampleImages.original, width: 295)
                        .accessibilityLabel(Text("The fake .env file before: every secret visible"))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Label { Text("After · what gets pasted") } icon: { Image(systemName: "checkmark.shield") }
                        .font(.system(size: 11)).foregroundStyle(OColor.text3)
                    TerminalFrame(image: r.clean, width: 295)
                        .accessibilityLabel(Text("The fake .env file after: \(ProtectionCopy.secrets(r.secrets)) blacked out"))
                }
            }
            Callout(.ok, symbol: "checkmark.shield.fill",
                    title: String(localized: "\(ProtectionCopy.secrets(r.secrets)) blacked out in \(r.durationMS) ms."),
                    message: String(localized: "This is exactly what your clipboard gets."))
        }
    }

    private func original(_ r: DemoResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Obscura just caught \(ProtectionCopy.secrets(r.secrets))").font(SetupFont.title)
            TerminalFrame(image: r.original ?? SampleImages.original, width: 520)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text("The fake .env file with every secret visible"))
            Callout(.live, symbol: "eye.fill", title: String(localized: "Original showing. Every secret is visible."),
                    message: String(localized: "This copy lives in the private Journal on this Mac for \(Retention.phrase(flow.model.settings.journalRetention)), then is deleted. It is never sent anywhere."))
        }
    }

    private func failed(_ failure: DemoFailure) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(failure == .didNotRun ? String(localized: "The test shot didn't run") : String(localized: "The test shot caught nothing"))
                .font(SetupFont.title)
            Paragraph(text: String(localized: "Obscura tries its real detector on a made-up .env file before anything else, so you can see what it does. This time there is no result to show."))
            TerminalFrame(image: SampleImages.original, width: 295)
            Callout(.needs, symbol: "exclamationmark.triangle.fill",
                    title: failure == .didNotRun ? String(localized: "The check didn't finish") : String(localized: "No secrets were found in the fake file"),
                    message: failure == .didNotRun
                        ? String(localized: "Nothing left this Mac. Try again; if it keeps failing, the menu bar shows what needs attention.")
                        : String(localized: "That file holds four made-up secrets, so this should not happen. Try again; if it repeats, check Settings → Detectors.")) {
                Button("Try again") { Task { await flow.runTestShot() } }.buttonStyle(OButtonStyle(.warn, size: .small))
            }
        }
    }
}

/// The fake .env as drawn by the kit, for the moments before (or without) the pipeline's own images.
@MainActor
enum SampleImages {
    static let original: NSImage? = NSImage(data: SampleData.terminalPNG(covered: false))
    /// A narrow crop of the same terminal for the floating-thumbnail drawing, so the keys are what shows.
    static let thumbnail: NSImage? = NSImage(data: SampleData.terminalPNG(covered: false, width: 380))
}

// MARK: - 2 · What Obscura is

struct WelcomePane: View {
    let flow: SetupFlow
    var body: some View {
        StepPage(flow: flow, lead: .privacy) {
            Text("Welcome to Obscura").font(SetupFont.title)
            Text("Keep taking screenshots the way you always do. Obscura reads each new one on this Mac and blacks out keys, tokens, passwords and card numbers before the image reaches Slack, GitHub or a chat.")
                .font(SetupFont.lead).foregroundStyle(OColor.text1).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            PromiseRow(symbol: "lock", title: String(localized: "Nothing leaves the Mac"),
                       message: String(localized: "No account, no analytics, no server. Text is read with Apple's on-device OCR."))
            PromiseRow(symbol: "clock.arrow.circlepath", title: String(localized: "Originals stay private"),
                       message: String(localized: "The untouched screenshot is kept in a private Journal for undo and deleted after \(Retention.phrase(flow.model.settings.journalRetention))."))
            PromiseRow(symbol: "chevron.left.forwardslash.chevron.right", title: String(localized: "Free and open source"),
                       message: String(localized: "No license, no trial. Every line is public; you can read what it does."))
        } buttons: {
            Button("Set it up") { flow.advance() }.buttonStyle(OButtonStyle(.primary)).keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - 3 · Screenshot folder

struct ScreenshotFolderPane: View {
    let flow: SetupFlow
    var body: some View {
        let folder = flow.snapshot.screenshotFolder
        let access = flow.snapshot.screenshotAccess
        StepPage(flow: flow, lead: .home(.protection)) {
            Text("Let Obscura read new screenshots").font(SetupFont.stepTitle)
            Paragraph(text: String(localized: "macOS asks once per folder. Screenshots are saved to \(FolderWords.name(folder)) on this Mac; Downloads is optional (for images you save from the web). Obscura reads new images only and never uploads your files."))
            RowCard {
                ListRow(symbol: "folder", title: FolderWords.name(folder),
                        help: String(localized: "\(FolderWords.path(folder)) · where macOS saves screenshots")) {
                    if let access { FolderWords.pill(access, optional: false) }
                    else { Button("Allow…") { flow.allowScreenshotFolder() }.buttonStyle(OButtonStyle(.primary, size: .small)) }
                }
                ListRow(symbol: "arrow.down.circle", title: FolderWords.name(flow.snapshot.downloadsFolder),
                        help: String(localized: "\(FolderWords.path(flow.snapshot.downloadsFolder)) · optional"), showsDivider: true) {
                    if let d = flow.snapshot.downloadsAccess { FolderWords.pill(d, optional: true) }
                    else { Pill(String(localized: "Optional"), tone: .quiet) }
                }
            }
            switch access {
            case .granted:
                Callout(.ok, symbol: "checkmark.shield.fill", title: String(localized: "Screenshots are checked"),
                        message: String(localized: "Every new screenshot in \(FolderWords.name(folder)) is read on this Mac as it is saved."))
            case .denied:
                Callout(.live, symbol: "xmark.shield.fill", title: String(localized: "Screenshots aren't checked"),
                        message: String(localized: "\(FolderWords.name(folder)) access was not allowed. Screenshots aren't checked until it is. Open System Settings → Privacy & Security → Files and Folders.")) {
                    Button("Open Files and Folders…") { flow.openFilesAndFolders() }.buttonStyle(OButtonStyle(.primary, size: .small))
                    Button("Try again") { flow.allowScreenshotFolder() }.buttonStyle(OButtonStyle(.quiet, size: .small))
                }
            case .missing:
                Callout(.live, symbol: "xmark.shield.fill", title: String(localized: "Screenshots aren't checked"),
                        message: String(localized: "macOS saves screenshots to \(FolderWords.path(folder)), and that folder doesn't exist. Pick a folder in the Screenshot app (⇧⌘5 → Options), then try again.")) {
                    Button("Try again") { flow.allowScreenshotFolder() }.buttonStyle(OButtonStyle(.quiet, size: .small))
                }
            case nil:
                EmptyView()
            }
        } buttons: {
            switch access {
            case nil:
                Button("Later") { flow.advance() }.buttonStyle(OButtonStyle(.quiet))
                Button("Continue") { flow.advance() }.buttonStyle(OButtonStyle(.primary)).keyboardShortcut(.defaultAction)
            case .granted:
                Button("Continue") { flow.advance() }.buttonStyle(OButtonStyle(.primary)).keyboardShortcut(.defaultAction)
            case .denied, .missing:
                Button("Continue anyway") { flow.advance() }.buttonStyle(OButtonStyle(.primary)).keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - 4 · Downloads (optional)

struct DownloadsPane: View {
    let flow: SetupFlow
    var body: some View {
        let downloads = flow.snapshot.downloadsFolder
        let access = flow.snapshot.downloadsAccess
        StepPage(flow: flow, lead: .home(.protection)) {
            Text("Also check Downloads?").font(SetupFont.stepTitle)
            Paragraph(text: String(localized: "Optional. Images you save from the web or a chat land in \(FolderWords.name(downloads)); Obscura can check those too. It reads new images only and never uploads your files."))
            RowCard {
                ListRow(symbol: "folder", title: FolderWords.name(flow.snapshot.screenshotFolder),
                        help: String(localized: "\(FolderWords.path(flow.snapshot.screenshotFolder)) · where macOS saves screenshots")) {
                    if let s = flow.snapshot.screenshotAccess { FolderWords.pill(s, optional: false) }
                    else { Pill(String(localized: "Not asked yet"), tone: .needs, symbol: "exclamationmark") }
                }
                ListRow(symbol: "arrow.down.circle", title: FolderWords.name(downloads),
                        help: String(localized: "\(FolderWords.path(downloads)) · optional"), showsDivider: true) {
                    if let access { FolderWords.pill(access, optional: true) }
                    else { Button("Allow…") { Task { await flow.allowDownloads() } }.buttonStyle(OButtonStyle(.primary, size: .small)) }
                }
            }
            switch access {
            case .granted:
                Callout(.ok, symbol: "checkmark.shield.fill", title: String(localized: "\(FolderWords.name(downloads)) is checked"),
                        message: String(localized: "New images saved there are read on this Mac as they arrive."))
            case .denied:
                Callout(.needs, symbol: "exclamationmark.triangle.fill", title: String(localized: "\(FolderWords.name(downloads)) isn't checked"),
                        message: String(localized: "Access was not allowed. Screenshots are still checked. To add it later, open System Settings → Privacy & Security → Files and Folders.")) {
                    Button("Open Files and Folders…") { flow.openFilesAndFolders() }.buttonStyle(OButtonStyle(.warn, size: .small))
                    Button("Try again") { Task { await flow.allowDownloads() } }.buttonStyle(OButtonStyle(.quiet, size: .small))
                }
            case .missing, nil:
                EmptyView()
            }
        } buttons: {
            if access == nil { Button("Skip") { flow.advance() }.buttonStyle(OButtonStyle(.quiet)) }
            Button("Continue") { flow.advance() }.buttonStyle(OButtonStyle(.primary)).keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - 5 · Floating thumbnail

struct ThumbnailPane: View {
    let flow: SetupFlow
    let action: (@MainActor (Bool) async -> Void)?

    var body: some View {
        let on = flow.snapshot.floatingThumbnailEnabled
        StepPage(flow: flow, lead: .home(.protection)) {
            Text("Turn off the floating thumbnail").font(SetupFont.stepTitle)
            Paragraph(text: String(localized: "macOS shows a small thumbnail after every screenshot. While it is visible the file is not saved yet, so dragging it into Slack sends the unscanned original. Turn it off and every capture is saved, and checked, right away. Obscura then shows its own thumbnail in the same corner once the check is done, so you can still drag, click or swipe it: turning macOS's off loses nothing."))
            HStack(alignment: .top, spacing: 16) {
                ThumbnailDesk(image: SampleImages.thumbnail)
                VStack(alignment: .leading, spacing: 8) {
                    if on {
                        Button {
                            Task { await flow.setFloatingThumbnail(shown: false, using: action) }
                        } label: {
                            Label { Text("Turn off floating thumbnail") } icon: { Image(systemName: "rectangle.on.rectangle.slash") }
                        }
                        .buttonStyle(OButtonStyle(.primary))
                        .disabled(action == nil || flow.thumbnailChanging)
                        if action == nil {
                            Text("Open the Screenshot app (⇧⌘5), choose Options and untick Show Floating Thumbnail. This step updates when you come back.")
                                .font(.system(size: 11.5)).foregroundStyle(OColor.text2).fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Callout(.ok, symbol: "checkmark.shield.fill", title: String(localized: "Floating thumbnail is off."),
                                message: String(localized: "Every capture is saved and checked right away, then Obscura's thumbnail appears in the same corner.")) {
                            if action != nil {
                                Button("Show the thumbnail again (captures dragged from it won't be checked)") {
                                    Task { await flow.setFloatingThumbnail(shown: true, using: action) }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5))
                                .foregroundStyle(OColor.accentText)
                                .disabled(flow.thumbnailChanging)
                            }
                        }
                    }
                    Text("Obscura changes the Screenshot app's own setting; nothing else is touched.")
                        .font(.system(size: 11.5)).foregroundStyle(OColor.text3).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } buttons: {
            if on { Button("Keep it on") { flow.advance() }.buttonStyle(OButtonStyle(.quiet)) }
            Button("Continue") { flow.advance() }.buttonStyle(OButtonStyle(.primary)).keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - 6 · Notifications

struct NotificationsPane: View {
    let flow: SetupFlow
    var body: some View {
        let permission = flow.snapshot.notifications
        let wanted = flow.model.settings.showsNotifications
        StepPage(flow: flow, lead: .home(.protection)) {
            Text("Allow notifications").font(SetupFont.stepTitle)
            Paragraph(text: String(localized: "A quick heads-up with Undo when something is blacked out. It never steals focus from the app you are pasting into."))
            BannerSample()
            switch permission {
            case .notDetermined:
                if flow.notificationsAsking {
                    Callout(.quiet, symbol: "arrow.up.right.square", title: String(localized: "macOS is asking in the top-right corner"),
                            message: String(localized: "Click Allow on the banner at the top right of your screen. If it has gone, click the date and time in the menu bar to find it in Notification Center."))
                } else if flow.notificationsRequestFailed {
                    Callout(.needs, symbol: "bell.slash.fill", title: String(localized: "macOS did not show its request"),
                            message: String(localized: "Turn on notifications for Obscura in System Settings instead. You will still see catches in the menu bar.")
                                + (flow.notificationsRequestError.map { "\n" + String(localized: "macOS said: \($0)") } ?? "")) {
                        Button("Open System Settings…") { flow.openNotificationSettings() }.buttonStyle(OButtonStyle(.warn, size: .small))
                        Button("Try Again") { Task { await flow.requestNotifications() } }.buttonStyle(OButtonStyle(.quiet, size: .small))
                    }
                } else {
                    Button("Allow Notifications…") { Task { await flow.requestNotifications() } }
                        .buttonStyle(OButtonStyle(.primary))
                        .keyboardShortcut(.defaultAction)
                }
            case .granted:
                if wanted {
                    Callout(.ok, symbol: "bell.badge.fill", title: String(localized: "Notifications are on"),
                            message: String(localized: "Catches arrive silently with Undo and Review; problems make a sound."))
                } else {
                    Callout(.quiet, symbol: "bell.slash", title: String(localized: "Notifications are off in Obscura"),
                            message: String(localized: "macOS allows them; Obscura keeps quiet. You will still see catches in the menu bar.")) {
                        Button("Turn them on") { flow.model.updateSettings { $0.showsNotifications = true } }.buttonStyle(OButtonStyle(.quiet, size: .small))
                    }
                }
            case .denied:
                Callout(.needs, symbol: "bell.slash.fill", title: String(localized: "Notifications are off"),
                        message: String(localized: "Notifications are turned off for Obscura in System Settings. You will still see catches in the menu bar.")) {
                    Button("Open System Settings…") { flow.openNotificationSettings() }.buttonStyle(OButtonStyle(.warn, size: .small))
                    Button("Keep them off") { flow.keepNotificationsOff() }.buttonStyle(OButtonStyle(.quiet, size: .small))
                }
            }
        } buttons: {
            Button("Not now") { flow.advance() }.buttonStyle(OButtonStyle(.quiet))
            if permission == .notDetermined {
                Button("Continue") { flow.advance() }.buttonStyle(OButtonStyle(.quiet))
            } else {
                Button("Continue") { flow.advance() }.buttonStyle(OButtonStyle(.primary)).keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - 7 · Open at login

struct LoginPane: View {
    let flow: SetupFlow
    var body: some View {
        let status = flow.snapshot.loginItem
        StepPage(flow: flow, lead: .home(.about)) {
            Text("Open at login").font(SetupFont.stepTitle)
            Paragraph(text: String(localized: "Stay protected after a restart. Obscura starts in the menu bar; no window opens."))
            RowCard {
                ListRow(symbol: "power", title: String(localized: "Start Obscura automatically when you log in")) {
                    Toggle(isOn: Binding(get: { flow.opensAtLogin }, set: { flow.setOpenAtLogin($0) })) {
                        Text("Start Obscura automatically when you log in")
                    }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(status == .notFound)
                }
            }
            if status == .notFound {
                Callout(.needs, symbol: "exclamationmark.triangle.fill", title: String(localized: "Obscura isn't in Applications"),
                        message: String(localized: "macOS can open Obscura at login once the app is in the Applications folder. Move it there, open it again, and come back to this step."))
            } else {
                LoginItemsDrawing(status: status) { flow.openLoginItems() }
            }
            if let error = flow.loginError {
                Callout(.needs, symbol: "exclamationmark.triangle.fill", title: error,
                        message: String(localized: "You can add Obscura yourself in System Settings → General → Login Items & Extensions.")) {
                    Button("Open Login Items…") { flow.openLoginItems() }.buttonStyle(OButtonStyle(.warn, size: .small))
                }
            }
        } buttons: {
            Button("Not now") { flow.advance() }.buttonStyle(OButtonStyle(.quiet))
            Button("Continue") { flow.advance() }.buttonStyle(OButtonStyle(.primary)).keyboardShortcut(.defaultAction)
        }
    }
}

/// System Settings' Login Items list, drawn and read back from `LoginItem.status()`.
struct LoginItemsDrawing: View {
    let status: LoginItemStatus
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("System Settings → General → Login Items & Extensions").font(.system(size: 11.5)).foregroundStyle(OColor.text2)
                Spacer()
                Button { open() } label: {
                    Label { Text("Open") } icon: { Image(systemName: "arrow.up.forward.app") }
                }
                .buttonStyle(OButtonStyle(.quiet, size: .small))
                .accessibilityLabel(Text("Open Login Items in System Settings"))
            }
            RowCard {
                ListRow(symbol: nil, title: String(localized: "Other apps"), bold: false) {
                    Capsule().fill(OColor.toggleOff).frame(width: 32, height: 19).accessibilityHidden(true)
                }
                .opacity(0.55)
                .accessibilityHidden(true)
                HStack(spacing: 10) {
                    AppTile(size: 22)
                    Text(verbatim: "Obscura").font(.system(size: 13))
                    Spacer()
                    pill
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(OColor.accentSoft)
                .overlay(alignment: .top) { Rectangle().fill(OColor.separator).frame(height: OMetric.hairline) }
                .accessibilityElement(children: .combine)
            }
            Text(caption).font(.system(size: 11.5)).foregroundStyle(OColor.text3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).fill(OColor.card))
        .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.xl, style: .continuous).strokeBorder(OColor.separator, lineWidth: OMetric.hairline))
    }

    @ViewBuilder private var pill: some View {
        switch status {
        case .enabled: Pill(String(localized: "On"), tone: .ok, symbol: "checkmark")
        case .requiresApproval: Pill(String(localized: "Needs approval"), tone: .needs, symbol: "exclamationmark")
        case .disabled, .notFound: Pill(String(localized: "Off"), tone: .quiet)
        }
    }

    private var caption: String {
        switch status {
        case .enabled: return String(localized: "Obscura opens at login.")
        case .requiresApproval: return String(localized: "Turn Obscura on there; this row updates on its own.")
        case .disabled, .notFound: return String(localized: "Turn on the switch above and macOS adds Obscura here.")
        }
    }
}

// MARK: - 8 · Menu bar icon (G-21)

/// "Pick your menu bar icon": the sixteen marks with live previews and the colour style. Each pick is written at once,
/// so the real menu bar shows it while the person chooses; Continue keeps whatever is picked (the Classic ring if
/// nothing was touched).
struct MenuBarIconPane: View {
    let flow: SetupFlow
    var body: some View {
        let s = flow.model.settings
        StepPage(flow: flow, lead: .home(.about)) {
            Text("Pick your menu bar icon").font(SetupFont.stepTitle)
            Paragraph(text: String(localized: "This is how Obscura shows in the menu bar. Pick one and watch the menu bar: it changes as you choose. Point at an icon to see it move."))
            MarkPicker(selection: s.menuBarMark, style: s.menuBarMarkStyle, state: flow.model.markState, pausedColor: s.pausedColor,
                       onPick: { mark in flow.model.updateSettings { $0.menuBarMark = mark } },
                       onStyle: { style in flow.model.updateSettings { $0.menuBarMarkStyle = style } })
        } buttons: {
            Button("Continue") { flow.advance() }.buttonStyle(OButtonStyle(.primary)).keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - 9 · Done

struct DonePane: View {
    let flow: SetupFlow
    let setFloatingThumbnail: (@MainActor (Bool) async -> Void)?
    let finish: () -> Void

    var body: some View {
        let progress = flow.progress
        let settings = flow.model.settings
        StepPage(flow: flow, lead: .privacy) {
            Text("You're set").font(SetupFont.stepTitle)
            Paragraph(text: String(localized: "Close setup. Obscura keeps running in the menu bar. Everything here can be changed later in Settings, and Setup… in the menu bar runs it again."))
            RowCard {
                summaryRow(symbol: "folder", title: String(localized: "Screenshot folder (\(FolderWords.name(flow.snapshot.screenshotFolder)))"),
                           home: .protection, divider: false) {
                    switch progress.state(.screenshotFolder) {
                    case .done: Pill(String(localized: "Reading"), tone: .ok, symbol: "checkmark")
                    case .unprotected:
                        Pill(String(localized: "Not allowed"), tone: .live, symbol: "xmark")
                        Button("Open Files and Folders…") { flow.openFilesAndFolders() }.buttonStyle(OButtonStyle(.quiet, size: .small))
                    case .declined:
                        Pill(String(localized: "Not asked yet"), tone: .needs, symbol: "exclamationmark")
                        Button("Ask now") { flow.go(to: .screenshotFolder) }.buttonStyle(OButtonStyle(.quiet, size: .small))
                    case .skipped, .pending: Pill(String(localized: "Off"), tone: .quiet)
                    }
                }
                summaryRow(symbol: "arrow.down.circle", title: FolderWords.name(flow.snapshot.downloadsFolder), home: .protection) {
                    switch progress.state(.downloads) {
                    case .done: Pill(String(localized: "Reading"), tone: .ok, symbol: "checkmark")
                    case .declined, .unprotected:
                        Pill(String(localized: "Not allowed"), tone: .needs, symbol: "exclamationmark")
                        Button("Open Files and Folders…") { flow.openFilesAndFolders() }.buttonStyle(OButtonStyle(.quiet, size: .small))
                    case .skipped, .pending: Pill(String(localized: "Off"), tone: .quiet)
                    }
                }
                summaryRow(symbol: "doc.on.clipboard", title: String(localized: "Clipboard images"), home: .protection) {
                    if settings.guardsClipboard { Pill(String(localized: "Guarded"), tone: .ok, symbol: "checkmark") }
                    else { Pill(String(localized: "Off"), tone: .quiet) }
                }
                summaryRow(symbol: "rectangle.on.rectangle", title: String(localized: "Floating thumbnail"), home: .protection) {
                    if flow.snapshot.floatingThumbnailEnabled {
                        Pill(String(localized: "On"), tone: .needs, symbol: "exclamationmark")
                        if setFloatingThumbnail != nil {
                            Button("Turn Off") { Task { await flow.setFloatingThumbnail(shown: false, using: setFloatingThumbnail) } }
                                .buttonStyle(OButtonStyle(.quiet, size: .small))
                        }
                    } else {
                        Pill(String(localized: "Off"), tone: .ok, symbol: "checkmark")
                    }
                }
                summaryRow(symbol: "bell", title: String(localized: "Notifications"), home: .protection) {
                    switch progress.state(.notifications) {
                    case .done: Pill(String(localized: "On"), tone: .ok, symbol: "checkmark")
                    case .declined, .unprotected:
                        Pill(String(localized: "Off"), tone: .needs, symbol: "exclamationmark")
                        if flow.snapshot.notifications == .denied {
                            Button("Open System Settings…") { flow.openNotificationSettings() }.buttonStyle(OButtonStyle(.quiet, size: .small))
                        } else {
                            Button("Allow…") { Task { await flow.requestNotifications() } }.buttonStyle(OButtonStyle(.quiet, size: .small))
                        }
                    case .skipped, .pending: Pill(String(localized: "Off"), tone: .quiet)
                    }
                }
                summaryRow(symbol: "power", title: String(localized: "Open at login"), home: .about) {
                    switch flow.snapshot.loginItem {
                    case .enabled: Pill(String(localized: "On"), tone: .ok, symbol: "checkmark")
                    case .requiresApproval:
                        Pill(String(localized: "Needs approval"), tone: .needs, symbol: "exclamationmark")
                        Button("Open Login Items…") { flow.openLoginItems() }.buttonStyle(OButtonStyle(.quiet, size: .small))
                    case .disabled:
                        Pill(String(localized: "Off"), tone: .needs, symbol: "exclamationmark")
                        Button("Turn On") { flow.setOpenAtLogin(true) }.buttonStyle(OButtonStyle(.quiet, size: .small))
                    case .notFound: Pill(String(localized: "Not available"), tone: .quiet)
                    }
                }
                summaryRow(symbol: "menubar.rectangle", title: String(localized: "Menu bar icon"), home: .about) {
                    Text(settings.menuBarMark.takesColourStyle ? "\(settings.menuBarMark.title) · \(settings.menuBarMarkStyle.title)"
                                                               : settings.menuBarMark.title)
                        .font(.system(size: 12)).foregroundStyle(OColor.text2)
                    Button("Change") { flow.go(to: .menuBarIcon) }.buttonStyle(OButtonStyle(.quiet, size: .small))
                }
            }
        } buttons: {
            Button("Close setup") { finish() }.buttonStyle(OButtonStyle(.primary)).keyboardShortcut(.defaultAction)
        }
    }

    /// A summary row: what it is, where it lives in Settings (a link), its state and, when it can be fixed, the fix.
    private func summaryRow<Trailing: View>(symbol: String, title: String, home: SettingsPane, divider: Bool = true,
                                            @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(OColor.separator).frame(height: OMetric.hairline) }
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(OColor.text2).frame(width: 18).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13))
                    Button(String(localized: "Settings → \(PaneNames.title(home))")) { flow.model.router?.openSettings(home) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(OColor.text3)
                        .accessibilityLabel(Text("Lives in Settings, \(PaneNames.title(home)) pane"))
                        .accessibilityHint(Text("Opens Settings"))
                }
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }
}
