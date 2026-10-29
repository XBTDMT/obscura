// G-38: the settings of an earlier identity's defaults domain are carried into this one's, once. Both domains here are
// throwaway TestDefaults domains (ObscuraTestSupport): no test reads or writes the app's real domains.
import Foundation
import Testing
import ObscuraTestSupport
@testable import ObscuraPrefs

@Suite struct PreviousIdentityDefaultsTests {
    /// An earlier identity's domain written the way that build wrote it: through the settings store, plus the
    /// panel's memories, the language override, a window frame and the status item's position.
    private static func earlierDomain() -> TestDefaults {
        let old = TestDefaults("earlier")
        let store = UserDefaultsSettingsStore(defaults: old.defaults)
        store.update { allChanged(&$0) }
        old.defaults.set(815_000_000.0, forKey: "menuBar.lastSeen")
        old.defaults.set("oneHour", forKey: "menuBar.pauseChoice")
        old.defaults.set(true, forKey: "loginItem.lastKnownOn")
        old.defaults.set(["fr"], forKey: "AppleLanguages")
        old.defaults.set("120 300 900 640 0 0 1512 944 ", forKey: "NSWindow Frame journal-AppWindow-1")
        old.defaults.set(812.0, forKey: "NSStatusItem Preferred Position ObscuraStatusItem")
        old.defaults.set("not Obscura's", forKey: "SomeOtherAppsKey")
        return old
    }

    private static func domain(_ d: TestDefaults) -> [String: Any] { d.defaults.persistentDomain(forName: d.suiteName) ?? [:] }

    private static func migrate(_ old: TestDefaults, _ new: TestDefaults) -> PreviousIdentityDefaults.Outcome {
        PreviousIdentityDefaults.migrate(from: domain(old), to: new.defaults, currentDomain: domain(new))
    }

    @Test func everyKnownKeyIsCarriedAndNothingElse() {
        #expect(SettingsKey.allCases.allSatisfy { PreviousIdentityDefaults.carries($0.rawValue) })
        #expect(PreviousIdentityDefaults.carries(SettingsMigration.schemaVersionKey))
        #expect(PreviousIdentityDefaults.carries(SettingsMigration.legacyPausedKey))
        for key in ["menuBar.lastSeen", "menuBar.pauseChoice", "loginItem.lastKnownOn", "AppleLanguages",
                    "NSWindow Frame settings", "NSStatusItem Preferred Position ObscuraStatusItem", "NSStatusItem Visible ObscuraStatusItem"] {
            #expect(PreviousIdentityDefaults.carries(key), "\(key)")
        }
        for key in ["SomeOtherAppsKey", "identity.migration.keychain", "SULastCheckTime", ""] {
            #expect(!PreviousIdentityDefaults.carries(key), "\(key)")
        }
    }

    @Test func theSettingsArriveAndTheStoreReadsThemBack() {
        let old = Self.earlierDomain(), new = TestDefaults("current")
        let before = Self.domain(old)

        guard case .carried(let copied, let kept) = Self.migrate(old, new) else { Issue.record("nothing carried"); return }
        #expect(kept == 0)
        #expect(copied == before.keys.filter(PreviousIdentityDefaults.carries).count)

        var expected = Settings.default
        allChanged(&expected)
        #expect(UserDefaultsSettingsStore(defaults: new.defaults).current() == expected)
        #expect(new.defaults.double(forKey: "menuBar.lastSeen") == 815_000_000)
        #expect(new.defaults.string(forKey: "menuBar.pauseChoice") == "oneHour")
        #expect(new.defaults.object(forKey: "loginItem.lastKnownOn") as? Bool == true)
        #expect(new.defaults.stringArray(forKey: "AppleLanguages") == ["fr"])
        #expect(new.defaults.string(forKey: "NSWindow Frame journal-AppWindow-1") == "120 300 900 640 0 0 1512 944 ")
        #expect(new.defaults.double(forKey: "NSStatusItem Preferred Position ObscuraStatusItem") == 812)
        #expect(new.defaults.object(forKey: "SomeOtherAppsKey") == nil, "a key the app does not know stays behind")
        #expect(NSDictionary(dictionary: Self.domain(old)).isEqual(to: before), "the earlier domain is left as it was")
    }

    @Test func aValueThisDomainAlreadyHoldsIsNeverOverwritten() {
        let old = Self.earlierDomain(), new = TestDefaults("current")
        new.defaults.set("light", forKey: SettingsKey.appearance.rawValue)
        new.defaults.set(999.0, forKey: "menuBar.lastSeen")

        guard case .carried(_, let kept) = Self.migrate(old, new) else { Issue.record("nothing carried"); return }
        #expect(kept == 2)
        #expect(new.defaults.string(forKey: SettingsKey.appearance.rawValue) == "light")
        #expect(new.defaults.double(forKey: "menuBar.lastSeen") == 999)
        #expect(new.defaults.string(forKey: SettingsKey.fileHandling.rawValue) == "keepBoth", "the rest still arrives")
    }

    @Test func aDomainThatIsAlreadySetUpIsLeftAlone() {
        let old = Self.earlierDomain(), new = TestDefaults("current")
        _ = UserDefaultsSettingsStore(defaults: new.defaults)   // writes this domain's schema version
        let before = Self.domain(new)

        #expect(Self.migrate(old, new) == .alreadySetUp)
        #expect(NSDictionary(dictionary: Self.domain(new)).isEqual(to: before))
    }

    @Test func itRunsOnce() {
        let old = Self.earlierDomain(), new = TestDefaults("current")
        _ = Self.migrate(old, new)
        let after = Self.domain(new)
        old.defaults.set("dark", forKey: SettingsKey.appearance.rawValue)

        #expect(Self.migrate(old, new) == .alreadySetUp, "the carried schema version marks the copy done")
        #expect(NSDictionary(dictionary: Self.domain(new)).isEqual(to: after))
    }

    @Test func nothingToCarryFromAnEmptyOrForeignDomain() {
        let new = TestDefaults("current")
        #expect(PreviousIdentityDefaults.migrate(from: nil, to: new.defaults, currentDomain: nil) == .nothingToCarry)
        #expect(PreviousIdentityDefaults.migrate(from: ["SomeOtherAppsKey": 1], to: new.defaults, currentDomain: nil) == .nothingToCarry)
        #expect(Self.domain(new).isEmpty)
    }

    /// A domain from schema 1 arrives as schema 1, and the usual migration brings it up: the Boolean pause becomes an
    /// open-ended pause.
    @Test func anOlderSchemaIsMigratedAfterTheCopy() {
        let old = TestDefaults("earlier"), new = TestDefaults("current")
        old.defaults.set(1, forKey: SettingsMigration.schemaVersionKey)
        old.defaults.set(true, forKey: SettingsMigration.legacyPausedKey)
        old.defaults.set("keepBoth", forKey: SettingsKey.fileHandling.rawValue)

        #expect(Self.migrate(old, new) == .carried(copied: 3, kept: 0))
        let settings = UserDefaultsSettingsStore(defaults: new.defaults).current()
        #expect(settings.pausedUntil == .distantFuture)
        #expect(settings.fileHandling == .keepBoth)
        #expect(new.defaults.integer(forKey: SettingsMigration.schemaVersionKey) == SettingsMigration.currentSchemaVersion)
    }
}
