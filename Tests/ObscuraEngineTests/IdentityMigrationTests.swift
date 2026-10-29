// G-38: the one-time move from an earlier bundle identifier. Every store here is a fake (in-memory key and confirmation
// stores, a recording Spotlight index, throwaway TestDefaults domains); no test touches the real Keychain, Spotlight or
// the app's defaults. The earlier identity is a made-up one.
import CryptoKit
import Foundation
import Testing
import ObscuraCapture
import ObscuraJournal
import ObscuraPrefs
import ObscuraSearch
import ObscuraSupport
import ObscuraTestSupport
@testable import ObscuraEngine

/// A Spotlight index split by domain, which can fail its next domain delete.
actor DomainIndex: SearchIndexing {
    private(set) var items: [String: Set<String>] = [:]
    private(set) var deletedDomains: [String] = []
    private var failNextDelete = false

    func put(_ ids: [String], domain: String) { items[domain, default: []].formUnion(ids) }
    func failNextDomainDelete() { failNextDelete = true }

    func index(_ new: [SearchItemContent]) async throws {
        for item in new { items[item.domainIdentifier, default: []].insert(item.uniqueIdentifier) }
    }
    func delete(identifiers: [String]) async throws {
        for domain in items.keys { items[domain]?.subtract(identifiers) }
    }
    func deleteAll(domain: String) async throws {
        if failNextDelete { failNextDelete = false; throw CocoaError(.featureUnsupported) }
        deletedDomains.append(domain)
        items[domain] = nil
    }
}

/// A confirmation store that can refuse every call, like a locked keychain.
final class RefusableApprovalStore: RemovableFolderApprovalStore, @unchecked Sendable {
    private let inner: InMemoryFolderApprovalStore
    private let lock = NSLock()
    private var refusing = false
    init(_ approvals: [FolderApproval]?) { inner = InMemoryFolderApprovalStore(approvals) }
    var refuses: Bool {
        get { lock.withLock { refusing } }
        set { lock.withLock { refusing = newValue } }
    }
    private func check() throws { if refuses { throw FolderApprovalStoreError.keychain(-25308) } }
    func load() throws -> [FolderApproval] { try check(); return try inner.load() }
    func save(_ approvals: [FolderApproval]) throws { try check(); try inner.save(approvals) }
    func prepare() throws { try check(); try inner.prepare() }
    func loadIfPresent() throws -> [FolderApproval]? { try check(); return try inner.loadIfPresent() }
    func remove() throws { try check(); try inner.remove() }
}

@Suite struct IdentityMigrationTests {
    static let earlier = AppIdentity(bundleIdentifier: "org.example.obscura-earlier")
    static let migration = IdentityMigration(previous: earlier)

    static let shots = FolderApproval(path: "/home/example/Shots", volume: "6F1C2D3E-0000-4000-8000-000000000001", inode: 42,
                                      confirmedAt: Date(timeIntervalSince1970: 1_793_000_000))
    static let downloads = FolderApproval(path: "/home/example/Downloads", volume: "6F1C2D3E-0000-4000-8000-000000000001", inode: 43,
                                          confirmedAt: Date(timeIntervalSince1970: 1_793_000_100))

    // MARK: Names

    @Test func everyStoredNameComesFromTheIdentity() {
        #expect(AppIdentity.current.bundleIdentifier == "io.github.xbtdmt.obscura")
        #expect(KeychainFolderApprovalStore.service == "io.github.xbtdmt.obscura.folder-approvals")
        #expect(KeychainRuleKeyStore.service == "io.github.xbtdmt.obscura.rule-values")
        #expect(SearchItemContent.domain == "io.github.xbtdmt.obscura.catches")
        #expect(CoreSpotlightIndex.indexName == SearchItemContent.domain)
        #expect(Log.subsystem == "io.github.xbtdmt.obscura")
        #expect(Self.earlier.folderApprovalService == "org.example.obscura-earlier.folder-approvals")
        #expect(Self.earlier.ruleKeyService == "org.example.obscura-earlier.rule-values")
        #expect(Self.earlier.spotlightDomain == "org.example.obscura-earlier.catches")
    }

    // MARK: Folder confirmations

    @Test func confirmationsMoveAndTheEarlierStoreGoes() throws {
        let old = InMemoryFolderApprovalStore([Self.shots, Self.downloads]), new = InMemoryFolderApprovalStore(nil)
        #expect(FolderApprovalMigration.move(from: old, to: new) == .moved(2))
        #expect(try new.loadIfPresent() == [Self.shots, Self.downloads])
        #expect(try old.loadIfPresent() == nil)
        #expect(FolderApprovalMigration.move(from: old, to: new) == .nothingToMove, "idempotent")
        #expect(try new.loadIfPresent() == [Self.shots, Self.downloads])
    }

    /// G-36 for the new service: whatever sits there before the move (planted, or prepared empty by an earlier launch)
    /// is replaced by the move's own copy, so no planted confirmation survives it.
    @Test func aPlantedConfirmationUnderTheNewServiceDoesNotSurvive() throws {
        let planted = FolderApproval(path: "/home/example/Documents", volume: nil, inode: 7, confirmedAt: .distantPast)
        let old = InMemoryFolderApprovalStore([Self.shots]), new = InMemoryFolderApprovalStore([planted])
        #expect(FolderApprovalMigration.move(from: old, to: new) == .moved(1))
        #expect(try new.load() == [Self.shots])
    }

    @Test func noEarlierStoreMeansNothingMoves() throws {
        let new = InMemoryFolderApprovalStore([Self.shots])
        #expect(FolderApprovalMigration.move(from: InMemoryFolderApprovalStore(nil), to: new) == .nothingToMove)
        #expect(try new.load() == [Self.shots], "this identity's own confirmations are untouched")
    }

    @Test func aLockedStoreKeepsTheEarlierConfirmationsForTheNextLaunch() throws {
        let old = RefusableApprovalStore([Self.shots]), new = InMemoryFolderApprovalStore(nil)
        old.refuses = true
        #expect(FolderApprovalMigration.move(from: old, to: new) == .failed)
        #expect(try new.loadIfPresent() == nil)
        old.refuses = false
        #expect(try old.loadIfPresent() == [Self.shots])
        #expect(FolderApprovalMigration.move(from: old, to: new) == .moved(1))

        let refusingNew = RefusableApprovalStore(nil)
        refusingNew.refuses = true
        let again = InMemoryFolderApprovalStore([Self.downloads])
        #expect(FolderApprovalMigration.move(from: again, to: refusingNew) == .failed)
        #expect(try again.loadIfPresent() == [Self.downloads], "nothing is deleted when the copy failed")
    }

    // MARK: Keychain step (rule keys + confirmations, with its marker)

    @Test func theKeychainStepMovesBothAndRunsOnce() throws {
        let markers = TestDefaults("markers").defaults
        let key = SymmetricKey(size: .bits256)
        let oldKeys = InMemoryRuleKeyStore(key: key), newKeys = InMemoryRuleKeyStore()
        let keyIDs = try oldKeys.storedKeyIDs()
        let oldApprovals = InMemoryFolderApprovalStore([Self.shots]), newApprovals = InMemoryFolderApprovalStore(nil)

        let outcome = try #require(Self.migration.moveKeychainItems(ruleKeys: (oldKeys, newKeys), folderApprovals: (oldApprovals, newApprovals),
                                                                    markers: markers))
        #expect(outcome.isComplete)
        #expect(outcome.ruleKeys.moved == 1)
        #expect(outcome.folderApprovals == .moved(1))
        #expect(try newKeys.storedKeyIDs() == keyIDs)
        #expect(try oldKeys.storedKeyIDs().isEmpty)

        // A key planted under the earlier service after the move is never picked up: the step is done.
        let late = SymmetricKey(size: .bits256)
        try oldKeys.store(late, id: Data(repeating: 1, count: 8))
        #expect(Self.migration.moveKeychainItems(ruleKeys: (oldKeys, newKeys), folderApprovals: (oldApprovals, newApprovals),
                                                 markers: markers) == nil)
        #expect(try newKeys.storedKeyIDs() == keyIDs)
    }

    @Test func anUnfinishedKeychainStepRunsAgain() throws {
        let markers = TestDefaults("markers").defaults
        let oldApprovals = RefusableApprovalStore([Self.shots]), newApprovals = InMemoryFolderApprovalStore(nil)
        oldApprovals.refuses = true
        let first = try #require(Self.migration.moveKeychainItems(ruleKeys: (InMemoryRuleKeyStore(), InMemoryRuleKeyStore()),
                                                                  folderApprovals: (oldApprovals, newApprovals), markers: markers))
        #expect(!first.isComplete)
        oldApprovals.refuses = false
        let second = try #require(Self.migration.moveKeychainItems(ruleKeys: (InMemoryRuleKeyStore(), InMemoryRuleKeyStore()),
                                                                   folderApprovals: (oldApprovals, newApprovals), markers: markers))
        #expect(second.isComplete)
        #expect(try newApprovals.load() == [Self.shots])
    }

    // MARK: Spotlight

    @Test func theEarlierDomainIsDeletedOnceAndTheNewOneIsLeftToTheReconcile() async {
        let markers = TestDefaults("markers").defaults
        let index = DomainIndex()
        await index.put(["a", "b"], domain: Self.earlier.spotlightDomain)
        await index.put(["c"], domain: SearchItemContent.domain)

        #expect(await Self.migration.retireSpotlightDomain(index: index, markers: markers))
        #expect(await index.items[Self.earlier.spotlightDomain] == nil)
        #expect(await index.items[SearchItemContent.domain] == ["c"], "this identity's entries are not touched")
        #expect(await index.deletedDomains == [Self.earlier.spotlightDomain])

        #expect(await !Self.migration.retireSpotlightDomain(index: index, markers: markers), "runs once")
        #expect(await index.deletedDomains.count == 1)
    }

    @Test func aFailedDomainDeleteIsTriedAgain() async {
        let markers = TestDefaults("markers").defaults
        let index = DomainIndex()
        await index.put(["a"], domain: Self.earlier.spotlightDomain)
        await index.failNextDomainDelete()

        #expect(await !Self.migration.retireSpotlightDomain(index: index, markers: markers))
        #expect(await index.items[Self.earlier.spotlightDomain] == ["a"])
        #expect(await Self.migration.retireSpotlightDomain(index: index, markers: markers))
        #expect(await index.items[Self.earlier.spotlightDomain] == nil)
    }

    // MARK: Login item

    @Test func theLoginItemIsRegisteredOnlyWhenTheEarlierIdentityHadItOn() {
        for (previous, status, registers) in [(true, LoginItemStatus.disabled, true), (false, .disabled, false), (nil, .disabled, false),
                                              (true, .enabled, false), (true, .notFound, false)] as [(Bool?, LoginItemStatus, Bool)] {
            let markers = TestDefaults("markers").defaults
            if let previous { markers.set(previous, forKey: LoginItem.lastKnownKey) }
            var registered = 0
            let action = Self.migration.carryLoginItem(markers: markers, status: { status }, register: { registered += 1 })
            #expect(action == (registers ? .register : .leave), "\(String(describing: previous)) \(status)")
            #expect(registered == (registers ? 1 : 0))
            #expect(Self.migration.carryLoginItem(markers: markers, status: { status }, register: { registered += 1 }) == nil, "decided once")
            #expect(registered == (registers ? 1 : 0))
        }
    }

    /// The companion keys other modules own are carried with the settings (each is named here from its owner).
    @Test func theLoginItemMemoryTravelsWithTheSettings() {
        #expect(PreviousIdentityDefaults.carries(LoginItem.lastKnownKey))
    }

    // MARK: Settings (the domain names)

    /// The step reads the domain the earlier identity names and writes the one it is given. (A TestDefaults domain is
    /// named by its path; `AppIdentity` takes it as is, which only `previous(named:)` would refuse.)
    @Test func settingsAreReadFromTheEarlierIdentitysDomain() {
        let earlier = TestDefaults("earlier"), current = TestDefaults("current")
        earlier.defaults.set("keepBoth", forKey: SettingsKey.fileHandling.rawValue)
        earlier.defaults.set(2, forKey: SettingsMigration.schemaVersionKey)
        let migration = IdentityMigration(previous: AppIdentity(bundleIdentifier: earlier.suiteName))

        #expect(migration.carrySettings(into: current.defaults, domain: current.suiteName) == .carried(copied: 2, kept: 0))
        #expect(current.defaults.string(forKey: SettingsKey.fileHandling.rawValue) == "keepBoth")
        #expect(migration.carrySettings(into: current.defaults, domain: current.suiteName) == .alreadySetUp)
    }
}
