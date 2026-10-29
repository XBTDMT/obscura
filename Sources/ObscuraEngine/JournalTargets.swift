// F26: obscura.sqlite is writable by any process running as the user, so a path read from it (an entry's `file_path` or
// `clean_copy_path`, a not-covered row's file) is a request, not an authority. Obscura writes or trashes one only when it
// is still a file the person asked Obscura to guard: a caught file (never an import, never a clipboard catch), an
// absolute path with nothing to resolve, whose folder resolves inside a folder Obscura watches right now, which is not a
// link and, when present, a regular file; a "(clean)" copy only at the exact sibling name its caught file gives.
import Darwin
import Foundation
import ObscuraCapture
import ObscuraJournal
import UniformTypeIdentifiers

enum JournalTargets {
    enum Target: Equatable {
        /// Nothing on disk to write (a clipboard catch, an import, a demo).
        case none
        /// The file to write or trash.
        case file(URL)
        /// The row names a path Obscura will not touch; the change stays in the Journal only.
        case refused
    }

    /// Where an entry's picture goes on disk, checked against `roots` (the folders watched now).
    static func target(of entry: Entry, roots: [WatchedRoot]) -> Target {
        guard entry.filePath != nil || entry.cleanCopyPath != nil else { return .none }
        // An import is never touched on disk (CaptureEvent), and only a caught file has a file to write.
        guard entry.source == .file else { return .none }
        guard let filePath = entry.filePath, let caught = checked(filePath, roots: roots) else { return .refused }
        guard let copy = entry.cleanCopyPath else { return .file(caught) }
        // The keep-both copy is bound to its caught file: the same folder, the name the engine gives it.
        let expected = ShieldEngine.cleanSibling(of: URL(fileURLWithPath: filePath), output: UTType(entry.containerUTI) ?? .png)
        guard copy == expected.path, let target = checked(copy, roots: roots) else { return .refused }
        return .file(target)
    }

    /// `path` (as the row names it, so every list keyed by it still matches) when it may be written or trashed; nil
    /// otherwise.
    static func checked(_ path: String, roots: [WatchedRoot]) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path)
        // Nothing to resolve: no "..", ".", doubled or trailing slash a crafted row could use to climb out.
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { return nil }      // a link, a folder or a device: never
        } else if errno != ENOENT {
            return nil
        }
        guard let folder = realPath(url.deletingLastPathComponent().path) else { return nil }
        let inside = roots.contains { root in
            guard let base = realPath(root.url.path) else { return false }
            return folder == base || folder.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
        guard inside else { return nil }
        return url
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
