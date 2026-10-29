// ObscuraEngine — G-40: a small spot that looks like text to Vision's rectangle detector but that no reading can read.
//
// The ruling (knowledge/decisions/G-40-text-like-patch-not-checked.md, 2026-10-28):
// - C (default): when EVERY unread part of a picture is such a spot, the picture is not called "couldn't be read" (Vision
//   did not fail: it answered every call with no text). It is listed under Not checked with its own reason
//   (`SkipReason.unreadPatch`), no alarm, the spots' rects stored with the row, for the person to settle in the viewer:
//   Not text, or Cover it. Never clean by itself, never on the clipboard before it is settled.
// - B (opt-in, `Settings.coversUnreadableSpots`): each spot is covered, padded to its re-read band plus at least one line
//   height on every side, and the entry says how many unreadable spots were covered.
// - D (opt-in, `Settings.skipsTinySpots`): a spot whose largest possible glyph count is below the shortest secret any
//   enabled detector or custom rule can report is skipped (recorded, outlined, never silent). D decides first; B covers
//   what D does not skip.
// Anything else that went unread keeps today's outcome and alarm. Geometry and counts only: no text exists for a spot.
public import CoreGraphics
import Foundation
public import ObscuraOCR
public import ObscuraJournal

/// One spot no reading could read, as the engine found it.
public struct UnreadSpot: Sendable, Hashable {
    /// The text the detector flagged (the route-B band's planned region, before padding): what the viewer outlines.
    public let rect: CGRect
    /// The cover a "Cover it" (or the B switch) draws: the re-read band's rect grown by at least one line height on every
    /// side, clamped to the picture, so a detector box that stops short of real text cannot leave the rest visible.
    public let coverRect: CGRect

    public init(rect: CGRect, coverRect: CGRect) {
        self.rect = rect
        self.coverRect = coverRect
    }

    /// The detector id, category and title of a spot's cover among an entry's findings (`SpotRecord.coverDetectorID`).
    public static var detectorID: String { SpotRecord.coverDetectorID }
    public static var category: String { SpotRecord.coverCategory }
    public static var title: String { SpotRecord.coverTitle }
}

public enum UnreadSpots {
    /// G-40: the spots together are "small" when they cover at most this fraction of the picture's area. The person's
    /// photo measured 0.032 % (one 66 × 16 px region on 2640 × 1240) and the made-up fixture 0.029 %; 1 % keeps the case
    /// to a few marks on a picture while a picture whose unread parts are large keeps today's alarm.
    public static let maxAreaFraction: CGFloat = 0.01

    /// The spots of `completeness`, or nil when the picture is not the patch case. The case holds exactly when there is
    /// something unread and EVERY unread band:
    /// - was planned for route B only (`unread`: a detector region nobody read), and has no lines (nothing pass 1 read
    ///   is on its row within an advance of it);
    /// - has no reading for a reason other than "Vision answered with no text" (its only gap is `empty`: no deadline,
    ///   no timeout, no failed or oversize sheet);
    /// - got G-32's whole last attempt (both calls made, both answered, none skipped for the deadline) and was still
    ///   not read;
    /// and the bands' regions together cover at most `maxAreaFraction` of the picture.
    public static func patchCase(_ completeness: ReadCompleteness, imageSize: CGSize) -> [UnreadSpot]? {
        guard !completeness.incomplete.isEmpty, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let bounds = CGRect(origin: .zero, size: imageSize)
        var spots: [UnreadSpot] = []
        var area: CGFloat = 0
        for band in completeness.incomplete {
            guard band.reasons == [.unread], !band.hasLines, band.gaps == [.empty], !band.core.isNull, !band.rect.isNull,
                  band.core.width > 0, band.core.height > 0,
                  let last = completeness.lastAttempts.first(where: { $0.band == band.band }),
                  last.readBy == nil, !last.skippedForDeadline,
                  last.calls == ReadCompleteness.LastReader.allCases.count, last.answered == last.calls
            else { return nil }
            area += band.core.width * band.core.height
            let margin = max(band.lineHeight, band.core.height, 1)
            let cover = band.rect.insetBy(dx: -margin, dy: -margin).intersection(bounds).integral.intersection(bounds)
            guard !cover.isNull, cover.width >= 1, cover.height >= 1 else { return nil }
            spots.append(UnreadSpot(rect: band.core, coverRect: cover))
        }
        guard area <= maxAreaFraction * bounds.width * bounds.height else { return nil }
        return spots
    }

    /// G-40 route D: the most glyphs a spot could hold, counted generously: its width over the narrowest advance any text
    /// of its height is taken to have (`RereadPlanner.narrowestAdvanceRatio`, the same lower bound the re-read planner
    /// and the cover grid use for an advance), rounded UP so a last glyph narrower than its advance still counts.
    public static func capacity(of spot: UnreadSpot) -> Int {
        let height = max(1, spot.rect.height)
        let advance = RereadPlanner.narrowestAdvanceRatio * height
        return Int((spot.rect.width / advance).rounded(.up))
    }

    /// G-40 route D: whether a spot is too small to hold any secret the enabled catalogue can report: its capacity is
    /// strictly below `shortestSecret` (`CompiledCatalogue.shortestSecretLength`). Nil (no detector enabled) or 0 (a
    /// pattern whose length cannot be bounded) never skips.
    public static func isTooSmall(_ spot: UnreadSpot, shortestSecret: Int?) -> Bool {
        guard let shortestSecret, shortestSecret > 0 else { return false }
        return capacity(of: spot) < shortestSecret
    }

    /// What the settings make of the patch case's spots: each spot's state, in order. D first (a skipped spot is
    /// `tooSmall` and is not covered), then B (`covered`), else `pending` for the person.
    public static func decide(_ spots: [UnreadSpot], skipsTiny: Bool, covers: Bool, shortestSecret: Int?) -> [SpotState] {
        spots.map { spot in
            if skipsTiny && isTooSmall(spot, shortestSecret: shortestSecret) { return .tooSmall }
            return covers ? .covered : .pending
        }
    }
}

extension UnreadSpot {
    /// The Journal's record of this spot in `state`.
    func record(state: SpotState, entryID: UUID? = nil, findingID: UUID? = nil) -> SpotRecord {
        SpotRecord(rect: rect, coverRect: coverRect, state: state, entryID: entryID, findingID: findingID)
    }
}
