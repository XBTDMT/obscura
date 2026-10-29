// About: version, automatic update checks with Check Now, open at login (with the requires-approval state),
// theme, language (with the restart row), the menu bar icon (G-21), feedback, the open-source link and the website.
import AppKit
import SwiftUI
import ObscuraUIKit
import ObscuraCapture
import ObscuraPrefs

struct AboutPane: View {
    let model: AppModel
    let system: SystemSnapshot
    let services: SystemServices
    let refresh: () async -> Void

    private var s: ObscuraPrefs.Settings { model.settings }

    var body: some View {
        PaneScaffold(String(localized: "About")) {
            lead
            ident
            Card { generalRows }
            GroupHeading(title: String(localized: "Menu bar icon"))
            Card { MenuBarIconPicker(model: model).padding(12) }
            Card { linkRows }
        }
        .onAppear { LanguageAtLaunch.capture(model.settings.language) }
    }

    // MARK: Headline

    private var lead: some View {
        let name = BuildInfo.version.map { String(localized: "Obscura \($0)") } ?? String(localized: "Obscura")
        let title: String
        if let offer = model.updateOffer { title = String(localized: "Obscura \(offer.version) is ready") }
        else if s.updatesCheckAutomatically { title = String(localized: "\(name) is up to date") }
        else { title = name }
        let detail: String
        if system.loginItem == .requiresApproval { detail = String(localized: "Approval needed before it opens at login.") }
        else if model.updateOffer != nil { detail = String(localized: "Install it from the menu bar or with Check Now below.") }
        else if !s.updatesCheckAutomatically { detail = String(localized: "Automatic update checks are off. Check Now looks once.") }
        else { detail = String(localized: "Free, open source, no account.") }
        let tone: Tone = system.loginItem == .requiresApproval ? .needs : (model.updateOffer != nil ? .accent : .ok)
        return Lead(tone: tone, title: title, detail: detail)
    }

    private var ident: some View {
        HStack(spacing: 14) {
            AppIcon().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Obscura").font(.system(size: 17, weight: .semibold)).foregroundStyle(OColor.text1)
                Text(BuildInfo.line).font(.system(size: 12)).foregroundStyle(OColor.text2)
                Text("Free and open source. No account, no licence.").font(.system(size: 12)).foregroundStyle(OColor.text2)
            }
        }
        .padding(.top, 4).padding(.horizontal, 2).padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }

    // MARK: General

    @ViewBuilder private var generalRows: some View {
        SettingRow(title: String(localized: "Check for updates automatically"),
                   help: String(localized: "At most once a day, when Obscura starts or a window opens. Never in the background")) {
            Button { model.router?.checkForUpdates() } label: { Label(String(localized: "Check Now"), systemImage: "arrow.clockwise") }
                .buttonStyle(OButtonStyle(.quiet, size: .small))
            AsyncSwitch(label: String(localized: "Check for updates automatically"), isOn: s.updatesCheckAutomatically) { on in
                model.updateSettings { $0.updatesCheckAutomatically = on }
            }
        }
        RowDivider()
        loginRow
        RowDivider()
        SettingRow(title: String(localized: "Opening Obscura again shows"),
                   help: String(localized: "From Spotlight, Finder or the Dock while it runs. An open window comes forward; unfinished setup opens Setup")) {
            Picker(String(localized: "Opening Obscura again shows"),
                   selection: Binding(get: { s.reopenShows }, set: { t in model.updateSettings { $0.reopenShows = t } })) {
                Text("Menu bar panel").tag(ReopenTarget.panel)
                Text("Settings").tag(ReopenTarget.settings)
                Text("Journal").tag(ReopenTarget.journal)
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
        }
        RowDivider()
        SettingRow(title: String(localized: "Theme"), help: String(localized: "Light, Dark, or follow the system setting")) {
            Picker(String(localized: "Theme"), selection: Binding(get: { s.appearance }, set: { a in model.updateSettings { $0.appearance = a } })) {
                Text("System").tag(Appearance.system)
                Text("Light").tag(Appearance.light)
                Text("Dark").tag(Appearance.dark)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        RowDivider()
        SettingRow(title: String(localized: "Language"),
                   help: String(localized: "For Obscura only. System follows the language order in System Settings")) {
            Picker(String(localized: "Language"), selection: Binding(get: { s.language ?? "" }, set: { setLanguage($0.isEmpty ? nil : $0) })) {
                Text("System").tag("")
                Divider()
                ForEach(Languages.available, id: \.self) { code in Text(verbatim: Languages.name(code)).tag(code) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
        }
        if LanguageAtLaunch.needsRestart(s.language) {
            RowDivider()
            SettingRow(title: String(localized: "Restart Obscura to use the new language"),
                       help: String(localized: "Quit and reopen Obscura in the new language")) {
                Button(String(localized: "Restart Now")) {
                    if services.relaunch() { model.router?.quit() }
                }
                .buttonStyle(OButtonStyle(.primary, size: .small))
            }
        }
    }

    @ViewBuilder private var loginRow: some View {
        let status = system.loginItem
        SettingRow(title: String(localized: "Open at login"),
                   help: status == .notFound ? String(localized: "Available once Obscura is in your Applications folder")
                                             : String(localized: "Stay protected after a restart")) {
            if status == .requiresApproval {
                Badge(String(localized: "Approval needed"), tone: .needs, symbol: "exclamationmark.triangle")
                Button(String(localized: "Open Login Items…")) { services.openLoginItems() }.buttonStyle(OButtonStyle(.warn, size: .small))
            }
            AsyncSwitch(label: String(localized: "Open at login"), isOn: status == .enabled || status == .requiresApproval) { on in
                _ = services.setLoginItem(on)
                await refresh()
            }
            .disabled(status == .notFound)
        }
    }

    private func setLanguage(_ code: String?) {
        model.updateSettings { $0.language = code }
        // macOS reads an app's language from its own AppleLanguages default at launch.
        guard SystemServices.isAppBundle else { return }
        if let code { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
        else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
    }

    // MARK: Links

    @ViewBuilder private var linkRows: some View {
        SettingRow(title: String(localized: "Send feedback"),
                   help: ProductLinks.feedbackEmail.map { String(localized: "Opens a new mail to \($0) in your mail app") }
                       ?? String(localized: "Opens a new issue on GitHub in your browser")) {
            Button { if let url = ProductLinks.feedback { services.open(url) } } label: { Label(String(localized: "Write…"), systemImage: "envelope") }
                .buttonStyle(OButtonStyle(.quiet, size: .small)).disabled(ProductLinks.feedback == nil)
        }
        RowDivider()
        SettingRow(title: String(localized: "Open source"), help: String(localized: "MIT licence. Read the code, file an issue, or build it yourself")) {
            Button { if let url = ProductLinks.repository { services.open(url) } } label: {
                Label(String(localized: "View on GitHub"), systemImage: "arrow.triangle.branch")
            }
            .buttonStyle(OButtonStyle(.quiet, size: .small)).disabled(ProductLinks.repository == nil)
        }
        RowDivider()
        SettingRow(title: String(localized: "Website"),
                   help: ProductLinks.website.map { String(localized: "\(ProductLinks.display($0)) — the manual and release notes") }
                       ?? String(localized: "The manual and release notes")) {
            Button { if let url = ProductLinks.website { services.open(url) } } label: {
                Label(String(localized: "Open"), systemImage: "arrow.up.right.square")
            }
            .buttonStyle(OButtonStyle(.quiet, size: .small)).disabled(ProductLinks.website == nil)
        }
    }
}

/// The app's own icon, or the mark on the accent outside an app bundle (tests, previews).
/// Settings → About → Menu bar icon (G-21): the sixteen marks and the colour style, each applied to the menu bar at once.
struct MenuBarIconPicker: View {
    let model: AppModel

    var body: some View {
        let s = model.settings
        MarkPicker(selection: s.menuBarMark, style: s.menuBarMarkStyle, state: model.markState, pausedColor: s.pausedColor,
                   onPick: { mark in model.updateSettings { $0.menuBarMark = mark } },
                   onStyle: { style in model.updateSettings { $0.menuBarMarkStyle = style } })
    }
}

struct AppIcon: View {
    var body: some View {
        if SystemServices.isAppBundle {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().interpolation(.high)
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 15, style: .continuous).fill(OColor.accent)
                .overlay(ObscuraMark(.protected).foregroundStyle(.white).padding(14))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 4)
                .accessibilityHidden(true)
        }
    }
}

/// The languages the bundle ships, by their own names.
enum Languages {
    static var available: [String] {
        var codes = Bundle.main.localizations.filter { $0 != "Base" }
        if !codes.contains("en") { codes.insert("en", at: 0) }
        return codes
    }

    static func name(_ code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forIdentifier: code)?.capitalized(with: locale) ?? code
    }
}

/// The language Obscura is running in: the setting as it was the first time Settings opened in this process.
@MainActor
enum LanguageAtLaunch {
    private static var value: String??

    static func capture(_ current: String?) {
        if value == nil { value = .some(current) }
    }

    static func needsRestart(_ current: String?) -> Bool {
        guard let launch = value else { return false }
        return launch != current
    }
}
