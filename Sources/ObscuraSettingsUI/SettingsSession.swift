// The list-shaped settings the Detectors, Custom Rules and Redaction Style panes edit. They live in the Journal's
// SQLite (G-3), not in `Settings`; this object mirrors them for one Settings window and writes every change back
// through `model.journal`. Scalar settings never pass through here: they go through `model.updateSettings`.
import Foundation
import Observation
import ObscuraDetect
import ObscuraEngine
import ObscuraJournal
import ObscuraSupport

@MainActor
@Observable
final class SettingsSession {
    let journal: any JournalStore
    /// Called after every change that alters what the scanner runs (detector state, overrides, rules, imports).
    var onCatalogueChange: @MainActor () -> Void = {}

    private(set) var loaded = false
    /// The last load failed; the panes that edit these lists offer Try Again instead of showing defaults.
    private(set) var loadFailed = false
    /// Detector id → enabled, as stored. Absent ids use the detector's default.
    private(set) var detectorState: [String: Bool] = [:]
    /// Detector id → replacement patterns, decoded from the stored JSON.
    private(set) var overrides: [String: [PatternSpec]] = [:]
    /// Overrides whose stored JSON could not be decoded. The detector shows Edited; Reset clears it.
    private(set) var undecodableOverrides: Set<String> = []
    private(set) var rules: [RuleRecord] = []
    /// Rules whose value can't be read on this Mac (G-30): listed apart with Re-enter and Delete, never compiled.
    private(set) var unreadableRules: [UnreadableRule] = []
    private(set) var defaultStyle: StyleRecord = .builtInDefault
    /// Bumped on every reload so editors holding drafts know the stored lists changed under them.
    private(set) var revision = 0
    /// A message for the window to show once: a failed write or an import summary.
    var notice: String? {
        didSet { if notice != nil { noticeID = UUID() } }
    }
    /// A new id each time a notice is raised, so the same words raised again are a new toast with its own lifetime.
    private(set) var noticeID = UUID()
    /// Bumped by every change to the lists, so the test footer recompiles once per change, never per keystroke.
    private(set) var changeCount = 0
    @ObservationIgnored private var catalogueCache: (stamp: Int, catalogue: CompiledCatalogue?)?

    static let builtIn: [Detector] = Catalogue.builtIn
    static let builtInByID: [String: Detector] = Dictionary(uniqueKeysWithValues: Catalogue.builtIn.map { ($0.id, $0) })

    init(journal: any JournalStore) {
        self.journal = journal
    }

    // MARK: Loading

    func load() async {
        do {
            let state = try await journal.detectorState()
            let records = try await journal.overrides()
            let unreadableOverrides = try await journal.unreadableOverrides()
            let rules = try await journal.rules()
            let style = try await journal.defaultStyle()
            var decoded: [String: [PatternSpec]] = [:]
            var bad: Set<String> = []
            for record in records {
                if let specs = try? JSONDecoder().decode([PatternSpec].self, from: Data(record.specsJSON.utf8)) {
                    decoded[record.detectorID] = specs
                } else {
                    bad.insert(record.detectorID)
                }
            }
            // F15: a sealed list that cannot be read on this Mac is shown like one that does not decode.
            for override in unreadableOverrides { bad.insert(override.detectorID) }
            detectorState = state
            overrides = decoded
            undecodableOverrides = bad
            self.rules = rules.compactMap(\.readable).sorted { $0.sortOrder < $1.sortOrder }
            unreadableRules = rules.compactMap(\.unreadable).sorted { $0.sortOrder < $1.sortOrder }
            defaultStyle = style
            loaded = true
            loadFailed = false
            revision += 1
            changeCount &+= 1
        } catch {
            Log.app.error("settings lists failed to load")
            loadFailed = true
            notice = String(localized: "Couldn’t read your detector and rule settings.")
        }
    }

    // MARK: Detectors

    func isOn(_ detector: Detector) -> Bool { detectorState[detector.id] ?? detector.enabledByDefault }

    var onCount: Int { Self.builtIn.filter(isOn).count }
    var totalCount: Int { Self.builtIn.count }

    func detectors(in category: Detector.Category) -> [Detector] { Self.builtIn.filter { $0.category == category } }

    func onCount(in category: Detector.Category) -> Int { detectors(in: category).filter(isOn).count }

    func isEdited(_ id: String) -> Bool { overrides[id] != nil || undecodableOverrides.contains(id) }

    var editedCount: Int { Self.builtIn.filter { isEdited($0.id) }.count }
    var offCount: Int { totalCount - onCount }

    /// The patterns a detector runs: its override when there is one, else the built-in list.
    func patterns(for detector: Detector) -> [PatternSpec] { overrides[detector.id] ?? detector.patterns }

    func setEnabled(_ id: String, _ enabled: Bool) async {
        detectorState[id] = enabled
        changeCount &+= 1
        do {
            try await journal.setDetectorEnabled(id, enabled: enabled)
            onCatalogueChange()
        } catch { await recover(String(localized: "Couldn’t change that detector.")) }
    }

    /// Turns every detector of a category on or off.
    func setCategory(_ category: Detector.Category, _ enabled: Bool) async {
        let ids = detectors(in: category).map(\.id)
        for id in ids { detectorState[id] = enabled }
        changeCount &+= 1
        do {
            for id in ids { try await journal.setDetectorEnabled(id, enabled: enabled) }
            onCatalogueChange()
        } catch { await recover(String(localized: "Couldn’t change that category.")) }
    }

    /// Stores a detector's patterns. A list equal to the built-in one clears the override, so "Edited" always means
    /// "differs from the built-in". Throws the first pattern error without writing: an override that does not
    /// compile would drop the whole detector from the scan (`Catalogue.resolved`).
    func savePatterns(_ specs: [PatternSpec], for detector: Detector) async throws {
        for spec in specs { _ = try spec.compiledPattern() }
        if specs == detector.patterns {
            guard isEdited(detector.id) else { return }
            await reset(detector)
            return
        }
        guard overrides[detector.id] != specs || undecodableOverrides.contains(detector.id) else { return }
        let data = try JSONEncoder().encode(specs)
        overrides[detector.id] = specs
        undecodableOverrides.remove(detector.id)
        changeCount &+= 1
        do {
            try await journal.setOverride(detector.id, specsJSON: String(decoding: data, as: UTF8.self))
            onCatalogueChange()
        } catch { await recover(String(localized: "Couldn’t save that pattern.")) }
    }

    func reset(_ detector: Detector) async {
        overrides[detector.id] = nil
        undecodableOverrides.remove(detector.id)
        changeCount &+= 1
        do {
            try await journal.clearOverride(detector.id)
            onCatalogueChange()
        } catch { await recover(String(localized: "Couldn’t reset that detector.")) }
    }

    // MARK: Custom rules

    var blackOutRules: [RuleRecord] { rules.filter { $0.action == .blackOut } }
    var allowRules: [RuleRecord] { rules.filter { $0.action == .allow } }

    /// Adds or replaces a rule. New rules go last.
    func saveRule(_ rule: RuleRecord) async {
        await storeRule(stageRule(rule))
    }

    /// The list half of a save, applied at once: the rule shows in the list in the same frame the editor closes, so
    /// no interim state (the empty "no rules" page, a list that shifts twice) is ever drawn (recon T-15). Returns the
    /// rule as stored (a new one gets the last sort order).
    @discardableResult
    func stageRule(_ rule: RuleRecord) -> RuleRecord {
        var rule = rule
        if let i = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[i] = rule
        } else if let i = unreadableRules.firstIndex(where: { $0.id == rule.id }) {
            // Re-entered (G-30): it takes the unreadable rule's place, order included.
            rule.sortOrder = unreadableRules[i].sortOrder
            unreadableRules.remove(at: i)
            rules.append(rule)
            rules.sort { $0.sortOrder < $1.sortOrder }
        } else {
            rule.sortOrder = RuleOrder.next(after: rules.map(\.sortOrder) + unreadableRules.map(\.sortOrder))   // F16: never traps
            rules.append(rule)
        }
        changeCount &+= 1
        return rule
    }

    /// The store half of a save.
    func storeRule(_ rule: RuleRecord) async {
        do {
            try await journal.upsertRule(rule)
            onCatalogueChange()
        } catch { await recover(String(localized: "Couldn’t save that rule.")) }
    }

    func setRuleEnabled(_ id: String, _ enabled: Bool) async {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[i].enabled = enabled
        await saveRule(rules[i])
    }

    func deleteRule(_ id: String) async {
        stageDeletion(id)
        await storeDeletion(id)
    }

    /// The list half of a delete, applied at once (see `stageRule`).
    func stageDeletion(_ id: String) {
        rules.removeAll { $0.id == id }
        unreadableRules.removeAll { $0.id == id }
        changeCount &+= 1
    }

    /// The store half of a delete.
    func storeDeletion(_ id: String) async {
        do {
            try await journal.deleteRule(id)
            onCatalogueChange()
        } catch { await recover(String(localized: "Couldn’t delete that rule.")) }
    }

    /// The rules document with plain values (G-30: the user's explicit act, to a file they choose; the save panel says
    /// so). Unreadable rules are left out of it.
    func exportRules() async throws -> Data { try await journal.exportRules() }

    /// Imports a rules document, then reloads every list it may have touched.
    func importRules(_ data: Data) async throws -> ImportReport {
        let report = try await journal.importRules(data)
        await load()
        onCatalogueChange()
        return report
    }

    /// How many rules and edited detectors `report` brought in that the catalogue cannot use: their pattern does not
    /// compile, or is refused as too long or too slow to check (security scan F23). Such a rule never runs; an edited
    /// detector runs on its built-in patterns. Counted for the import notice.
    func unusableImports(_ report: ImportReport) -> Int {
        guard let catalogue = compiledCatalogue() else { return 0 }
        var ruleIDs = report.rulesAdded + report.rulesRecovered
        var overrideIDs = report.overridesAdded
        if report.policy == .preferIncoming {
            for conflict in report.conflicts {
                switch conflict {
                case .rule(let id, _, _): ruleIDs.append(id)
                case .override(let id, _, _): overrideIDs.append(id)
                case .detectorState, .defaultStyle: break
                }
            }
        }
        let rules = Set(ruleIDs.compactMap { UUID(uuidString: String($0.dropFirst("custom.".count)))?.uuidString })
        return rules.filter { catalogue.compileErrors[$0] != nil }.count
            + Set(overrideIDs).filter { catalogue.overrideErrors[$0] != nil }.count
    }

    // MARK: Style

    func setDefaultStyle(_ style: StyleRecord) async {
        var style = style
        style.isDefault = true
        defaultStyle = style
        do { try await journal.setDefaultStyle(style) }
        catch { await recover(String(localized: "Couldn’t save the style.")) }
    }

    // MARK: Catalogue

    /// The catalogue exactly as the engine would build it from what is stored now, for the test footer.
    func compiledCatalogue() -> CompiledCatalogue? {
        if let cache = catalogueCache, cache.stamp == changeCount { return cache.catalogue }
        let catalogue = buildCatalogue()
        catalogueCache = (changeCount, catalogue)
        return catalogue
    }

    private func buildCatalogue() -> CompiledCatalogue? {
        let records = overrides.compactMap { id, specs -> OverrideRecord? in
            guard let data = try? JSONEncoder().encode(specs) else { return nil }
            return OverrideRecord(detectorID: id, specsJSON: String(decoding: data, as: UTF8.self), updatedAt: Date())
        }
        return try? CatalogueBuilder.build(rules: rules.map(StoredRule.readable), overrides: records, state: detectorState).catalogue
    }

    // MARK: Errors

    private func recover(_ message: String) async {
        Log.app.error("settings write failed")
        notice = message
        await load()
    }
}
