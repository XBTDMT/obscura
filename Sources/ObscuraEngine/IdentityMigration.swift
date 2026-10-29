// G-38: the one-time move from an earlier bundle identifier to this one, run at launch before anything opens a store.
// Everything Obscura keeps under its own name moves with it, so the person loses nothing:
//   - settings, window positions and the panel's memories: copied into the new defaults domain (PreviousIdentityDefaults);
//   - the rule keys (G-30, G-34) and the watched-folder confirmations (G-36): re-created under the new Keychain services,
//     read back, then deleted under the old ones (RuleKeyMigration, FolderApprovalMigration);
//   - Spotlight: the old domain is deleted; the launch's full reconcile (G-24) indexes every covered file again under the
//     new domain. Core Spotlight keeps entries per app, so entries the earlier identity indexed may be outside this
//     identity's reach; switching "Spotlight entries" off in the earlier build before updating removes them for certain
//     (they hold labels only, never secret text);
//   - the login item: registered again when the earlier identity recorded it as on (LoginItemCarryOver).
// The Journal (~/Library/Application Support/Obscura) and the backups folder beside it are named by path, not by bundle
// identifier, so they stay where they are and need no move.
//
// What macOS asks again, once: macOS treats the renamed app as a new app. Its privacy permissions are recorded per app,
// so the Files & Folders access (Desktop or the screenshot folder, Downloads, added folders) and the notification
// permission are asked for again the first time they are needed. Reading the earlier identity's Keychain items can also
// ask, once per item, because their access list trusts the earlier app (Always Allow ends that). Nothing here can grant
// those on the person's behalf, and nothing should.
//
// Each step is idempotent and records its own completion in the new defaults domain, so a launch that stops half way
// finishes on the next one; a step that fails (a locked keychain, a refused prompt) leaves the earlier items in place and
// runs again at the next launch.
public import Foundation
public import ObscuraCapture
public import ObscuraJournal
public import ObscuraPrefs
public import ObscuraSearch
public import ObscuraSupport

public struct IdentityMigration: Sendable {
    public let previous: AppIdentity
    public let current: AppIdentity

    public init(previous: AppIdentity, current: AppIdentity = .current) {
        self.previous = previous
        self.current = current
    }

    /// Completion markers in the new defaults domain.
    enum Marker {
        static let keychain = "identity.migration.keychain"
        static let spotlight = "identity.migration.spotlight"
        static let loginItem = "identity.migration.loginItem"
    }

    // MARK: Settings

    /// Copies the earlier identity's settings into `defaults` (whose persistent domain is named `domain`) when this
    /// domain has none yet.
    public func carrySettings(into defaults: UserDefaults, domain: String) -> PreviousIdentityDefaults.Outcome {
        PreviousIdentityDefaults.migrate(from: defaults.persistentDomain(forName: previous.defaultsDomain), to: defaults,
                                         currentDomain: defaults.persistentDomain(forName: domain))
    }

    // MARK: Keychain

    public struct KeychainOutcome: Sendable, Equatable {
        public var ruleKeys: RuleKeyMigration.Outcome
        public var folderApprovals: FolderApprovalMigration.Outcome
        public var isComplete: Bool { ruleKeys.isComplete && folderApprovals.isComplete }
    }

    /// Moves the rule keys and folder confirmations from the earlier identity's stores to this one's, unless an earlier
    /// launch finished it. Returns nil when there was nothing left to do.
    public func moveKeychainItems(ruleKeys: (from: any RuleKeyStore, to: any RuleKeyStore),
                                  folderApprovals: (from: any RemovableFolderApprovalStore, to: any RemovableFolderApprovalStore),
                                  markers defaults: UserDefaults) -> KeychainOutcome? {
        guard !defaults.bool(forKey: Marker.keychain) else { return nil }
        let outcome = KeychainOutcome(ruleKeys: RuleKeyMigration.move(from: ruleKeys.from, to: ruleKeys.to),
                                      folderApprovals: FolderApprovalMigration.move(from: folderApprovals.from, to: folderApprovals.to))
        if outcome.isComplete { defaults.set(true, forKey: Marker.keychain) }
        return outcome
    }

    /// The app's stores: the login keychain under each identity's services.
    public func moveKeychainItems(markers defaults: UserDefaults) -> KeychainOutcome? {
        moveKeychainItems(ruleKeys: (KeychainRuleKeyStore(service: previous.ruleKeyService),
                                     KeychainRuleKeyStore(service: current.ruleKeyService)),
                          folderApprovals: (KeychainFolderApprovalStore(service: previous.folderApprovalService),
                                            KeychainFolderApprovalStore(service: current.folderApprovalService)),
                          markers: defaults)
    }

    // MARK: Spotlight

    /// Deletes the earlier identity's Spotlight domain, unless an earlier launch did. The new domain is rebuilt by the
    /// launch's full reconcile, so nothing is re-indexed here. Returns whether the delete ran and succeeded.
    @discardableResult
    public func retireSpotlightDomain(index: any SearchIndexing, markers defaults: UserDefaults) async -> Bool {
        guard !defaults.bool(forKey: Marker.spotlight) else { return false }
        do {
            try await index.deleteAll(domain: previous.spotlightDomain)
            defaults.set(true, forKey: Marker.spotlight)
            Log.search.info("search: the earlier identity's domain was deleted")
            return true
        } catch {
            Log.search.error("search: the earlier identity's domain could not be deleted; retried at the next launch")
            return false
        }
    }

    // MARK: Login item

    /// Decides the login item once, from the carried `LoginItem.lastKnownOn` and this identity's status, and carries it
    /// out with `register`. Returns the action taken (nil when an earlier launch decided it).
    @discardableResult
    public func carryLoginItem(markers defaults: UserDefaults, status: () -> LoginItemStatus,
                               register: () throws -> Void) -> LoginItemCarryOver.Action? {
        guard !defaults.bool(forKey: Marker.loginItem) else { return nil }
        let action = LoginItemCarryOver.action(previouslyOn: LoginItem.lastKnownOn(in: defaults), status: status())
        if action == .register {
            do { try register() } catch { Log.app.error("login item: registering under the new identity failed") }
        }
        defaults.set(true, forKey: Marker.loginItem)
        Log.app.info("login item carried over: \(action == .register ? "registered" : "left as is", privacy: .public)")
        return action
    }
}
