// ObscuraEngine — the words a "kind of secret" label prints on a cover (security scan 2026-10-28 F4/F5/F7).
// A cover label is drawn into the picture Obscura calls safe to share, so it is built only from words Obscura owns:
// a built-in detector's title, one fixed phrase for every custom rule, or a fixed fallback. Never a rule's own words.
import Foundation
public import ObscuraDetect
import ObscuraSearch
import ObscuraJournal

public enum CoverLabels {
    /// Every custom rule's label. A custom rule's title is the person's words (or, unnamed, once a description of its
    /// pattern, which for an exact-text rule IS the text it blacks out), so it never reaches a cover: the same rule
    /// `SearchLabels.kinds` applies to Spotlight and Finder tags, and `DetectorNames` to notifications.
    public static var customRule: String { SearchLabels.customRule }
    /// The label of an area whose detector the catalogue no longer knows (an id is not a label).
    public static let fallback = "Secret"

    /// Whether `detectorID` names a custom rule (`custom.<UUID>`).
    public static func isCustom(_ detectorID: String) -> Bool { detectorID.hasPrefix("custom.") }

    /// Detector id → cover label for every detector in `catalogue`: a built-in (or edited built-in) detector's title,
    /// `customRule` for every custom rule.
    public static func titles(for catalogue: CompiledCatalogue) -> [String: String] {
        var titles: [String: String] = [:]
        for compiled in catalogue.detectors {
            let id = compiled.detector.id
            titles[id] = isCustom(id) || compiled.detector.source == .custom ? customRule : compiled.detector.title
        }
        return titles
    }

    /// The label of an area whose finding's detectors are `detectorIDs` (the first owns the label, DETECTORS.md §8).
    /// Checked at the label site as well as in `titles(for:)`, so a title map built anywhere else still cannot put a
    /// custom rule's words on a cover.
    public static func label(for detectorIDs: [String], titles: [String: String]) -> String {
        guard let id = detectorIDs.first else { return fallback }
        if isCustom(id) { return customRule }
        // G-40: the cover of a spot no reading could read says what it is, never a secret's kind.
        if id == SpotRecord.coverDetectorID { return SpotRecord.coverTitle }
        guard let title = titles[id], !title.isEmpty else { return fallback }
        return title
    }
}
