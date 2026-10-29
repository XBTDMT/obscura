// F17 (G-36): Obscura's settings live in a defaults domain any process running as the user can write
// (`defaults write <Obscura's bundle id> guards.extraFolders -array ~/Documents`), so a folder named there is a request,
// not the person's choice. Obscura watches Downloads or an added folder only when the person confirmed it in Obscura
// itself (an open-panel pick, or the Downloads switch), and that confirmation is kept where another process cannot
// rewrite it without a Keychain prompt: a generic-password item Obscura creates. A folder requested any other way, the
// plain paths from before this change included, is shown to the person to confirm once and is not watched until then.
//
// A confirmation names the folder by its resolved path and its file identity (volume and inode), so a folder swapped for
// a link, or another folder moved into its place, is not the one confirmed.
public import Foundation
import Security
import ObscuraSupport
import Synchronization

public struct FolderApproval: Codable, Sendable, Hashable {
    /// The folder's resolved path (`realpath`) when it was confirmed.
    public var path: String
    /// The volume's UUID, when the volume has one.
    public var volume: String?
    public var inode: UInt64
    public var confirmedAt: Date

    public init(path: String, volume: String?, inode: UInt64, confirmedAt: Date) {
        self.path = path; self.volume = volume; self.inode = inode; self.confirmedAt = confirmedAt
    }

    /// The confirmation for the folder at `url` as it is now; nil when it is not a folder that exists.
    public static func current(_ url: URL, at date: Date) -> FolderApproval? {
        guard let resolved = JournalTargets.realPath(url.path) else { return nil }
        var info = stat()
        guard stat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        let volume = try? URL(fileURLWithPath: resolved, isDirectory: true).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        return FolderApproval(path: resolved, volume: volume, inode: UInt64(info.st_ino), confirmedAt: date)
    }

    /// Whether this confirmation is for the folder at `url` as it is now: the same resolved path, volume and inode.
    public func matches(_ url: URL) -> Bool {
        guard let now = FolderApproval.current(url, at: confirmedAt) else { return false }
        return now.path == path && now.inode == inode && now.volume == volume
    }

    /// Whether this confirmation names the folder at `url`: it matches, or the folder is gone and the confirmed one was at
    /// that path (a confirmed folder that was moved or deleted stays the person's, so its "missing" problem shows; a new
    /// folder made at the path later is another inode and not confirmed).
    public func names(_ url: URL) -> Bool {
        if matches(url) { return true }
        guard JournalTargets.realPath(url.path) == nil, let parent = JournalTargets.realPath(url.deletingLastPathComponent().path) else {
            return false
        }
        return (parent.hasSuffix("/") ? parent : parent + "/") + url.lastPathComponent == path
    }
}

/// Where confirmations are kept. Synchronous and cheap; the engine caches what it reads.
public protocol FolderApprovalStore: Sendable {
    /// Every confirmation. Throws when the store cannot be asked now (a locked keychain, access refused).
    func load() throws -> [FolderApproval]
    func save(_ approvals: [FolderApproval]) throws
    /// Makes sure the store exists (an empty one when there is none), so it is Obscura's own from the first launch on and
    /// not something another process could have created first. Never replaces what is there.
    func prepare() throws
}

/// A store that can also say whether it exists and be removed whole: what moving confirmations from an earlier
/// identity's store to this one's needs (G-38, `FolderApprovalMigration`).
public protocol RemovableFolderApprovalStore: FolderApprovalStore {
    /// The confirmations, or nil when there is no store at all (as opposed to an empty one).
    func loadIfPresent() throws -> [FolderApproval]?
    /// Removes the store, if any.
    func remove() throws
}

/// Confirmations in memory: tests, previews and the CLI.
public final class InMemoryFolderApprovalStore: RemovableFolderApprovalStore {
    private let state: Mutex<[FolderApproval]?>
    /// `approvals`: an existing store holding these; nil for no store at all (`prepare()` then creates an empty one).
    public init(_ approvals: [FolderApproval]? = []) { state = Mutex(approvals) }
    public func prepare() throws { state.withLock { if $0 == nil { $0 = [] } } }
    public func load() throws -> [FolderApproval] { state.withLock { $0 ?? [] } }
    public func save(_ approvals: [FolderApproval]) throws { state.withLock { $0 = approvals } }
    public func loadIfPresent() throws -> [FolderApproval]? { state.withLock { $0 } }
    public func remove() throws { state.withLock { $0 = nil } }
}

public enum FolderApprovalStoreError: Error, Sendable, Equatable {
    case keychain(OSStatus)
    case malformed
}

/// The app's store: one generic-password item in the login keychain, created by Obscura (so its default access list
/// trusts Obscura), holding the confirmations as JSON. Not synchronizable, this device only. No path in it is a secret;
/// the Keychain is used because another process cannot rewrite Obscura's item without a prompt, unlike the defaults
/// domain.
public struct KeychainFolderApprovalStore: RemovableFolderApprovalStore {
    public static let service = AppIdentity.current.folderApprovalService
    public static let account = "watched-folders.v1"

    private let service: String

    /// `service`: this identity's by default; `FolderApprovalMigration` also opens an earlier identity's (G-38).
    public init(service: String = KeychainFolderApprovalStore.service) {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    public func load() throws -> [FolderApproval] {
        try loadIfPresent() ?? []
    }

    public func loadIfPresent() throws -> [FolderApproval]? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw FolderApprovalStoreError.malformed }
            return try Self.decode(data)
        case errSecItemNotFound:
            return nil
        default:
            throw FolderApprovalStoreError.keychain(status)
        }
    }

    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw FolderApprovalStoreError.keychain(status) }
    }

    public func prepare() throws {
        do { try add(Self.encode([])) } catch FolderApprovalStoreError.keychain(errSecDuplicateItem) { return }
    }

    public func save(_ approvals: [FolderApproval]) throws {
        let data = try Self.encode(approvals)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw FolderApprovalStoreError.keychain(status) }
        try add(data)
    }

    private func add(_ data: Data) throws {
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel as String] = "Obscura watched folders"
        attributes[kSecAttrDescription as String] = "Folders you confirmed for Obscura to watch"
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw FolderApprovalStoreError.keychain(added) }
    }

    static func encode(_ approvals: [FolderApproval]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(approvals)
    }

    static func decode(_ data: Data) throws -> [FolderApproval] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode([FolderApproval].self, from: data) } catch { throw FolderApprovalStoreError.malformed }
    }
}

/// G-38: moves the confirmations from an earlier identity's store to this one's, once. The new store is removed first
/// and written by this move, so it is an item Obscura created (whatever was there, planted or left by an interrupted run,
/// is not kept: at worst a folder is asked about again, never watched without the person). The earlier store is removed
/// only after the copy reads back equal; until then it stays and the next launch tries again.
public enum FolderApprovalMigration {
    public enum Outcome: Sendable, Equatable {
        /// The earlier identity had no store.
        case nothingToMove
        /// This many confirmations moved; the earlier store is gone.
        case moved(Int)
        /// A step failed (a locked keychain, access refused); the earlier store is kept for the next launch.
        case failed

        public var isComplete: Bool { self != .failed }
    }

    public static func move(from source: any RemovableFolderApprovalStore, to destination: any RemovableFolderApprovalStore) -> Outcome {
        do {
            guard let approvals = try source.loadIfPresent() else { return .nothingToMove }
            try destination.remove()
            try destination.save(approvals)
            guard try destination.loadIfPresent() == approvals else {
                Log.engine.error("folder confirmation migration: the copy did not read back equal")
                return .failed
            }
            try source.remove()
            Log.engine.info("folder confirmation migration moved=\(approvals.count)")
            return .moved(approvals.count)
        } catch {
            Log.engine.error("folder confirmation migration failed; the earlier confirmations are kept")
            return .failed
        }
    }
}
