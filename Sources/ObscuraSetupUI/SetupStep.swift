// The setup window's nine rail rows, their three groups and the state each row can show
// (design/mockups/unified/onboarding.html, from onboarding/r3-a "Setup window: catch first, status rail, resumable").
public import ObscuraUIKit

/// The rail's three parts, in order.
public enum SetupGroup: String, CaseIterable, Sendable, Hashable {
    case catchFirst, allow, keep

    public var title: String {
        switch self {
        case .catchFirst: return String(localized: "Catch")
        case .allow: return String(localized: "Allow")
        case .keep: return String(localized: "Keep")
        }
    }

    public var steps: [SetupStep] { SetupStep.allCases.filter { $0.group == self } }
}

/// One rail row. `allCases` is the order the window walks through.
public enum SetupStep: String, CaseIterable, Sendable, Hashable, Identifiable {
    case theCatch, welcome, screenshotFolder, downloads, floatingThumbnail, notifications, openAtLogin
    /// G-21: "Pick your menu bar icon". Until it is passed the menu bar shows the Classic ring.
    case menuBarIcon
    case done

    public var id: String { rawValue }

    public var group: SetupGroup {
        switch self {
        case .theCatch, .welcome: return .catchFirst
        case .screenshotFolder, .downloads, .floatingThumbnail: return .allow
        case .notifications, .openAtLogin, .menuBarIcon, .done: return .keep
        }
    }

    /// The rail label.
    public var title: String {
        switch self {
        case .theCatch: return String(localized: "The catch")
        case .welcome: return String(localized: "What Obscura is")
        case .screenshotFolder: return String(localized: "Screenshot folder")
        case .downloads: return String(localized: "Downloads")
        case .floatingThumbnail: return String(localized: "Floating thumbnail")
        case .notifications: return String(localized: "Notifications")
        case .openAtLogin: return String(localized: "Open at login")
        case .menuBarIcon: return String(localized: "Menu bar icon")
        case .done: return String(localized: "Done")
        }
    }

    /// Optional rows say so on the rail from the first screen.
    public var isOptional: Bool { self == .downloads }

    /// Where this setting lives once setup is closed (the footer line and the Done list).
    public var settingsHome: SettingsPane? {
        switch self {
        case .screenshotFolder, .downloads, .floatingThumbnail, .notifications: return .protection
        case .openAtLogin, .menuBarIcon: return .about
        case .theCatch, .welcome, .done: return nil
        }
    }

    var next: SetupStep? {
        let all = SetupStep.allCases
        guard let i = all.firstIndex(of: self), i + 1 < all.count else { return nil }
        return all[i + 1]
    }
}

/// What a rail row shows. State is carried by a symbol inside the dot as well as its colour.
public enum SetupStepState: Sendable, Hashable {
    /// Not reached yet.
    case pending
    /// Granted, turned off, or read.
    case done
    /// An optional row the user passed without turning it on.
    case skipped
    /// Refused or put off, still protected (orange).
    case declined
    /// Refused and screenshots are not checked (red).
    case unprotected

    /// Counts toward "N of 9 done".
    public var isFinished: Bool { self == .done || self == .skipped }

    var tone: Tone? {
        switch self {
        case .pending: return nil
        case .done: return .ok
        case .skipped: return .quiet
        case .declined: return .needs
        case .unprotected: return .live
        }
    }

    var symbol: String? {
        switch self {
        case .pending: return nil
        case .done: return "checkmark"
        case .skipped: return "minus"
        case .declined: return "exclamationmark"
        case .unprotected: return "xmark"
        }
    }

    /// Spoken after the row's title.
    var accessibilityWord: String {
        switch self {
        case .pending: return String(localized: "not done yet")
        case .done: return String(localized: "done")
        case .skipped: return String(localized: "skipped")
        case .declined: return String(localized: "not allowed, still protected")
        case .unprotected: return String(localized: "not allowed, screenshots aren't checked")
        }
    }
}
