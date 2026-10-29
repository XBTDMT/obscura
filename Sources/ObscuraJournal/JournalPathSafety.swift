// F2: the Journal's own folders are never followed through a symbolic link. Everything Obscura deletes or writes under
// its root (the images folder, the trash, an entry's folder) is a real folder whose resolved path stays inside the
// resolved root, and an entry's folder name is always the canonical text of a parsed UUID, never a string from a row.
import Darwin
import Foundation

enum JournalPathSafety {
    /// The resolved path (`realpath(3)`: every link in it followed), or nil when it does not exist.
    static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    enum Kind: Equatable { case missing, directory, symbolicLink, other }

    /// What the last component of `url` is, without following it.
    static func kind(_ url: URL) -> Kind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .missing }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
    }

    /// The root itself may sit under links (`/tmp`, `/var`), but its own last component is a real folder or not there yet.
    static func checkRoot(_ root: URL) throws {
        switch kind(root) {
        case .missing, .directory: return
        case .symbolicLink, .other: throw JournalError.unsafeLocation("folder")
        }
    }

    /// A folder inside the root: missing (made later), or a real folder (not a link) whose resolved path is inside the
    /// resolved root. `what` names it in the error, never a path.
    static func checkContained(_ url: URL, in root: URL, what: String) throws {
        switch kind(url) {
        case .missing: return
        case .symbolicLink, .other: throw JournalError.unsafeLocation(what)
        case .directory:
            guard let base = realPath(root), let resolved = realPath(url), resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/") else {
                throw JournalError.unsafeLocation(what)
            }
        }
    }

    /// A folder beside the root (`Obscura-Backups`): missing or a real folder, never a link.
    static func checkNotLink(_ url: URL, what: String) throws {
        switch kind(url) {
        case .missing, .directory: return
        case .symbolicLink, .other: throw JournalError.unsafeLocation(what)
        }
    }

    /// The folder name of an entry id read from a row: its canonical UUID text, or nil when the row's id is not a UUID
    /// (then nothing on disk is touched for it).
    static func entryFolderName(_ rowID: String) -> String? { UUID(uuidString: rowID)?.uuidString }
}
