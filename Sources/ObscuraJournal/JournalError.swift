public import Foundation

/// Every failure of the Journal. Nothing in this package fails silently.
public enum JournalError: Error, Sendable, Equatable {
    /// The database was written by a newer Obscura than this one.
    case newerSchema(found: Int, supported: Int)
    /// SQLite reported an error.
    case sqlite(code: Int32, message: String)
    /// No entry with this id (or it is not in the state the operation needs).
    case entryNotFound(UUID)
    case findingNotFound(UUID)
    case ruleNotFound(String)
    case styleNotFound(Int64)
    /// No "Not checked" row with this id.
    case uncheckedNotFound(UUID)
    /// No "Not covered on disk" row with this id.
    case uncoveredNotFound(UUID)
    /// `container_uti` is not one of public.png / public.jpeg / public.heic.
    case unsupportedContainer(String)
    /// A stored value does not decode (corrupt row or file).
    case corruptRecord(String)
    /// A file the store expected is missing.
    case fileMissing(URL)
    /// The entry's clean file does not match the digest its row was committed with (or the row has none yet, from
    /// before schema 6): it is not trusted as the picture its flags describe until the engine renders it again (G-28).
    case cleanOutOfDate(UUID)
    /// The entry changed (another commit landed) since the revision a re-render started from.
    case revisionConflict(UUID)
    /// Upkeep (`step`: trash, prune, sweep, orphans, deleteAll) did everything it could but `failed` items would not go;
    /// they keep their rows and are tried again (fail-open #11).
    case maintenanceIncomplete(step: String, failed: Int)
    /// The rules document being imported is not one this version understands.
    case invalidImport(String)
    /// A rule value could not be sealed because the key store (the Keychain) did not answer (G-30). Nothing was written.
    case ruleKeyUnavailable
    /// A Journal folder (`what`: the root, the images folder or a trash folder) is a symbolic link, not a folder, or
    /// resolves outside the Journal's root (F2). The store never follows it: it refuses to open, or skips that folder.
    case unsafeLocation(String)
}

extension JournalError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .newerSchema(let found, let supported):
            return "This Journal was written by a newer Obscura (schema \(found); this version reads up to \(supported))."
        case .sqlite(let code, let message): return "SQLite error \(code): \(message)"
        case .entryNotFound(let id): return "No Journal entry \(id.uuidString)"
        case .findingNotFound(let id): return "No finding \(id.uuidString)"
        case .ruleNotFound(let id): return "No rule \(id)"
        case .styleNotFound(let id): return "No style \(id)"
        case .uncheckedNotFound(let id): return "No unchecked file \(id.uuidString)"
        case .uncoveredNotFound(let id): return "No uncovered file \(id.uuidString)"
        case .unsupportedContainer(let uti): return "Unsupported image container \(uti)"
        case .corruptRecord(let what): return "Corrupt Journal record: \(what)"
        case .fileMissing(let url): return "Missing file \(url.lastPathComponent)"
        case .cleanOutOfDate(let id): return "The clean picture of \(id.uuidString) does not match its findings"
        case .revisionConflict(let id): return "Entry \(id.uuidString) changed meanwhile"
        case .maintenanceIncomplete(let step, let failed): return "Journal \(step) left \(failed) item(s) to try again"
        case .invalidImport(let why): return "Cannot import rules: \(why)"
        case .ruleKeyUnavailable: return "The key that protects your rules could not be read from the keychain"
        case .unsafeLocation(let what): return "The Journal's \(what) is a link or lies outside the Journal folder; Obscura will not use it"
        }
    }
}
