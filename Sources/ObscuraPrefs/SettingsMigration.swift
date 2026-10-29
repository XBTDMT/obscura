public import Foundation
import ObscuraSupport

/// Versioned hook for renaming or re-typing stored keys. The schema version is itself a default so a
/// future rename is a code change here, not a scattered one.
public enum SettingsMigration {
    /// The `UserDefaults` key holding the schema version of the stored settings.
    public static let schemaVersionKey = "settings.schemaVersion"
    /// The schema this build writes. A new key with a registered default (G-40's `ocr.coversUnreadableSpots` and
    /// `ocr.skipsTinySpots`, both off) needs no step: a Mac that never stored it reads the default, so the schema only
    /// moves for a rename or a re-type.
    public static let currentSchemaVersion = 2
    /// Schema 1's Boolean pause key, retired at schema 2 for `protection.pausedUntil`.
    static let legacyPausedKey = "protection.paused"

    /// Brings the stored settings up to `currentSchemaVersion`. Idempotent.
    /// Stores the version only after every step for it has run, so a crash mid-way re-runs the step.
    public static func migrateIfNeeded(defaults: UserDefaults) {
        let stored = defaults.object(forKey: schemaVersionKey) as? Int ?? 0
        guard stored < currentSchemaVersion else { return }
        var version = stored
        while version < currentSchemaVersion {
            switch version {
            case 1:
                // 1 → 2: the Boolean `protection.paused` becomes the date `protection.pausedUntil`. A pause stored as
                // a Boolean had no end, so it stays paused until the user resumes.
                if defaults.object(forKey: legacyPausedKey) as? Bool == true {
                    defaults.set(Date.distantFuture, forKey: SettingsKey.pausedUntil.rawValue)
                }
                defaults.removeObject(forKey: legacyPausedKey)
            default:
                // 0 → 1: the first schema; nothing to rename.
                break
            }
            version += 1
            defaults.set(version, forKey: schemaVersionKey)
        }
        Log.app.info("settings schema migrated from \(stored) to \(version)")
    }
}
