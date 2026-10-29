// ObscuraSearch — keeps each covered file's Spotlight item and Finder tags in step with the file (G-24).
//
// Lifetime follows the COVERED FILE, not the Journal entry (entries expire after 24 h by default; "search later" must
// still work): an item and tags are made when a file is covered, updated when its findings change, and removed when the
// file is gone, in the Trash, or showing its original after Undo; checked at launch (full reindex) and on every
// maintenance tick. Search is never allowed to fail a catch: every error here is logged (counts and ids) and dropped.
public import Foundation
public import ObscuraJournal
public import ObscuraSupport
import CoreSpotlight

/// The two switches of Settings → Journal & Privacy, as read when a call is made.
public struct SearchSwitches: Sendable, Hashable {
    public var spotlight: Bool
    public var tags: Bool
    public init(spotlight: Bool, tags: Bool) { self.spotlight = spotlight; self.tags = tags }
}

/// What opening a Spotlight result shows.
public enum SearchTarget: Sendable, Hashable {
    /// The Journal entry still exists: Obscura's viewer opens on it.
    case entry(UUID)
    /// The entry expired; the covered file is revealed in Finder.
    case file(URL)
    /// Neither is left.
    case none
}

/// The debug report: counts and ids only, never a path, a name or a label.
public struct SearchReport: Sendable, Codable, Hashable {
    public var records = 0
    public var covered = 0
    public var filesPresent = 0
    /// Covered files whose Finder tags include every tag Obscura recorded writing.
    public var taggedFiles = 0
    public var recordIDs: [String] = []
    public var taggedIDs: [String] = []
    public var missingIDs: [String] = []
    /// The ids Core Spotlight holds in Obscura's domain, when the report ran inside the app (nil elsewhere: the index
    /// belongs to the app's bundle).
    public var spotlightIDs: [String]?
    public init() {}

    /// The report for these records, reading each covered file's tags (never printing them).
    public static func make(records: [CoveredFileRecord], tagger: any FileTagging = FinderTagFiles()) -> SearchReport {
        var report = SearchReport()
        report.records = records.count
        for record in records {
            report.recordIDs.append(record.id.uuidString)
            if record.covered { report.covered += 1 }
            guard let (url, _) = SearchCoordinator.locate(record) else { report.missingIDs.append(record.id.uuidString); continue }
            report.filesPresent += 1
            if !record.tagsWritten.isEmpty, let tags = try? tagger.tags(of: url), Set(record.tagsWritten).isSubset(of: Set(tags)) {
                report.taggedFiles += 1
                report.taggedIDs.append(record.id.uuidString)
            }
        }
        return report
    }
}

/// Reads the Journal entry a Spotlight result names out of the activity macOS hands the app when it is opened.
public enum SearchResultActivity {
    /// `CSSearchableItemActionType` with `CSSearchableItemActivityIdentifier` in its user info; nil for anything else.
    public static func identifier(activityType: String, userInfo: [AnyHashable: Any]?) -> String? {
        guard activityType == CSSearchableItemActionType else { return nil }
        return userInfo?[CSSearchableItemActivityIdentifier] as? String
    }
}

public actor SearchCoordinator {
    private let journal: any JournalStore
    private let index: any SearchIndexing
    private let tagger: any FileTagging
    private let clock: any WallClock
    private var lastSwitches: SearchSwitches?

    public init(journal: any JournalStore, index: any SearchIndexing, tagger: any FileTagging = FinderTagFiles(),
                clock: any WallClock = SystemClock()) {
        self.journal = journal
        self.index = index
        self.tagger = tagger
        self.clock = clock
    }

    // MARK: Events

    /// A file on disk was just covered. Its record is made (replacing one for the same path) and published.
    public func caught(entryID: UUID, coveredFile: URL, findings: [Finding], isScreenshot: Bool, titles: [String: String],
                       switches: SearchSwitches) async {
        let enabled = findings.filter(\.enabled)
        guard !enabled.isEmpty else { return }
        do {
            let path = coveredFile.standardizedFileURL.path
            let previous = try await journal.coveredFiles().first { $0.filePath == path && $0.id != entryID }
            let now = clock.now()
            var record = CoveredFileRecord(id: entryID, filePath: path, bookmark: Self.bookmark(coveredFile),
                                           detectorIDs: Self.detectorIDs(enabled), categories: Self.categories(enabled),
                                           isScreenshot: isScreenshot, caughtAt: now, updatedAt: now,
                                           tagsWritten: previous?.tagsWritten ?? [])
            let displaced = try await journal.upsertCoveredFile(record)
            if !displaced.isEmpty { try await index.delete(identifiers: displaced.map(\.uuidString)) }
            record = try await publish(record, at: coveredFile, titles: titles, switches: switches)
            Log.search.info("search caught entry=\(entryID.uuidString, privacy: .public) kinds=\(record.detectorIDs.count) displaced=\(displaced.count)")
        } catch {
            Log.search.error("search caught failed entry=\(entryID.uuidString, privacy: .public)")
        }
    }

    /// The entry's findings or picture changed (a finding toggled, Undo, Redo, a new style). A file Obscura never
    /// labelled (a clipboard catch, an import) has no record and is left alone.
    public func entryChanged(_ entry: Entry, titles: [String: String], switches: SearchSwitches) async {
        do {
            guard var record = try await journal.coveredFile(entry.id) else { return }
            let enabled = entry.enabledFindings
            record.covered = !enabled.isEmpty
            if record.covered {
                record.detectorIDs = Self.detectorIDs(enabled)
                record.categories = Self.categories(enabled)
            }
            guard let (url, located) = Self.locate(record) else {
                try await retire(record, at: nil)
                return
            }
            record = try await publish(located, at: url, titles: titles, switches: switches)
            Log.search.info("search updated entry=\(entry.id.uuidString, privacy: .public) covered=\(record.covered) kinds=\(record.detectorIDs.count)")
        } catch {
            Log.search.error("search update failed entry=\(entry.id.uuidString, privacy: .public)")
        }
    }

    /// Checks every record against its file. `full` (at launch) also rebuilds Obscura's Spotlight domain from the
    /// records, which removes any item whose record is gone, and re-applies or removes tags to match the switches.
    /// Returns how many records were retired.
    @discardableResult
    public func reconcile(full: Bool, titles: [String: String], switches: SearchSwitches) async -> Int {
        lastSwitches = switches
        var retired = 0, published = 0
        do {
            if full { try await index.deleteAll(domain: SearchItemContent.domain) }
            for record in try await journal.coveredFiles() {
                guard let (url, located) = Self.locate(record) else {
                    // A file on a disk that is not connected right now is not gone: it keeps its record until the disk
                    // is back (Spotlight shows nothing for it meanwhile).
                    if Self.isOnUnmountedVolume(record.filePath) { continue }
                    try await retire(record, at: nil)
                    retired += 1
                    continue
                }
                // Showing its original and no entry left to Redo from: nothing will cover this file again.
                if !located.covered, (try? await journal.entry(located.id)) == nil {
                    try await retire(located, at: url)
                    retired += 1
                    continue
                }
                if full || located != record {
                    _ = try await publish(located, at: url, titles: titles, switches: switches)
                    published += 1
                }
            }
            Log.search.info("search reconcile full=\(full) retired=\(retired) published=\(published)")
        } catch {
            Log.search.error("search reconcile failed retired=\(retired)")
        }
        return retired
    }

    /// Follows the Settings switches: Spotlight off deletes Obscura's whole domain, on indexes every covered file;
    /// tags off removes exactly the tags Obscura wrote, on adds them. The first call only records the switches.
    public func switchesChanged(to switches: SearchSwitches, titles: [String: String]) async {
        guard let previous = lastSwitches else { lastSwitches = switches; return }
        lastSwitches = switches
        guard previous != switches else { return }
        do {
            if previous.spotlight && !switches.spotlight { try await index.deleteAll(domain: SearchItemContent.domain) }
            for record in try await journal.coveredFiles() {
                guard let (url, located) = Self.locate(record) else { try await retire(record, at: nil); continue }
                _ = try await publish(located, at: url, titles: titles, switches: switches)
            }
            Log.search.info("search switches spotlight=\(switches.spotlight) tags=\(switches.tags)")
        } catch {
            Log.search.error("search switch change failed")
        }
    }

    /// What a Spotlight result opens: the viewer while the entry exists, else the covered file in Finder.
    public func target(for identifier: String) async -> SearchTarget {
        guard let id = UUID(uuidString: identifier) else { return .none }
        if let entry = try? await journal.entry(id), !entry.isTrashed { return .entry(id) }
        guard let record = try? await journal.coveredFile(id), let (url, _) = Self.locate(record) else { return .none }
        return .file(url)
    }

    /// Counts and ids of the records and of the files that carry Obscura's tags.
    public func report() async -> SearchReport {
        guard let records = try? await journal.coveredFiles() else { return SearchReport() }
        return SearchReport.make(records: records, tagger: tagger)
    }

    // MARK: Publishing

    /// Brings the file's tags and Spotlight item in line with the record and the switches, then stores the record.
    private func publish(_ record: CoveredFileRecord, at url: URL, titles: [String: String], switches: SearchSwitches) async throws -> CoveredFileRecord {
        var record = record
        // A file listed as not covered on disk (fail-open #7) shows what was caught: no "covered" item, no thumbnail of
        // it and no tags until a write lands, whatever the record last said (G-28).
        let notOnDisk = try await journal.uncoveredFiles().contains { $0.filePath == record.filePath }
        let shows = record.covered && !notOnDisk
        if switches.tags && shows {
            let current = (try? tagger.tags(of: url)) ?? []
            let plan = TagPlan.apply(current: current, written: record.tagsWritten,
                                     wanted: SearchLabels.tags(detectorIDs: record.detectorIDs, titles: titles))
            if plan.tags != current { try tagger.setTags(plan.tags, on: url) }
            record.tagsWritten = plan.written
        } else if !record.tagsWritten.isEmpty {
            try removeTags(of: record, at: url)
            record.tagsWritten = []
        }
        if switches.spotlight && shows {
            try await index.index([CatchSearchItem.build(record: record, titles: titles, thumbnail: CoveredThumbnail.data(of: url))])
        } else {
            try await index.delete(identifiers: [record.id.uuidString])
        }
        record.updatedAt = clock.now()
        try await journal.upsertCoveredFile(record)
        return record
    }

    /// The file is gone, in the Trash, or will not be covered again: its item, Obscura's tags and its record go.
    private func retire(_ record: CoveredFileRecord, at url: URL?) async throws {
        if let url, !record.tagsWritten.isEmpty { try? removeTags(of: record, at: url) }
        else if !record.tagsWritten.isEmpty, FileManager.default.fileExists(atPath: record.filePath) {
            try? removeTags(of: record, at: record.fileURL)
        }
        try await index.delete(identifiers: [record.id.uuidString])
        try await journal.deleteCoveredFile(record.id)
        Log.search.info("search retired entry=\(record.id.uuidString, privacy: .public)")
    }

    private func removeTags(of record: CoveredFileRecord, at url: URL) throws {
        let current = try tagger.tags(of: url)
        let left = TagPlan.remove(current: current, written: record.tagsWritten)
        if left != current { try tagger.setTags(left, on: url) }
    }

    // MARK: Finding the file

    /// The covered file as it is now: at its recorded path, else where its bookmark leads (a move or rename, with the
    /// record updated). Nil when it is gone or in the Trash.
    nonisolated static func locate(_ record: CoveredFileRecord) -> (URL, CoveredFileRecord)? {
        let fm = FileManager.default
        let recorded = record.fileURL
        if fm.fileExists(atPath: recorded.path), !Self.isInTrash(recorded) { return (recorded, record) }
        guard let bookmark = record.bookmark else { return nil }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                      bookmarkDataIsStale: &stale),
              fm.fileExists(atPath: resolved.path), !Self.isInTrash(resolved) else { return nil }
        var moved = record
        moved.filePath = resolved.standardizedFileURL.path
        moved.bookmark = Self.bookmark(resolved) ?? bookmark
        return (resolved, moved)
    }

    /// `/Volumes/<name>/…` whose volume is not mounted now.
    static func isOnUnmountedVolume(_ path: String) -> Bool {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/\(parts[2])")
    }

    static func isInTrash(_ url: URL) -> Bool {
        let parts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return parts.contains(".Trash") || parts.contains(".Trashes")
    }

    static func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Each covered finding's display detector (its first id), in order, without repeats.
    static func detectorIDs(_ findings: [Finding]) -> [String] {
        var out: [String] = []
        for f in findings { if let id = f.detectorIDs.first, !out.contains(id) { out.append(id) } }
        return out
    }

    static func categories(_ findings: [Finding]) -> [String] {
        var out: [String] = []
        for f in findings where !out.contains(f.category) { out.append(f.category) }
        return out
    }
}
