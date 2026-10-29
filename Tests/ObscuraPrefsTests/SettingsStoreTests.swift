import Foundation
import Testing
import ObscuraTestSupport
@testable import ObscuraPrefs

// MARK: - Fixtures
// Every UserDefaults store here runs on a throwaway TestDefaults domain (ObscuraTestSupport), kept outside
// ~/Library/Preferences and removed when the test process exits.

/// A fully non-default `Settings`, to prove every field round-trips.
func allChanged(_ s: inout Settings) {
    s.guardsScreenshotFolder = false
    s.guardsDownloads = true
    s.guardsClipboard = false
    s.extraFolders = ["/home/example/Desktop", "/home/example/Pictures/Shots"]
    s.fileHandling = .keepBoth
    s.copiesCleanImage = false
    s.showsNotifications = false
    s.journalRetention = .oneWeek
    s.allowRuleMode = .containedOnly
    s.ocrPixelBudget = 12_000_000
    s.ocrTimeoutSeconds = 7.5
    s.appearance = .dark
    s.language = "fr"
    s.updatesCheckAutomatically = false
    s.hasFinishedSetup = true
    s.journalView = .list
    s.journalShowsInspector = false
    s.detectorsShowPatterns = true
    s.pausedUntil = Date(timeIntervalSinceReferenceDate: 815_000_000)
    s.setupStepsSeen = ["catch", "welcome"]
    s.thumbnailEnabled = false
    s.thumbnailSeconds = 8
    s.thumbnailClickOpens = .viewer
    s.showsUncoveredKeyText = true
    s.keyBindings.set(KeyChord("k", [.control, .command]), for: .journalImport)
    s.keyBindings.set(nil, for: .viewerZoomToFit)
    s.patternModeScope = .perPane
    s.rulesShowPatterns = true
    s.showsPatternNumber = false
    s.catchSound = true
    s.confirmsUndo = true
    s.compareStyle = .wipe
    s.pausedColor = .orange
    s.reservesBadgeSpace = true
    s.reopenShows = .journal
    s.pauseChoicesOpen = .click
    s.journalInspectorMotion = .slide
    s.indexesCatchesInSpotlight = !SearchIndexDefaults.spotlightEntries
    s.tagsCoveredFiles = !SearchIndexDefaults.finderTags
    s.menuBarMark = .pixelatedHalf
    s.menuBarMarkStyle = .glass
    s.coversUnreadableSpots = true
    s.skipsTinySpots = true
}

/// Waits for the first element of `stream`, failing the test instead of hanging.
func firstValue(of stream: AsyncStream<Settings>, within timeout: Duration = .seconds(5)) async -> Settings? {
    await withTaskGroup(of: Settings?.self) { group in
        group.addTask { for await v in stream { return v }; return nil }
        group.addTask { try? await Task.sleep(for: timeout); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

// MARK: - Shared conformance cases (run against both stores)

enum StoreConformance {
    static func startsAtDefaults(_ store: some SettingsWriter) {
        #expect(store.current() == .default)
    }

    static func roundTripsEveryField(_ store: some SettingsWriter) {
        var expected = Settings.default
        allChanged(&expected)
        store.update(allChanged)
        let got = store.current()
        #expect(got == expected)
        // Field by field so a failure names the field.
        #expect(got.guardsScreenshotFolder == false)
        #expect(got.guardsDownloads == true)
        #expect(got.guardsClipboard == false)
        #expect(got.extraFolders == ["/home/example/Desktop", "/home/example/Pictures/Shots"])
        #expect(got.fileHandling == .keepBoth)
        #expect(got.copiesCleanImage == false)
        #expect(got.showsNotifications == false)
        #expect(got.journalRetentionHours == 168)
        #expect(got.allowRuleMode == .containedOnly)
        #expect(got.ocrPixelBudget == 12_000_000)
        #expect(got.ocrTimeoutSeconds == 7.5)
        #expect(got.appearance == .dark)
        #expect(got.language == "fr")
        #expect(got.updatesCheckAutomatically == false)
        #expect(got.hasFinishedSetup == true)
        #expect(got.journalView == .list)
        #expect(got.journalShowsInspector == false)
        #expect(got.detectorsShowPatterns == true)
        #expect(got.pausedUntil == Date(timeIntervalSinceReferenceDate: 815_000_000))
        #expect(got.setupStepsSeen == ["catch", "welcome"])
        #expect(got.thumbnailEnabled == false)
        #expect(got.thumbnailSeconds == 8)
        #expect(got.thumbnailClickOpens == .viewer)
        #expect(got.showsUncoveredKeyText == true)
        #expect(got.patternModeScope == .perPane)
        #expect(got.rulesShowPatterns == true)
        #expect(got.showsPatternNumber == false)
        #expect(got.catchSound == true)
        #expect(got.confirmsUndo == true)
        #expect(got.compareStyle == .wipe)
        #expect(got.pausedColor == .orange)
        #expect(got.reservesBadgeSpace == true)
        #expect(got.reopenShows == .journal)
        #expect(got.pauseChoicesOpen == .click)
        #expect(got.journalInspectorMotion == .slide)
        #expect(got.indexesCatchesInSpotlight == !SearchIndexDefaults.spotlightEntries)
        #expect(got.tagsCoveredFiles == !SearchIndexDefaults.finderTags)
        #expect(got.menuBarMark == .pixelatedHalf)
        #expect(got.menuBarMarkStyle == .glass)
    }

    static func languageRoundTripsBackToNil(_ store: some SettingsWriter) {
        store.update { $0.language = "de" }
        #expect(store.current().language == "de")
        store.update { $0.language = nil }
        #expect(store.current().language == nil)
    }

    static func invalidRetentionViaHoursSetterIsCoerced(_ store: some SettingsWriter) {
        store.update { $0.journalRetentionHours = 5 }
        #expect(store.current().journalRetentionHours == 24)
        store.update { $0.journalRetentionHours = 720 }
        #expect(store.current().journalRetention == .thirtyDays)
    }

    static func changesEmitsOnceAfterUpdate(_ store: some SettingsWriter) async {
        let stream = store.changes
        store.update { $0.protectionPaused = true }
        let first = await firstValue(of: stream)
        #expect(first?.protectionPaused == true)
        #expect(first == store.current())
    }

    static func noOpUpdateEmitsNothing(_ store: some SettingsWriter) async {
        let stream = store.changes
        store.update { _ in }
        store.update { $0.appearance = .system }  // already the default
        let got = await firstValue(of: stream, within: .milliseconds(300))
        #expect(got == nil)
    }

    static func twoListenersBothReceive(_ store: some SettingsWriter) async {
        let a = store.changes
        let b = store.changes
        store.update { $0.journalView = .list }
        let (ra, rb) = (await firstValue(of: a), await firstValue(of: b))
        #expect(ra?.journalView == .list)
        #expect(rb?.journalView == .list)
    }

    static func codableRoundTrip(_ store: some SettingsWriter) throws {
        store.update(allChanged)
        let data = try JSONEncoder().encode(store.current())
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded == store.current())
        let keys = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(Set(keys?.keys.map { $0 } ?? []) == Set(SettingsKey.allCases.map(\.rawValue)))
    }
}

// MARK: - InMemorySettingsStore

@Suite struct InMemorySettingsStoreTests {
    @Test func startsAtDefaults() { StoreConformance.startsAtDefaults(InMemorySettingsStore()) }
    @Test func roundTripsEveryField() { StoreConformance.roundTripsEveryField(InMemorySettingsStore()) }
    @Test func languageRoundTripsBackToNil() { StoreConformance.languageRoundTripsBackToNil(InMemorySettingsStore()) }
    @Test func invalidRetentionCoerced() { StoreConformance.invalidRetentionViaHoursSetterIsCoerced(InMemorySettingsStore()) }
    @Test func changesEmitsAfterUpdate() async { await StoreConformance.changesEmitsOnceAfterUpdate(InMemorySettingsStore()) }
    @Test func noOpUpdateEmitsNothing() async { await StoreConformance.noOpUpdateEmitsNothing(InMemorySettingsStore()) }
    @Test func twoListenersBothReceive() async { await StoreConformance.twoListenersBothReceive(InMemorySettingsStore()) }
    @Test func codableRoundTrip() throws { try StoreConformance.codableRoundTrip(InMemorySettingsStore()) }
    @Test func seededInitialValue() {
        var seed = Settings.default
        seed.hasFinishedSetup = true
        #expect(InMemorySettingsStore(seed).current().hasFinishedSetup == true)
    }
}

// MARK: - UserDefaultsSettingsStore

@Suite struct UserDefaultsSettingsStoreTests {
    @Test func startsAtDefaults() {
        let tmp = TestDefaults("settings")
        StoreConformance.startsAtDefaults(UserDefaultsSettingsStore(defaults: tmp.defaults))
    }
    @Test func roundTripsEveryField() {
        let tmp = TestDefaults("settings")
        StoreConformance.roundTripsEveryField(UserDefaultsSettingsStore(defaults: tmp.defaults))
    }
    @Test func languageRoundTripsBackToNil() {
        let tmp = TestDefaults("settings")
        StoreConformance.languageRoundTripsBackToNil(UserDefaultsSettingsStore(defaults: tmp.defaults))
    }
    @Test func invalidRetentionCoerced() {
        let tmp = TestDefaults("settings")
        StoreConformance.invalidRetentionViaHoursSetterIsCoerced(UserDefaultsSettingsStore(defaults: tmp.defaults))
    }
    @Test func changesEmitsAfterUpdate() async {
        let tmp = TestDefaults("settings")
        await StoreConformance.changesEmitsOnceAfterUpdate(UserDefaultsSettingsStore(defaults: tmp.defaults))
    }
    @Test func noOpUpdateEmitsNothing() async {
        let tmp = TestDefaults("settings")
        await StoreConformance.noOpUpdateEmitsNothing(UserDefaultsSettingsStore(defaults: tmp.defaults))
    }
    @Test func twoListenersBothReceive() async {
        let tmp = TestDefaults("settings")
        await StoreConformance.twoListenersBothReceive(UserDefaultsSettingsStore(defaults: tmp.defaults))
    }
    @Test func codableRoundTrip() throws {
        let tmp = TestDefaults("settings")
        try StoreConformance.codableRoundTrip(UserDefaultsSettingsStore(defaults: tmp.defaults))
    }

    // UserDefaults-specific behaviour

    @Test func everyKeyHasARegisteredDefault() {
        let tmp = TestDefaults("settings")
        _ = UserDefaultsSettingsStore(defaults: tmp.defaults)
        for key in SettingsKey.allCases {
            #expect(tmp.defaults.object(forKey: key.rawValue) != nil, "\(key.rawValue) is not registered")
        }
        #expect(UserDefaultsSettingsStore.registrationDictionary.count == SettingsKey.allCases.count)
    }

    @Test func registeredDefaultsReadBackAsTheDefaultSettings() {
        let tmp = TestDefaults("settings")
        _ = UserDefaultsSettingsStore(defaults: tmp.defaults)
        #expect(tmp.defaults.bool(forKey: "guards.screenshotFolder") == true)
        #expect(tmp.defaults.bool(forKey: "guards.downloads") == false)
        #expect(tmp.defaults.string(forKey: "fileHandling") == "replace")
        #expect(tmp.defaults.integer(forKey: "journalRetentionHours") == 24)
        #expect(tmp.defaults.integer(forKey: "ocr.pixelBudget") == 24_000_000)
        #expect(tmp.defaults.double(forKey: "ocr.timeoutSeconds") == 20.0)
        #expect(tmp.defaults.string(forKey: "appearance") == "system")
        #expect(tmp.defaults.stringArray(forKey: "guards.extraFolders") == [])
    }

    @Test func updateWritesOnlyChangedKeysAndPersists() {
        let tmp = TestDefaults("settings")
        let store = UserDefaultsSettingsStore(defaults: tmp.defaults)
        store.update { $0.fileHandling = .keepBoth }
        let persisted = tmp.defaults.persistentDomain(forName: tmp.suiteName) ?? [:]
        #expect(persisted["fileHandling"] as? String == "keepBoth")
        #expect(persisted["guards.clipboard"] == nil)  // untouched keys stay in the registration domain
        // A second store over the same domain sees the written value.
        #expect(UserDefaultsSettingsStore(defaults: tmp.defaults).current().fileHandling == .keepBoth)
    }

    @Test func invalidStoredRetentionIsCoercedToDefault() {
        let tmp = TestDefaults("settings")
        tmp.defaults.set(5, forKey: "journalRetentionHours")
        let store = UserDefaultsSettingsStore(defaults: tmp.defaults)
        #expect(store.current().journalRetention == .oneDay)
        // Reading does not rewrite the stored value; a later update does.
        #expect(tmp.defaults.integer(forKey: "journalRetentionHours") == 5)
        store.update { $0.journalRetention = .oneHour }
        #expect(tmp.defaults.integer(forKey: "journalRetentionHours") == 1)
    }

    @Test func wrongTypesAreCoercedToDefaults() {
        let tmp = TestDefaults("settings")
        tmp.defaults.set("sometimes", forKey: "guards.clipboard")    // text that is not a Boolean
        tmp.defaults.set("sometimes", forKey: "appearance")           // unknown raw value
        tmp.defaults.set(-1, forKey: "ocr.pixelBudget")               // non-positive
        tmp.defaults.set(0.0, forKey: "ocr.timeoutSeconds")           // non-positive
        tmp.defaults.set(42, forKey: "guards.extraFolders")           // Int where [String] expected
        tmp.defaults.set(7, forKey: "language")                       // Int where String expected
        let s = UserDefaultsSettingsStore(defaults: tmp.defaults).current()
        #expect(s.guardsClipboard == true)
        #expect(s.appearance == .system)
        #expect(s.ocrPixelBudget == 24_000_000)
        #expect(s.ocrTimeoutSeconds == 20.0)
        #expect(s.extraFolders == [])
        #expect(s.language == nil)
    }

    @Test func launchArgumentTextIsReadAsMacOSMeansIt() {
        // `-guards.clipboard NO` on the command line, or `defaults write` without `-bool`, store text.
        let tmp = TestDefaults("settings")
        tmp.defaults.set("NO", forKey: "guards.clipboard")
        tmp.defaults.set("no", forKey: "guards.screenshotFolder")
        tmp.defaults.set("YES", forKey: "guards.downloads")
        tmp.defaults.set("0", forKey: "copiesCleanImage")
        tmp.defaults.set("false", forKey: "showsNotifications")
        tmp.defaults.set("168", forKey: "journalRetentionHours")
        tmp.defaults.set("12000000", forKey: "ocr.pixelBudget")
        tmp.defaults.set("7.5", forKey: "ocr.timeoutSeconds")
        let s = UserDefaultsSettingsStore(defaults: tmp.defaults).current()
        #expect(s.guardsClipboard == false)
        #expect(s.guardsScreenshotFolder == false)
        #expect(s.guardsDownloads == true)
        #expect(s.copiesCleanImage == false)
        #expect(s.showsNotifications == false)
        #expect(s.journalRetentionHours == 168)
        #expect(s.ocrPixelBudget == 12_000_000)
        #expect(s.ocrTimeoutSeconds == 7.5)
    }

    @Test func externalDefaultsWriteIsEmitted() async {
        let tmp = TestDefaults("settings")
        let store = UserDefaultsSettingsStore(defaults: tmp.defaults)
        let stream = store.changes
        tmp.defaults.set(Date.distantFuture, forKey: "protection.pausedUntil")
        let got = await firstValue(of: stream)
        #expect(got?.protectionPaused == true)
        #expect(store.current().protectionPaused == true)
    }

    @Test func externalBurstIsDebouncedToOneEmission() async {
        let tmp = TestDefaults("settings")
        let store = UserDefaultsSettingsStore(defaults: tmp.defaults, debounce: .milliseconds(100))
        let stream = store.changes
        tmp.defaults.set(true, forKey: "guards.downloads")
        tmp.defaults.set("dark", forKey: "appearance")
        tmp.defaults.set("list", forKey: "journal.view")
        let first = await firstValue(of: stream)
        #expect(first?.guardsDownloads == true)
        #expect(first?.appearance == .dark)
        #expect(first?.journalView == .list)
        let second = await firstValue(of: stream, within: .milliseconds(400))
        #expect(second == nil)
    }

    @Test func ownUpdateDoesNotEchoThroughTheObserver() async {
        let tmp = TestDefaults("settings")
        let store = UserDefaultsSettingsStore(defaults: tmp.defaults, debounce: .milliseconds(20))
        let stream = store.changes
        store.update { $0.hasFinishedSetup = true }
        let first = await firstValue(of: stream)
        #expect(first?.hasFinishedSetup == true)
        let echo = await firstValue(of: stream, within: .milliseconds(300))
        #expect(echo == nil)
    }

    @Test func externalWriteOfInvalidValueEmitsNothingWhenValueStaysDefault() async {
        let tmp = TestDefaults("settings")
        let store = UserDefaultsSettingsStore(defaults: tmp.defaults, debounce: .milliseconds(20))
        let stream = store.changes
        tmp.defaults.set(5, forKey: "journalRetentionHours")  // coerces to 24, which is what we already had
        let got = await firstValue(of: stream, within: .milliseconds(300))
        #expect(got == nil)
    }
}

// MARK: - Model

@Suite struct SettingsModelTests {
    @Test func defaultsMatchTheSpecTable() {
        let s = Settings.default
        #expect(s.guardsScreenshotFolder == true)
        #expect(s.guardsDownloads == false)
        #expect(s.guardsClipboard == true)
        #expect(s.extraFolders == [])
        #expect(s.fileHandling == .replace)
        #expect(s.copiesCleanImage == true)
        #expect(s.showsNotifications == true)
        #expect(s.journalRetentionHours == 24)
        #expect(s.allowRuleMode == .trim)
        #expect(s.ocrPixelBudget == 24_000_000)
        #expect(s.ocrTimeoutSeconds == 20.0)
        #expect(s.appearance == .system)
        #expect(s.language == nil)
        #expect(s.updatesCheckAutomatically == true)
        #expect(s.hasFinishedSetup == false)
        #expect(s.journalView == .grid)
        #expect(s.journalShowsInspector == true)
        #expect(s.detectorsShowPatterns == false)
        #expect(s.pausedUntil == nil && s.protectionPaused == false)
        #expect(s.setupStepsSeen == [])
        #expect(s.thumbnailEnabled == true)
        #expect(s.thumbnailSeconds == 5)
        #expect(s.thumbnailClickOpens == .preview)
        #expect(s.showsUncoveredKeyText == false)
        #expect(s.keyBindings == .defaults && s.keyBindings.overrides.isEmpty)
        // G-19: each new option defaults to the ruled pick.
        #expect(s.patternModeScope == .appWide)
        #expect(s.rulesShowPatterns == false)
        #expect(s.showsPatternNumber == true)
        #expect(s.catchSound == false)
        #expect(s.confirmsUndo == false)
        #expect(s.compareStyle == .sideBySide)
        #expect(s.pausedColor == .red)
        #expect(s.reservesBadgeSpace == false)
        #expect(s.reopenShows == .panel)
        #expect(s.pauseChoicesOpen == .hover)
        #expect(s.journalInspectorMotion == .instant)
        // G-24: one place holds both search defaults, provisional until a test on an installed copy decides them.
        #expect(s.indexesCatchesInSpotlight == SearchIndexDefaults.spotlightEntries)
        #expect(s.tagsCoveredFiles == SearchIndexDefaults.finderTags)
        // G-21
        #expect(s.menuBarMark == .classic)
        #expect(s.menuBarMarkStyle == .warm)
    }

    @Test func keyStringsMatchTheSpec() {
        let expected: Set<String> = [
            "guards.screenshotFolder", "guards.downloads", "guards.clipboard", "guards.extraFolders",
            "fileHandling", "copiesCleanImage", "showsNotifications", "journalRetentionHours", "allowRuleMode",
            "ocr.pixelBudget", "ocr.timeoutSeconds", "appearance", "language", "updates.checksAutomatically",
            "hasFinishedSetup", "journal.view", "journal.showsInspector", "detectors.showsPatterns", "protection.pausedUntil", "setup.stepsSeen", "thumbnail.enabled", "thumbnail.seconds", "thumbnail.clickOpens",
            "journal.showsUncoveredKeyText",
            "shortcuts.overrides",
            // G-19
            "patterns.modeScope", "rules.showsPatterns", "patterns.showsNumber", "notifications.catchSound", "undo.confirms",
            "viewer.compareStyle", "protection.pausedColor", "menuBar.reservesBadgeSpace", "app.reopenShows",
            "menuBar.pauseChoicesOpen", "journal.inspectorMotion",
            // G-24
            "search.spotlightEntries", "search.finderTags",
            // G-21
            "menuBar.mark", "menuBar.markStyle",
            // G-40
            "ocr.coversUnreadableSpots", "ocr.skipsTinySpots",
        ]
        #expect(Set(SettingsKey.allCases.map(\.rawValue)) == expected)
        #expect(SettingsKey.allCases.count == 42)
    }

    /// G-21: a fresh install shows the Classic ring in the Warm style until setup's step (or Settings) picks.
    @Test func theMenuBarMarkDefaultsToTheClassicRingInWarm() {
        #expect(Settings.default.menuBarMark == .classic)
        #expect(Settings.default.menuBarMarkStyle == .warm)
    }

    /// G-21: a document from before the menu bar marks has neither key and decodes to the defaults; a mark or style a
    /// newer build added falls back to them and never fails the document.
    @Test func menuBarMarkDecodingFallsBackToTheDefaults() throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"guards.clipboard": false}"#.utf8))
        #expect(old.menuBarMark == .classic && old.menuBarMarkStyle == .warm)
        let unknown = try JSONDecoder().decode(Settings.self, from: Data(#"{"menuBar.mark": "hexagon", "menuBar.markStyle": "neon", "undo.confirms": true}"#.utf8))
        #expect(unknown.menuBarMark == .classic && unknown.menuBarMarkStyle == .warm)
        #expect(unknown.confirmsUndo == true, "the rest of the document still reads")
        let picked = try JSONDecoder().decode(Settings.self, from: Data(#"{"menuBar.mark": "shutter", "menuBar.markStyle": "oneColor"}"#.utf8))
        #expect(picked.menuBarMark == .shutter && picked.menuBarMarkStyle == .oneColor)
    }

    /// A stored mark the build does not know (or the wrong type) reads as the default, as every enum setting does.
    @Test func anUnknownStoredMarkReadsAsTheClassicRing() {
        let tmp = TestDefaults("settings")
        tmp.defaults.set("hexagon", forKey: "menuBar.mark")
        tmp.defaults.set(7, forKey: "menuBar.markStyle")
        let s = UserDefaultsSettingsStore(defaults: tmp.defaults).current()
        #expect(s.menuBarMark == .classic)
        #expect(s.menuBarMarkStyle == .warm)
        tmp.defaults.set("yinYang", forKey: "menuBar.mark")
        #expect(UserDefaultsSettingsStore(defaults: tmp.defaults).current().menuBarMark == .yinYang)
    }

    /// Stored raw values never change once shipped: sixteen marks, the Classic ring first, then the gallery's order.
    @Test func g21RawValuesAreStable() {
        #expect(MenuBarMarkID.allCases.map(\.rawValue) == [
            "classic", "twoTone", "pixelatedHalf", "dissolving", "halfBar", "redactedLines", "patched", "scanlines",
            "checkerBand", "keyholeSplit", "shutter", "orbit", "segments", "viewfinder", "yinYang", "shield",
        ])
        #expect(MenuBarMarkStyle.allCases.map(\.rawValue) == ["warm", "glass", "indigo", "oneColor"])
    }

    @Test func retentionAcceptsOnlyTheFourValues() {
        #expect(JournalRetention.allCases.map(\.hours) == [1, 24, 168, 720])
        #expect(JournalRetention(coercingHours: 5) == .oneDay)
        #expect(JournalRetention(coercingHours: 0) == .oneDay)
        #expect(JournalRetention(coercingHours: 168) == .oneWeek)
    }

    @Test func enumRawValuesAreStrings() {
        #expect(FileHandling.keepBoth.rawValue == "keepBoth")
        #expect(AllowRuleMode.containedOnly.rawValue == "containedOnly")
        #expect(Appearance.allCases.map(\.rawValue) == ["system", "light", "dark"])
        #expect(JournalView.allCases.map(\.rawValue) == ["grid", "list"])
    }

    @Test func decodingCoercesInvalidRetentionAndFillsMissingKeys() throws {
        let json = Data(#"{"journalRetentionHours": 5, "appearance": "light"}"#.utf8)
        let s = try JSONDecoder().decode(Settings.self, from: json)
        #expect(s.journalRetention == .oneDay)
        #expect(s.appearance == .light)
        #expect(s.guardsClipboard == true)
    }

    /// G-24: the provisional defaults are Spotlight entries on, Finder tags off; a document written before G-24 decodes
    /// to them, and a stored value wins.
    @Test func searchSwitchesDecodeWithTheirDefaults() throws {
        #expect(SearchIndexDefaults.spotlightEntries == true)
        #expect(SearchIndexDefaults.finderTags == false)
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"guards.clipboard": false}"#.utf8))
        #expect(old.indexesCatchesInSpotlight == SearchIndexDefaults.spotlightEntries)
        #expect(old.tagsCoveredFiles == SearchIndexDefaults.finderTags)
        let set = try JSONDecoder().decode(Settings.self, from: Data(#"{"search.spotlightEntries": false, "search.finderTags": true}"#.utf8))
        #expect(set.indexesCatchesInSpotlight == false && set.tagsCoveredFiles == true)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings.default)) as? [String: Any]
        #expect(encoded?["search.spotlightEntries"] as? Bool == SearchIndexDefaults.spotlightEntries)
        #expect(encoded?["search.finderTags"] as? Bool == SearchIndexDefaults.finderTags)
    }

    /// A document written before G-19 has none of its keys: every one decodes to the ruled pick.
    @Test func aPreG19DocumentDecodesToThePicks() throws {
        let old = Data(#"{"guards.clipboard": false, "thumbnail.clickOpens": "viewer", "detectors.showsPatterns": true}"#.utf8)
        let s = try JSONDecoder().decode(Settings.self, from: old)
        var expected = Settings.default
        expected.guardsClipboard = false
        expected.thumbnailClickOpens = .viewer
        expected.detectorsShowPatterns = true
        #expect(s == expected)
    }

    /// A value this build does not know (a newer build wrote it) falls back to the pick and never fails the document.
    @Test func unknownG19ValuesFallBackToThePicks() throws {
        let json = Data(#"{"viewer.compareStyle": "carousel", "protection.pausedColor": "teal", "app.reopenShows": "dock", "menuBar.pauseChoicesOpen": "voice", "journal.inspectorMotion": "spin", "patterns.modeScope": "never", "undo.confirms": true}"#.utf8)
        let s = try JSONDecoder().decode(Settings.self, from: json)
        #expect(s.compareStyle == .sideBySide)
        #expect(s.pausedColor == .red)
        #expect(s.reopenShows == .panel)
        #expect(s.pauseChoicesOpen == .hover)
        #expect(s.journalInspectorMotion == .instant)
        #expect(s.patternModeScope == .appWide)
        #expect(s.confirmsUndo == true)
    }

    @Test func g19RawValuesAreStable() {
        #expect(CompareStyle.allCases.map(\.rawValue) == ["sideBySide", "wipe"])
        #expect(PausedColor.allCases.map(\.rawValue) == ["red", "orange", "grey"])
        #expect(ReopenTarget.allCases.map(\.rawValue) == ["panel", "settings", "journal"])
        #expect(PauseChoicesTrigger.allCases.map(\.rawValue) == ["hover", "click"])
        #expect(InspectorMotion.allCases.map(\.rawValue) == ["instant", "slide"])
        #expect(PatternModeScope.allCases.map(\.rawValue) == ["appWide", "perPane"])
    }

    /// #2: app-wide, both panes read and write the one choice; per pane, each keeps its own, and going per pane starts
    /// Custom Rules where the shared choice was.
    @Test func patternModeFollowsTheScope() {
        var s = Settings()
        s.setShowsPatterns(true, in: .customRules)
        #expect(s.showsPatterns(in: .detectors) && s.showsPatterns(in: .customRules))
        s.setPatternModeScope(.perPane)
        #expect(s.rulesShowPatterns == true, "per pane starts on the shared choice")
        s.setShowsPatterns(false, in: .detectors)
        #expect(!s.showsPatterns(in: .detectors))
        #expect(s.showsPatterns(in: .customRules))
        s.setPatternModeScope(.appWide)
        #expect(!s.showsPatterns(in: .customRules), "app-wide, Custom Rules follows the shared choice again")
    }

    /// A stored value the UserDefaults store cannot read is the pick, as for every other key.
    @Test func malformedStoredG19ValuesReadAsThePicks() {
        let tmp = TestDefaults()
        tmp.defaults.set("teal", forKey: "protection.pausedColor")
        tmp.defaults.set(42, forKey: "viewer.compareStyle")
        tmp.defaults.set("maybe", forKey: "undo.confirms")
        let s = UserDefaultsSettingsStore(defaults: tmp.defaults).current()
        #expect(s.pausedColor == .red)
        #expect(s.compareStyle == .sideBySide)
        #expect(s.confirmsUndo == false)
    }
}

// MARK: - Migration

@Suite struct SettingsMigrationTests {
    @Test func freshDomainIsStampedWithCurrentVersion() {
        let tmp = TestDefaults("settings")
        #expect(tmp.defaults.object(forKey: SettingsMigration.schemaVersionKey) == nil)
        SettingsMigration.migrateIfNeeded(defaults: tmp.defaults)
        #expect(tmp.defaults.integer(forKey: "settings.schemaVersion") == SettingsMigration.currentSchemaVersion)
        #expect(SettingsMigration.currentSchemaVersion == 2)
    }

    @Test func isIdempotentAndStoreRunsIt() {
        let tmp = TestDefaults("settings")
        _ = UserDefaultsSettingsStore(defaults: tmp.defaults)
        #expect(tmp.defaults.integer(forKey: "settings.schemaVersion") == 2)
        SettingsMigration.migrateIfNeeded(defaults: tmp.defaults)
        #expect(tmp.defaults.integer(forKey: "settings.schemaVersion") == 2)
    }

    @Test func newerVersionIsLeftAlone() {
        let tmp = TestDefaults("settings")
        tmp.defaults.set(99, forKey: "settings.schemaVersion")
        SettingsMigration.migrateIfNeeded(defaults: tmp.defaults)
        #expect(tmp.defaults.integer(forKey: "settings.schemaVersion") == 99)
    }

    @Test func schemaOnePauseBecomesPausedUntilResumed() {
        let tmp = TestDefaults("settings")
        tmp.defaults.set(1, forKey: "settings.schemaVersion")
        tmp.defaults.set(true, forKey: "protection.paused")
        let store = UserDefaultsSettingsStore(defaults: tmp.defaults)
        #expect(tmp.defaults.object(forKey: "protection.paused") == nil)
        #expect(store.current().pausedUntil == .distantFuture)
        #expect(store.current().isPausedUntilResumed)
        #expect(store.current().protectionPaused)
    }

    @Test func schemaOneProtectingStaysProtecting() {
        let tmp = TestDefaults("settings")
        tmp.defaults.set(1, forKey: "settings.schemaVersion")
        tmp.defaults.set(false, forKey: "protection.paused")
        let store = UserDefaultsSettingsStore(defaults: tmp.defaults)
        #expect(tmp.defaults.object(forKey: "protection.paused") == nil)
        #expect(store.current().pausedUntil == nil)
    }
}

// MARK: - The persisted pause

@Suite struct PausedUntilTests {
    @Test func timedIndefiniteAndNoPauseSurviveAReopen() {
        let tmp = TestDefaults("settings")
        let until = Date(timeIntervalSinceReferenceDate: 815_000_000)
        UserDefaultsSettingsStore(defaults: tmp.defaults).update { $0.pausedUntil = until }
        #expect(UserDefaultsSettingsStore(defaults: tmp.defaults).current().pausedUntil == until)
        UserDefaultsSettingsStore(defaults: tmp.defaults).update { $0.pausedUntil = .distantFuture }
        let reopened = UserDefaultsSettingsStore(defaults: tmp.defaults).current()
        #expect(reopened.pausedUntil == .distantFuture && reopened.isPausedUntilResumed)
        UserDefaultsSettingsStore(defaults: tmp.defaults).update { $0.pausedUntil = nil }
        #expect(UserDefaultsSettingsStore(defaults: tmp.defaults).current().pausedUntil == nil)
    }

    @Test func aMalformedValueReadsAsProtecting() {
        let tmp = TestDefaults("settings")
        tmp.defaults.set("tomorrow", forKey: "protection.pausedUntil")
        #expect(UserDefaultsSettingsStore(defaults: tmp.defaults).current().pausedUntil == nil)
    }

    @Test func theBooleanIsDerivedFromTheDate() {
        var s = Settings()
        s.protectionPaused = true
        #expect(s.pausedUntil == .distantFuture)
        let until = Date(timeIntervalSinceReferenceDate: 815_000_000)
        s.pausedUntil = until
        s.protectionPaused = true
        #expect(s.pausedUntil == until, "setting true keeps an existing end")
        #expect(!s.isPausedUntilResumed)
        s.protectionPaused = false
        #expect(s.pausedUntil == nil)
    }

    @Test func aSchemaOneDocumentDecodesItsPause() throws {
        let legacy = try JSONDecoder().decode(Settings.self, from: Data(#"{"protection.paused": true}"#.utf8))
        #expect(legacy.isPausedUntilResumed)
        let current = try JSONDecoder().decode(Settings.self, from: Data(#"{"protection.paused": true, "protection.pausedUntil": 815000000}"#.utf8))
        #expect(current.pausedUntil == Date(timeIntervalSinceReferenceDate: 815_000_000), "the new key wins")
        let none = try JSONDecoder().decode(Settings.self, from: Data(#"{}"#.utf8))
        #expect(none.pausedUntil == nil)
    }
}

// MARK: - Uncovered key text (G-17)

@Suite struct UncoveredKeyTextSettingTests {
    @Test func isOffByDefault() {
        #expect(Settings.default.showsUncoveredKeyText == false)
        #expect(UserDefaultsSettingsStore.registrationDictionary["journal.showsUncoveredKeyText"] as? Bool == false)
    }

    @Test func aDocumentWrittenBeforeTheKeyDecodesAsOff() throws {
        // An exported settings document from before G-17: every other key changed, none for the switch.
        var old = Settings.default
        allChanged(&old)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "journal.showsUncoveredKeyText")
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.showsUncoveredKeyText == false)
        #expect(decoded.thumbnailClickOpens == .viewer, "the other keys still decode")
    }

    @Test func aDefaultsDomainWithoutTheKeyReadsAsOff() {
        let temp = TestDefaults()
        temp.defaults.set(SettingsMigration.currentSchemaVersion, forKey: SettingsMigration.schemaVersionKey)
        temp.defaults.set(false, forKey: "guards.clipboard")
        let store = UserDefaultsSettingsStore(defaults: temp.defaults)
        #expect(store.current().showsUncoveredKeyText == false)
        #expect(store.current().guardsClipboard == false)
    }

    @Test func roundTripsThroughJSONAndDefaults() throws {
        var on = Settings.default
        on.showsUncoveredKeyText = true
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(on))
        #expect(decoded.showsUncoveredKeyText == true)
        #expect(decoded == on)

        let temp = TestDefaults()
        let store = UserDefaultsSettingsStore(defaults: temp.defaults)
        store.update { $0.showsUncoveredKeyText = true }
        #expect(temp.defaults.object(forKey: "journal.showsUncoveredKeyText") as? Bool == true)
        #expect(UserDefaultsSettingsStore(defaults: temp.defaults).current().showsUncoveredKeyText == true)
        store.update { $0.showsUncoveredKeyText = false }
        #expect(store.current().showsUncoveredKeyText == false)
    }
}
