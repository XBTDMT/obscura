// Fail-open #1: how much of a planned G-12 re-read was actually read. A band the re-read could not read (the deadline
// left too little time, its sheet timed out or failed, Vision returned no text for a strip at every scale, or its tiles
// stitched to nothing) must never let the image pass as checked: its lines are covered conservatively (G-22's rule) and
// the engine lists the image "not checked". Counts and reasons only; no text.
//
// G-32: before a band with no text at all is left unread, it gets one bounded last attempt (`LastAttempt`): the band
// cropped full-width at 1× with the accurate level, then, only if that read nothing, the same crop at Vision's `.fast`
// level. Which attempt read the band (or that none did, or that the deadline left no time) is recorded here for the logs
// and the image suite; counts and ids only.
public import CoreGraphics

public struct ReadCompleteness: Sendable, Hashable {
    /// Why a strip of a band has no reading.
    public enum Gap: String, Sendable, Hashable, CaseIterable, Comparable {
        /// Too little of the image's deadline was left to request the strip's sheet.
        case deadline
        /// The strip's sheet request timed out.
        case timeout
        /// Drawing or reading the strip's sheet failed.
        case failed
        /// Vision returned no text for the strip at every scale tried, or the strips stitched to no text.
        case empty
        /// The strip is larger than a re-read sheet may be at every scale tried (`RereadSheet.layout`), so it was never
        /// drawn: a band of text that tall is not checked rather than read from a multi-gigabyte bitmap (security F13).
        case oversize

        /// True when the gap is a matter of time: the image ran out of its OCR deadline.
        public var isTime: Bool { self == .deadline || self == .timeout }

        public static func < (a: Gap, b: Gap) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    /// One band that was not completely read.
    public struct Band: Sendable, Hashable {
        /// The band's position in the plan.
        public let band: Int
        public let reasons: Set<RereadReason>
        /// Strips (tiles) planned for the band, and how many of them have a reading.
        public let strips: Int
        public let readStrips: Int
        /// Why its unread strips have none.
        public let gaps: Set<Gap>
        /// True when pass 1 read lines on the band (they are covered conservatively); false for text nobody read
        /// (route B), where nothing can be covered and only the "not checked" verdict protects the user.
        public let hasLines: Bool
        /// G-40: the band's re-read rect (full resolution, padded and clipped to the image), the text it was planned
        /// around (for a route-B band: the detector's region(s) nobody read, before padding), and its line height.
        /// Geometry only: where the unread part is, never what it holds.
        public let rect: CGRect
        public let core: CGRect
        public let lineHeight: CGFloat

        public init(band: Int, reasons: Set<RereadReason>, strips: Int, readStrips: Int, gaps: Set<Gap>, hasLines: Bool,
                    rect: CGRect = .null, core: CGRect = .null, lineHeight: CGFloat = 0) {
            self.band = band
            self.reasons = reasons
            self.strips = strips
            self.readStrips = readStrips
            self.gaps = gaps
            self.hasLines = hasLines
            self.rect = rect
            self.core = core
            self.lineHeight = lineHeight
        }
    }

    /// Bands the plan asked to re-read, and how many were read completely, in all and per reason.
    public var planned = 0
    public var read = 0
    public var plannedByReason: [RereadReason: Int] = [:]
    public var readByReason: [RereadReason: Int] = [:]
    /// The bands not completely read, in plan order.
    public var incomplete: [Band] = []
    /// G-32: every band that reached the last attempt (no re-read could read it), in plan order, read or not.
    public var lastAttempts: [LastAttempt] = []

    /// G-32: the reading that read a band the re-read could not.
    public enum LastReader: String, Sendable, Hashable, CaseIterable {
        /// The band cropped at the image's full width, scale 1, accurate level, pass 1's languages (G-31).
        case fullWidth
        /// The same crop at Vision's `.fast` recognition level: a weaker model, so its line is also covered
        /// conservatively (G-22's rule, `ShortRead.Cause.fast`).
        case fast
    }

    /// G-32: one band's last attempt. At most two recognition calls (`calls`), each only when the image's deadline
    /// leaves `RecallTuning.minimumRereadBudget`; never a longer timeout.
    public struct LastAttempt: Sendable, Hashable {
        /// The band's position in the plan.
        public let band: Int
        /// Recognition calls made for it (0, 1 or 2).
        public let calls: Int
        /// The attempt that read it; nil when it is still unread (it then stays in `incomplete`, unchanged).
        public let readBy: LastReader?
        /// True when an attempt was not made because too little of the deadline was left.
        public let skippedForDeadline: Bool
        /// G-40: the calls Vision answered (returned, with or without text); a call that timed out or failed is not
        /// answered. Only a band whose every call was answered with no text is "a spot no reading can read".
        public let answered: Int

        public init(band: Int, calls: Int, readBy: LastReader?, skippedForDeadline: Bool, answered: Int? = nil) {
            self.band = band
            self.calls = calls
            self.readBy = readBy
            self.skippedForDeadline = skippedForDeadline
            self.answered = answered ?? calls
        }
    }

    /// G-32: bands the last attempt read with `reader`.
    public func readByLastAttempt(_ reader: LastReader) -> Int { lastAttempts.filter { $0.readBy == reader }.count }

    public init() {}

    /// Every planned band was read (also true when nothing was planned).
    public var isComplete: Bool { incomplete.isEmpty }

    /// True when every gap is a matter of time (the deadline or a sheet's timeout): the image "timed out" rather than
    /// "failed to read". Nil when complete.
    public var timedOut: Bool? {
        guard !isComplete else { return nil }
        let gaps = incomplete.flatMap(\.gaps)
        return !gaps.isEmpty && gaps.allSatisfy(\.isTime)
    }

    /// Records one planned band.
    mutating func plan(_ reasons: Set<RereadReason>) {
        planned += 1
        for reason in reasons { plannedByReason[reason, default: 0] += 1 }
    }

    /// Records a planned band read completely.
    mutating func complete(_ reasons: Set<RereadReason>) {
        read += 1
        for reason in reasons { readByReason[reason, default: 0] += 1 }
    }
}
