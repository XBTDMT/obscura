// F17 (G-36): the settings' folder list lives in a defaults domain any process running as the user can write, so a folder
// named there (or Downloads switched on there) is watched only once the person confirmed it in Obscura. Every folder here
// is a temporary one and every confirmation store lives in memory; nothing touches the real Keychain or Preferences.
import Foundation
import Testing
import ObscuraCapture
import ObscuraJournal
import ObscuraSupport
import ObscuraOCR
import ObscuraPrefs
@testable import ObscuraEngine

@Suite(.serialized) struct FolderApprovalTests {
    /// An engine whose settings were written behind Obscura's back (as `defaults write` would), with nothing confirmed.
    struct Scene {
        let h: Harness
        let base: URL, documents: URL
        init() throws {
            h = try Harness()
            base = try Fixture.tempDirectory("f17")
            documents = base.appendingPathComponent("Documents", isDirectory: true)
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            h.folders.downloads = base.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: h.folders.downloads, withIntermediateDirectories: true)
        }
        func roots() async -> [WatchedRoot] { await h.engine.watchedRoots() }
        func unconfirmedProblems() async -> [URL] {
            await h.engine.currentStatus().problems.filter { $0.messageKey == ShieldEngine.unconfirmedFolderKey }.compactMap(\.url)
        }
        func tearDown() { h.tearDown(); try? FileManager.default.removeItem(at: base) }
    }

    /// The reported exploit: an added folder and Downloads switched on outside Obscura are not watched, and the person
    /// is told; once they confirm in Obscura, both are.
    @Test func foldersNamedOutsideObscuraAreNotWatchedUntilConfirmed() async throws {
        let s = try Scene(); defer { s.tearDown() }
        s.h.settings.update { $0.extraFolders = [s.documents.path]; $0.guardsDownloads = true }
        await s.h.engine.applySettings(s.h.settings.current())
        #expect(await s.roots().filter { $0.origin != .screenshotFolder }.isEmpty, "nothing named outside Obscura is watched")
        #expect(Set(await s.unconfirmedProblems().map(\.standardizedFileURL.path))
                == [s.documents.standardizedFileURL.path, s.h.folders.downloads.standardizedFileURL.path])

        #expect(await s.h.engine.confirmFolder(s.documents))
        #expect(await s.h.engine.confirmFolder(s.h.folders.downloads))
        let origins = await s.roots().map(\.origin)
        #expect(origins.contains(.watched(URL(fileURLWithPath: s.documents.path, isDirectory: true))) && origins.contains(.downloads))
        #expect(await s.unconfirmedProblems().isEmpty)
    }

    /// The folder watcher itself never receives an unconfirmed folder.
    @Test func theFolderWatcherOnlyGetsConfirmedFolders() async throws {
        let watcher = FolderWatcher(roots: [])
        let base = try Fixture.tempDirectory("f17-watcher")
        defer { try? FileManager.default.removeItem(at: base) }
        var settings = Settings.default
        settings.guardsScreenshotFolder = false
        let h = try Harness(settings: settings, folderWatcher: watcher)
        defer { h.tearDown() }
        h.settings.update { $0.extraFolders = [base.path] }
        await h.engine.applySettings(h.settings.current())
        #expect(await watcher.currentRoots.isEmpty)
        #expect(await h.engine.confirmFolder(base))
        #expect(await watcher.currentRoots.map(\.url.standardizedFileURL.path) == [base.standardizedFileURL.path])
    }

    /// A confirmed folder swapped for a link to another folder, or deleted and made again, is not the folder confirmed.
    @Test func aSwappedFolderIsNotTheOneConfirmed() async throws {
        let s = try Scene(); defer { s.tearDown() }
        let mine = s.base.appendingPathComponent("Shots", isDirectory: true)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        s.h.settings.update { $0.extraFolders = [mine.path] }
        #expect(await s.h.engine.confirmFolder(mine))
        #expect(await s.roots().contains { $0.origin == .watched(URL(fileURLWithPath: mine.path, isDirectory: true)) })

        try FileManager.default.removeItem(at: mine)
        try FileManager.default.createSymbolicLink(at: mine, withDestinationURL: s.documents)
        #expect(await s.roots().filter { $0.origin != .screenshotFolder }.isEmpty, "a link put in its place is not confirmed")

        try FileManager.default.removeItem(at: mine)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        #expect(await s.roots().filter { $0.origin != .screenshotFolder }.isEmpty, "a new folder at the same path is not confirmed")
    }

    /// The plain paths from before G-36 are asked about once: confirmed once, they stay confirmed across a relaunch.
    @Test func aConfirmationIsAskedOnceAndSurvivesARelaunch() async throws {
        let s = try Scene(); defer { s.tearDown() }
        s.h.settings.update { $0.extraFolders = [s.documents.path] }
        #expect(await s.roots().filter { $0.origin != .screenshotFolder }.isEmpty)
        #expect(await s.h.engine.confirmFolder(s.documents))
        let relaunched = ShieldEngine(sources: [], recognizer: StubTextRecognizer(lines: []), journal: s.h.journal, settings: s.h.settings,
                                      clock: s.h.clock, folderWatcher: nil, clipboardGuard: nil, locations: s.h.folders.locations,
                                      folderApprovals: s.h.folders.approvals)
        #expect(await relaunched.watchedRoots().contains { $0.origin != .screenshotFolder })
    }

    /// Stop Watching forgets the confirmation: the same path named again outside Obscura is not watched.
    @Test func stopWatchingForgetsTheConfirmation() async throws {
        let s = try Scene(); defer { s.tearDown() }
        s.h.settings.update { $0.extraFolders = [s.documents.path] }
        #expect(await s.h.engine.confirmFolder(s.documents))
        s.h.settings.update { $0.extraFolders = [] }
        await s.h.engine.forgetFolder(s.documents)
        s.h.settings.update { $0.extraFolders = [s.documents.path] }
        #expect(await s.roots().filter { $0.origin != .screenshotFolder }.isEmpty)
    }

    /// A store that cannot be read (a locked keychain) is not "nothing confirmed" after a good read: the last read stands;
    /// and only a folder that exists can be confirmed.
    @Test func anUnreadableStoreKeepsTheLastGoodRead() async throws {
        let base = try Fixture.tempDirectory("f17-locked")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = LockableApprovalStore()
        let settings = InMemorySettingsStore(.default)
        let journalRoot = try Fixture.tempDirectory("f17-locked-journal")
        defer { try? FileManager.default.removeItem(at: journalRoot) }
        let engine = ShieldEngine(sources: [], recognizer: StubTextRecognizer(lines: []),
                                  journal: try SQLiteJournalStore(root: journalRoot, ruleKeys: InMemoryRuleKeyStore()), settings: settings,
                                  clock: ManualClock(), folderWatcher: nil, clipboardGuard: nil, locations: TestFolders().locations,
                                  folderApprovals: store)
        settings.update { $0.extraFolders = [base.path] }
        #expect(await engine.confirmFolder(base))
        store.locked = true
        await engine.applySettings(settings.current())
        #expect(await engine.watchedRoots().contains { $0.origin != .screenshotFolder }, "the last good read stands")
        #expect(!(await engine.confirmFolder(base.appendingPathComponent("not-there"))), "only a folder that exists is confirmed")
    }

    @Test func confirmationsRoundTripAsTheKeychainItemHoldsThem() throws {
        let approvals = [FolderApproval(path: "/home/example/Shots", volume: "6F1C2D3E-0000-4000-8000-000000000001", inode: 42,
                                        confirmedAt: Date(timeIntervalSince1970: 1_793_000_000))]
        let data = try KeychainFolderApprovalStore.encode(approvals)
        #expect(try KeychainFolderApprovalStore.decode(data) == approvals)
        #expect(throws: FolderApprovalStoreError.malformed) { try KeychainFolderApprovalStore.decode(Data("not json".utf8)) }
    }
}

/// An in-memory confirmation store that can refuse to answer, like a locked keychain.
final class LockableApprovalStore: FolderApprovalStore, @unchecked Sendable {
    private let lock = NSLock()
    private var approvals: [FolderApproval] = []
    private var isLocked = false
    var locked: Bool {
        get { lock.withLock { isLocked } }
        set { lock.withLock { isLocked = newValue } }
    }
    func load() throws -> [FolderApproval] {
        try lock.withLock { if isLocked { throw FolderApprovalStoreError.keychain(-25308) }; return approvals }
    }
    func save(_ approvals: [FolderApproval]) throws {
        try lock.withLock { if isLocked { throw FolderApprovalStoreError.keychain(-25308) }; self.approvals = approvals }
    }
    func prepare() throws {}
}
