// One verdict vocabulary for every surface (unified pass, CHANGES.md): "Safe to share" / "N of N left visible" /
// "Original showing", and the protection sentences. Surfaces never write these words themselves.
import Foundation
public import ObscuraEngine
import ObscuraJournal
public import ObscuraPrefs
public import SwiftUI

/// What a caught screenshot's file holds right now.
public enum Verdict: Sendable, Hashable {
    /// Every finding is covered.
    case safeToShare(total: Int)
    /// Some findings were left visible on purpose.
    case leftVisible(visible: Int, total: Int)
    /// Every finding is visible: the file is the original.
    case originalShowing(total: Int)

    public init(enabled: Int, total: Int) {
        if total == 0 || enabled == total { self = .safeToShare(total: total) }
        else if enabled == 0 { self = .originalShowing(total: total) }
        else { self = .leftVisible(visible: total - enabled, total: total) }
    }

    public var title: String {
        switch self {
        case .safeToShare: return String(localized: "Safe to share")
        case .leftVisible(let v, let t): return String(localized: "\(v) of \(t) left visible")
        case .originalShowing: return String(localized: "Original showing")
        }
    }

    public var tone: Tone {
        switch self {
        case .safeToShare: return .ok
        case .leftVisible: return .needs
        case .originalShowing: return .live
        }
    }

    /// The SF Symbol beside the verdict words, so the verdict reads in shape as well as colour (every mockup draws a
    /// tick for safe, an eye for left visible and a warning triangle for the original).
    public var symbol: String {
        switch self {
        case .safeToShare: return "checkmark"
        case .leftVisible: return "eye"
        case .originalShowing: return "exclamationmark.triangle"
        }
    }

    /// The line under the title in the inspector and the viewer strip.
    public var detail: String {
        switch self {
        case .safeToShare(let t): return t == 1 ? String(localized: "1 secret blacked out. The file matches this preview.")
                                              : String(localized: "All \(t) secrets blacked out. The file matches this preview.")
        case .leftVisible: return String(localized: "The file and the copied image show what you left visible.")
        case .originalShowing: return String(localized: "The file and the copied image contain every secret.")
        }
    }
}

/// Protection words for the panel, the Settings foot strip and setup.
public enum ProtectionCopy {
    public static func title(_ state: ProtectionState) -> String {
        switch state {
        case .protected: return String(localized: "Protected")
        case .partlyProtected: return String(localized: "Partly protected")
        case .paused: return String(localized: "Paused")
        case .needsAttention: return String(localized: "Needs attention")
        }
    }

    /// The state's tone; Paused is the colour the user chose (`Settings.pausedColor`, G-19 #17: red by default).
    public static func tone(_ state: ProtectionState, pausedColor: PausedColor = .red) -> Tone {
        switch state {
        case .protected: return .ok
        case .partlyProtected, .needsAttention: return .needs
        case .paused: return pausedColor.tone
        }
    }

    /// A count phrase that is always grammatical: "1 secret", "3 secrets".
    public static func secrets(_ n: Int) -> String {
        n == 1 ? String(localized: "1 secret") : String(localized: "\(n) secrets")
    }

    public static func images(_ n: Int) -> String {
        n == 1 ? String(localized: "1 image") : String(localized: "\(n) images")
    }
}

/// Human titles for detector ids, resolved from the built-in catalogue; custom rules fall back to their stored name.
public enum DetectorNames {
    public static func title(for id: String) -> String {
        if let d = ObscuraDetectBridge.builtInTitles[id] { return d }
        if id.hasPrefix("custom.") { return String(localized: "Your rule") }
        // G-40: a spot's cover is not a secret's kind.
        if id == SpotRecord.coverDetectorID { return String(localized: "Unreadable spot") }
        return id
    }
}

public extension ObscuraPrefs.Appearance {
    /// nil follows the Mac's appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
