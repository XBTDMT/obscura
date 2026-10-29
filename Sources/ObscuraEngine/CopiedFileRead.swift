// F6/F12 (G-35): a file reference on the clipboard is a request any process running as the user can make, without any
// Files & Folders permission of its own. Obscura reads one only when it is plausibly the person's: a regular file inside
// a folder Obscura already guards for them (the screenshot folder, Downloads, their added folders), where Obscura reads
// every new image with the same permission anyway. The path is resolved first, then opened with no link followed
// anywhere in it (O_NOFOLLOW_ANY) and checked to be the same file. Anything else is never opened: it is left as it is,
// "not checked", with a notice.
import Darwin
import Foundation
import ObscuraCapture

enum CopiedFileRead {
    enum Outcome: Equatable {
        case data(Data)
        /// Larger than `maxBytes`; nothing past the size was read.
        case tooLarge
        /// Not inside a folder Obscura guards (or not a regular file there): never opened.
        case notGuarded
        /// It could not be opened or read (gone, no permission, an I/O error): `errno`.
        case unreadable(Int32)
    }

    static func read(_ url: URL, roots: [WatchedRoot], maxBytes: Int) -> Outcome {
        guard url.isFileURL, url.path.hasPrefix("/") else { return .notGuarded }
        guard let resolved = JournalTargets.realPath(url.path) else { return .unreadable(errno) }
        let inside = roots.contains { root in
            guard let base = JournalTargets.realPath(root.url.path) else { return false }
            return resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
        guard inside else { return .notGuarded }
        var before = stat()
        guard lstat(resolved, &before) == 0 else { return .unreadable(errno) }
        guard before.st_mode & S_IFMT == S_IFREG else { return .notGuarded }

        let fd = open(resolved, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return errno == ELOOP ? .notGuarded : .unreadable(errno) }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { return .unreadable(errno) }
        // The file opened is the one checked: not swapped between the check and the open.
        guard opened.st_mode & S_IFMT == S_IFREG, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino else { return .notGuarded }
        guard opened.st_size <= off_t(maxBytes) else { return .tooLarge }

        var data = Data(count: Int(opened.st_size))
        var total = 0
        while total < data.count {
            let n = data.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress!.advanced(by: total), buffer.count - total)
            }
            if n < 0 { if errno == EINTR { continue }; return .unreadable(errno) }
            if n == 0 { break }
            total += n
        }
        data.count = total
        return .data(data)
    }
}
