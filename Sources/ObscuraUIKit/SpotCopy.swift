// G-40: the words every surface uses for a small spot Obscura could not read (the panel, the Journal, the spot viewer,
// Settings). Plain, and never an alarm: Vision answered every call, nothing failed, and the person decides. Surfaces never
// write these words themselves.
import Foundation
public import ObscuraJournal
public import ObscuraEngine

public enum SpotCopy {
    /// "1 spot couldn't be read" / "3 spots couldn't be read": the panel row's and the Journal row's title.
    public static func title(_ spots: Int) -> String {
        spots == 1 ? String(localized: "1 spot couldn't be read") : String(localized: "\(spots) spots couldn't be read")
    }

    /// What is true and what to do, for one file or several.
    public static func body(spots: Int, files: Int, name: String?) -> String {
        if files == 1, let name {
            return spots == 1 ? String(localized: "Obscura couldn't read a small spot in \(name). Check it in the viewer.")
                              : String(localized: "Obscura couldn't read \(spots) small spots in \(name). Check them in the viewer.")
        }
        if files <= 1 {
            return spots == 1 ? String(localized: "Obscura couldn't read a small spot in this picture. Check it in the viewer.")
                              : String(localized: "Obscura couldn't read \(spots) small spots in this picture. Check them in the viewer.")
        }
        return String(localized: "Obscura couldn't read small spots in \(files) images. Check them in the viewer.")
    }

    /// The Journal's reason line for an `unreadPatch` row (true: no reading failed; the spot may not be text at all).
    public static let reason = String(localized: "Obscura couldn't read a small spot in this picture. Check it in the viewer.")

    /// The viewer's lead line: what an outlined spot is.
    public static let viewerLead = String(localized: "Obscura couldn't read the outlined spot. It may be a mark, not text. Look closely before you share it.")
    public static func viewerLead(_ pending: Int) -> String {
        pending == 1 ? viewerLead
                     : String(localized: "Obscura couldn't read the \(pending) outlined spots. They may be marks, not text. Look closely before you share it.")
    }
    /// The viewer when nothing waits any more.
    public static let viewerSettled = String(localized: "Every spot in this picture is settled.")

    // MARK: Actions

    /// The person settles it: not text. Checked by the person, never by Obscura.
    public static let notText = String(localized: "Not Text")
    /// A normal cover over the spot, padded past its edges.
    public static let coverIt = String(localized: "Cover It")
    public static let review = String(localized: "Review…")
    public static let notTextHelp = String(localized: "You looked, and there's no text here: mark the picture checked by you")
    public static let coverItHelp = String(localized: "Cover the spot, a little past its edges, like any secret")

    /// The toast after an action (with Undo).
    public static func settled(_ how: ShieldEngine.SpotSettlement, spots: Int) -> String {
        switch how {
        case .notText: return spots == 1 ? String(localized: "Marked as not text") : String(localized: "\(spots) spots marked as not text")
        case .cover: return spots == 1 ? String(localized: "Spot covered") : String(localized: "\(spots) spots covered")
        }
    }
    public static let coverFailed = String(localized: "Couldn't cover the spot. The picture is as it was.")
    public static let settleFailed = String(localized: "Couldn't save that. The spot is still waiting for you.")
    public static let undoFailed = String(localized: "Couldn't undo that.")

    // MARK: States

    /// One spot's state, as the viewer and the Journal's record say it.
    public static func state(_ state: SpotState) -> String {
        switch state {
        case .pending: return String(localized: "Waiting for you")
        case .notText: return String(localized: "You said it isn't text")
        case .covered: return String(localized: "Covered")
        case .tooSmall: return String(localized: "Skipped: too small to hold a secret")
        }
    }

    /// How a settled row was settled, as one line for the Journal's record.
    public static func settledSummary(_ spots: [SpotRecord]) -> String {
        let states = Set(spots.map(\.state))
        if states == [.notText] { return String(localized: "You said it isn't text") }
        if states == [.covered] { return spots.count == 1 ? String(localized: "Covered") : String(localized: "\(spots.count) spots covered") }
        if states == [.tooSmall] {
            return spots.count == 1 ? String(localized: "Skipped: too small to hold a secret")
                                    : String(localized: "\(spots.count) spots skipped: too small to hold a secret")
        }
        return String(localized: "\(spots.count) spots settled")
    }

    /// The Journal's record section.
    public static let recordTitle = String(localized: "Spots settled")
    public static let recordDetail = String(localized: "Pictures whose unreadable spots were covered, skipped as too small, or marked not text by you. Kept as long as the Journal keeps catches.")

    // MARK: Settings (Protection ▸ When a spot can't be read)

    public static let settingsGroup = String(localized: "When a spot can't be read")

    public static let coverSwitch = String(localized: "Cover spots Obscura can't read")
    public static let coverSwitchDetail = String(localized: "A small mark that looks like text but can't be read is covered a little past its edges, instead of waiting for you. The notice says how many were covered")
    public static let skipSwitch = String(localized: "Skip spots too small to hold a secret")
    public static let skipSwitchDetail = String(localized: "A spot too narrow to fit the shortest secret your detectors and rules look for is skipped. Skipped spots are still recorded and outlined")
}
