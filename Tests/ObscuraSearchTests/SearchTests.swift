// G-24: the Spotlight item as a pure function, the tag arithmetic, and the coordinator's lifetime rules against a fake
// index (the Mac's real Spotlight index is never touched) and real files in a temp folder.
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ObscuraDetect
import ObscuraJournal
import ObscuraSupport
@testable import ObscuraSearch

/// Records every call instead of talking to Core Spotlight.
actor RecordingIndex: SearchIndexing {
    private(set) var items: [String: SearchItemContent] = [:]
    private(set) var indexed: [SearchItemContent] = []
    private(set) var deletedIDs: [String] = []
    private(set) var domainsDeleted: [String] = []

    func index(_ items: [SearchItemContent]) async throws {
        for item in items { self.items[item.uniqueIdentifier] = item }
        indexed += items
    }
    func delete(identifiers: [String]) async throws {
        deletedIDs += identifiers
        for id in identifiers { items[id] = nil }
    }
    func deleteAll(domain: String) async throws {
        domainsDeleted.append(domain)
        items = items.filter { $0.value.domainIdentifier != domain }
    }
}

enum SearchFixture {
    /// Made-up Anthropic-shaped key; never a real credential.
    static let fakeKey = "sk-ant-api03-Zq7FAKExKEYxONLYxFORxTESTSx0000000000"
    static let titles = ["ai.anthropic.api_key": "Anthropic API key", "payments.stripe.secret_key": "Stripe secret key"]

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("obscura-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A small PNG filled with one colour.
    static func png(red: CGFloat) -> Data {
        let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: red, green: 0.2, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    static func record(_ ids: [String] = ["ai.anthropic.api_key", "payments.stripe.secret_key"], categories: [String] = ["ai", "payments"],
                       screenshot: Bool = true, path: String = "/home/x/Desktop/Screenshot 2026-10-27 at 10.00.00.png") -> CoveredFileRecord {
        CoveredFileRecord(id: UUID(), filePath: path, bookmark: nil, detectorIDs: ids, categories: categories, isScreenshot: screenshot,
                          caughtAt: Date(timeIntervalSince1970: 1_800_000_000), updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
}

@Suite struct SearchItemTests {
    @Test func itemCarriesLabelsDateAndNameOnly() {
        let record = SearchFixture.record()
        let item = CatchSearchItem.build(record: record, titles: SearchFixture.titles, thumbnail: Data([1, 2, 3]))
        #expect(item.uniqueIdentifier == record.id.uuidString)
        #expect(item.domainIdentifier == "io.github.xbtdmt.obscura.catches")
        #expect(item.title == "Covered screenshot — Anthropic API key, Stripe secret key")
        #expect(item.displayName == "Screenshot 2026-10-27 at 10.00.00.png")
        #expect(item.contentDescription == "Covered by Obscura: Anthropic API key, Stripe secret key")
        #expect(item.keywords == ["Anthropic API key", "Stripe secret key", "AI providers", "Payments", "Obscura", "covered", "redacted"])
        #expect(item.contentCreationDate == record.caughtAt)
        #expect(item.thumbnailData == Data([1, 2, 3]))
        // Every word in the item is one of: the fixed words, a detector title, a category name, the file name.
        let allowed = Set(["Covered screenshot", "Covered by Obscura", "Anthropic API key", "Stripe secret key", "AI providers", "Payments",
                           "Obscura", "covered", "redacted", item.displayName, item.uniqueIdentifier, item.domainIdentifier])
        for text in item.allText {
            let pieces = text.replacingOccurrences(of: " — ", with: "|").replacingOccurrences(of: ": ", with: "|")
                .replacingOccurrences(of: ", ", with: "|").split(separator: "|").map(String.init)
            for piece in pieces { #expect(allowed.contains(piece), "unexpected text in the item: \(piece)") }
        }
    }

    @Test func anImageThatIsNotAScreenshotSaysImage() {
        let item = CatchSearchItem.build(record: SearchFixture.record(screenshot: false), titles: SearchFixture.titles, thumbnail: nil)
        #expect(item.title.hasPrefix("Covered image — "))
    }

    /// A custom rule's title is the person's own words (unnamed, a description of its pattern: the text itself). A
    /// made-up key standing in for such a title never reaches any field of the item or the tags.
    @Test func noValueSubstringReachesTheItemOrTheTags() {
        let key = SearchFixture.fakeKey
        let customID = "custom.\(UUID().uuidString)"
        var titles = SearchFixture.titles
        titles[customID] = "Exact text “\(key)”"
        titles["unknown.detector"] = nil
        let record = SearchFixture.record([customID, "ai.anthropic.api_key", "unknown.detector"], categories: ["custom", "ai", "notACategory"])
        let item = CatchSearchItem.build(record: record, titles: titles, thumbnail: nil)
        let tags = SearchLabels.tags(detectorIDs: record.detectorIDs, titles: titles)
        let everything = (item.allText + tags).joined(separator: "\n")
        // Every 6-character piece of the key: none appears anywhere.
        let chars = Array(key)
        for start in 0...(chars.count - 6) {
            let piece = String(chars[start..<(start + 6)])
            #expect(!everything.contains(piece), "a piece of the made-up key reached the item: \(piece)")
        }
        #expect(item.title == "Covered screenshot — Custom rule, Anthropic API key")
        #expect(tags == ["Obscura", "Custom rule", "Anthropic API key"])
        #expect(!everything.contains("unknown.detector") && !everything.contains("notACategory"))
    }

    @Test func noKindsStillMakesATitle() {
        let item = CatchSearchItem.build(record: SearchFixture.record(["gone.detector"], categories: []), titles: [:], thumbnail: nil)
        #expect(item.title == "Covered screenshot")
        #expect(item.keywords == ["Obscura", "covered", "redacted"])
    }

    @Test func spotlightItemIsBuiltFieldForField() {
        let content = CatchSearchItem.build(record: SearchFixture.record(), titles: SearchFixture.titles, thumbnail: Data([7]))
        let item = CoreSpotlightIndex.searchableItem(content)
        #expect(item.uniqueIdentifier == content.uniqueIdentifier)
        #expect(item.domainIdentifier == content.domainIdentifier)
        #expect(item.attributeSet.title == content.title)
        #expect(item.attributeSet.displayName == content.displayName)
        #expect(item.attributeSet.keywords == content.keywords)
        #expect(item.attributeSet.contentCreationDate == content.contentCreationDate)
        #expect(item.attributeSet.thumbnailData == Data([7]))
        #expect(item.expirationDate == .distantFuture)
    }

    @Test func categoryNamesAreTheSettingsNames() {
        #expect(SearchLabels.categories(["ai", "payments", "ai", "custom"]) == ["AI providers", "Payments", "Your rules"])
    }
}

@Suite struct TagPlanTests {
    @Test func addsWantedTagsAndKeepsThePersonsOwn() {
        let plan = TagPlan.apply(current: ["Work", "Red"], written: [], wanted: ["Obscura", "Stripe secret key"])
        #expect(plan.tags == ["Work", "Red", "Obscura", "Stripe secret key"])
        #expect(plan.written == ["Obscura", "Stripe secret key"])
    }

    @Test func aWantedTagThePersonAlreadyHadStaysTheirs() {
        let plan = TagPlan.apply(current: ["Obscura", "Work"], written: [], wanted: ["Obscura", "AWS access key"])
        #expect(plan.tags == ["Obscura", "Work", "AWS access key"])
        #expect(plan.written == ["AWS access key"])
        #expect(TagPlan.remove(current: plan.tags, written: plan.written) == ["Obscura", "Work"])
    }

    @Test func syncDropsAKindNoLongerCoveredAndKeepsUserTags() {
        let plan = TagPlan.apply(current: ["Work", "Obscura", "Stripe secret key", "AWS access key"], written: ["Obscura", "Stripe secret key", "AWS access key"],
                                 wanted: ["Obscura", "AWS access key"])
        #expect(plan.tags == ["Work", "Obscura", "AWS access key"])
        #expect(plan.written == ["Obscura", "AWS access key"])
    }

    @Test func removeTakesOnlyObscurasTags() {
        #expect(TagPlan.remove(current: ["Work", "Obscura", "Stripe secret key"], written: ["Obscura", "Stripe secret key"]) == ["Work"])
    }

    @Test func finderTagsRoundTripOnARealFile() throws {
        let dir = try SearchFixture.folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.png")
        try SearchFixture.png(red: 1).write(to: file)
        let tagger = FinderTagFiles()
        try tagger.setTags(["Work", "Obscura"], on: file)
        #expect(try tagger.tags(of: file) == ["Work", "Obscura"])
        try tagger.setTags([], on: file)
        #expect(try tagger.tags(of: file).isEmpty)
    }

    /// FileAtomics.replace (every cover and undo of a file in place) keeps the person's Finder tags.
    @Test func replacingAFileKeepsItsTags() throws {
        let dir = try SearchFixture.folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.png")
        try SearchFixture.png(red: 1).write(to: file)
        try FinderTagFiles().setTags(["Work"], on: file)
        try FileAtomics.replace(contentsOf: file, with: SearchFixture.png(red: 0))
        #expect(try FinderTagFiles().tags(of: file) == ["Work"])
        #expect(try Data(contentsOf: file) == SearchFixture.png(red: 0))
    }
}

/// The coordinator with a real Journal, real files and the recording index.
struct SearchHarness {
    let dir: URL
    let journal: SQLiteJournalStore
    let index = RecordingIndex()
    let coordinator: SearchCoordinator
    let clock = ManualClock()

    init() throws {
        dir = try SearchFixture.folder()
        journal = try SQLiteJournalStore(root: dir.appendingPathComponent("store", isDirectory: true), ruleKeys: InMemoryRuleKeyStore(), clock: clock,
                                         backupsRoot: dir.appendingPathComponent("backups", isDirectory: true))
        coordinator = SearchCoordinator(journal: journal, index: index, clock: clock)
    }

    /// A covered file on disk and its Journal entry with two findings (Anthropic, Stripe).
    func catchFile(_ name: String = "Screenshot.png", red: CGFloat = 0) async throws -> (Entry, URL) {
        let file = dir.appendingPathComponent(name)
        try SearchFixture.png(red: red).write(to: file)
        let entry = try await journal.create(
            NewEntry(source: .file, displayName: name, filePath: file.path, containerUTI: "public.png", pixelWidth: 64, pixelHeight: 32,
                     findings: [NewFinding(lineIndex: 0, rect: CGRect(x: 1, y: 1, width: 10, height: 5), detectorIDs: ["ai.anthropic.api_key"], category: "ai"),
                                NewFinding(lineIndex: 1, rect: CGRect(x: 1, y: 9, width: 10, height: 5), detectorIDs: ["payments.stripe.secret_key"], category: "payments")]),
            original: SearchFixture.png(red: 1), clean: SearchFixture.png(red: 0))
        return (entry, file)
    }

    func tearDown() { try? FileManager.default.removeItem(at: dir) }
}

let on = SearchSwitches(spotlight: true, tags: true)
let spotlightOnly = SearchSwitches(spotlight: true, tags: false)
let off = SearchSwitches(spotlight: false, tags: false)

@Suite struct SearchCoordinatorTests {
    @Test func aCatchIndexesTheCoveredFileWithItsCoveredThumbnail() async throws {
        let h = try SearchHarness(); defer { h.tearDown() }
        let (entry, file) = try await h.catchFile()
        await h.coordinator.caught(entryID: entry.id, coveredFile: file, findings: entry.findings, isScreenshot: true,
                                   titles: SearchFixture.titles, switches: spotlightOnly)
        let items = await h.index.items
        let item = try #require(items[entry.id.uuidString])
        #expect(item.title == "Covered screenshot — Anthropic API key, Stripe secret key")
        #expect(item.thumbnailData == CoveredThumbnail.data(of: file), "the thumbnail is the covered file on disk")
        #expect(item.thumbnailData != nil)
        #expect(try FinderTagFiles().tags(of: file).isEmpty, "tags are off")
        let record = try #require(try await h.journal.coveredFile(entry.id))
        #expect(record.detectorIDs == ["ai.anthropic.api_key", "payments.stripe.secret_key"])
        #expect(record.categories == ["ai", "payments"])
        #expect(record.covered && record.isScreenshot)
    }

    @Test func tagsAreAddedSyncedAndRemovedKeepingThePersonsTags() async throws {
        let h = try SearchHarness(); defer { h.tearDown() }
        let (entry, file) = try await h.catchFile()
        try FinderTagFiles().setTags(["Work"], on: file)
        await h.coordinator.caught(entryID: entry.id, coveredFile: file, findings: entry.findings, isScreenshot: true,
                                   titles: SearchFixture.titles, switches: on)
        #expect(try FinderTagFiles().tags(of: file) == ["Work", "Obscura", "Anthropic API key", "Stripe secret key"])

        // One finding left visible: its kind's tag goes, the rest stay.
        let stripe = try #require(entry.findings.first { $0.category == "payments" })
        try await h.journal.setCovered(stripe.id, false, in: entry.id)
        await h.coordinator.entryChanged(try await h.journal.entry(entry.id), titles: SearchFixture.titles, switches: on)
        #expect(try FinderTagFiles().tags(of: file) == ["Work", "Obscura", "Anthropic API key"])
        #expect(await h.index.items[entry.id.uuidString]?.title == "Covered screenshot — Anthropic API key")

        // Undo (every finding visible): Obscura's tags and the item go; the record stays for Redo.
        for f in entry.findings { try await h.journal.setCovered(f.id, false, in: entry.id) }
        await h.coordinator.entryChanged(try await h.journal.entry(entry.id), titles: SearchFixture.titles, switches: on)
        #expect(try FinderTagFiles().tags(of: file) == ["Work"])
        #expect(await h.index.items[entry.id.uuidString] == nil)
        #expect(try await h.journal.coveredFile(entry.id)?.covered == false)

        // Redo: back again.
        for f in entry.findings { try await h.journal.setCovered(f.id, true, in: entry.id) }
        await h.coordinator.entryChanged(try await h.journal.entry(entry.id), titles: SearchFixture.titles, switches: on)
        #expect(try FinderTagFiles().tags(of: file) == ["Work", "Obscura", "Anthropic API key", "Stripe secret key"])
        #expect(await h.index.items[entry.id.uuidString] != nil)
    }

    @Test func switchingTagsOffRemovesOnlyObscurasTags() async throws {
        let h = try SearchHarness(); defer { h.tearDown() }
        let (entry, file) = try await h.catchFile()
        await h.coordinator.reconcile(full: true, titles: SearchFixture.titles, switches: on)
        await h.coordinator.caught(entryID: entry.id, coveredFile: file, findings: entry.findings, isScreenshot: true,
                                   titles: SearchFixture.titles, switches: on)
        // The person adds a tag of their own afterwards, including one named like Obscura's.
        try FinderTagFiles().setTags(try FinderTagFiles().tags(of: file) + ["Work"], on: file)
        await h.coordinator.switchesChanged(to: spotlightOnly, titles: SearchFixture.titles)
        #expect(try FinderTagFiles().tags(of: file) == ["Work"])
        #expect(try await h.journal.coveredFile(entry.id)?.tagsWritten == [])
        await h.coordinator.switchesChanged(to: on, titles: SearchFixture.titles)
        #expect(try FinderTagFiles().tags(of: file) == ["Work", "Obscura", "Anthropic API key", "Stripe secret key"])
    }

    @Test func switchingSpotlightOffDeletesTheDomainAndOnIndexesAgain() async throws {
        let h = try SearchHarness(); defer { h.tearDown() }
        let (entry, file) = try await h.catchFile()
        await h.coordinator.reconcile(full: true, titles: SearchFixture.titles, switches: spotlightOnly)
        await h.coordinator.caught(entryID: entry.id, coveredFile: file, findings: entry.findings, isScreenshot: true,
                                   titles: SearchFixture.titles, switches: spotlightOnly)
        await h.coordinator.switchesChanged(to: off, titles: SearchFixture.titles)
        #expect(await h.index.domainsDeleted.last == SearchItemContent.domain)
        #expect(await h.index.items.isEmpty)
        await h.coordinator.switchesChanged(to: spotlightOnly, titles: SearchFixture.titles)
        #expect(await h.index.items.keys.sorted() == [entry.id.uuidString])
    }

    @Test func theItemOutlivesTheJournalEntry() async throws {
        let h = try SearchHarness(); defer { h.tearDown() }
        let (entry, file) = try await h.catchFile()
        await h.coordinator.caught(entryID: entry.id, coveredFile: file, findings: entry.findings, isScreenshot: true,
                                   titles: SearchFixture.titles, switches: spotlightOnly)
        #expect(await h.coordinator.target(for: entry.id.uuidString) == .entry(entry.id))
        // Retention expires the entry; the covered file is still there.
        h.clock.advance(by: 48 * 3600)
        _ = try await h.journal.pruneExpired(olderThan: .seconds(24 * 3600))
        #expect(try await h.journal.entries(matching: .live).isEmpty)
        await h.coordinator.reconcile(full: false, titles: SearchFixture.titles, switches: spotlightOnly)
        #expect(await h.index.items[entry.id.uuidString] != nil, "search later still finds it")
        #expect(await h.coordinator.target(for: entry.id.uuidString) == .file(file))
        // A full reconcile rebuilds the domain from the records: still there.
        await h.coordinator.reconcile(full: true, titles: SearchFixture.titles, switches: spotlightOnly)
        #expect(await h.index.items.keys.sorted() == [entry.id.uuidString])
    }

    @Test func aDeletedFileRetiresItsItemAndRecord() async throws {
        let h = try SearchHarness(); defer { h.tearDown() }
        let (entry, file) = try await h.catchFile()
        await h.coordinator.caught(entryID: entry.id, coveredFile: file, findings: entry.findings, isScreenshot: true,
                                   titles: SearchFixture.titles, switches: spotlightOnly)
        try FileManager.default.removeItem(at: file)
        #expect(await h.coordinator.reconcile(full: false, titles: SearchFixture.titles, switches: spotlightOnly) == 1)
        #expect(await h.index.items.isEmpty)
        #expect(await h.index.deletedIDs.contains(entry.id.uuidString))
        #expect(try await h.journal.coveredFiles().isEmpty)
        #expect(await h.coordinator.target(for: entry.id.uuidString) == .entry(entry.id), "the entry itself still opens")
        try await h.journal.trash([entry.id])
        #expect(await h.coordinator.target(for: entry.id.uuidString) == SearchTarget.none)
    }

    @Test func aFileMovedToTheTrashIsRetiredAndLosesObscurasTags() async throws {
        let h = try SearchHarness(); defer { h.tearDown() }
        let (entry, file) = try await h.catchFile()
        await h.coordinator.caught(entryID: entry.id, coveredFile: file, findings: entry.findings, isScreenshot: true,
                                   titles: SearchFixture.titles, switches: on)
        let trash = h.dir.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let trashed = trash.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: trashed)
        #expect(await h.coordinator.reconcile(full: false, titles: SearchFixture.titles, switches: on) == 1)
        #expect(await h.index.items.isEmpty)
        #expect(try await h.journal.coveredFiles().isEmpty)
    }

    @Test func aMovedFileIsFollowedByItsBookmark() async throws {
        let h = try SearchHarness(); defer { h.tearDown() }
        let (entry, file) = try await h.catchFile()
        await h.coordinator.caught(entryID: entry.id, coveredFile: file, findings: entry.findings, isScreenshot: true,
                                   titles: SearchFixture.titles, switches: spotlightOnly)
        let moved = h.dir.appendingPathComponent("Renamed.png")
        try FileManager.default.moveItem(at: file, to: moved)
        #expect(await h.coordinator.reconcile(full: false, titles: SearchFixture.titles, switches: spotlightOnly) == 0)
        let record = try #require(try await h.journal.coveredFile(entry.id))
        #expect(URL(fileURLWithPath: record.filePath).resolvingSymlinksInPath() == moved.resolvingSymlinksInPath())
        #expect(await h.index.items[entry.id.uuidString]?.displayName == "Renamed.png")
    }

    @Test func catchingTheSameFileAgainReplacesItsItem() async throws {
        let h = try SearchHarness(); defer { h.tearDown() }
        let (first, file) = try await h.catchFile()
        await h.coordinator.caught(entryID: first.id, coveredFile: file, findings: first.findings, isScreenshot: true,
                                   titles: SearchFixture.titles, switches: spotlightOnly)
        let (second, _) = try await h.catchFile()
        await h.coordinator.caught(entryID: second.id, coveredFile: file, findings: second.findings, isScreenshot: true,
                                   titles: SearchFixture.titles, switches: spotlightOnly)
        #expect(await h.index.items.keys.sorted() == [second.id.uuidString])
        #expect(try await h.journal.coveredFiles().map(\.id) == [second.id])
    }

    @Test func undoWithNoEntryLeftRetiresTheRecord() async throws {
        let h = try SearchHarness(); defer { h.tearDown() }
        let (entry, file) = try await h.catchFile()
        await h.coordinator.caught(entryID: entry.id, coveredFile: file, findings: entry.findings, isScreenshot: true,
                                   titles: SearchFixture.titles, switches: spotlightOnly)
        for f in entry.findings { try await h.journal.setCovered(f.id, false, in: entry.id) }
        await h.coordinator.entryChanged(try await h.journal.entry(entry.id), titles: SearchFixture.titles, switches: spotlightOnly)
        h.clock.advance(by: 48 * 3600)
        _ = try await h.journal.pruneExpired(olderThan: .seconds(24 * 3600))
        #expect(await h.coordinator.reconcile(full: false, titles: SearchFixture.titles, switches: spotlightOnly) == 1)
        #expect(try await h.journal.coveredFiles().isEmpty)
    }

    @Test func fullReconcileRemovesStaleIdsAndReportsCountsAndIds() async throws {
        let h = try SearchHarness(); defer { h.tearDown() }
        try await h.index.index([CatchSearchItem.build(record: SearchFixture.record(), titles: SearchFixture.titles, thumbnail: nil)])
        let (entry, file) = try await h.catchFile()
        await h.coordinator.caught(entryID: entry.id, coveredFile: file, findings: entry.findings, isScreenshot: true,
                                   titles: SearchFixture.titles, switches: on)
        await h.coordinator.reconcile(full: true, titles: SearchFixture.titles, switches: on)
        #expect(await h.index.items.keys.sorted() == [entry.id.uuidString], "the stale id is gone")
        let report = await h.coordinator.report()
        #expect(report.records == 1 && report.covered == 1 && report.filesPresent == 1 && report.taggedFiles == 1)
        #expect(report.recordIDs == [entry.id.uuidString] && report.taggedIDs == [entry.id.uuidString] && report.missingIDs.isEmpty)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!json.contains(file.lastPathComponent) && !json.contains("Anthropic"), "the report carries counts and ids only")
    }
}

/// A finding's flag changed the only way the Journal allows (G-28): with a picture, in one commit. These tests stand in
/// for the engine, so the picture is the original's bytes; what they check does not read it.
fileprivate extension JournalStore {
    func setCovered(_ findingID: UUID, _ covered: Bool, in entryID: UUID) async throws {
        let entry = try await entry(entryID)
        var set = Set(entry.enabledFindings.map(\.id))
        if covered { set.insert(findingID) } else { set.remove(findingID) }
        try await commitRender(entryID, clean: try await originalData(entryID), enabled: set, style: nil, expectedRevision: entry.revision)
    }
}
