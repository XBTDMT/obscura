public import Foundation

/// Every scalar preference Obscura stores in `UserDefaults`, typed, with its default.
///
/// List-shaped data (rules, detector overrides, detector state, styles) is NOT here: it lives in
/// SQLite owned by `ObscuraJournal`. Derived values (`openAtLogin`) are never stored.
///
/// The `Codable` form uses the `SettingsKey` strings as JSON keys, so an exported settings document
/// reads the same as the defaults domain.
public struct Settings: Codable, Sendable, Hashable {
    public var guardsScreenshotFolder: Bool = true
    public var guardsDownloads: Bool = false
    public var guardsClipboard: Bool = true
    public var extraFolders: [String] = []
    public var fileHandling: FileHandling = .replace
    /// Put the final picture of each checked screenshot on the clipboard (G-18): a screenshot-folder file that reaches a
    /// verdict, clean or covered, so ⇧⌘4 then ⌘V pastes the clean picture. Never the original, never another source.
    public var copiesCleanImage: Bool = true
    public var showsNotifications: Bool = true
    /// Stored as hours; only the four `JournalRetention` values are valid.
    public var journalRetention: JournalRetention = .oneDay
    public var allowRuleMode: AllowRuleMode = .trim
    public var ocrPixelBudget: Int = 24_000_000
    public var ocrTimeoutSeconds: Double = 20.0
    public var appearance: Appearance = .system
    /// `nil` means "follow the system language".
    public var language: String? = nil
    public var updatesCheckAutomatically: Bool = true
    public var hasFinishedSetup: Bool = false
    public var journalView: JournalView = .grid
    public var journalShowsInspector: Bool = true
    public var detectorsShowPatterns: Bool = false
    /// When the current pause ends (`protection.pausedUntil`): `nil` = protecting; `Date.distantFuture` = paused until
    /// the user resumes; any other date = a timed pause. A date already past means the pause ran out while the app was
    /// not running: the app resumes protection and clears it at launch (`AppModel.start`).
    public var pausedUntil: Date? = nil
    /// Setup steps the user has passed (`SetupStep` raw values), so setup resumes at the first one not yet passed.
    public var setupStepsSeen: [String] = []
    /// Obscura's own floating thumbnail after each new screenshot is checked (B-9, G-8).
    public var thumbnailEnabled: Bool = true
    /// Seconds the thumbnail stays before sliding away (hover pauses it).
    public var thumbnailSeconds: Double = 5
    /// What clicking the thumbnail opens.
    public var thumbnailClickOpens: ThumbnailClick = .preview
    /// Show a finding left visible as text with a Copy button, read again from the original on demand (G-17). Off by
    /// default, so a fresh install never shows a secret as text. The text itself is never stored anywhere.
    public var showsUncoveredKeyText: Bool = false
    /// The person's keyboard shortcut changes (G-20); every command not in it has its catalogue default.
    public var keyBindings: KeyBindings = .defaults

    // MARK: G-19 options (each defaults to the pick ruled on the decision page)

    /// Whether Detectors and Custom Rules share one Plain words / Regular expressions choice (#2).
    public var patternModeScope: PatternModeScope = .appWide
    /// Custom Rules' own choice, read only while `patternModeScope` is `.perPane`; app-wide, both read
    /// `detectorsShowPatterns`.
    public var rulesShowPatterns: Bool = false
    /// The test line's "pattern 1 of 2" tag in plain-words mode (#6). Regular expressions always show it.
    public var showsPatternNumber: Bool = true
    /// Every catch notification plays the notification sound (#8); off, only problems do.
    public var catchSound: Bool = false
    /// Undo asks before it shows an original (#11).
    public var confirmsUndo: Bool = false
    /// How the Viewer's Space compare draws the two images (#15).
    public var compareStyle: CompareStyle = .sideBySide
    /// The colour that shows "Paused" (#17).
    public var pausedColor: PausedColor = .red
    /// Keep the count badge's width on the menu bar item while panel-only mode is on, so nothing beside it moves (S-12).
    public var reservesBadgeSpace: Bool = false
    /// What opening Obscura again shows when no window is open and setup is finished (M-6).
    public var reopenShows: ReopenTarget = .panel
    /// How the panel's pause choices open (M-15a).
    public var pauseChoicesOpen: PauseChoicesTrigger = .hover
    /// How the Journal's inspector shows and hides (T-8).
    public var journalInspectorMotion: InspectorMotion = .instant

    // MARK: G-40 unread spots (both off by default: the person settles each spot in the viewer)

    /// Cover each small spot Obscura can't read (a mark that looks like text to the detector but that no reading can
    /// read), padded past its edges, instead of listing the picture under Not checked (route B). The entry says how many
    /// such spots were covered: the picture is never presented as fully read.
    public var coversUnreadableSpots: Bool = false
    /// Skip a spot too small to hold the shortest secret the enabled detectors and custom rules can report (route D). A
    /// skipped spot is recorded and outlined, never silent. Decides before `coversUnreadableSpots`.
    public var skipsTinySpots: Bool = false

    // MARK: G-24 search labels (defaults in `SearchIndexDefaults`, decided by a test on an installed copy)

    /// Each covered file gets a Spotlight entry under the kind of secret it hid (labels only, never the secret).
    /// Switching it off removes every entry Obscura made.
    public var indexesCatchesInSpotlight: Bool = SearchIndexDefaults.spotlightEntries
    /// Each covered file gets the Finder tags "Obscura" and the kind of secret. Switching it off removes the tags
    /// Obscura added, never the person's own.
    public var tagsCoveredFiles: Bool = SearchIndexDefaults.finderTags
    // MARK: G-21 the menu bar mark
    /// The menu bar mark the person picked (setup's "Pick your menu bar icon" step, Settings → About). A fresh install
    /// shows the Classic ring until they pick.
    public var menuBarMark: MenuBarMarkID = .classic
    /// How the picked mark's designed part is coloured; One colour is the template image macOS tints.
    public var menuBarMarkStyle: MenuBarMarkStyle = .warm

    public init() {}

    /// The retention as an hour count. Setting an unsupported value coerces to the default (24).
    public var journalRetentionHours: Int {
        get { journalRetention.hours }
        set { journalRetention = JournalRetention(coercingHours: newValue) }
    }

    /// Whether protection is paused. Derived from `pausedUntil` and never stored on its own, so the engine (which skips
    /// every source while this is true) and the resume time cannot disagree. Setting `true` keeps an existing end and
    /// otherwise pauses until resumed; setting `false` clears the pause.
    public var protectionPaused: Bool {
        get { pausedUntil != nil }
        set { pausedUntil = newValue ? (pausedUntil ?? .distantFuture) : nil }
    }

    /// Paused with no end: only the user's Resume ends it.
    public var isPausedUntilResumed: Bool {
        guard let pausedUntil else { return false }
        return pausedUntil >= .distantFuture
    }

    /// The defaults, as a value.
    public static let `default` = Settings()

    // MARK: Codable (keys are the UserDefaults key strings)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: SettingsKey.self)
        var s = Settings()
        s.guardsScreenshotFolder = try c.decodeIfPresent(Bool.self, forKey: .guardsScreenshotFolder) ?? s.guardsScreenshotFolder
        s.guardsDownloads = try c.decodeIfPresent(Bool.self, forKey: .guardsDownloads) ?? s.guardsDownloads
        s.guardsClipboard = try c.decodeIfPresent(Bool.self, forKey: .guardsClipboard) ?? s.guardsClipboard
        s.extraFolders = try c.decodeIfPresent([String].self, forKey: .extraFolders) ?? s.extraFolders
        s.fileHandling = try c.decodeIfPresent(FileHandling.self, forKey: .fileHandling) ?? s.fileHandling
        s.copiesCleanImage = try c.decodeIfPresent(Bool.self, forKey: .copiesCleanImage) ?? s.copiesCleanImage
        s.showsNotifications = try c.decodeIfPresent(Bool.self, forKey: .showsNotifications) ?? s.showsNotifications
        if let hours = try c.decodeIfPresent(Int.self, forKey: .journalRetentionHours) {
            s.journalRetention = JournalRetention(coercingHours: hours)
        }
        s.allowRuleMode = try c.decodeIfPresent(AllowRuleMode.self, forKey: .allowRuleMode) ?? s.allowRuleMode
        s.ocrPixelBudget = try c.decodeIfPresent(Int.self, forKey: .ocrPixelBudget) ?? s.ocrPixelBudget
        s.ocrTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .ocrTimeoutSeconds) ?? s.ocrTimeoutSeconds
        s.appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? s.appearance
        s.language = try c.decodeIfPresent(String.self, forKey: .language)
        s.updatesCheckAutomatically = try c.decodeIfPresent(Bool.self, forKey: .updatesCheckAutomatically) ?? s.updatesCheckAutomatically
        s.hasFinishedSetup = try c.decodeIfPresent(Bool.self, forKey: .hasFinishedSetup) ?? s.hasFinishedSetup
        s.journalView = try c.decodeIfPresent(JournalView.self, forKey: .journalView) ?? s.journalView
        s.journalShowsInspector = try c.decodeIfPresent(Bool.self, forKey: .journalShowsInspector) ?? s.journalShowsInspector
        s.detectorsShowPatterns = try c.decodeIfPresent(Bool.self, forKey: .detectorsShowPatterns) ?? s.detectorsShowPatterns
        s.pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        // A document written before schema 2 carries the old Boolean instead; a pause from then had no end.
        if s.pausedUntil == nil, try decoder.container(keyedBy: LegacySettingsKey.self)
            .decodeIfPresent(Bool.self, forKey: .protectionPaused) == true {
            s.pausedUntil = .distantFuture
        }
        s.setupStepsSeen = try c.decodeIfPresent([String].self, forKey: .setupStepsSeen) ?? s.setupStepsSeen
        s.thumbnailEnabled = try c.decodeIfPresent(Bool.self, forKey: .thumbnailEnabled) ?? s.thumbnailEnabled
        if let v = try c.decodeIfPresent(Double.self, forKey: .thumbnailSeconds), v.isFinite, v > 0 { s.thumbnailSeconds = v }
        s.thumbnailClickOpens = (try? c.decodeIfPresent(ThumbnailClick.self, forKey: .thumbnailClickOpens)) ?? s.thumbnailClickOpens
        s.showsUncoveredKeyText = try c.decodeIfPresent(Bool.self, forKey: .showsUncoveredKeyText) ?? s.showsUncoveredKeyText
        s.keyBindings = (try? c.decodeIfPresent(KeyBindings.self, forKey: .keyBindings)) ?? s.keyBindings
        // G-19: an older document has none of these and decodes to the picks; an unknown enum value does too.
        s.patternModeScope = (try? c.decodeIfPresent(PatternModeScope.self, forKey: .patternModeScope)) ?? s.patternModeScope
        s.rulesShowPatterns = try c.decodeIfPresent(Bool.self, forKey: .rulesShowPatterns) ?? s.rulesShowPatterns
        s.showsPatternNumber = try c.decodeIfPresent(Bool.self, forKey: .showsPatternNumber) ?? s.showsPatternNumber
        s.catchSound = try c.decodeIfPresent(Bool.self, forKey: .catchSound) ?? s.catchSound
        s.confirmsUndo = try c.decodeIfPresent(Bool.self, forKey: .confirmsUndo) ?? s.confirmsUndo
        s.compareStyle = (try? c.decodeIfPresent(CompareStyle.self, forKey: .compareStyle)) ?? s.compareStyle
        s.pausedColor = (try? c.decodeIfPresent(PausedColor.self, forKey: .pausedColor)) ?? s.pausedColor
        s.reservesBadgeSpace = try c.decodeIfPresent(Bool.self, forKey: .reservesBadgeSpace) ?? s.reservesBadgeSpace
        s.reopenShows = (try? c.decodeIfPresent(ReopenTarget.self, forKey: .reopenShows)) ?? s.reopenShows
        s.pauseChoicesOpen = (try? c.decodeIfPresent(PauseChoicesTrigger.self, forKey: .pauseChoicesOpen)) ?? s.pauseChoicesOpen
        s.journalInspectorMotion = (try? c.decodeIfPresent(InspectorMotion.self, forKey: .journalInspectorMotion)) ?? s.journalInspectorMotion
        // G-40: an older document has neither and decodes to off.
        s.coversUnreadableSpots = try c.decodeIfPresent(Bool.self, forKey: .coversUnreadableSpots) ?? s.coversUnreadableSpots
        s.skipsTinySpots = try c.decodeIfPresent(Bool.self, forKey: .skipsTinySpots) ?? s.skipsTinySpots
        s.indexesCatchesInSpotlight = try c.decodeIfPresent(Bool.self, forKey: .indexesCatchesInSpotlight) ?? s.indexesCatchesInSpotlight
        s.tagsCoveredFiles = try c.decodeIfPresent(Bool.self, forKey: .tagsCoveredFiles) ?? s.tagsCoveredFiles
        // G-21: an older document has neither and decodes to the defaults; a mark or style a newer build added does too.
        s.menuBarMark = (try? c.decodeIfPresent(MenuBarMarkID.self, forKey: .menuBarMark)) ?? s.menuBarMark
        s.menuBarMarkStyle = (try? c.decodeIfPresent(MenuBarMarkStyle.self, forKey: .menuBarMarkStyle)) ?? s.menuBarMarkStyle
        self = s
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: SettingsKey.self)
        try c.encode(guardsScreenshotFolder, forKey: .guardsScreenshotFolder)
        try c.encode(guardsDownloads, forKey: .guardsDownloads)
        try c.encode(guardsClipboard, forKey: .guardsClipboard)
        try c.encode(extraFolders, forKey: .extraFolders)
        try c.encode(fileHandling, forKey: .fileHandling)
        try c.encode(copiesCleanImage, forKey: .copiesCleanImage)
        try c.encode(showsNotifications, forKey: .showsNotifications)
        try c.encode(journalRetention.hours, forKey: .journalRetentionHours)
        try c.encode(allowRuleMode, forKey: .allowRuleMode)
        try c.encode(ocrPixelBudget, forKey: .ocrPixelBudget)
        try c.encode(ocrTimeoutSeconds, forKey: .ocrTimeoutSeconds)
        try c.encode(appearance, forKey: .appearance)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encode(updatesCheckAutomatically, forKey: .updatesCheckAutomatically)
        try c.encode(hasFinishedSetup, forKey: .hasFinishedSetup)
        try c.encode(journalView, forKey: .journalView)
        try c.encode(journalShowsInspector, forKey: .journalShowsInspector)
        try c.encode(detectorsShowPatterns, forKey: .detectorsShowPatterns)
        try c.encodeIfPresent(pausedUntil, forKey: .pausedUntil)
        try c.encode(setupStepsSeen, forKey: .setupStepsSeen)
        try c.encode(thumbnailEnabled, forKey: .thumbnailEnabled)
        try c.encode(thumbnailSeconds, forKey: .thumbnailSeconds)
        try c.encode(thumbnailClickOpens, forKey: .thumbnailClickOpens)
        try c.encode(showsUncoveredKeyText, forKey: .showsUncoveredKeyText)
        try c.encode(keyBindings, forKey: .keyBindings)
        try c.encode(patternModeScope, forKey: .patternModeScope)
        try c.encode(rulesShowPatterns, forKey: .rulesShowPatterns)
        try c.encode(showsPatternNumber, forKey: .showsPatternNumber)
        try c.encode(catchSound, forKey: .catchSound)
        try c.encode(confirmsUndo, forKey: .confirmsUndo)
        try c.encode(compareStyle, forKey: .compareStyle)
        try c.encode(pausedColor, forKey: .pausedColor)
        try c.encode(reservesBadgeSpace, forKey: .reservesBadgeSpace)
        try c.encode(reopenShows, forKey: .reopenShows)
        try c.encode(pauseChoicesOpen, forKey: .pauseChoicesOpen)
        try c.encode(journalInspectorMotion, forKey: .journalInspectorMotion)
        try c.encode(coversUnreadableSpots, forKey: .coversUnreadableSpots)
        try c.encode(skipsTinySpots, forKey: .skipsTinySpots)
        try c.encode(indexesCatchesInSpotlight, forKey: .indexesCatchesInSpotlight)
        try c.encode(tagsCoveredFiles, forKey: .tagsCoveredFiles)
        try c.encode(menuBarMark, forKey: .menuBarMark)
        try c.encode(menuBarMarkStyle, forKey: .menuBarMarkStyle)
    }
}

/// The `UserDefaults` key of every scalar setting (ARCHITECTURE.md §6). Also the `CodingKey` of `Settings`.
public enum SettingsKey: String, CaseIterable, CodingKey, Sendable {
    case guardsScreenshotFolder = "guards.screenshotFolder"
    case guardsDownloads = "guards.downloads"
    case guardsClipboard = "guards.clipboard"
    case extraFolders = "guards.extraFolders"
    case fileHandling
    case copiesCleanImage
    case showsNotifications
    case journalRetentionHours
    case allowRuleMode
    case ocrPixelBudget = "ocr.pixelBudget"
    case ocrTimeoutSeconds = "ocr.timeoutSeconds"
    case appearance
    case language
    case updatesCheckAutomatically = "updates.checksAutomatically"
    case hasFinishedSetup
    case journalView = "journal.view"
    case journalShowsInspector = "journal.showsInspector"
    case detectorsShowPatterns = "detectors.showsPatterns"
    case pausedUntil = "protection.pausedUntil"
    case setupStepsSeen = "setup.stepsSeen"
    case thumbnailEnabled = "thumbnail.enabled"
    case thumbnailSeconds = "thumbnail.seconds"
    case thumbnailClickOpens = "thumbnail.clickOpens"
    case showsUncoveredKeyText = "journal.showsUncoveredKeyText"
    case keyBindings = "shortcuts.overrides"
    // G-19
    case patternModeScope = "patterns.modeScope"
    case rulesShowPatterns = "rules.showsPatterns"
    case showsPatternNumber = "patterns.showsNumber"
    case catchSound = "notifications.catchSound"
    case confirmsUndo = "undo.confirms"
    case compareStyle = "viewer.compareStyle"
    case pausedColor = "protection.pausedColor"
    case reservesBadgeSpace = "menuBar.reservesBadgeSpace"
    case reopenShows = "app.reopenShows"
    case pauseChoicesOpen = "menuBar.pauseChoicesOpen"
    case journalInspectorMotion = "journal.inspectorMotion"
    // G-40
    case coversUnreadableSpots = "ocr.coversUnreadableSpots"
    case skipsTinySpots = "ocr.skipsTinySpots"
    // G-24
    case indexesCatchesInSpotlight = "search.spotlightEntries"
    case tagsCoveredFiles = "search.finderTags"
    // G-21
    case menuBarMark = "menuBar.mark"
    case menuBarMarkStyle = "menuBar.markStyle"
}

/// Keys `SettingsMigration` retired, still read from an exported document written before the migration.
enum LegacySettingsKey: String, CodingKey {
    /// Schema 1's Boolean pause; schema 2 replaced it with `protection.pausedUntil`.
    case protectionPaused = "protection.paused"
}

/// What happens to the file that was caught: overwrite it with the clean image, or write a clean copy beside it.
public enum FileHandling: String, Codable, Sendable, Hashable, CaseIterable {
    case replace
    case keepBoth
}

/// How long a journal entry (and its images) is kept. Stored as hours.
public enum JournalRetention: Int, Codable, Sendable, Hashable, CaseIterable {
    case oneHour = 1
    case oneDay = 24
    case oneWeek = 168
    case thirtyDays = 720

    public static let `default`: JournalRetention = .oneDay

    public var hours: Int { rawValue }

    /// Exact match or the default; unsupported hour counts are never stored.
    public init(coercingHours hours: Int) {
        self = JournalRetention(rawValue: hours) ?? .default
    }
}

/// How an allow rule interacts with a finding it overlaps (Obscura's own option).
public enum AllowRuleMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Trim the allowed text out of the finding and keep the remainder.
    case trim
    /// Drop the finding only when it lies entirely inside the allowed text.
    case containedOnly
}

public enum Appearance: String, Codable, Sendable, Hashable, CaseIterable {
    case system
    case light
    case dark
}

/// What clicking Obscura's floating thumbnail opens.
public enum ThumbnailClick: String, Codable, Sendable, Hashable, CaseIterable {
    case preview
    case viewer
}

public enum JournalView: String, Codable, Sendable, Hashable, CaseIterable {
    case grid
    case list
}

// MARK: - G-19 option values

/// Whether the Detectors and Custom Rules panes share one Plain words / Regular expressions choice.
public enum PatternModeScope: String, Codable, Sendable, Hashable, CaseIterable {
    case appWide
    case perPane
}

/// How the Viewer compares the covered image with the original (Space).
public enum CompareStyle: String, Codable, Sendable, Hashable, CaseIterable {
    /// The two images next to each other.
    case sideBySide
    /// One picture with a divider dragged across it: covered on one side, original on the other.
    case wipe
}

/// The colour that shows "Paused" on the mark, in the panel and in Settings. Three of the design system's status
/// tones; green is left out because it means protected.
public enum PausedColor: String, Codable, Sendable, Hashable, CaseIterable {
    case red
    case orange
    case grey
}

/// What opening Obscura again (Finder, Spotlight, Launchpad, the Dock) shows when no window is open and setup is done.
public enum ReopenTarget: String, Codable, Sendable, Hashable, CaseIterable {
    case panel
    case settings
    case journal
}

/// How the menu bar panel's pause choices open: when the pointer rests on the row (a click works too), or on a click only.
public enum PauseChoicesTrigger: String, Codable, Sendable, Hashable, CaseIterable {
    case hover
    case click
}

/// How the Journal's inspector shows and hides.
public enum InspectorMotion: String, Codable, Sendable, Hashable, CaseIterable {
    /// At once (G-15).
    case instant
    /// The system's slide; instant under Reduce Motion.
    case slide
}

// MARK: - G-21 menu bar mark values

/// The marks a person can pick for the menu bar (G-21, ruled 2026-10-27): the Classic ring Obscura shipped with,
/// then the fifteen picked from the mark gallery, in the gallery's order. Raw values are stored, so
/// they never change once shipped.
public enum MenuBarMarkID: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case classic
    case twoTone
    case pixelatedHalf
    case dissolving
    case halfBar
    case redactedLines
    case patched
    case scanlines
    case checkerBand
    case keyholeSplit
    case shutter
    case orbit
    case segments
    case viewfinder
    case yinYang
    case shield

    public var id: String { rawValue }
}

/// How a mark's designed part is coloured (G-21 colour order: Warm, Glass, Indigo; One colour stays available).
public enum MenuBarMarkStyle: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    /// Indigo to pink to orange.
    case warm
    /// Blue to indigo to violet.
    case glass
    /// The brand indigo alone.
    case indigo
    /// No colour: the whole mark in the menu bar's own colour, as a template image.
    case oneColor

    public var id: String { rawValue }
}

public extension Settings {
    /// Whether the given pane shows its patterns as regular expressions, following `patternModeScope`.
    func showsPatterns(in pane: PatternPane) -> Bool {
        switch (patternModeScope, pane) {
        case (.appWide, _), (.perPane, .detectors): return detectorsShowPatterns
        case (.perPane, .customRules): return rulesShowPatterns
        }
    }

    /// Sets the given pane's choice; app-wide, it is the one shared choice.
    mutating func setShowsPatterns(_ on: Bool, in pane: PatternPane) {
        switch (patternModeScope, pane) {
        case (.appWide, _), (.perPane, .detectors): detectorsShowPatterns = on
        case (.perPane, .customRules): rulesShowPatterns = on
        }
    }

    /// Switches between one shared choice and one per pane. Going per pane starts Custom Rules on the shared choice,
    /// so nothing on screen changes until the user flips one pane.
    mutating func setPatternModeScope(_ scope: PatternModeScope) {
        if scope == .perPane, patternModeScope == .appWide { rulesShowPatterns = detectorsShowPatterns }
        patternModeScope = scope
    }
}

/// The two panes that show patterns.
public enum PatternPane: Sendable, Hashable {
    case detectors
    case customRules
}
