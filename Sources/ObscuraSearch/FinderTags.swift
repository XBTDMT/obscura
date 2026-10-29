// ObscuraSearch — Finder tags on a covered file (G-24), keeping the person's own tags untouched.
public import Foundation
import ObscuraSupport

/// The tag arithmetic, pure. Obscura remembers which tags it added (`written`); everything else on the file is the
/// person's and is never removed or reordered.
public enum TagPlan {
    /// The tags to set and the ones Obscura now owns. A wanted tag the person already had stays theirs: Obscura does not
    /// claim it, so switching tags off later leaves it on the file.
    public static func apply(current: [String], written: [String], wanted: [String]) -> (tags: [String], written: [String]) {
        let own = current.filter { !written.contains($0) }
        var added: [String] = []
        for tag in wanted where !own.contains(tag) && !added.contains(tag) { added.append(tag) }
        return (own + added, added)
    }

    /// The tags left once Obscura's own are taken off.
    public static func remove(current: [String], written: [String]) -> [String] {
        current.filter { !written.contains($0) }
    }
}

/// Reads and writes a file's Finder tags. The real one is `FinderTagFiles`; tests use it on temp files.
public protocol FileTagging: Sendable {
    func tags(of url: URL) throws -> [String]
    func setTags(_ tags: [String], on url: URL) throws
}

/// Finder tags through `URLResourceValues.tagNames` (the `com.apple.metadata:_kMDItemUserTags` attribute).
public struct FinderTagFiles: FileTagging {
    public init() {}

    public func tags(of url: URL) throws -> [String] {
        var target = url
        target.removeAllCachedResourceValues()
        return try target.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    public func setTags(_ tags: [String], on url: URL) throws {
        try FileAtomics.setTagNames(tags, on: url)
    }
}
