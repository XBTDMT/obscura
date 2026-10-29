import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A bound or read SQLite value.
enum SQLValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    init(_ s: String?) { self = s.map { .text($0) } ?? .null }
    init(_ i: Int?) { self = i.map { .integer(Int64($0)) } ?? .null }
    init(_ b: Bool) { self = .integer(b ? 1 : 0) }
    init(_ d: Double) { self = .real(d) }
}

/// One SQLite connection. Not Sendable: it is owned by exactly one actor.
/// Opens with WAL, foreign keys on and a busy timeout; every failure is a `JournalError.sqlite`.
final class SQLiteConnection {
    private var db: OpaquePointer?

    /// `readOnly` opens an existing file without creating, migrating or changing anything (the debug report reads the
    /// running app's Journal that way); the connection settings are left as the file has them.
    init(path: String, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        let flags = readOnly ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX) : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX)
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let handle { sqlite3_close_v2(handle) }
            throw JournalError.sqlite(code: rc, message: message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 5_000)
        guard !readOnly else { return }
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA foreign_keys = ON")
    }

    deinit { close() }

    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    private func check(_ rc: Int32, _ sql: String? = nil) throws {
        guard rc == SQLITE_OK || rc == SQLITE_ROW || rc == SQLITE_DONE else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
            throw JournalError.sqlite(code: rc, message: sql.map { "\(message) in: \($0)" } ?? message)
        }
    }

    /// Runs one or more statements with no bindings (DDL, PRAGMA, transaction control).
    func exec(_ sql: String) throws {
        guard let db else { throw JournalError.sqlite(code: SQLITE_MISUSE, message: "connection closed") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorMessage)
            throw JournalError.sqlite(code: rc, message: message)
        }
    }

    /// Runs a single statement with positional bindings, discarding rows.
    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql, values)
        _ = try statement.step()
    }

    /// Runs a query and maps every row.
    func query<T>(_ sql: String, _ values: [SQLValue] = [], _ map: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        var out: [T] = []
        while try statement.step() { out.append(try map(Row(statement))) }
        return out
    }

    /// Runs a query and maps the first row, or nil. Steps once, so it also works for PRAGMA statements.
    func first<T>(_ sql: String, _ values: [SQLValue] = [], _ map: (Row) throws -> T) throws -> T? {
        let statement = try prepare(sql, values)
        guard try statement.step() else { return nil }
        return try map(Row(statement))
    }

    func scalarInt(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
        try first(sql, values) { $0.int(0) } ?? 0
    }

    var changes: Int { db.map { Int(sqlite3_changes($0)) } ?? 0 }
    var lastInsertRowID: Int64 { db.map { sqlite3_last_insert_rowid($0) } ?? 0 }

    /// Runs `body` inside BEGIN IMMEDIATE … COMMIT, rolling back on any throw.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try exec("COMMIT")
            return value
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func tableExists(_ name: String) throws -> Bool {
        try scalarInt("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(name)]) > 0
    }

    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> Statement {
        guard let db else { throw JournalError.sqlite(code: SQLITE_MISUSE, message: "connection closed") }
        var raw: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &raw, nil), sql)
        guard let raw else { throw JournalError.sqlite(code: SQLITE_ERROR, message: "empty statement: \(sql)") }
        let statement = Statement(raw, owner: self, sql: sql)
        let expected = Int(sqlite3_bind_parameter_count(raw))
        guard expected == values.count else {
            throw JournalError.sqlite(code: SQLITE_MISUSE, message: "expected \(expected) bindings, got \(values.count) in: \(sql)")
        }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(raw, position)
            case .integer(let i): rc = sqlite3_bind_int64(raw, position, i)
            case .real(let d): rc = sqlite3_bind_double(raw, position, d)
            case .text(let s): rc = sqlite3_bind_text(raw, position, s, -1, sqliteTransient)
            case .blob(let data):
                rc = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(raw, position, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
                }
            }
            try check(rc, sql)
        }
        return statement
    }

    /// A prepared statement; finalized when it goes away.
    final class Statement {
        fileprivate let raw: OpaquePointer
        private unowned let owner: SQLiteConnection
        private let sql: String

        fileprivate init(_ raw: OpaquePointer, owner: SQLiteConnection, sql: String) {
            self.raw = raw
            self.owner = owner
            self.sql = sql
        }

        deinit { sqlite3_finalize(raw) }

        /// Advances; true when a row is available.
        func step() throws -> Bool {
            let rc = sqlite3_step(raw)
            switch rc {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: try owner.check(rc, sql); return false
            }
        }
    }

    /// Typed column accessors for the current row.
    struct Row {
        private let statement: Statement
        fileprivate init(_ statement: Statement) { self.statement = statement }

        func isNull(_ column: Int) -> Bool { sqlite3_column_type(statement.raw, Int32(column)) == SQLITE_NULL }
        func int(_ column: Int) -> Int { Int(sqlite3_column_int64(statement.raw, Int32(column))) }
        func int64(_ column: Int) -> Int64 { sqlite3_column_int64(statement.raw, Int32(column)) }
        func optionalInt(_ column: Int) -> Int? { isNull(column) ? nil : int(column) }
        func bool(_ column: Int) -> Bool { int(column) != 0 }
        func double(_ column: Int) -> Double { sqlite3_column_double(statement.raw, Int32(column)) }
        func string(_ column: Int) -> String {
            guard let text = sqlite3_column_text(statement.raw, Int32(column)) else { return "" }
            return String(cString: text)
        }
        func optionalString(_ column: Int) -> String? { isNull(column) ? nil : string(column) }
        func data(_ column: Int) -> Data {
            let count = Int(sqlite3_column_bytes(statement.raw, Int32(column)))
            guard count > 0, let bytes = sqlite3_column_blob(statement.raw, Int32(column)) else { return Data() }
            return Data(bytes: bytes, count: count)
        }
    }
}
