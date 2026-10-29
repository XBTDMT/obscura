// ObscuraSearch — what a covered file says in Spotlight and on its Finder tags (G-24). Labels only: the kind of
// secret (a built-in detector's title, its category) and plain words. Nothing here ever receives recognized text, a
// hash of it or anything derived from a value, so nothing here can put one in an index or a tag.
public import Foundation
import ObscuraDetect
import ObscuraSupport
public import ObscuraJournal

/// One Core Spotlight item, as plain values: the pure output of `CatchSearchItem.build`, turned into a
/// `CSSearchableItem` only by `CoreSpotlightIndex`, so tests read exactly what Spotlight would be given.
public struct SearchItemContent: Sendable, Hashable {
    /// The domain of every item Obscura makes; switching Spotlight entries off deletes it whole.
    public static let domain = AppIdentity.current.spotlightDomain

    /// The covered file's record id (the Journal entry it was caught as).
    public let uniqueIdentifier: String
    public let domainIdentifier: String
    /// "Covered screenshot — Anthropic API key, Stripe secret key"
    public let title: String
    /// The covered file's name.
    public let displayName: String
    public let contentDescription: String
    public let keywords: [String]
    public let contentCreationDate: Date
    /// A small PNG of the COVERED file on disk; never of an original.
    public let thumbnailData: Data?

    /// Every text the item carries, for the tests that prove what it says.
    public var allText: [String] { [uniqueIdentifier, domainIdentifier, title, displayName, contentDescription] + keywords }
}

/// The words the labels are made of.
public enum SearchLabels {
    /// The Finder tag and keyword every covered file gets.
    public static let appTag = "Obscura"
    /// A custom rule's own title is the person's words (or, unnamed, a description of its pattern, which can be the
    /// text it blacks out), so it never reaches a label: every custom rule is this one phrase.
    public static var customRule: String { String(localized: "Custom rule") }

    /// The kinds of secret, in finding order, without repeats: a built-in detector's title; `customRule` for a custom
    /// rule; nothing for an id the catalogue no longer knows (an id is not a label).
    public static func kinds(detectorIDs: [String], titles: [String: String]) -> [String] {
        var out: [String] = []
        for id in detectorIDs {
            let label: String?
            if id.hasPrefix("custom.") { label = customRule }
            else if id == SpotRecord.coverDetectorID { label = SpotRecord.coverTitle }   // G-40: a spot's cover
            else if let title = titles[id], !title.isEmpty { label = title }
            else { label = nil }
            if let label, !out.contains(label) { out.append(label) }
        }
        return out
    }

    /// Category names in order, without repeats; an unknown raw value is dropped.
    public static func categories(_ raw: [String]) -> [String] {
        var out: [String] = []
        for value in raw {
            guard let title = Detector.Category(rawValue: value)?.displayTitle, !out.contains(title) else { continue }
            out.append(title)
        }
        return out
    }

    /// The Finder tags Obscura wants on a covered file: "Obscura" and the kinds of secret.
    public static func tags(detectorIDs: [String], titles: [String: String]) -> [String] {
        [appTag] + kinds(detectorIDs: detectorIDs, titles: titles).filter { $0 != appTag }
    }
}

public enum CatchSearchItem {
    /// The Spotlight item for one covered file. Pure: the same record, titles and thumbnail always make the same item.
    public static func build(record: CoveredFileRecord, titles: [String: String], thumbnail: Data?) -> SearchItemContent {
        let kinds = SearchLabels.kinds(detectorIDs: record.detectorIDs, titles: titles)
        let categories = SearchLabels.categories(record.categories)
        let noun = record.isScreenshot ? String(localized: "Covered screenshot") : String(localized: "Covered image")
        let title = kinds.isEmpty ? noun : "\(noun) — \(kinds.joined(separator: ", "))"
        let description = kinds.isEmpty
            ? String(localized: "Covered by Obscura")
            : String(localized: "Covered by Obscura: \(kinds.joined(separator: ", "))")
        var keywords: [String] = []
        for word in kinds + categories + [SearchLabels.appTag, String(localized: "covered"), String(localized: "redacted")]
        where !keywords.contains(word) {
            keywords.append(word)
        }
        return SearchItemContent(uniqueIdentifier: record.id.uuidString, domainIdentifier: SearchItemContent.domain, title: title,
                                 displayName: record.fileURL.lastPathComponent, contentDescription: description, keywords: keywords,
                                 contentCreationDate: record.caughtAt, thumbnailData: thumbnail)
    }
}
