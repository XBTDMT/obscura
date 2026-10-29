// F2: what `obscura journal list` and `obscura journal rules` read. A Journal the person names with `--root` may be a copy
// someone sent them, so it is opened read-only and nothing the store does at open runs on it: no folder is created or
// re-moded, no migration, no layout move, no trash purge, no backup prune, no key created. Like `CoveredFilesReader`.
public import Foundation

public struct JournalInspector {
    /// The schema version the file says it is at.
    public let schemaVersion: Int
    private let db: SQLiteConnection

    /// One custom rule as the inspection shows it: never its value, only whether it could be read here.
    public struct Rule: Sendable, Equatable {
        public enum State: Sendable, Equatable {
            case readable
            case unreadable(RuleValueProblem)
            /// The file is older than schema 8: its rule values are still plain and Obscura seals them at its next open of
            /// this Journal. The inspection does not read them.
            case notSealedYet
        }
        public let id: String
        public let action: RuleAction
        public let kind: RuleKind
        public let name: String?
        public let enabled: Bool
        public let state: State
    }

    /// Opens `root/obscura.sqlite` read-only. Throws `fileMissing` when there is no database, `newerSchema` when a newer
    /// Obscura wrote it, and `corruptRecord` when it is not a Journal.
    public init(root: URL) throws {
        let url = root.appendingPathComponent(SQLiteJournalStore.databaseName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw JournalError.fileMissing(url) }
        let db = try SQLiteConnection(path: url.path, readOnly: true)
        // A file someone else made: its schema's triggers and views are not trusted, and nothing is written.
        try db.exec("PRAGMA trusted_schema = OFF")
        try db.exec("PRAGMA query_only = ON")
        guard try db.tableExists("schema_version") else { throw JournalError.corruptRecord("not a Journal (no schema_version)") }
        let version = try db.scalarInt("SELECT coalesce(max(version), 0) FROM schema_version")
        if version > Migrations.latestVersion { throw JournalError.newerSchema(found: version, supported: Migrations.latestVersion) }
        self.db = db
        schemaVersion = version
    }

    /// Entries not in the trash, newest first.
    public func liveEntries() throws -> [Entry] {
        try SQLiteJournalStore.loadEntries(db, where: "e.trashed_at IS NULL", [], tail: "")
    }

    /// Every custom rule in order, with whether its value opens with the key `ruleKeys` already holds. Never creates a key
    /// and never returns a value.
    public func rules(ruleKeys: any RuleKeyStore) throws -> [Rule] {
        let sealed = schemaVersion >= SQLiteJournalStore.sealedRulesVersion
        let columns = "id, action, kind, name, enabled" + (sealed ? ", sealed_value" : "")
        struct Row { let id: String; let action: RuleAction; let kind: RuleKind; let name: String?; let enabled: Bool; let sealed: Data? }
        let rows: [Row] = try db.query("SELECT \(columns) FROM rules ORDER BY sort_order, created_at", []) { r in
            guard let action = RuleAction(rawValue: r.string(1)), let kind = RuleKind(rawValue: r.string(2)) else {
                throw JournalError.corruptRecord("rule \(r.string(0))")
            }
            return Row(id: r.string(0), action: action, kind: kind, name: r.optionalString(3), enabled: r.bool(4),
                       sealed: sealed ? (r.isNull(5) ? Data() : r.data(5)) : nil)
        }
        guard sealed else {
            return rows.map { Rule(id: $0.id, action: $0.action, kind: $0.kind, name: $0.name, enabled: $0.enabled, state: .notSealedYet) }
        }
        guard !rows.isEmpty else { return [] }
        return rows.map { row in
            let state: Rule.State
            switch RuleSeal.open(row.sealed ?? Data(), id: row.id, action: row.action, kind: row.kind, keys: { ruleKeys.lookup($0) }) {
            case .success: state = .readable
            case .failure(let problem): state = .unreadable(problem)
            }
            return Rule(id: row.id, action: row.action, kind: row.kind, name: row.name, enabled: row.enabled, state: state)
        }
    }
}
