// ObscuraEngine — what the menu bar panel reads (ARCHITECTURE.md §3 "AppState", §7).
public import Foundation
public import ObscuraCapture
public import ObscuraJournal

/// A condition the user should know about. `messageKey` is a localization key; the app resolves it.
public struct Problem: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// A folder we should watch cannot be listed (TCC revoked or folder gone).
        case folderAccess
        /// A user rule or override did not compile, or rules' values cannot be read on this Mac (G-30, `detail` is how
        /// many); the rule is skipped and protection is Partly protected.
        case ruleCompile
        /// A capture source refused to start.
        case sourceStart
        /// Recent scans failed (render/encode/journal/write-back).
        case scanFailure
        /// The OCR warm-up did not complete; the first real scan may be slow.
        case ocrWarmup
        /// Files on disk still show what Obscura caught: the covered picture could not be written there (fail-open #7).
        /// `detail` is how many. Kept until a write succeeds, so protection is never green while one exists.
        case notCovered
        /// The Journal's upkeep (retention, the stale sweep, the orphan sweep) could not finish: originals may be kept
        /// longer than the retention the app promises (fail-open #11). `detail` names the steps. Cleared by the next
        /// tick that finishes.
        case journalMaintenance
        /// G-40: spots no reading could read wait for the person (`detail` is how many; `url` the newest file that holds
        /// one). Quiet: never an alarm, never "needs attention"; listed so the person can settle them in the viewer.
        case unreadSpots
    }

    public var kind: Kind
    public var messageKey: String
    /// The folder or file involved, when there is one.
    public var url: URL?
    /// Rule id, detector id or reason string, when there is one. Never recognized text.
    public var detail: String?

    public var id: String { "\(kind.rawValue)|\(url?.path ?? "")|\(detail ?? "")" }

    public init(kind: Kind, messageKey: String, url: URL? = nil, detail: String? = nil) {
        self.kind = kind
        self.messageKey = messageKey
        self.url = url
        self.detail = detail
    }
}

/// The last image that had findings, for the panel's "Last catch" row.
public struct LastCatch: Sendable, Hashable {
    public var entryID: UUID
    public var displayName: String
    public var findings: Int
    public var date: Date

    public init(entryID: UUID, displayName: String, findings: Int, date: Date) {
        self.entryID = entryID
        self.displayName = displayName
        self.findings = findings
        self.date = date
    }
}

public enum ProtectionState: Sendable, Hashable {
    case protected
    /// Running, but some watched folder or source is not covered. `reasons` are localization keys.
    case partlyProtected(reasons: [String])
    case paused
    case needsAttention(problems: [Problem])
}

public struct EngineStatus: Sendable, Hashable {
    public var protection: ProtectionState
    /// Scans currently running or waiting (one per image).
    public var inFlight: Int
    /// OCR queue depth (running + waiting). The panel shows "Checking N images…" from this.
    public var queueDepth: Int
    public var lastCatch: LastCatch?
    /// Today and the six days before, oldest first.
    public var weekStats: [DayStats]
    public var problems: [Problem]
    /// Milliseconds the OCR warm-up took; nil until it completes.
    public var warmupMilliseconds: Int?
    /// Files left without a verdict, most recently seen first: the Journal's persisted "Not checked" list (G-13), so it
    /// survives a relaunch and never ages out. Each can be checked again with `ShieldEngine.retry(_:)`; one leaves this
    /// list when a later check of it reaches a verdict or the user dismisses it (`ShieldEngine.dismissUnchecked(_:)`).
    public var unchecked: [UncheckedFile]
    /// Files on disk that still show what Obscura caught because the covered picture could not be written there, most
    /// recently seen first: the Journal's persisted list (fail-open #7). Each leaves when a write there succeeds
    /// (`ShieldEngine.retryUncovered(_:)`), a later check of the caught file reaches a verdict, the catch is undone, or
    /// the user dismisses it.
    public var uncovered: [UncoveredFile]

    public init(protection: ProtectionState = .protected, inFlight: Int = 0, queueDepth: Int = 0, lastCatch: LastCatch? = nil,
                weekStats: [DayStats] = [], problems: [Problem] = [], warmupMilliseconds: Int? = nil, unchecked: [UncheckedFile] = [],
                uncovered: [UncoveredFile] = []) {
        self.protection = protection
        self.inFlight = inFlight
        self.queueDepth = queueDepth
        self.lastCatch = lastCatch
        self.weekStats = weekStats
        self.problems = problems
        self.warmupMilliseconds = warmupMilliseconds
        self.unchecked = unchecked
        self.uncovered = uncovered
    }
}

/// A file on disk that still shows what Obscura caught (fail-open #7): the engine's view of one row of the Journal's
/// `uncovered_files` table.
public struct UncoveredFile: Sendable, Hashable, Identifiable {
    public let record: UncoveredRecord

    public init(_ record: UncoveredRecord) { self.record = record }

    public var id: UUID { record.id }
    /// The file that should hold the covered picture (the caught file, or its "(clean)" copy).
    public var fileURL: URL { URL(fileURLWithPath: record.filePath) }
    /// The caught file itself.
    public var sourceURL: URL { URL(fileURLWithPath: record.sourcePath) }
    public var displayName: String { fileURL.lastPathComponent }
    public var entryID: UUID? { record.entryID }
    public var date: Date { record.lastSeen }
    public var attempts: Int { record.attempts }
    /// The covered picture belongs in a "(clean)" copy beside the caught file; the caught file is the original by choice.
    public var isCleanCopy: Bool { record.isCleanCopy }
}

/// What `ShieldEngine.retryUncovered(_:)` did.
public enum UncoveredRetry: Sendable, Hashable {
    /// The covered picture is in the file now; the row is gone.
    case written
    /// The entry is gone (retention), so the caught file was sent to be checked again; its verdict settles the row.
    case checkingAgain
    /// The write failed again; the row stays with one more attempt.
    case failed
    /// The caught file is gone, so there is nothing to cover; the row stays until dismissed.
    case fileMissing
    /// The entry is gone and no watched folder holds the caught file any more, so a check would not write it; the row
    /// stays.
    case notWatched
}

/// A file the pipeline left without a verdict (OCR timed out or failed, the queue stayed full, or a stage threw before
/// the clean copy existed), kept with everything "Check Again" needs to re-submit it as it first came in. It mirrors one
/// row of the Journal's `unchecked` table (`UncheckedRecord`).
public struct UncheckedFile: Sendable, Hashable, Identifiable {
    /// The Journal row's id.
    public let id: UUID
    public let key: CaptureKey
    public let displayName: String
    public let fileURL: URL
    public let origin: FileOrigin
    /// The outcome's stat label (`ocrTimeout`, `renderFailed`, …), an `UncheckedReason` raw value. Never image content.
    public let reason: String
    /// When the latest check of it ended without a verdict.
    public let date: Date
    /// When the first one did.
    public let firstSeen: Date
    /// How many checks of it ended without a verdict.
    public let attempts: Int
    /// G-40: an `unreadPatch` file's spots no reading could read, each with how it stands; empty for every other reason.
    public let spots: [SpotRecord]
    /// G-40: when every spot was settled; nil while the file is listed.
    public let settledAt: Date?

    public init(id: UUID = UUID(), key: CaptureKey, displayName: String, fileURL: URL, origin: FileOrigin, reason: String, date: Date,
                firstSeen: Date? = nil, attempts: Int = 1, spots: [SpotRecord] = [], settledAt: Date? = nil) {
        self.id = id
        self.key = key
        self.displayName = displayName
        self.fileURL = fileURL
        self.origin = origin
        self.reason = reason
        self.date = date
        self.firstSeen = firstSeen ?? date
        self.attempts = attempts
        self.spots = spots
        self.settledAt = settledAt
    }

    /// G-40: the file's only unread parts are spots no reading could read: it waits for the person, with no alarm.
    public var isUnreadSpots: Bool { reason == UncheckedReason.unreadPatch.rawValue }
    /// G-40: the spots still waiting for the person.
    public var pendingSpots: Int { spots.filter { $0.state == .pending }.count }

    /// The typed reason; nil only for a label the Journal does not list.
    public var uncheckedReason: UncheckedReason? { UncheckedReason(rawValue: reason) }

    /// The engine's view of a Journal row.
    public init(_ record: UncheckedRecord) {
        let url = URL(fileURLWithPath: record.filePath)
        self.init(id: record.id, key: .path(record.filePath), displayName: url.lastPathComponent, fileURL: url,
                  origin: FileOrigin(record.origin), reason: record.reason.rawValue, date: record.lastSeen,
                  firstSeen: record.firstSeen, attempts: record.attempts, spots: record.spots, settledAt: record.settledAt)
    }

    /// The Journal row this file is, for putting a dismissed one back exactly.
    public var record: UncheckedRecord? {
        guard let reason = uncheckedReason, case .path(let path) = key else { return nil }
        return UncheckedRecord(id: id, filePath: path, origin: UncheckedOrigin(origin), reason: reason, firstSeen: firstSeen,
                               lastSeen: date, attempts: attempts, spots: spots, settledAt: settledAt)
    }
}

public extension FileOrigin {
    /// The capture origin of a Journal "Not checked" row.
    init(_ origin: UncheckedOrigin) {
        switch origin {
        case .screenshotFolder: self = .screenshotFolder
        case .downloads: self = .downloads
        case .watched(let folder): self = .watched(URL(fileURLWithPath: folder, isDirectory: true))
        case .imported: self = .imported
        }
    }
}

public extension UncheckedOrigin {
    /// How the Journal stores a capture origin.
    init(_ origin: FileOrigin) {
        switch origin {
        case .screenshotFolder: self = .screenshotFolder
        case .downloads: self = .downloads
        case .watched(let url): self = .watched(folder: url.standardizedFileURL.path)
        case .imported: self = .imported
        }
    }
}
