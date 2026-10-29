public import Foundation
import ObscuraSupport

/// The production `SettingsWriter`: every scalar setting lives in `UserDefaults` under its `SettingsKey`.
///
/// Invariants:
/// - Every key has a registered default, so `object(forKey:)` is never `nil` and "absent" never means "default" by accident.
/// - A stored value of the wrong type or outside the allowed set is coerced to its default and logged (never thrown).
/// - `update` runs the transform under a lock, writes only the keys that changed, and emits once.
/// - Changes made elsewhere in this process (`defaults.set`, the `defaults` tool is out of scope: the notification is
///   in-process only) are observed through `UserDefaults.didChangeNotification`, debounced, and emitted when they
///   produce a different `Settings` value.
public final class UserDefaultsSettingsStore: SettingsWriter, @unchecked Sendable {
    private let defaults: UserDefaults
    /// Guards `lastEmitted` and serialises read-transform-write in `update`.
    private let lock = NSLock()
    private var lastEmitted: Settings
    /// Guards `pendingReload` alone. `UserDefaults.didChangeNotification` is posted synchronously inside `set`,
    /// i.e. while `update` still holds `lock`; the observer must therefore never take `lock`.
    private let reloadLock = NSLock()
    private var pendingReload: Task<Void, Never>?
    private var observer: (any NSObjectProtocol)?
    private let broadcaster = SettingsBroadcaster()
    private let debounce: Duration

    /// - Parameters:
    ///   - defaults: the domain to use; tests pass a throwaway suite.
    ///   - debounce: how long to wait after an external change before re-reading. Coalesces bursts of writes.
    public init(defaults: UserDefaults = .standard, debounce: Duration = .milliseconds(50)) {
        self.defaults = defaults
        self.debounce = debounce
        SettingsMigration.migrateIfNeeded(defaults: defaults)
        defaults.register(defaults: Self.registrationDictionary)
        lastEmitted = Self.read(from: defaults)
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in
            self?.scheduleReload()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        pendingReload?.cancel()
        broadcaster.finish()
    }

    // MARK: SettingsReader / SettingsWriter

    public func current() -> Settings {
        lock.withLock { Self.read(from: defaults) }
    }

    public var changes: AsyncStream<Settings> {
        broadcaster.makeStream()
    }

    public func update(_ transform: @Sendable (inout Settings) -> Void) {
        let emitted: Settings? = lock.withLock {
            let before = Self.read(from: defaults)
            var next = before
            transform(&next)
            guard next != before else { return nil }
            Self.write(next, over: before, to: defaults)
            lastEmitted = next
            return next
        }
        if let emitted { broadcaster.send(emitted) }
    }

    // MARK: External changes

    private func scheduleReload() {
        reloadLock.withLock {
            pendingReload?.cancel()
            pendingReload = Task { [weak self, debounce] in
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
                self?.reloadAndEmitIfChanged()
            }
        }
    }

    private func reloadAndEmitIfChanged() {
        let emitted: Settings? = lock.withLock {
            let now = Self.read(from: defaults)
            guard now != lastEmitted else { return nil }
            lastEmitted = now
            return now
        }
        if let emitted { broadcaster.send(emitted) }
    }

    // MARK: Registration

    /// The dictionary handed to `register(defaults:)`: one entry per `SettingsKey`.
    /// `language` registers as the empty string, which reads back as `nil` ("system"); the registration domain
    /// cannot hold `nil`, and an unregistered key is exactly the ambiguity the spec forbids.
    static var registrationDictionary: [String: Any] {
        let d = Settings.default
        var dict: [String: Any] = [:]
        for key in SettingsKey.allCases {
            dict[key.rawValue] = Self.plistValue(of: d, for: key)
        }
        return dict
    }

    private static let languageSystemSentinel = ""
    /// `protection.pausedUntil` registers as `Date.distantPast` ("ended long ago"), which reads back as `nil`
    /// (protecting), for the same reason as the language sentinel.
    static let pausedUntilNoneSentinel = Date.distantPast

    private static func plistValue(of s: Settings, for key: SettingsKey) -> Any {
        switch key {
        case .guardsScreenshotFolder: s.guardsScreenshotFolder
        case .guardsDownloads: s.guardsDownloads
        case .guardsClipboard: s.guardsClipboard
        case .extraFolders: s.extraFolders
        case .fileHandling: s.fileHandling.rawValue
        case .copiesCleanImage: s.copiesCleanImage
        case .showsNotifications: s.showsNotifications
        case .journalRetentionHours: s.journalRetention.hours
        case .allowRuleMode: s.allowRuleMode.rawValue
        case .ocrPixelBudget: s.ocrPixelBudget
        case .ocrTimeoutSeconds: s.ocrTimeoutSeconds
        case .appearance: s.appearance.rawValue
        case .language: s.language ?? languageSystemSentinel
        case .updatesCheckAutomatically: s.updatesCheckAutomatically
        case .hasFinishedSetup: s.hasFinishedSetup
        case .journalView: s.journalView.rawValue
        case .journalShowsInspector: s.journalShowsInspector
        case .detectorsShowPatterns: s.detectorsShowPatterns
        case .pausedUntil: s.pausedUntil ?? pausedUntilNoneSentinel
        case .setupStepsSeen: s.setupStepsSeen
        case .thumbnailEnabled: s.thumbnailEnabled
        case .thumbnailSeconds: s.thumbnailSeconds
        case .thumbnailClickOpens: s.thumbnailClickOpens.rawValue
        case .showsUncoveredKeyText: s.showsUncoveredKeyText
        case .keyBindings: s.keyBindings.overrides
        case .patternModeScope: s.patternModeScope.rawValue
        case .rulesShowPatterns: s.rulesShowPatterns
        case .showsPatternNumber: s.showsPatternNumber
        case .catchSound: s.catchSound
        case .confirmsUndo: s.confirmsUndo
        case .compareStyle: s.compareStyle.rawValue
        case .pausedColor: s.pausedColor.rawValue
        case .reservesBadgeSpace: s.reservesBadgeSpace
        case .reopenShows: s.reopenShows.rawValue
        case .pauseChoicesOpen: s.pauseChoicesOpen.rawValue
        case .journalInspectorMotion: s.journalInspectorMotion.rawValue
        case .coversUnreadableSpots: s.coversUnreadableSpots
        case .skipsTinySpots: s.skipsTinySpots
        case .indexesCatchesInSpotlight: s.indexesCatchesInSpotlight
        case .tagsCoveredFiles: s.tagsCoveredFiles
        case .menuBarMark: s.menuBarMark.rawValue
        case .menuBarMarkStyle: s.menuBarMarkStyle.rawValue
        }
    }

    // MARK: Read

    /// Reads every key with its exact type. Anything malformed is replaced by the default and logged by key name.
    static func read(from defaults: UserDefaults) -> Settings {
        var s = Settings.default
        s.guardsScreenshotFolder = bool(defaults, .guardsScreenshotFolder, s.guardsScreenshotFolder)
        s.guardsDownloads = bool(defaults, .guardsDownloads, s.guardsDownloads)
        s.guardsClipboard = bool(defaults, .guardsClipboard, s.guardsClipboard)
        s.extraFolders = stringArray(defaults, .extraFolders, s.extraFolders)
        s.fileHandling = enumValue(defaults, .fileHandling, s.fileHandling)
        s.copiesCleanImage = bool(defaults, .copiesCleanImage, s.copiesCleanImage)
        s.showsNotifications = bool(defaults, .showsNotifications, s.showsNotifications)
        s.journalRetention = retention(defaults, s.journalRetention)
        s.allowRuleMode = enumValue(defaults, .allowRuleMode, s.allowRuleMode)
        s.ocrPixelBudget = positiveInt(defaults, .ocrPixelBudget, s.ocrPixelBudget)
        s.ocrTimeoutSeconds = positiveDouble(defaults, .ocrTimeoutSeconds, s.ocrTimeoutSeconds)
        s.appearance = enumValue(defaults, .appearance, s.appearance)
        s.language = language(defaults)
        s.updatesCheckAutomatically = bool(defaults, .updatesCheckAutomatically, s.updatesCheckAutomatically)
        s.hasFinishedSetup = bool(defaults, .hasFinishedSetup, s.hasFinishedSetup)
        s.journalView = enumValue(defaults, .journalView, s.journalView)
        s.journalShowsInspector = bool(defaults, .journalShowsInspector, s.journalShowsInspector)
        s.detectorsShowPatterns = bool(defaults, .detectorsShowPatterns, s.detectorsShowPatterns)
        s.pausedUntil = pausedUntil(defaults)
        s.setupStepsSeen = stringArray(defaults, .setupStepsSeen, s.setupStepsSeen)
        s.thumbnailEnabled = bool(defaults, .thumbnailEnabled, s.thumbnailEnabled)
        s.thumbnailSeconds = positiveDouble(defaults, .thumbnailSeconds, s.thumbnailSeconds)
        s.thumbnailClickOpens = enumValue(defaults, .thumbnailClickOpens, s.thumbnailClickOpens)
        s.showsUncoveredKeyText = bool(defaults, .showsUncoveredKeyText, s.showsUncoveredKeyText)
        s.keyBindings = keyBindings(defaults)
        s.patternModeScope = enumValue(defaults, .patternModeScope, s.patternModeScope)
        s.rulesShowPatterns = bool(defaults, .rulesShowPatterns, s.rulesShowPatterns)
        s.showsPatternNumber = bool(defaults, .showsPatternNumber, s.showsPatternNumber)
        s.catchSound = bool(defaults, .catchSound, s.catchSound)
        s.confirmsUndo = bool(defaults, .confirmsUndo, s.confirmsUndo)
        s.compareStyle = enumValue(defaults, .compareStyle, s.compareStyle)
        s.pausedColor = enumValue(defaults, .pausedColor, s.pausedColor)
        s.reservesBadgeSpace = bool(defaults, .reservesBadgeSpace, s.reservesBadgeSpace)
        s.reopenShows = enumValue(defaults, .reopenShows, s.reopenShows)
        s.pauseChoicesOpen = enumValue(defaults, .pauseChoicesOpen, s.pauseChoicesOpen)
        s.journalInspectorMotion = enumValue(defaults, .journalInspectorMotion, s.journalInspectorMotion)
        s.coversUnreadableSpots = bool(defaults, .coversUnreadableSpots, s.coversUnreadableSpots)
        s.skipsTinySpots = bool(defaults, .skipsTinySpots, s.skipsTinySpots)
        s.indexesCatchesInSpotlight = bool(defaults, .indexesCatchesInSpotlight, s.indexesCatchesInSpotlight)
        s.tagsCoveredFiles = bool(defaults, .tagsCoveredFiles, s.tagsCoveredFiles)
        s.menuBarMark = enumValue(defaults, .menuBarMark, s.menuBarMark)
        s.menuBarMarkStyle = enumValue(defaults, .menuBarMarkStyle, s.menuBarMarkStyle)
        return s
    }

    private static func coerced(_ key: SettingsKey) {
        // The value is a preference, never secret text, but only the key name is logged anyway.
        Log.app.error("setting \(key.rawValue, privacy: .public) held an invalid value; using the default")
    }

    private static func bool(_ d: UserDefaults, _ key: SettingsKey, _ fallback: Bool) -> Bool {
        let value = d.object(forKey: key.rawValue)
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        // Launch arguments (`-guards.clipboard NO`) and `defaults write` without `-bool` arrive as text. Accept the
        // forms macOS itself means as Booleans; anything else is a type error, never a guessed truthy value.
        // (Before: "NO" was rejected and the default, on, was used, so a guard asked to be off stayed on.)
        if let text = value as? String {
            switch text.lowercased() {
            case "yes", "true", "1": return true
            case "no", "false", "0": return false
            default: break
            }
        }
        if let n = value as? NSNumber, n.intValue == 0 || n.intValue == 1, n.doubleValue == Double(n.intValue) { return n.intValue == 1 }
        coerced(key)
        return fallback
    }

    /// A number stored as a number, or as decimal text (launch arguments, `defaults write` without a type).
    private static func number(_ d: UserDefaults, _ key: String) -> NSNumber? {
        let value = d.object(forKey: key)
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n }
        if let text = value as? String, let v = Double(text.trimmingCharacters(in: .whitespaces)) { return NSNumber(value: v) }
        return nil
    }

    private static func stringArray(_ d: UserDefaults, _ key: SettingsKey, _ fallback: [String]) -> [String] {
        if let a = d.object(forKey: key.rawValue) as? [String] { return a }
        coerced(key)
        return fallback
    }

    private static func enumValue<E: RawRepresentable>(_ d: UserDefaults, _ key: SettingsKey, _ fallback: E) -> E
    where E.RawValue == String {
        if let raw = d.object(forKey: key.rawValue) as? String, let value = E(rawValue: raw) { return value }
        coerced(key)
        return fallback
    }

    private static func retention(_ d: UserDefaults, _ fallback: JournalRetention) -> JournalRetention {
        if let n = number(d, SettingsKey.journalRetentionHours.rawValue), n.doubleValue == Double(n.intValue),
           let value = JournalRetention(rawValue: n.intValue) {
            return value
        }
        coerced(.journalRetentionHours)
        return fallback
    }

    private static func positiveInt(_ d: UserDefaults, _ key: SettingsKey, _ fallback: Int) -> Int {
        if let n = number(d, key.rawValue), n.doubleValue == Double(n.intValue), n.intValue > 0 { return n.intValue }
        coerced(key)
        return fallback
    }

    private static func positiveDouble(_ d: UserDefaults, _ key: SettingsKey, _ fallback: Double) -> Double {
        if let n = number(d, key.rawValue), n.doubleValue.isFinite, n.doubleValue > 0 { return n.doubleValue }
        coerced(key)
        return fallback
    }

    private static func language(_ d: UserDefaults) -> String? {
        guard let raw = d.object(forKey: SettingsKey.language.rawValue) as? String else {
            coerced(.language)
            return nil
        }
        return raw == languageSystemSentinel ? nil : raw
    }

    /// A stored date; the registered sentinel (or anything at or before it) is `nil`. A value that is not a date is a
    /// type error and reads as protecting: a malformed value must never leave every guard off.
    private static func pausedUntil(_ d: UserDefaults) -> Date? {
        guard let date = d.object(forKey: SettingsKey.pausedUntil.rawValue) as? Date else {
            coerced(.pausedUntil)
            return nil
        }
        return date <= pausedUntilNoneSentinel ? nil : date
    }

    /// The shortcut overrides: a dictionary of text to text. Anything else is a type error and reads as no changes
    /// (every command at its default); a single unreadable entry is ignored by `KeyBindings` itself.
    private static func keyBindings(_ d: UserDefaults) -> KeyBindings {
        guard let raw = d.object(forKey: SettingsKey.keyBindings.rawValue) as? [String: Any] else {
            coerced(.keyBindings)
            return .defaults
        }
        return KeyBindings(overrides: raw.compactMapValues { $0 as? String })
    }

    // MARK: Write

    /// Writes only the keys whose value differs between `before` and `next`.
    static func write(_ next: Settings, over before: Settings, to d: UserDefaults) {
        for key in SettingsKey.allCases {
            let old = plistValue(of: before, for: key)
            let new = plistValue(of: next, for: key)
            guard !isEqualPlist(old, new) else { continue }
            d.set(new, forKey: key.rawValue)
        }
    }

    private static func isEqualPlist(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case let (x as Bool, y as Bool): x == y
        case let (x as Int, y as Int): x == y
        case let (x as Double, y as Double): x == y
        case let (x as String, y as String): x == y
        case let (x as [String], y as [String]): x == y
        case let (x as Date, y as Date): x == y
        case let (x as [String: String], y as [String: String]): x == y
        default: false
        }
    }
}
