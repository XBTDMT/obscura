public import Foundation
import CoreGraphics

// Value types of the Journal. All Codable with snake_case keys so a JSON dump reads like the SQLite rows.
// No type here carries recognized text, or a hash of it (fail-open #19): findings carry rects, detector ids, a category.

/// Where an image came from.
public enum EntrySource: String, Codable, Sendable, Hashable, CaseIterable {
    case file, clipboard, imported, demo
}

public enum StyleKind: String, Codable, Sendable, Hashable, CaseIterable {
    case solid, erase, blur, mosaic
}

public enum LabelMode: String, Codable, Sendable, Hashable, CaseIterable {
    case none, redacted, kind
}

public enum RuleAction: String, Codable, Sendable, Hashable, CaseIterable {
    case blackOut, allow
}

public enum RuleKind: String, Codable, Sendable, Hashable, CaseIterable {
    case exactText, prefix, label, example, regex
}

/// A redaction style row. `id` is nil until stored.
public struct StyleRecord: Codable, Sendable, Hashable {
    public var id: Int64?
    public var kind: StyleKind
    /// "r,g,b,a", each 0...1.
    public var color: String
    public var roundness: Double
    public var padding: Double
    public var labelMode: LabelMode
    public var isDefault: Bool

    public init(id: Int64? = nil, kind: StyleKind = .solid, color: String = "0,0,0,1", roundness: Double = 0.07,
                padding: Double = 0.14, labelMode: LabelMode = .none, isDefault: Bool = false) {
        self.id = id; self.kind = kind; self.color = color; self.roundness = roundness
        self.padding = padding; self.labelMode = labelMode; self.isDefault = isDefault
    }

    /// Obscura's built-in default: solid black, slightly rounded.
    public static let builtInDefault = StyleRecord(isDefault: true)

    enum CodingKeys: String, CodingKey {
        case id, kind, color = "color_rgba", roundness, padding, labelMode = "label_mode", isDefault = "is_default"
    }

    /// Equality that ignores the row id, for conflict detection.
    public func sameAppearance(as other: StyleRecord) -> Bool {
        kind == other.kind && color == other.color && roundness == other.roundness
            && padding == other.padding && labelMode == other.labelMode
    }
}

/// A finding to store with a new entry or a re-render. Text is never part of it.
public struct NewFinding: Codable, Sendable, Hashable {
    public var lineIndex: Int
    /// Image pixels, top-left origin.
    public var rect: CGRect
    /// First id is the display label.
    public var detectorIDs: [String]
    public var category: String
    public var enabled: Bool

    public init(lineIndex: Int, rect: CGRect, detectorIDs: [String], category: String, enabled: Bool = true) {
        self.lineIndex = lineIndex; self.rect = rect; self.detectorIDs = detectorIDs
        self.category = category; self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case lineIndex = "line_index", rect, detectorIDs = "detector_ids", category, enabled
    }
}

public struct Finding: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let entryID: UUID
    public var lineIndex: Int
    public var rect: CGRect
    public var detectorIDs: [String]
    public var category: String
    public var enabled: Bool

    public init(id: UUID, entryID: UUID, lineIndex: Int, rect: CGRect, detectorIDs: [String], category: String, enabled: Bool) {
        self.id = id; self.entryID = entryID; self.lineIndex = lineIndex; self.rect = rect
        self.detectorIDs = detectorIDs; self.category = category; self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case id, entryID = "entry_id", lineIndex = "line_index", rect, detectorIDs = "detector_ids", category, enabled
    }
}

/// What the engine hands the store when an image was caught.
public struct NewEntry: Codable, Sendable, Hashable {
    public var source: EntrySource
    public var displayName: String
    public var filePath: String?
    public var cleanCopyPath: String?
    /// public.png, public.jpeg or public.heic — decides the on-disk extension.
    public var containerUTI: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var findings: [NewFinding]
    /// nil → the store's default style.
    public var style: StyleRecord?

    public init(source: EntrySource, displayName: String, filePath: String? = nil, cleanCopyPath: String? = nil,
                containerUTI: String, pixelWidth: Int, pixelHeight: Int, findings: [NewFinding], style: StyleRecord? = nil) {
        self.source = source; self.displayName = displayName; self.filePath = filePath; self.cleanCopyPath = cleanCopyPath
        self.containerUTI = containerUTI; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.findings = findings; self.style = style
    }

    enum CodingKeys: String, CodingKey {
        case source, displayName = "display_name", filePath = "file_path", cleanCopyPath = "clean_copy_path"
        case containerUTI = "container_uti", pixelWidth = "pixel_width", pixelHeight = "pixel_height", findings, style
    }
}

/// A stored entry with its findings and style.
public struct Entry: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let source: EntrySource
    public let displayName: String
    public let filePath: String?
    public let cleanCopyPath: String?
    public let containerUTI: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let revision: Int
    public let style: StyleRecord
    public let trashedAt: Date?
    public let findings: [Finding]

    public var isTrashed: Bool { trashedAt != nil }
    public var enabledFindings: [Finding] { findings.filter(\.enabled) }

    public init(id: UUID, createdAt: Date, source: EntrySource, displayName: String, filePath: String?, cleanCopyPath: String?,
                containerUTI: String, pixelWidth: Int, pixelHeight: Int, revision: Int, style: StyleRecord, trashedAt: Date?, findings: [Finding]) {
        self.id = id; self.createdAt = createdAt; self.source = source; self.displayName = displayName
        self.filePath = filePath; self.cleanCopyPath = cleanCopyPath; self.containerUTI = containerUTI
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.revision = revision
        self.style = style; self.trashedAt = trashedAt; self.findings = findings
    }

    enum CodingKeys: String, CodingKey {
        case id, createdAt = "created_at", source, displayName = "display_name", filePath = "file_path"
        case cleanCopyPath = "clean_copy_path", containerUTI = "container_uti", pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height", revision, style, trashedAt = "trashed_at", findings
    }
}

/// An entry and its clean picture read in one Journal turn (G-28): the bytes show exactly the findings `entry` says are
/// covered, at `entry.revision`. Whoever shows or shares the clean picture reads it this way, never the entry and the
/// bytes in two calls (fail-open #14).
public struct CleanImage: Sendable, Hashable {
    public let entry: Entry
    public let data: Data

    public init(entry: Entry, data: Data) { self.entry = entry; self.data = data }

    /// Every finding is covered in these bytes.
    public var coversEverything: Bool { !entry.findings.isEmpty && entry.findings.allSatisfy(\.enabled) }
}

/// Filter for `entries(matching:)`. Results are newest first.
public struct EntryQuery: Codable, Sendable, Hashable {
    /// false (default) = live entries only; true = trash only; nil = both.
    public var trashed: Bool?
    /// Case-insensitive substring of display_name.
    public var search: String?
    /// created_at >= from
    public var from: Date?
    /// created_at < to
    public var to: Date?
    public var limit: Int?
    public var offset: Int

    public init(trashed: Bool? = false, search: String? = nil, from: Date? = nil, to: Date? = nil, limit: Int? = nil, offset: Int = 0) {
        self.trashed = trashed; self.search = search; self.from = from; self.to = to; self.limit = limit; self.offset = offset
    }

    public static let live = EntryQuery()
    public static let trash = EntryQuery(trashed: true)
    public static let all = EntryQuery(trashed: nil)
}

/// A user rule (custom black-out or allow).
public struct RuleRecord: Codable, Sendable, Hashable, Identifiable {
    /// "custom.<UUID>"
    public var id: String
    public var action: RuleAction
    public var kind: RuleKind
    /// What the user typed. Plain in memory and in an export file the user saves; sealed in the Journal (G-30).
    public var value: String
    public var tokenLength: Int?
    public var name: String?
    public var enabled: Bool
    public var createdAt: Date
    public var sortOrder: Int

    public init(id: String = "custom." + UUID().uuidString, action: RuleAction, kind: RuleKind, value: String, tokenLength: Int? = nil,
                name: String? = nil, enabled: Bool = true, createdAt: Date, sortOrder: Int) {
        self.id = id; self.action = action; self.kind = kind; self.value = value; self.tokenLength = tokenLength
        self.name = name; self.enabled = enabled; self.createdAt = createdAt; self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case id, action, kind, value, tokenLength = "token_length", name, enabled, createdAt = "created_at", sortOrder = "sort_order"
    }
}

/// A replaced pattern list for one built-in detector. `specsJSON` is the JSON array of PatternSpec, kept opaque here.
public struct OverrideRecord: Codable, Sendable, Hashable, Identifiable {
    public var detectorID: String
    public var specsJSON: String
    public var updatedAt: Date
    public var id: String { detectorID }

    public init(detectorID: String, specsJSON: String, updatedAt: Date) {
        self.detectorID = detectorID; self.specsJSON = specsJSON; self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case detectorID = "detector_id", specsJSON = "specs_json", updatedAt = "updated_at" }
}

/// One local day of counters.
public struct DayStats: Codable, Sendable, Hashable, Identifiable {
    /// "YYYY-MM-DD" in the local calendar.
    public var day: String
    public var checked: Int
    public var caught: Int
    public var secrets: Int
    public var skipped: [String: Int]
    public var categories: [String: Int]
    public var id: String { day }

    public init(day: String, checked: Int = 0, caught: Int = 0, secrets: Int = 0, skipped: [String: Int] = [:], categories: [String: Int] = [:]) {
        self.day = day; self.checked = checked; self.caught = caught; self.secrets = secrets; self.skipped = skipped; self.categories = categories
    }
}

/// Something to count. An image that reaches a verdict is exactly one `clean` or one `caught`, and both count as
/// checked: a day's `checked` is every image checked and `caught` the ones of them with findings, so caught ≤ checked.
public enum StatEvent: Sendable, Hashable {
    /// An image was checked and nothing was found.
    case clean
    /// An image was checked and had findings: `secrets` of them, bucketed by category. Counts as checked too.
    case caught(secrets: Int, categories: [String: Int])
    /// An image was skipped (reason is a short identifier like "ocrTimeout", never text from the image).
    case skipped(reason: String)
}

/// The document `exportRules()` writes and `importRules(_:)` reads.
public struct RulesDocument: Codable, Sendable, Hashable {
    public static let currentFormat = 1
    public var formatVersion: Int
    public var exportedAt: Date
    public var rules: [RuleRecord]
    public var detectorOverrides: [OverrideRecord]
    public var detectorState: [String: Bool]
    public var defaultStyle: StyleRecord

    public init(formatVersion: Int = RulesDocument.currentFormat, exportedAt: Date, rules: [RuleRecord], detectorOverrides: [OverrideRecord],
                detectorState: [String: Bool], defaultStyle: StyleRecord) {
        self.formatVersion = formatVersion; self.exportedAt = exportedAt; self.rules = rules
        self.detectorOverrides = detectorOverrides; self.detectorState = detectorState; self.defaultStyle = defaultStyle
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version", exportedAt = "exported_at", rules, detectorOverrides = "detector_overrides"
        case detectorState = "detector_state", defaultStyle = "default_style"
    }
}

/// What to do when an imported item's id already exists with different content.
public enum ImportConflictPolicy: String, Codable, Sendable, Hashable {
    /// The imported value replaces the stored one (default: the user chose the file).
    case preferIncoming
    /// The stored value stays; the conflict is only reported.
    case keepExisting
}

/// What an import did. Every id in the document lands in exactly one bucket.
public struct ImportReport: Codable, Sendable, Hashable {
    public enum Conflict: Codable, Sendable, Hashable {
        case rule(id: String, existing: RuleRecord, incoming: RuleRecord)
        case override(detectorID: String, existing: OverrideRecord, incoming: OverrideRecord)
        case detectorState(detectorID: String, existing: Bool, incoming: Bool)
        case defaultStyle(existing: StyleRecord, incoming: StyleRecord)
    }

    public var rulesAdded: [String] = []
    public var rulesUnchanged: [String] = []
    /// Rules stored here whose value could not be read on this Mac (G-30), restored from the file's value whatever the
    /// policy: an unreadable value has nothing to keep.
    public var rulesRecovered: [String] = []
    public var overridesAdded: [String] = []
    public var overridesUnchanged: [String] = []
    public var statesAdded: [String] = []
    public var statesUnchanged: [String] = []
    public var defaultStyleChanged: Bool = false
    /// Ids that existed with different content, and both versions; `policy` says which one is now stored.
    public var conflicts: [Conflict] = []
    public var policy: ImportConflictPolicy
    /// Items of the file that were not stored, and why (`RulesImportValidation`, security scan F16/F22).
    public var rejected: [Rejection] = []

    /// One item of a rules file refused on import.
    public struct Rejection: Codable, Sendable, Hashable {
        public enum Item: String, Codable, Sendable, Hashable { case rule, override, detectorState = "detector_state" }
        public enum Reason: String, Codable, Sendable, Hashable {
            /// Not `custom.<UUID>` (a rule), or not a built-in detector id's ASCII shape (an override or a state).
            case badID = "bad_id"
            /// Another item of the file already has this id (after canonical spelling); the first one is kept.
            case duplicate
            /// Empty, or longer than `RulesImportValidation.maxValueLength`.
            case valueLength = "value_length"
            case nameLength = "name_length"
            case tokenLength = "token_length"
        }
        public let item: Item
        /// The id as the file wrote it, or its canonical spelling for a duplicate. Never a rule's value.
        public let id: String
        public let reason: Reason

        public init(item: Item, id: String, reason: Reason) { self.item = item; self.id = id; self.reason = reason }
    }

    public init(policy: ImportConflictPolicy) { self.policy = policy }

    enum CodingKeys: String, CodingKey {
        case rulesAdded = "rules_added", rulesUnchanged = "rules_unchanged", rulesRecovered = "rules_recovered", overridesAdded = "overrides_added"
        case overridesUnchanged = "overrides_unchanged", statesAdded = "states_added", statesUnchanged = "states_unchanged"
        case defaultStyleChanged = "default_style_changed", conflicts, policy, rejected
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rulesAdded = try c.decode([String].self, forKey: .rulesAdded)
        rulesUnchanged = try c.decode([String].self, forKey: .rulesUnchanged)
        rulesRecovered = try c.decodeIfPresent([String].self, forKey: .rulesRecovered) ?? []
        overridesAdded = try c.decode([String].self, forKey: .overridesAdded)
        overridesUnchanged = try c.decode([String].self, forKey: .overridesUnchanged)
        statesAdded = try c.decode([String].self, forKey: .statesAdded)
        statesUnchanged = try c.decode([String].self, forKey: .statesUnchanged)
        defaultStyleChanged = try c.decode(Bool.self, forKey: .defaultStyleChanged)
        conflicts = try c.decode([Conflict].self, forKey: .conflicts)
        policy = try c.decode(ImportConflictPolicy.self, forKey: .policy)
        rejected = try c.decodeIfPresent([Rejection].self, forKey: .rejected) ?? []
    }
}

// MARK: - Not checked (G-13)

/// Why a file was left without a verdict. Only outcomes a later check can change are listed (the engine's retryable
/// ones); the raw values are the engine's stat labels.
public enum UncheckedReason: String, Codable, Sendable, Hashable, CaseIterable {
    case ocrTimeout, ocrFailed, queueFull, renderFailed, encodeFailed, journalFailed, catalogueFailed
    /// Schema 4 (fail-open #2): the picture itself could not be opened. `decodeFailed`: the bytes do not decode;
    /// `unsupportedImage`: a real image container Obscura does not read; `unreadable`: the file could not be read
    /// (permission, I/O, an iCloud file not downloaded, vanished); `tooLarge`: over the size Obscura reads.
    case decodeFailed, unsupportedImage, unreadable, tooLarge
    /// Schema 4 (fail-open #5): the file stops before its container says it ends (still being written, or cut short).
    case incomplete
    /// Schema 4 (fail-open #6): a picture with several frames that could not be covered frame by frame.
    case multiFrame
    /// Schema 4 (fail-open #21): it arrived while protection was paused.
    case protectionPaused
    /// Schema 10 (G-40): every unread part of the picture is a small spot that looks like text to Vision's rectangle
    /// detector but that no reading could read (Vision answered every call, with no text). Not a failure: the spots are
    /// kept with the row (`UncheckedRecord.spots`) for the person to settle.
    case unreadPatch
    /// Schema 10 (G-40, true wording): part of the picture looks like text to Vision's rectangle detector and no reading
    /// could read it, outside the small-spot case (large, beside read text, or planned for another reason). Vision
    /// answered every call, so it is not `ocrFailed`; the picture keeps its alarm.
    case textNotRead
}

/// G-40: where one unread spot stands.
public enum SpotState: String, Codable, Sendable, Hashable, CaseIterable {
    /// Waiting for the person (listed under Not checked).
    case pending
    /// The person looked and said it is not text: checked by the person, never by Obscura.
    case notText
    /// Covered: by "Cover it", or when found with "Cover spots Obscura can't read" on. `entryID` and `findingID` name
    /// the cover.
    case covered
    /// "Skip spots too small to hold a secret" was on and the spot could not hold the shortest secret the enabled
    /// detectors and rules report: skipped, and recorded as such.
    case tooSmall

    /// Every state but `pending` settles the spot.
    public var isSettled: Bool { self != .pending }
}

/// G-40: one spot of an `unreadPatch` row. Geometry and ids only: there is no text for a spot (nothing read it).
public struct SpotRecord: Codable, Sendable, Hashable {
    /// What Vision's rectangle detector flagged; the viewer outlines it. Image pixels, top-left origin.
    public var rect: CGRect
    /// The cover "Cover it" draws: the re-read band plus at least a line height on every side, clamped to the picture.
    public var coverRect: CGRect
    public var state: SpotState
    /// The Journal entry the picture is in (for `covered`: the entry that covers it).
    public var entryID: UUID?
    /// For `covered`: the finding in `entryID` that is this spot's cover.
    public var findingID: UUID?

    public init(rect: CGRect, coverRect: CGRect, state: SpotState, entryID: UUID? = nil, findingID: UUID? = nil) {
        self.rect = rect; self.coverRect = coverRect; self.state = state; self.entryID = entryID; self.findingID = findingID
    }

    enum CodingKeys: String, CodingKey {
        case rect, coverRect = "cover_rect", state, entryID = "entry_id", findingID = "finding_id"
    }

    /// The detector id of a cover drawn over an unreadable spot, as it is stored among an entry's findings. Never a
    /// detector of the catalogue (whose ids are `<category>.<vendor>.<kind>`; none starts `obscura.`), so a spot's cover
    /// is never counted, named or read back as a secret.
    public static let coverDetectorID = "obscura.spot.unread"
    /// The category of such a cover.
    public static let coverCategory = "unread"
    /// The words such a cover shows when covers name their kind, and its kind in Spotlight.
    public static let coverTitle = "Unreadable spot"

    /// Whether a finding with these detector ids is a spot's cover.
    public static func isCoverDetector(_ detectorIDs: [String]) -> Bool { detectorIDs.first == coverDetectorID }
}

public extension Finding {
    /// G-40: this finding is the cover of a spot Obscura could not read, not a secret it found.
    var isSpotCover: Bool { detectorIDs.first == SpotRecord.coverDetectorID }
}

public extension Entry {
    /// The findings that are secrets Obscura read (every finding but the covers of unreadable spots, G-40).
    var secretFindings: [Finding] { findings.filter { !$0.isSpotCover } }
    /// G-40: the covers of spots Obscura could not read.
    var spotCovers: [Finding] { findings.filter(\.isSpotCover) }
}

/// Where an unchecked file came from, so "Check Again" re-submits it exactly as it first came in.
public enum UncheckedOrigin: Codable, Sendable, Hashable {
    case screenshotFolder
    case downloads
    /// An extra watched folder, by its path.
    case watched(folder: String)
    case imported
}

/// A file Obscura could not check: a path and when, never an image copy (the file was never read to the end) and never
/// recognized text.
public struct UncheckedRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    /// The file's resolved path; one record per path.
    public let filePath: String
    public let origin: UncheckedOrigin
    /// Why the latest attempt left it without a verdict.
    public let reason: UncheckedReason
    public let firstSeen: Date
    public let lastSeen: Date
    /// How many checks of it ended without a verdict (1 for the first).
    public let attempts: Int
    /// G-40 (schema 10): an `unreadPatch` row's spots, in the order the engine found them; empty for every other reason.
    public let spots: [SpotRecord]
    /// G-40: when every spot was settled (Not text, covered, or skipped as too small). A settled row is no longer listed
    /// under Not checked; it is kept as the record of how the picture was settled. Nil while listed.
    public let settledAt: Date?

    public init(id: UUID, filePath: String, origin: UncheckedOrigin, reason: UncheckedReason, firstSeen: Date, lastSeen: Date, attempts: Int,
                spots: [SpotRecord] = [], settledAt: Date? = nil) {
        self.id = id; self.filePath = filePath; self.origin = origin; self.reason = reason
        self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.attempts = attempts
        self.spots = spots; self.settledAt = settledAt
    }

    /// The spots still waiting for the person.
    public var pendingSpots: [SpotRecord] { spots.filter { $0.state == .pending } }

    enum CodingKeys: String, CodingKey {
        case id, filePath = "file_path", origin, reason, firstSeen = "first_seen", lastSeen = "last_seen", attempts, spots,
             settledAt = "settled_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        filePath = try c.decode(String.self, forKey: .filePath)
        origin = try c.decode(UncheckedOrigin.self, forKey: .origin)
        reason = try c.decode(UncheckedReason.self, forKey: .reason)
        firstSeen = try c.decode(Date.self, forKey: .firstSeen)
        lastSeen = try c.decode(Date.self, forKey: .lastSeen)
        attempts = try c.decode(Int.self, forKey: .attempts)
        spots = try c.decodeIfPresent([SpotRecord].self, forKey: .spots) ?? []
        settledAt = try c.decodeIfPresent(Date.self, forKey: .settledAt)
    }
}

/// A file on disk that Obscura covered, as the search labels see it (G-24): where it is, which detectors' findings are
/// covered in it now, and which Finder tags Obscura added to it. It outlives the Journal entry it was caught as (the
/// entry expires with retention; the covered file stays), and goes when the file is gone, in the Trash, or caught again.
/// Labels only: no recognized text, no hash of it.
public struct CoveredFileRecord: Codable, Sendable, Hashable, Identifiable {
    /// The Journal entry the file was caught as; also the Spotlight item's identifier.
    public var id: UUID
    public var filePath: String
    /// A bookmark of the file (follows a move or rename); nil when the system would not make one.
    public var bookmark: Data?
    /// The detectors of the findings covered now, in finding order, without repeats.
    public var detectorIDs: [String]
    public var categories: [String]
    public var isScreenshot: Bool
    /// False while Undo shows the original: the record stays for Redo, with no Spotlight item and no tags.
    public var covered: Bool
    public var caughtAt: Date
    public var updatedAt: Date
    /// The Finder tags Obscura added; removing Obscura's tags removes exactly these, never one the person set.
    public var tagsWritten: [String]

    public init(id: UUID, filePath: String, bookmark: Data?, detectorIDs: [String], categories: [String], isScreenshot: Bool,
                covered: Bool = true, caughtAt: Date, updatedAt: Date, tagsWritten: [String] = []) {
        self.id = id; self.filePath = filePath; self.bookmark = bookmark; self.detectorIDs = detectorIDs
        self.categories = categories; self.isScreenshot = isScreenshot; self.covered = covered
        self.caughtAt = caughtAt; self.updatedAt = updatedAt; self.tagsWritten = tagsWritten
    }

    public var fileURL: URL { URL(fileURLWithPath: filePath) }

    enum CodingKeys: String, CodingKey {
        case id, filePath = "file_path", bookmark, detectorIDs = "detector_ids", categories, isScreenshot = "is_screenshot",
             covered, caughtAt = "caught_at", updatedAt = "updated_at", tagsWritten = "tags_written"
    }
}

// MARK: - Not covered on disk (fail-open #7)

/// A file on disk that still shows what Obscura caught: the covered picture could not be written there. Kept until a
/// write there succeeds, a later check of the caught file reaches a verdict, the catch is undone on purpose, or the
/// user dismisses it; it outlives the Journal entry (retention removes the entry, not the secret in the file). Paths
/// only: never an image and never recognized text.
public struct UncoveredRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    /// Where the covered picture belongs: the caught file (replace) or its "(clean)" copy (keep both). One row per path.
    public let filePath: String
    /// The caught file itself; the same as `filePath` unless the clean copy is kept beside it.
    public let sourcePath: String
    /// The entry whose covered picture belongs at `filePath`; nil when none was recorded. It may name an entry that has
    /// since gone (retention), in which case the fix is to check the caught file again.
    public let entryID: UUID?
    public let firstSeen: Date
    public let lastSeen: Date
    /// How many writes there failed (1 for the first).
    public let attempts: Int

    public init(id: UUID, filePath: String, sourcePath: String, entryID: UUID?, firstSeen: Date, lastSeen: Date, attempts: Int) {
        self.id = id; self.filePath = filePath; self.sourcePath = sourcePath; self.entryID = entryID
        self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.attempts = attempts
    }

    /// The covered picture belongs in a "(clean)" copy beside the caught file, not in the caught file itself.
    public var isCleanCopy: Bool { filePath != sourcePath }

    enum CodingKeys: String, CodingKey {
        case id, filePath = "file_path", sourcePath = "source_path", entryID = "entry_id", firstSeen = "first_seen",
             lastSeen = "last_seen", attempts
    }
}
