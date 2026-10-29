// ObscuraTestSupport — helpers shared by the test targets only; nothing here ships.
//
// TestDefaults: a throwaway UserDefaults domain that never touches ~/Library/Preferences.
//
// Why not `UserDefaults(suiteName: "<name>")` + `removePersistentDomain(forName:)`: that clears the keys, but cfprefsd
// still leaves an empty `~/Library/Preferences/<name>.plist` behind, one per test run (2,200+ of them had piled up by
// 2026-10-27), and deleting that file from the test races cfprefsd and loses. A suite name that is an absolute path
// makes CFPreferences keep the domain in that file instead, so every TestDefaults domain is a plist inside one private
// temporary folder per test process. When the process exits, each domain is cleared and flushed
// (`CFPreferencesAppSynchronize`) and then the folder is removed; without the flush a write still queued in cfprefsd
// recreates the folder after it is gone (measured with a standalone probe: folder back 3 s after a delete that raced a
// write; with the flush first, 5 of 5 rounds of 20 domains left nothing).
public import Foundation
import Synchronization

/// A fresh, empty defaults domain stored in this test process's private folder. It lives until the process exits, so
/// it can be handed to an object that outlives the test's own scope (a model registered for a render, say).
public final class TestDefaults: @unchecked Sendable {
    /// The domain's name: an absolute path ending in the plist's base name. Pass it wherever a suite name is wanted
    /// (`persistentDomain(forName:)`, `removePersistentDomain(forName:)`).
    public let suiteName: String
    public let defaults: UserDefaults

    public init(_ label: String = "defaults") {
        let folder = Self.folder
        suiteName = folder.appendingPathComponent("\(label)-\(UUID().uuidString)").path
        defaults = UserDefaults(suiteName: suiteName)!
        Self.created.withLock { $0.append(suiteName) }
    }

    /// The folder every domain of this process is stored in.
    public static var folder: URL { root }

    /// Every domain made in this process, cleared at exit before the folder is removed.
    private static let created = Mutex<[String]>([])

    private static let root: URL = {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("obscura-test-defaults-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                                    isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        atexit { TestDefaults.removeAll() }
        return url
    }()

    /// Clears and flushes every domain, then removes the folder. Runs once, at process exit.
    static func removeAll() {
        let suites = created.withLock { $0 }
        for suite in suites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            CFPreferencesAppSynchronize(suite as CFString)
        }
        try? FileManager.default.removeItem(at: root)
    }
}
