// G-38: carrying the stored settings from an earlier identity's defaults domain to this one's, once, on the first launch
// under this identity. macOS keeps preferences per bundle identifier, so without this a renamed Obscura would start from
// the defaults and run setup again.
//
// What is carried: every `SettingsKey`, the schema version and the key it retired, the small memories the app keeps
// beside its settings (the menu bar panel's, the login item's, the language override) and the window and status item
// positions AppKit stores for the app. Only these: a key the app does not know is not copied.
//
// When: only while this domain has no `settings.schemaVersion` yet (the settings store writes one at its first launch,
// so after that this never runs again), and a key this domain already holds is never overwritten. The schema version
// is written last, so a launch that stops half way copies the rest next time; `SettingsMigration` then brings the copied
// values up to this build's schema as usual.
//
// The earlier domain is left as it is: it holds preferences only (no rule text, no secret; rule values live sealed in
// the Journal), the earlier build still finds its own settings if it is ever opened again, and this app writes nothing
// under another identity's name.
public import Foundation
import ObscuraSupport

public enum PreviousIdentityDefaults {
    /// Keys the app stores beside `SettingsKey` that are worth keeping across an identity change. Each owning module
    /// has a test that its key is listed here.
    public static let companionKeys: Set<String> = [
        "menuBar.lastSeen", "menuBar.pauseChoice",   // ObscuraMenuBarUI.PanelMemory
        "loginItem.lastKnownOn",                     // ObscuraCapture.LoginItem
        "AppleLanguages",                            // Settings → About → Language (the per-app override)
    ]

    /// Key prefixes AppKit uses for state it keeps for the app: window frames, the status item's position and
    /// visibility, split views, open and save panels.
    public static let appKitPrefixes = ["NSWindow Frame ", "NSStatusItem ", "NSSplitView Subview Frames ", "NSNavPanel",
                                        "NSNavLast", "NSOSPLast"]

    /// Whether `key` is carried over.
    public static func carries(_ key: String) -> Bool {
        if SettingsKey(rawValue: key) != nil { return true }
        if key == SettingsMigration.schemaVersionKey || key == SettingsMigration.legacyPausedKey { return true }
        if companionKeys.contains(key) { return true }
        return appKitPrefixes.contains { key.hasPrefix($0) }
    }

    public enum Outcome: Sendable, Equatable {
        /// This domain already has a schema version: it is set up (or was migrated before).
        case alreadySetUp
        /// The earlier domain holds nothing to carry.
        case nothingToCarry
        /// `copied` keys written; `kept` keys this domain already held and were left alone.
        case carried(copied: Int, kept: Int)
    }

    /// Copies the carried keys of `previous` (the earlier identity's persistent domain, as
    /// `persistentDomain(forName:)` returns it) into `current`, whose own persistent domain is `currentDomain`.
    public static func migrate(from previous: [String: Any]?, to current: UserDefaults, currentDomain: [String: Any]?) -> Outcome {
        let existing = currentDomain ?? [:]
        guard existing[SettingsMigration.schemaVersionKey] == nil else { return .alreadySetUp }
        let carried = (previous ?? [:]).filter { carries($0.key) }
        guard !carried.isEmpty else { return .nothingToCarry }
        var copied = 0, kept = 0
        // The schema version last: it is the marker that the copy finished.
        let ordered = carried.keys.sorted { a, b in
            (a == SettingsMigration.schemaVersionKey ? 1 : 0, a) < (b == SettingsMigration.schemaVersionKey ? 1 : 0, b)
        }
        for key in ordered {
            guard existing[key] == nil else { kept += 1; continue }
            current.set(carried[key], forKey: key)
            copied += 1
        }
        Log.app.info("settings carried from the earlier identity: copied=\(copied) kept=\(kept)")
        return .carried(copied: copied, kept: kept)
    }
}
