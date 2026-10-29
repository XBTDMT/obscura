// G-40: "Cover spots Obscura can't read" (B) and "Skip spots too small to hold a secret" (D). Both off by default, each
// stored under its own key, exported and imported with the rest, and back to off when the stored value is removed.
// Every UserDefaults store here runs on a throwaway TestDefaults domain (ObscuraTestSupport).
import Foundation
import Testing
import ObscuraTestSupport
@testable import ObscuraPrefs

@Suite struct UnreadSpotSettingsTests {
    @Test func bothAreOffByDefault() {
        #expect(Settings.default.coversUnreadableSpots == false)
        #expect(Settings.default.skipsTinySpots == false)
        let tmp = TestDefaults("spots-default")
        let s = UserDefaultsSettingsStore(defaults: tmp.defaults).current()
        #expect(!s.coversUnreadableSpots && !s.skipsTinySpots)
        #expect(SettingsKey.coversUnreadableSpots.rawValue == "ocr.coversUnreadableSpots")
        #expect(SettingsKey.skipsTinySpots.rawValue == "ocr.skipsTinySpots")
        #expect(UserDefaultsSettingsStore.registrationDictionary["ocr.coversUnreadableSpots"] as? Bool == false)
        #expect(UserDefaultsSettingsStore.registrationDictionary["ocr.skipsTinySpots"] as? Bool == false)
    }

    @Test func eachIsPersistedAndReadBackByANewStore() {
        let tmp = TestDefaults("spots-persist")
        let store = UserDefaultsSettingsStore(defaults: tmp.defaults)
        store.update { $0.coversUnreadableSpots = true }
        #expect(tmp.defaults.object(forKey: "ocr.coversUnreadableSpots") as? Bool == true)
        #expect(UserDefaultsSettingsStore(defaults: tmp.defaults).current().coversUnreadableSpots)
        #expect(!UserDefaultsSettingsStore(defaults: tmp.defaults).current().skipsTinySpots, "one switch never moves the other")
        store.update { $0.skipsTinySpots = true }
        #expect(UserDefaultsSettingsStore(defaults: tmp.defaults).current().skipsTinySpots)
        // Written as text from the command line, read as macOS means it.
        tmp.defaults.set("NO", forKey: "ocr.skipsTinySpots")
        #expect(!UserDefaultsSettingsStore(defaults: tmp.defaults).current().skipsTinySpots)
    }

    @Test func resetTakesThemBackToOff() {
        let tmp = TestDefaults("spots-reset")
        let store = UserDefaultsSettingsStore(defaults: tmp.defaults)
        store.update { $0.coversUnreadableSpots = true; $0.skipsTinySpots = true }
        for key in SettingsKey.allCases { tmp.defaults.removeObject(forKey: key.rawValue) }
        let s = UserDefaultsSettingsStore(defaults: tmp.defaults).current()
        #expect(!s.coversUnreadableSpots && !s.skipsTinySpots)
        #expect(s == Settings.default)
    }

    @Test func exportAndImportCarryThem() throws {
        var s = Settings.default
        s.coversUnreadableSpots = true
        s.skipsTinySpots = true
        let json = try JSONEncoder().encode(s)
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.contains("\"ocr.coversUnreadableSpots\":true") && text.contains("\"ocr.skipsTinySpots\":true"))
        #expect(try JSONDecoder().decode(Settings.self, from: json) == s)
        // A document written before G-40 has neither and reads them as off.
        var old = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        old.removeValue(forKey: "ocr.coversUnreadableSpots")
        old.removeValue(forKey: "ocr.skipsTinySpots")
        let decoded = try JSONDecoder().decode(Settings.self, from: try JSONSerialization.data(withJSONObject: old))
        #expect(!decoded.coversUnreadableSpots && !decoded.skipsTinySpots)
    }

    @Test func noSchemaStepIsNeeded() {
        // An added key with a registered default: a Mac that never stored it reads off; the schema moves only for a rename.
        #expect(SettingsMigration.currentSchemaVersion == 2)
        #expect(PreviousIdentityDefaults.carries("ocr.coversUnreadableSpots") && PreviousIdentityDefaults.carries("ocr.skipsTinySpots"))
    }
}
