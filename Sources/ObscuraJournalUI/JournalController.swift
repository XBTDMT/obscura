// The Journal window's view state and the verbs it offers. Every change to an entry goes through `AppModel` (or the
// store it exposes); this type only remembers what the window shows (filter, search, mode, peek, the undo ladder) and
// pairs each verb with its inverse so ⌘Z and the toast's Undo do the same thing.
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import ObscuraUIKit
import ObscuraEngine
import ObscuraJournal
import ObscuraPrefs
import ObscuraSupport

/// A row in the Journal sidebar: a source filter, a protection-state filter, or the Not checked section (G-13), which
/// lists files Obscura could not check rather than catches.
enum SidebarItem: Hashable, CaseIterable, Identifiable, Sendable {
    case all, screenshots, clipboard, imported, testShots
    case safe, leftVisible, original
    case notChecked
    /// Fail-open #7: files on disk that still show what was caught.
    case notCovered

    /// The two sections that list files on disk rather than catches.
    var listsFiles: Bool { self == .notChecked || self == .notCovered }

    var id: Self { self }
    static let library: [SidebarItem] = [.all, .screenshots, .clipboard, .imported, .testShots]
    static let states: [SidebarItem] = [.safe, .leftVisible, .original]

    var title: String {
        switch self {
        case .all: return String(localized: "All catches")
        case .screenshots: return String(localized: "Screenshots")
        case .clipboard: return String(localized: "Clipboard")
        case .imported: return String(localized: "Imported")
        case .testShots: return String(localized: "Test shots")
        case .safe: return Verdict.safeToShare(total: 1).title
        case .leftVisible: return String(localized: "Left visible")
        case .original: return Verdict.originalShowing(total: 1).title
        case .notChecked: return String(localized: "Not checked")
        case .notCovered: return String(localized: "Not covered on disk")
        }
    }

    var symbol: String {
        switch self {
        case .all: return "house"
        case .screenshots: return JournalFormat.sourceSymbol(.file)
        case .clipboard: return JournalFormat.sourceSymbol(.clipboard)
        case .imported: return JournalFormat.sourceSymbol(.imported)
        case .testShots: return JournalFormat.sourceSymbol(.demo)
        case .safe: return Verdict.safeToShare(total: 1).symbol
        case .leftVisible: return Verdict.leftVisible(visible: 1, total: 2).symbol
        case .original: return Verdict.originalShowing(total: 1).symbol
        // The panel's "N images weren't checked" banner carries the same symbol, so the two read as one thing.
        case .notChecked: return JournalFormat.notCheckedSymbol
        case .notCovered: return JournalFormat.notCoveredSymbol
        }
    }

    /// State rows carry their verdict's tone; source rows use the accent; Not checked needs you.
    var tone: Tone {
        switch self {
        case .safe: return .ok
        case .leftVisible, .notChecked, .notCovered: return .needs
        case .original: return .live
        default: return .accent
        }
    }

    func matches(_ entry: Entry, verdict: Verdict) -> Bool {
        switch self {
        case .all: return true
        case .screenshots: return entry.source == .file
        case .clipboard: return entry.source == .clipboard
        case .imported: return entry.source == .imported
        case .testShots: return entry.source == .demo
        case .safe: if case .safeToShare = verdict { return true } else { return false }
        case .leftVisible: if case .leftVisible = verdict { return true } else { return false }
        case .original: if case .originalShowing = verdict { return true } else { return false }
        case .notChecked, .notCovered: return false
        }
    }
}

/// One day of entries in the grid or list.
struct DayGroup: Identifiable {
    let day: Date
    let entries: [Entry]
    var id: Date { day }
}

/// One toast in the undo ladder (newest first, at most three).
struct LadderItem: Identifiable {
    let id = UUID()
    let text: String
    let isError: Bool
    /// The inverse of what the toast announces; nil when there is nothing to undo (sweeps, copies, errors).
    let undo: (@MainActor () async -> Void)?
    let ticket = UndoTicket()
}

/// The target an undo registration hangs off, so one ladder item's undo can be withdrawn on its own.
final class UndoTicket {}

struct ImageKey: Hashable { let id: UUID; let revision: Int; let original: Bool }

/// A decoded clean image and the entry revision it shows.
struct LoadedImage { let revision: Int; let image: NSImage }

@MainActor
@Observable
final class JournalController {
    let model: AppModel

    // MARK: View state

    var sidebar: SidebarItem = .all
    var search = ""
    var searchFocused = false
    var viewMode: JournalView
    var showsInspector: Bool
    var styleExpanded = false
    var detailsExpanded = true
    /// The toolbar's Peek switch (latched) and the preview's press-and-hold.
    var peekLatched = false
    private(set) var peekHeld = false
    /// The preview's hold-to-peek: the original shows only after a deliberate hold (the Viewer's rule), never on a
    /// click or the double-click that opens the Viewer (recon T-2).
    @ObservationIgnored let peekHold = HoldToPeek()
    var isDropTargeted = false
    var confirmingSaveDefault = false
    /// The last plain click, for ⇧-click ranges.
    var selectionAnchor: UUID?
    /// Grid columns as last laid out, for ↑/↓.
    var gridColumns = 3
    /// The style being edited for the single selected entry (committed on release).
    var styleDraft: StyleRecord?
    private var styleDraftSource: ImageKey?

    private(set) var ladder: [LadderItem] = []
    /// Each entry's clean image at the newest revision loaded so far. An edit (a finding toggle, a style change)
    /// bumps the revision; the previous image stays on screen until the new one is decoded, then the two cross-fade
    /// (recon T-1: looking images up by the new revision showed the dark ground in between).
    private(set) var cleanImages: [UUID: LoadedImage] = [:]
    /// Each entry's original. The original never changes with the revision, so it is loaded once.
    private(set) var originalImages: [UUID: NSImage] = [:]
    private(set) var fileSizes: [UUID: Int64] = [:]
    private var loadingImages: Set<ImageKey> = []
    /// Reads the system setting by default; tests pin it.
    var reduceMotion: () -> Bool = { OMotion.systemReduceMotion }

    /// The window's undo manager; set by the view. Each verb registers its inverse here as well as on the ladder.
    weak var undoManager: UndoManager?
    /// Injectable clock for day headers and retention lines.
    var now: () -> Date = { Date() }
    var calendar: Calendar = .current
    /// How long a toast stays in the ladder: the one toast lifetime (G-15).
    var toastLifetime: Duration = .seconds(OMotion.toastSeconds)
    /// The key texts this window shows under findings left visible (G-17). View state only: cleared when a finding is
    /// covered again, when the switch goes off and when the window closes.
    let keyTexts: UncoveredKeyText

    init(model: AppModel, keyTexts: UncoveredKeyText? = nil) {
        self.model = model
        self.keyTexts = keyTexts ?? UncoveredKeyText(model: model)
        self.viewMode = model.settings.journalView
        self.showsInspector = model.settings.journalShowsInspector
        peekHold.onBegin = { [weak self] in self?.peekHeld = true }
        peekHold.onEnd = { [weak self] in self?.peekHeld = false }
    }

    // MARK: Derived

    var retention: JournalRetention { model.settings.journalRetention }
    var allEntries: [Entry] { model.entries }

    func entry(_ id: UUID) -> Entry? { model.entries.first { $0.id == id } }
    func entries(_ ids: Set<UUID>) -> [Entry] { model.entries.filter { ids.contains($0.id) } }

    var visibleEntries: [Entry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.entries.filter { entry in
            sidebar.matches(entry, verdict: model.verdict(for: entry))
                && (query.isEmpty || entry.displayName.localizedCaseInsensitiveContains(query))
        }
    }

    var groups: [DayGroup] {
        var order: [Date] = []
        var byDay: [Date: [Entry]] = [:]
        for entry in visibleEntries {
            let day = calendar.startOfDay(for: entry.createdAt)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(entry)
        }
        return order.map { DayGroup(day: $0, entries: byDay[$0] ?? []) }
    }

    func count(_ item: SidebarItem) -> Int {
        if item == .notChecked { return model.status.unchecked.count }
        if item == .notCovered { return model.status.uncovered.count }
        return model.entries.reduce(0) { $0 + (item.matches($1, verdict: model.verdict(for: $1)) ? 1 : 0) }
    }

    // MARK: Not checked (G-13)

    /// Whether the sidebar shows the Not checked row: while there is a file to show, and while it is the section on
    /// screen (so dismissing the last one leaves its quiet empty state in place rather than pulling the row away).
    var showsNotChecked: Bool { !model.status.unchecked.isEmpty || sidebar == .notChecked }

    /// The same for Not covered on disk (fail-open #7).
    var showsNotCovered: Bool { !model.status.uncovered.isEmpty || sidebar == .notCovered }

    /// The Not covered on disk list as the window shows it: most recently seen first, narrowed by the search field.
    var visibleUncovered: [UncoveredFile] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.status.uncovered.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    /// Whether the caught file is still where it was; without it there is nothing to cover.
    func sourceExists(_ file: UncoveredFile) -> Bool { FileManager.default.fileExists(atPath: file.sourceURL.path) }

    /// Try Again on one file: the covered picture is written there again (or the file is checked again).
    func retry(_ file: UncoveredFile) async {
        await model.retryNotCovered(file)
        adoptModelToast()
    }

    /// Try Again on every listed file.
    func retryAllNotCovered() async {
        await model.retryAllNotCovered()
        adoptModelToast()
    }

    /// Reveals the file that should hold the covered picture (or the caught file, for a clean copy never written).
    func showInFinder(_ file: UncoveredFile) {
        let fm = FileManager.default
        if fm.fileExists(atPath: file.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file.fileURL])
        } else if sourceExists(file) {
            NSWorkspace.shared.activateFileViewerSelecting([file.sourceURL])
        } else {
            push(String(localized: "Couldn't find \(file.displayName). It was moved or deleted."), isError: true)
        }
    }

    /// Dismiss: the file leaves the list as it is. ⌘Z and the toast's Undo list it again exactly as it was.
    func dismiss(_ file: UncoveredFile) async {
        await model.dismissNotCovered(file)
        let undo: @MainActor () async -> Void = { [weak self] in await self?.model.restoreNotCovered(file) }
        push(String(localized: "Dismissed \(file.displayName)"), undo: undo)
        registerUndo(String(localized: "Dismiss"), ticket: ladder.first?.ticket, undo: undo,
                     redo: { [weak self] in await self?.model.dismissNotCovered(file) }, alsoOnLadder: true)
    }

    /// The Not checked list as the window shows it: most recently seen first, narrowed by the search field.
    var visibleUnchecked: [UncheckedFile] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.status.unchecked.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    /// Whether the file is still where it was. A moved or deleted one cannot be checked again or shown in Finder; it can
    /// only be dismissed.
    func fileExists(_ file: UncheckedFile) -> Bool { FileManager.default.fileExists(atPath: file.fileURL.path) }

    /// Goes where a router request says: the Not checked section, or the catches (leaving Not checked, and leaving a
    /// filter that would hide the entry asked for).
    func open(_ destination: JournalDestination) {
        switch destination {
        case .notChecked:
            sidebar = .notChecked
        case .notCovered:
            sidebar = .notCovered
        case .catches(let entryID):
            if sidebar.listsFiles { sidebar = .all }
            if let entryID, let entry = entry(entryID), !sidebar.matches(entry, verdict: model.verdict(for: entry)) { sidebar = .all }
        }
    }

    /// Check Again on one file: it goes back through the engine and leaves the list when that check reaches a verdict.
    func checkAgain(_ file: UncheckedFile) async {
        guard fileExists(file) else {
            push(String(localized: "Couldn't find \(file.displayName). It was moved or deleted."), isError: true)
            return
        }
        await model.checkAgain(file)
        push(String(localized: "Checking \(file.displayName) again"))
    }

    /// Check All Again: every listed file goes back through the engine.
    func checkAllAgain() async {
        let n = await model.checkAgain()
        guard n > 0 else { return }
        push(n == 1 ? String(localized: "Checking 1 image again") : String(localized: "Checking \(n) images again"))
    }

    /// Reveals the file in Finder, or says it is gone.
    func showInFinder(_ file: UncheckedFile) {
        guard fileExists(file) else {
            push(String(localized: "Couldn't find \(file.displayName). It was moved or deleted."), isError: true)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([file.fileURL])
    }

    /// Dismiss: the file leaves the list without a check. ⌘Z and the toast's Undo list it again exactly as it was.
    func dismiss(_ file: UncheckedFile) async {
        await model.dismissUnchecked(file)
        let undo: @MainActor () async -> Void = { [weak self] in await self?.model.restoreUnchecked(file) }
        push(String(localized: "Dismissed \(file.displayName)"), undo: undo)
        registerUndo(String(localized: "Dismiss"), ticket: ladder.first?.ticket, undo: undo,
                     redo: { [weak self] in await self?.model.dismissUnchecked(file) }, alsoOnLadder: true)
    }

    /// Entries per verdict across the whole Journal: the sidebar's "By state" numbers.
    var stateCounts: (safe: Int, leftVisible: Int, original: Int) {
        (count(.safe), count(.leftVisible), count(.original))
    }

    /// "8 screenshots · 23 secrets" for what the grid shows, or the empty sentence.
    var statsLine: String {
        if sidebar == .notChecked { return JournalFormat.notChecked(model.status.unchecked.count) }
        if sidebar == .notCovered { return JournalFormat.notCovered(model.status.uncovered.count) }
        if model.entries.isEmpty { return String(localized: "No screenshots yet") }
        let shown = visibleEntries
        return "\(JournalFormat.screenshots(shown.count)) · \(ProtectionCopy.secrets(shown.reduce(0) { $0 + $1.findings.count }))"
    }

    /// The day header's small line: counts, or "originals delete today" when that day's originals expire before midnight.
    func dayLine(_ group: DayGroup) -> String {
        let n = JournalFormat.screenshots(group.entries.count)
        let current = now()
        let isToday = calendar.isDate(group.day, inSameDayAs: current)
        if !isToday, let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: current)),
           group.entries.contains(where: { JournalFormat.expiry(of: $0, retention: retention) < endOfToday }) {
            return "\(n) · \(String(localized: "originals delete today"))"
        }
        return "\(n) · \(ProtectionCopy.secrets(group.entries.reduce(0) { $0 + $1.findings.count }))"
    }

    /// The combined verdict of several entries, counted finding by finding.
    func combinedVerdict(_ entries: [Entry]) -> Verdict {
        Verdict(enabled: entries.reduce(0) { $0 + $1.enabledFindings.count }, total: entries.reduce(0) { $0 + $1.findings.count })
    }

    func batchSummary(_ entries: [Entry]) -> String {
        var safe = 0, left = 0, original = 0
        for e in entries {
            switch model.verdict(for: e) {
            case .safeToShare: safe += 1
            case .leftVisible: left += 1
            case .originalShowing: original += 1
            }
        }
        return JournalFormat.batchSummary(safe: safe, leftVisible: left, original: original)
    }

    var isPeeking: Bool { peekLatched || peekHeld }

    var canUndo: Bool { (undoManager?.canUndo ?? false) || ladder.contains { $0.undo != nil } }

    // MARK: Images

    /// The image to draw for `entry`: its original, or its clean image at the newest revision loaded so far (which,
    /// right after an edit, is the previous revision until `loadImage` has decoded the new one).
    func image(for entry: Entry, original: Bool = false) -> NSImage? {
        original ? originalImages[entry.id] : cleanImages[entry.id]?.image
    }

    /// Whether the image on screen for `entry` is its current revision.
    func showsCurrentImage(of entry: Entry) -> Bool { cleanImages[entry.id]?.revision == entry.revision }

    func loadImage(for entry: Entry, original: Bool = false) async {
        let key = ImageKey(id: entry.id, revision: original ? 0 : entry.revision, original: original)
        if original ? originalImages[entry.id] != nil : showsCurrentImage(of: entry) { return }
        guard !loadingImages.contains(key) else { return }
        loadingImages.insert(key)
        defer { loadingImages.remove(key) }
        guard let image = await model.thumbnail(for: entry, original: original) else { return }
        if original {
            originalImages[entry.id] = image
            return
        }
        // A slower load of an older revision never replaces a newer image.
        let shown = cleanImages[entry.id]
        if let shown, shown.revision >= entry.revision { return }
        let loaded = LoadedImage(revision: entry.revision, image: image)
        if shown == nil {
            cleanImages[entry.id] = loaded   // the first image of an entry appears at once, never faded in
        } else {
            OMotion.withFade(reduceMotion: reduceMotion()) { cleanImages[entry.id] = loaded }
        }
    }

    func loadFileSize(for entry: Entry) async {
        guard fileSizes[entry.id] == nil,
              let url = try? await model.journal.originalURL(entry.id),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return }
        fileSizes[entry.id] = size.int64Value
    }

    /// Loads every visible thumbnail and the selection's originals and sizes (used before a snapshot and on appear).
    func preload(selection: Set<UUID>) async {
        for entry in visibleEntries { await loadImage(for: entry) }
        for entry in entries(selection) {
            await loadImage(for: entry, original: true)
            await loadFileSize(for: entry)
        }
    }

    // MARK: Style draft

    /// The style the inspector edits: the draft when one is open for this revision, else the entry's own.
    func style(for entry: Entry) -> StyleRecord {
        if let styleDraft, styleDraftSource == ImageKey(id: entry.id, revision: entry.revision, original: false) { return styleDraft }
        return entry.style
    }

    func editStyle(of entry: Entry, _ change: (inout StyleRecord) -> Void) {
        var s = style(for: entry)
        change(&s)
        styleDraft = s
        styleDraftSource = ImageKey(id: entry.id, revision: entry.revision, original: false)
    }

    /// Applies the draft to the entry when it differs from what the entry has.
    func commitStyle(of entry: Entry) async {
        guard let draft = styleDraft, styleDraftSource?.id == entry.id, !draft.sameAppearance(as: entry.style) else { return }
        await applyStyle(draft, to: [entry.id], announce: false)
        styleDraft = nil
        styleDraftSource = nil
    }

    // MARK: Verbs

    /// Flips one finding between blacked out and left visible.
    func toggleFinding(_ finding: Finding, in entryID: UUID) async {
        let target = !finding.enabled
        await model.setFinding(finding.id, enabled: target, in: entryID)
        adoptModelToast()
        let name = target ? String(localized: "Black Out") : String(localized: "Leave Visible")
        registerUndo(name, undo: { [weak self] in await self?.model.setFinding(finding.id, enabled: !target, in: entryID) },
                     redo: { [weak self] in await self?.model.setFinding(finding.id, enabled: target, in: entryID) })
    }

    /// Select All (cover every finding) or Deselect All (leave every finding visible) in one entry.
    func setAllFindings(in entryID: UUID, enabled: Bool) async {
        guard let entry = entry(entryID) else { return }
        let changing = entry.findings.filter { $0.enabled != enabled }.map(\.id)
        guard !changing.isEmpty else { return }
        await setFindings(changing, enabled: enabled, in: entryID)
        adoptModelToast()
        let name = enabled ? String(localized: "Select All") : String(localized: "Deselect All")
        registerUndo(name, undo: { [weak self] in await self?.setFindings(changing, enabled: !enabled, in: entryID) },
                     redo: { [weak self] in await self?.setFindings(changing, enabled: enabled, in: entryID) })
    }

    private func setFindings(_ ids: [UUID], enabled: Bool, in entryID: UUID) async {
        for id in ids { await model.setFinding(id, enabled: enabled, in: entryID) }
    }

    /// Restore Original: every finding is left visible and, where the caught file exists, its original bytes go back.
    /// Undo covers again exactly the findings that were covered before.
    func restoreOriginals(_ ids: [UUID]) async {
        // One question for the whole selection when the user wants Undo to ask first (G-19 #11).
        guard await model.mayUndo(ids) else { return }
        let covered = await performRestore(ids)
        if adoptModelToast() { return }
        let names = ids.compactMap { entry($0)?.displayName }
        let text = names.count == 1 ? String(localized: "Restored original of \(names[0])")
                                    : String(localized: "Restored \(ids.count) originals")
        let undo: @MainActor () async -> Void = { [weak self] in
            guard let self else { return }
            for (id, findings) in covered {
                // All were covered before: one exact redo. Some were left visible: cover just those again.
                if let entry = self.entry(id), findings.count == entry.findings.count { await self.model.blackOutAll(id) }
                else { await self.setFindings(findings, enabled: true, in: id) }
            }
        }
        push(text, undo: undo)
        registerUndo(String(localized: "Restore Original"), ticket: ladder.first?.ticket, undo: undo,
                     redo: { [weak self] in _ = await self?.performRestore(ids) }, alsoOnLadder: true)
    }

    /// Leaves every finding visible and writes the original bytes back; returns what was covered before, per entry.
    private func performRestore(_ ids: [UUID]) async -> [UUID: [UUID]] {
        var covered: [UUID: [UUID]] = [:]
        for id in ids {
            guard let entry = entry(id) else { continue }
            // One engine call: every finding visible, the original delivered to the file or the clipboard.
            if await model.restoreOriginal(id) { covered[id] = entry.enabledFindings.map(\.id) }
        }
        return covered
    }

    /// Black Out All / Black Out Again: every finding covered. Undo leaves visible again what was visible before.
    func blackOutAll(_ ids: [UUID]) async {
        var visible: [UUID: [UUID]] = [:]
        for id in ids {
            guard let entry = entry(id) else { continue }
            visible[id] = entry.findings.filter { !$0.enabled }.map(\.id)
        }
        await performBlackOut(ids)
        if adoptModelToast() { return }
        let total = visible.values.reduce(0) { $0 + $1.count }
        guard total > 0 else { return }
        let text = ids.count == 1 ? String(localized: "Blacked out \(ProtectionCopy.secrets(total)) again")
                                  : String(localized: "Blacked out every secret in \(JournalFormat.screenshots(ids.count))")
        let undo: @MainActor () async -> Void = { [weak self] in
            for (id, findings) in visible { await self?.setFindings(findings, enabled: false, in: id) }
        }
        push(text, undo: undo)
        registerUndo(String(localized: "Black Out All"), ticket: ladder.first?.ticket, undo: undo,
                     redo: { [weak self] in await self?.performBlackOut(ids) }, alsoOnLadder: true)
    }

    private func performBlackOut(_ ids: [UUID]) async {
        for id in ids { await model.blackOutAll(id) }
    }

    /// Re-renders entries with `style`. Undo puts each entry's previous style back.
    func applyStyle(_ style: StyleRecord, to ids: [UUID], announce: Bool) async {
        var previous: [UUID: StyleRecord] = [:]
        for id in ids {
            guard let entry = entry(id) else { continue }
            previous[id] = entry.style
        }
        await performStyle(style, ids)
        if adoptModelToast() { return }
        let undo: @MainActor () async -> Void = { [weak self] in
            for (id, s) in previous { await self?.model.setStyle(s, for: id) }
        }
        if announce {
            push(ids.count == 1 ? String(localized: "Applied the default style")
                                : String(localized: "Applied the default style to \(JournalFormat.screenshots(ids.count))"), undo: undo)
        }
        registerUndo(String(localized: "Change Style"), ticket: announce ? ladder.first?.ticket : nil, undo: undo,
                     redo: { [weak self] in await self?.performStyle(style, ids) }, alsoOnLadder: announce)
    }

    private func performStyle(_ style: StyleRecord, _ ids: [UUID]) async {
        for id in ids { await model.setStyle(style, for: id) }
    }

    func applyDefaultStyle(to ids: [UUID]) async {
        do {
            let style = try await model.journal.defaultStyle()
            await applyStyle(style, to: ids, announce: true)
        } catch {
            push(String(localized: "Couldn't read the default style."), isError: true)
        }
    }

    /// Makes this entry's style the one new catches get.
    func saveAsDefault(_ entry: Entry) async {
        let style = style(for: entry)
        do {
            let previous = try await model.journal.defaultStyle()
            try await model.journal.setDefaultStyle(style)
            let undo: @MainActor () async -> Void = { [weak self] in try? await self?.model.journal.setDefaultStyle(previous) }
            push(String(localized: "New catches will use this style"), undo: undo)
            registerUndo(String(localized: "Save as Default"), ticket: ladder.first?.ticket, undo: undo,
                         redo: { [weak self] in try? await self?.model.journal.setDefaultStyle(style) }, alsoOnLadder: true)
        } catch {
            push(String(localized: "Couldn't save the default style."), isError: true)
        }
    }

    /// Moves entries to the Journal's trash. ⌘Z and the toast's Undo bring them back.
    func delete(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        let done = await performDelete(ids)
        let message = model.toast
        model.toast = nil
        // Fail-open #12: the toast says what was really deleted; nothing deleted is an error with nothing to undo.
        guard !done.isEmpty else {
            push(message?.text ?? String(localized: "Couldn't delete the screenshot."), isError: true)
            return
        }
        let text = message?.text ?? (done.count == 1 ? String(localized: "Screenshot deleted") : String(localized: "\(done.count) screenshots deleted"))
        let undo: @MainActor () async -> Void = { [weak self] in
            await self?.model.restore(done)
            self?.adoptModelToast()
        }
        push(text, isError: message?.isError ?? false, undo: undo)
        registerUndo(String(localized: "Delete"), ticket: ladder.first?.ticket, undo: undo,
                     redo: { [weak self] in await self?.performDelete(done); self?.adoptModelToast() }, alsoOnLadder: true)
    }

    @discardableResult
    private func performDelete(_ ids: [UUID]) async -> [UUID] { await model.trash(ids) }

    // MARK: Uncovered key text (G-17)

    /// The switch in Settings → Journal & Privacy.
    var showsKeyText: Bool { model.settings.showsUncoveredKeyText }

    /// What the field under `finding` shows; nil when there is no field.
    func keyTextState(for finding: Finding) -> KeyTextState? { keyTexts.state(for: finding, switchOn: showsKeyText) }

    /// Starts reading `finding`'s key when its field shows.
    func requestKeyText(_ finding: Finding, in entryID: UUID) { keyTexts.request(finding, in: entryID, switchOn: showsKeyText) }

    /// Drops every text the inspector no longer shows: findings covered again or gone, findings of an entry no longer the
    /// single selection (the inspector shows fields for one entry only), or all of them when the switch is off.
    func syncKeyTexts(selection: Set<UUID>) {
        let shown = selection.count == 1 ? entries(selection) : []
        keyTexts.sync(shown.flatMap(\.findings), switchOn: showsKeyText)
    }

    /// Copy beside the key: the text goes on the clipboard marked concealed, and the ladder says so.
    func copyKeyText(_ findingID: UUID, to pasteboard: NSPasteboard = .general) {
        if keyTexts.copy(findingID, to: pasteboard) { push(KeyTextCopy.copied) } else { push(KeyTextCopy.copyFailed, isError: true) }
    }

    // MARK: Copy, reveal, import

    func copyClean(_ id: UUID) async {
        guard let entry = entry(id), model.verdict(for: entry).isSafe else { return }
        await model.copy(id, original: false)
        adoptModelToast()
    }

    func copyOriginal(_ id: UUID) async {
        await model.copy(id, original: true)
        adoptModelToast()
    }

    /// Copies the file as it is now; when secrets are left visible the toast says so instead of "clean".
    func copyAsShown(_ id: UUID) async {
        guard let entry = entry(id) else { return }
        await model.copy(id, original: false)
        let verdict = model.verdict(for: entry)
        if let toast = model.toast, !toast.isError, !verdict.isSafe {
            model.toast?.text = String(localized: "Copied as shown. \(verdict.title).")
        }
        adoptModelToast()
    }

    /// Reveals the caught file when it still exists, else the Journal's clean copy.
    func showInFinder(_ id: UUID) async {
        guard let entry = entry(id) else { return }
        // The clean copy beside the file in keep-both mode (gone after an Undo, #17), else the caught file itself.
        if let path = [entry.cleanCopyPath, entry.filePath].compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else if let url = try? await model.journal.cleanURL(id) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            push(String(localized: "Couldn't find the file."), isError: true)
        }
    }

    /// The folder that holds the originals.
    func originalsFolder() async -> URL? {
        if let store = model.journal as? SQLiteJournalStore { return store.journalRoot }
        guard let first = model.entries.first, let url = try? await model.journal.originalURL(first.id) else { return nil }
        return url.deletingLastPathComponent().deletingLastPathComponent()
    }

    func openOriginalsFolder() async {
        guard let folder = await originalsFolder() else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Whether a dropped or chosen file is already in the Journal (one of its own files, or a caught file it tracks).
    func isJournaled(_ url: URL) async -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let folder = await originalsFolder() {
            let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
            if path.hasPrefix(root + "/") { return true }
        }
        return model.entries.contains { e in
            [e.filePath, e.cleanCopyPath].compactMap { $0 }.contains { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path == path }
        }
    }

    /// Imports images; files already in the Journal are skipped. Returns the new entries' ids (newest first).
    @discardableResult
    func importFiles(_ urls: [URL]) async -> [UUID] {
        let images = urls.filter { url in
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
            return type?.conforms(to: .image) ?? false
        }
        guard !images.isEmpty else {
            push(String(localized: "Only images can be imported."), isError: true)
            return []
        }
        var fresh: [URL] = [], skipped = 0
        for url in images { if await isJournaled(url) { skipped += 1 } else { fresh.append(url) } }
        guard !fresh.isEmpty else {
            push(String(localized: "That's already in the Journal."))
            return []
        }
        let before = Set(model.entries.map(\.id))
        await model.importImages(fresh)
        let added = model.entries.filter { !before.contains($0.id) }.map(\.id)
        var text: String
        if added.isEmpty {
            text = fresh.count == 1 ? String(localized: "No secrets found in that image.")
                                    : String(localized: "No secrets found in those \(fresh.count) images.")
        } else {
            text = added.count == 1 ? String(localized: "Imported 1 screenshot") : String(localized: "Imported \(added.count) screenshots")
        }
        if skipped > 0 { text += " · " + String(localized: "\(skipped) already in the Journal") }
        push(text)
        return added
    }

    /// Removes entries whose stored files vanished, and says so.
    func sweepStale() async {
        guard let removed = try? await model.journal.sweepStale(), removed > 0 else { return }
        await model.reloadEntries()
        push(removed == 1 ? String(localized: "Removed 1 screenshot whose file was deleted")
                          : String(localized: "Removed \(removed) screenshots whose files were deleted"))
    }

    // MARK: Settings write-through

    func setViewMode(_ mode: JournalView) {
        viewMode = mode
        model.updateSettings { $0.journalView = mode }
    }

    /// Shows or hides the inspector: at once by default (G-15), or with the system slide when the user chose it
    /// (G-19 T-8); instant under Reduce Motion either way.
    func setShowsInspector(_ shows: Bool, reduceMotion: Bool = OMotion.systemReduceMotion) {
        withAnimation(InspectorMotionRule.animation(model.settings.journalInspectorMotion, reduceMotion: reduceMotion)) {
            showsInspector = shows
        }
        model.updateSettings { $0.journalShowsInspector = shows }
    }

    // MARK: Selection helpers

    /// The new selection after a click on `id` with the given modifiers (⌘ toggles, ⇧ extends a range).
    func selection(afterClicking id: UUID, in current: Set<UUID>, command: Bool, shift: Bool) -> Set<UUID> {
        if command {
            selectionAnchor = id
            var s = current
            if s.contains(id) { s.remove(id) } else { s.insert(id) }
            return s
        }
        if shift, let anchor = selectionAnchor {
            let order = visibleEntries.map(\.id)
            if let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
                return current.union(order[min(a, b)...max(a, b)])
            }
        }
        selectionAnchor = id
        return [id]
    }

    /// Arrow-key movement: ±1 sideways, ± a row of the grid (or ±1 in the list) up and down.
    func selection(moving step: Int, vertical: Bool, from current: Set<UUID>) -> Set<UUID> {
        let order = visibleEntries.map(\.id)
        guard !order.isEmpty else { return [] }
        let delta = vertical && viewMode == .grid ? step * max(gridColumns, 1) : step
        let anchor = selectionAnchor.flatMap { order.firstIndex(of: $0) } ?? order.firstIndex { current.contains($0) }
        guard let start = anchor else { selectionAnchor = order[0]; return [order[0]] }
        let next = order[min(max(start + delta, 0), order.count - 1)]
        selectionAnchor = next
        return [next]
    }

    // MARK: Ladder and undo

    /// Moves the model's pending toast (if any) onto this window's ladder. Returns true when it was an error.
    @discardableResult
    func adoptModelToast() -> Bool {
        guard let toast = model.toast else { return false }
        model.toast = nil
        push(toast.text, isError: toast.isError)
        return toast.isError
    }

    func push(_ text: String, isError: Bool = false, undo: (@MainActor () async -> Void)? = nil) {
        let item = LadderItem(text: text, isError: isError, undo: undo)
        ladder.insert(item, at: 0)
        if ladder.count > 3 { ladder.removeLast(ladder.count - 3) }
        let lifetime = toastLifetime
        Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            self?.dismiss(item.id)
        }
    }

    func dismiss(_ id: LadderItem.ID) { ladder.removeAll { $0.id == id } }

    /// Undoes one ladder item (its own Undo button) and withdraws its ⌘Z registration.
    func undo(_ id: LadderItem.ID) async {
        guard let item = ladder.first(where: { $0.id == id }), let undo = item.undo else { return }
        ladder.removeAll { $0.id == id }
        undoManager?.removeAllActions(withTarget: item.ticket)
        await undo()
    }

    /// ⌘Z: the window's undo manager when there is one, else the newest undoable toast.
    func undoLatest() async {
        if let um = undoManager, um.canUndo { um.undo(); return }
        if let item = ladder.first(where: { $0.undo != nil }) { await undo(item.id) }
    }

    /// Registers `undo` (and its `redo`) with the window's undo manager. When `alsoOnLadder` is set the newest ladder
    /// item is the same change, so performing the undo here removes that toast.
    private func registerUndo(_ name: String, ticket: UndoTicket? = nil, undo: @escaping @MainActor () async -> Void,
                              redo: @escaping @MainActor () async -> Void, alsoOnLadder: Bool = false) {
        guard let um = undoManager else { return }
        let target = ticket ?? UndoTicket()
        let ladderID = alsoOnLadder ? ladder.first?.id : nil
        um.registerUndo(withTarget: target) { [weak self] _ in
            MainActor.assumeIsolated {
                if let ladderID { self?.dismiss(ladderID) }
                Task { await undo() }
                self?.registerRedo(name, target: target, redo: redo, undo: undo)
            }
        }
        um.setActionName(name)
    }

    private func registerRedo(_ name: String, target: UndoTicket, redo: @escaping @MainActor () async -> Void,
                              undo: @escaping @MainActor () async -> Void) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: target) { [weak self] _ in
            MainActor.assumeIsolated {
                Task { await redo() }
                self?.registerUndo(name, ticket: target, undo: undo, redo: redo)
            }
        }
        um.setActionName(name)
    }
}
