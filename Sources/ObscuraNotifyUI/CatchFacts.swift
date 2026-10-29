// ObscuraNotifyUI — what a catch banner needs to know about one Journal entry. Built from `Entry`; carries detector
// names and file names only, never recognized text.
import Foundation
import ObscuraEngine
import ObscuraJournal
import ObscuraUIKit

/// What happened to the caught image's bytes, which decides the body and the verdict line.
enum CatchDelivery: Sendable, Hashable {
    /// The screenshot file now holds the clean image.
    case fileReplaced
    /// A clean copy was written next to the file; the original file still shows the secret.
    case keepBoth(cleanName: String)
    /// The clipboard guard put the clean image on the pasteboard.
    case clipboard
}

struct CatchFacts: Sendable, Hashable {
    var entryID: UUID
    /// `EntrySource` raw value; also the thread.
    var source: String
    var displayName: String
    var delivery: CatchDelivery
    var createdAt: Date
    /// One name per finding, in finding order (full detector names, already cased for the start of a title).
    var findingNames: [String]
    /// The same names cased for the middle of a sentence ("payment card number"); brand names keep their capital.
    var inSentenceNames: [String]
    /// The disk file the original went back to after Undo (the clean copy for keep-both, else the file); nil for clipboard.
    var restoreTargetName: String?
    /// What the scan's report adds (`ScanReport.notes`): the clipboard changed during the check (#18), the text copied
    /// with the image was left out because it held a secret (#8).
    var notes: ScanNotes = []
    /// G-40: covers drawn over spots no reading could read (route B), counted apart from the secrets.
    var spotsCovered = 0
    /// G-40: spots no reading could read that wait for the person (the picture is listed under Not checked).
    var pendingSpots = 0

    /// The secrets covered (a spot's cover is not a secret).
    var findingCount: Int { findingNames.count }

    /// Builds the facts for a caught entry. Returns nil for sources that never notify (imports happen in the Journal
    /// window the user is looking at; the demo belongs to setup) and for an entry with no findings.
    init?(entry: Entry) {
        guard !entry.findings.isEmpty else { return nil }
        switch entry.source {
        case .imported, .demo: return nil
        case .clipboard: delivery = .clipboard
        case .file:
            if let clean = entry.cleanCopyPath { delivery = .keepBoth(cleanName: URL(fileURLWithPath: clean).lastPathComponent) }
            else { delivery = .fileReplaced }
        }
        entryID = entry.id
        source = entry.source.rawValue
        displayName = entry.displayName
        createdAt = entry.createdAt
        findingNames = entry.secretFindings.map { DetectorNames.title(for: $0.detectorIDs.first ?? "") }
        inSentenceNames = entry.secretFindings.map { Self.inSentence(DetectorNames.title(for: $0.detectorIDs.first ?? ""), category: $0.category) }
        spotsCovered = entry.spotCovers.count
        let target = entry.cleanCopyPath ?? entry.filePath
        restoreTargetName = target.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    init(entryID: UUID, source: String, displayName: String, delivery: CatchDelivery, createdAt: Date,
         findingNames: [String], inSentenceNames: [String]? = nil, restoreTargetName: String?) {
        self.entryID = entryID; self.source = source; self.displayName = displayName; self.delivery = delivery
        self.createdAt = createdAt; self.findingNames = findingNames
        self.inSentenceNames = inSentenceNames ?? findingNames; self.restoreTargetName = restoreTargetName
    }

    /// Personal-data detector titles are common nouns ("Payment card number", "Email address") and take a lower-case
    /// first letter mid-sentence; vendor titles ("Stripe …", "GitHub token") and acronyms ("IBAN") keep theirs.
    static func inSentence(_ title: String, category: String) -> String {
        guard category == "personal", let first = title.first, title.count > 1 else { return title }
        let second = title[title.index(after: title.startIndex)]
        guard second.isLowercase else { return title }
        return first.lowercased() + title.dropFirst()
    }
}
