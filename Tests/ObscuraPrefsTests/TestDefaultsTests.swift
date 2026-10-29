// TestDefaults (ObscuraTestSupport) keeps every test defaults domain out of ~/Library/Preferences (redman 2026-10-27,
// "44 <bundle id>.tests.<UUID>.plist files are left in ~/Library/Preferences"). These only read that folder.
import CoreFoundation
import Foundation
import Testing
import ObscuraTestSupport
@testable import ObscuraPrefs

@Suite struct TestDefaultsTests {
    static var userPreferences: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    @Test func aDomainIsStoredInThePrivateTemporaryFolderAndNotInPreferences() throws {
        let tmp = TestDefaults("probe")
        let store = UserDefaultsSettingsStore(defaults: tmp.defaults)
        store.update { $0.fileHandling = .keepBoth }
        #expect(CFPreferencesAppSynchronize(tmp.suiteName as CFString))

        let file = URL(fileURLWithPath: tmp.suiteName + ".plist")
        #expect(file.deletingLastPathComponent() == TestDefaults.folder)
        #expect(TestDefaults.folder.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path))
        #expect(FileManager.default.fileExists(atPath: file.path), "the domain's plist is the file named by the suite")
        let name = file.lastPathComponent
        let inPreferences = try FileManager.default.contentsOfDirectory(atPath: Self.userPreferences.path)
            .filter { $0.hasSuffix(name) }
        #expect(inPreferences.isEmpty, "nothing named after the domain lands in ~/Library/Preferences")
    }

    @Test func aSecondInstanceOverTheSameDomainSeesTheWrites() {
        let tmp = TestDefaults("relaunch")
        tmp.defaults.set("keepBoth", forKey: "fileHandling")
        #expect(UserDefaults(suiteName: tmp.suiteName)?.string(forKey: "fileHandling") == "keepBoth")
        #expect(tmp.defaults.persistentDomain(forName: tmp.suiteName)?["fileHandling"] as? String == "keepBoth")
    }

    @Test func twoDomainsAreIndependent() {
        let a = TestDefaults(), b = TestDefaults()
        a.defaults.set(1, forKey: "k")
        #expect(a.suiteName != b.suiteName)
        #expect(b.defaults.object(forKey: "k") == nil)
    }
}
