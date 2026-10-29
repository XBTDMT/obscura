import Testing
import Foundation
import AppKit
@testable import ObscuraViewerUI
import ObscuraUIKit
import ObscuraJournal
import ObscuraPrefs

// MARK: - Zoom math

@Suite struct ZoomMathTests {
    @Test func fitKeepsPaddingAndNeverUpscales() {
        // 1920 × 460 content in a 720 × 400 canvas with 22 pt padding: width-bound, (720 − 44) / 1920.
        let m = ZoomMath.fit(content: CGSize(width: 1920, height: 460), viewport: CGSize(width: 720, height: 400))
        #expect(abs(m - 676.0 / 1920.0) < 0.0001)
        // A small image fits at actual size, not blown up.
        #expect(ZoomMath.fit(content: CGSize(width: 200, height: 100), viewport: CGSize(width: 720, height: 400)) == 1)
        #expect(ZoomMath.fit(content: CGSize(width: 200, height: 100), viewport: CGSize(width: 720, height: 400), allowsUpscale: true) > 1)
        // Height-bound.
        let tall = ZoomMath.fit(content: CGSize(width: 400, height: 2000), viewport: CGSize(width: 720, height: 444))
        #expect(abs(tall - 400.0 / 2000.0) < 0.0001)
    }

    @Test func fitHandlesDegenerateSizes() {
        #expect(ZoomMath.fit(content: .zero, viewport: CGSize(width: 720, height: 400)) == 1)
        #expect(ZoomMath.fit(content: CGSize(width: 100_000, height: 100_000), viewport: CGSize(width: 10, height: 10)) == ZoomMath.minimum)
    }

    @Test func stepsWalkTheLadder() {
        #expect(ZoomMath.stepIn(from: 1) == 1.25)
        #expect(ZoomMath.stepOut(from: 1) == 0.75)
        // From a fitted, off-ladder value the next step is the next round one.
        #expect(ZoomMath.stepIn(from: 0.352) == 0.5)
        #expect(abs(ZoomMath.stepOut(from: 0.352) - 1.0 / 3.0) < 1e-9)
        // Bounds hold.
        #expect(ZoomMath.stepIn(from: 16) == 16)
        #expect(ZoomMath.stepOut(from: 0.05) == 0.05)
        // In then out returns to the same step.
        #expect(ZoomMath.stepOut(from: ZoomMath.stepIn(from: 2)) == 2)
    }

    @Test func commandScrollZoomsSmoothlyAndClamps() {
        #expect(ZoomMath.scrolled(from: 1, deltaY: 10, precise: true) > 1)
        #expect(ZoomMath.scrolled(from: 1, deltaY: -10, precise: true) < 1)
        #expect(abs(ZoomMath.scrolled(from: 1, deltaY: 10, precise: true) * ZoomMath.scrolled(from: 1, deltaY: -10, precise: true) - 1) < 0.0001)
        #expect(ZoomMath.scrolled(from: 15, deltaY: 1000, precise: false) == ZoomMath.maximum)
        #expect(ZoomMath.scrolled(from: 0.06, deltaY: -1000, precise: false) == ZoomMath.minimum)
        // A line-based wheel step moves further than a trackpad pixel.
        #expect(ZoomMath.scrollFactor(deltaY: 1, precise: false) > ZoomMath.scrollFactor(deltaY: 1, precise: true))
    }

    @Test func labelSaysFitOrPercent() {
        let en = Locale(identifier: "en_US")
        #expect(ZoomMath.label(for: .fit, locale: en) == "Fit")
        #expect(ZoomMath.label(for: .scale(0.5), locale: en) == "50%")
        #expect(ZoomMath.label(for: .scale(1), locale: en) == "100%")
        #expect(ZoomMath.label(for: .scale(2.0 / 3.0), locale: en) == "67%")
    }
}

// MARK: - Mode, peek, compare, zoom state

@Suite @MainActor struct ViewerStateTests {
    private func loaded(original: Bool = true) -> ViewerState {
        let s = ViewerState()
        let img = NSImage(size: NSSize(width: 100, height: 50))
        s.install(clean: img, original: original ? img : nil, revision: 1)
        return s
    }

    @Test func tabTogglesBetweenRedactedAndOriginal() {
        let s = loaded()
        #expect(s.mode == .redacted)
        #expect(!s.showsOriginalImage)
        s.toggleMode()
        #expect(s.mode == .original)
        #expect(s.showsOriginalImage)
        s.toggleMode()
        #expect(s.mode == .redacted)
    }

    @Test func originalIsUnavailableWhenTheOriginalIsGone() {
        let s = loaded(original: false)
        s.toggleMode()
        #expect(s.mode == .redacted)
        s.beginPeek()
        #expect(!s.isPeeking)
        s.toggleCompare()
        #expect(!s.isComparing)
    }

    @Test func peekShowsTheOriginalOnlyWhileHeldAndOnlyFromRedacted() {
        let s = loaded()
        s.beginPeek()
        #expect(s.isPeeking && s.showsOriginalImage && s.mode == .redacted)
        s.endPeek()
        #expect(!s.isPeeking && !s.showsOriginalImage)
        s.setMode(.original)
        s.beginPeek()
        #expect(!s.isPeeking)
        // Switching modes ends a peek.
        s.setMode(.redacted)
        s.beginPeek()
        s.toggleMode()
        #expect(!s.isPeeking)
    }

    @Test func spaceOpensCompareAndEscapeClosesItBeforeTheWindow() {
        let s = loaded()
        s.toggleCompare()
        #expect(s.isComparing)
        #expect(!s.canZoom)
        #expect(s.handleEscape())
        #expect(!s.isComparing)
        #expect(!s.handleEscape(), "nothing left to close: the window closes")
        s.toggleCompare(); s.toggleCompare()
        #expect(!s.isComparing)
    }

    @Test func zoomCommandsStepFromTheShownMagnification() {
        let s = loaded()
        #expect(s.zoom == .fit)
        s.lastMagnification = 0.352
        s.zoomIn()
        #expect(s.zoom == .scale(0.5))
        s.lastMagnification = 0.5
        s.zoomOut()
        #expect(s.zoom == .scale(1.0 / 3.0))
        s.actualSize()
        #expect(s.zoom == .scale(1))
        s.zoomToFit()
        #expect(s.zoom == .fit)
        s.magnificationChangedByUser(40)
        #expect(s.zoom == .scale(ZoomMath.maximum))
    }

    @Test func copyTakesTheSelectionThenTheImageAsShown() {
        let s = loaded()
        #expect(s.copyTarget(liveTextSelection: nil) == .clean)
        // A selection only counts over the original (Live Text is off over the redacted image).
        #expect(s.copyTarget(liveTextSelection: "x") == .clean)
        s.setMode(.original)
        #expect(s.copyTarget(liveTextSelection: nil) == .original)
        #expect(s.copyTarget(liveTextSelection: "sk_live_EXAMPLE") == .text("sk_live_EXAMPLE"))
        s.setMode(.redacted)
        s.beginPeek()
        #expect(s.copyTarget(liveTextSelection: nil) == .original)
        s.endPeek()
        s.toggleCompare()
        #expect(s.copyTarget(liveTextSelection: nil) == .clean)
    }

    @Test func inspectorOpensItselfOnlyWhenSomethingIsLeftVisible() {
        #expect(!ViewerState.autoOpensInspector(for: .safeToShare(total: 4)))
        #expect(ViewerState.autoOpensInspector(for: .leftVisible(visible: 1, total: 4)))
        #expect(ViewerState.autoOpensInspector(for: .originalShowing(total: 4)))
        let s = loaded()
        #expect(s.windowWidth == 720)
        s.toggleInspector()
        #expect(s.showsInspector && s.windowWidth == 880)
    }

    @Test func loadReadsBothFilesFromTheJournal() async throws {
        let model = try await SampleData.model(entries: 1)
        let entry = try #require(model.entries.first)
        let s = ViewerState()
        await s.load(entry, from: model.journal)
        #expect(s.cleanImage != nil)
        #expect(s.originalImage != nil)
        #expect(s.originalAvailable)
        #expect(s.originalURL != nil)
        #expect(s.pixelSize.width > 0)
        #expect(s.loadedRevision == entry.revision)
    }
}

// MARK: - Live Text → rules

@Suite @MainActor struct LiveTextRuleTests {
    @Test func alwaysMakesALooksLikeThisBlackOutRule() async throws {
        let journal = try SampleData.makeJournal()
        let outcome = try await LiveTextRules.add("  sk_live_EXAMPLE0000000000000000 \n", intent: .alwaysBlackOut, to: journal)
        guard case .added(let rule) = outcome else { Issue.record("expected a rule, got \(outcome)"); return }
        #expect(rule.action == .blackOut)
        #expect(rule.kind == .example)
        #expect(rule.value == "sk_live_EXAMPLE0000000000000000")
        #expect(rule.id.hasPrefix("custom."))
        #expect(rule.enabled)
        let stored = try await journal.rules()
        #expect(stored.map(\.id) == [rule.id])
    }

    @Test func neverMakesAnExactTextAllowRule() async throws {
        let journal = try SampleData.makeJournal()
        let outcome = try await LiveTextRules.add("4242 4242 4242 4242", intent: .neverBlackOut, to: journal)
        guard case .added(let rule) = outcome else { Issue.record("expected a rule, got \(outcome)"); return }
        #expect(rule.action == .allow)
        #expect(rule.kind == .exactText)
        #expect(rule.value == "4242 4242 4242 4242")
    }

    @Test func duplicatesShortAndMultiLineSelectionsAreRefused() async throws {
        let journal = try SampleData.makeJournal()
        _ = try await LiveTextRules.add("jordan.reyes@example.com", intent: .neverBlackOut, to: journal)
        #expect(try await LiveTextRules.add("jordan.reyes@example.com", intent: .neverBlackOut, to: journal) == .alreadyExists)
        // The same text with the other intent is a different rule.
        if case .added = try await LiveTextRules.add("jordan.reyes@example.com", intent: .alwaysBlackOut, to: journal) {} else {
            Issue.record("the other intent should add a rule")
        }
        #expect(try await LiveTextRules.add(" ab ", intent: .alwaysBlackOut, to: journal) == .tooShort)
        #expect(try await LiveTextRules.add("first line\nsecond line", intent: .alwaysBlackOut, to: journal) == .multipleLines)
        #expect(try await journal.rules().count == 2)
    }

    @Test func newRulesGoAfterTheExistingOnes() async throws {
        let journal = try SampleData.makeJournal()
        try await journal.upsertRule(RuleRecord(action: .blackOut, kind: .prefix, value: "EXAMPLE_", createdAt: Date(), sortOrder: 7))
        let outcome = try await LiveTextRules.add("ghp_EXAMPLE00000000000000000000000000", intent: .alwaysBlackOut, to: journal)
        guard case .added(let rule) = outcome else { Issue.record("expected a rule"); return }
        #expect(rule.sortOrder == 8)
    }

    @Test func recordIsBuiltWithoutAStore() {
        let r = LiveTextRules.record(for: "\tEXAMPLEpass ", intent: .neverBlackOut, sortOrder: 3, now: Date(timeIntervalSince1970: 0))
        #expect(r?.value == "EXAMPLEpass")
        #expect(r?.sortOrder == 3)
        #expect(LiveTextRules.record(for: "no", intent: .neverBlackOut, sortOrder: 0, now: Date()) == nil)
    }

    @Test func everyOutcomeHasAMessage() {
        let rule = RuleRecord(action: .allow, kind: .exactText, value: "abc", createdAt: Date(), sortOrder: 0)
        #expect(!LiveTextRules.message(for: .added(rule), intent: .neverBlackOut).isError)
        #expect(LiveTextRules.message(for: .tooShort, intent: .alwaysBlackOut).isError)
        #expect(LiveTextRules.message(for: .multipleLines, intent: .alwaysBlackOut).isError)
        #expect(LiveTextRules.message(for: .tooShort, intent: .alwaysBlackOut).text.contains("3"))
    }

    @Test func contextMenuGainsTheTwoRuleItemsOnlyWithASelection() {
        let controller = LiveTextController()
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "c")
        // No analysis, so no selection: the menu is left as VisionKit built it.
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let out = controller.overlayView(controller.overlay, updatedMenuFor: menu, for: event, at: .zero)
        #expect(out.items.map(\.title) == ["Copy"])
        // The items themselves run their closure with the selection and intent.
        var got: (String, LiveTextRuleIntent)?
        controller.onRule = { got = ($0, $1) }
        let item = LiveTextController.ruleItem("Never Black Out This", symbol: "eye") { controller.onRule?("EXAMPLE", .neverBlackOut) }
        _ = (item.target as? NSObject)?.perform(item.action!, with: item)
        #expect(got?.0 == "EXAMPLE")
        #expect(got?.1 == .neverBlackOut)
    }
}

// MARK: - Keys, words, strip

@Suite struct ViewerKeyTests {
    /// A key press under the default bindings; `base` is what the key types with no modifier held.
    private func key(_ code: UInt16, _ base: String?, _ flags: NSEvent.ModifierFlags, _ keys: KeyBindings = .defaults) -> ViewerKey? {
        ViewerKey.command(keyCode: code, baseCharacters: base, flags: flags, bindings: keys)
    }

    @Test func shortcutTable() {
        #expect(key(48, "\t", []) == .toggleMode)
        #expect(key(49, " ", []) == .compare)
        #expect(key(53, "\u{1b}", []) == .escape)
        #expect(key(8, "c", .command) == .copy)
        #expect(key(24, "=", .command) == .zoomIn)
        // ⌘+ is typed as ⇧⌘= on most layouts: the default's alias.
        #expect(key(24, "=", [.command, .shift]) == .zoomIn)
        #expect(key(27, "-", .command) == .zoomOut)
        #expect(key(29, "0", .command) == .actualSize)
        #expect(key(25, "9", .command) == .fit)
        // ⌥I types "ˆ"; the unmodified character is still "i".
        #expect(key(34, "i", [.command, .option]) == .inspector)
        // Not ours: ⇧Tab, ⌘W, plain letters, ⌥⌘C (Copy Original lives on its button).
        #expect(key(48, "\t", .shift) == nil)
        #expect(key(13, "w", .command) == nil)
        #expect(key(8, "c", []) == nil)
        #expect(key(8, "c", [.command, .option]) == nil)
        // Caps Lock does not change the meaning.
        #expect(key(49, " ", .capsLock) == .compare)
    }

    @Test func everyViewerKeyIsACatalogueCommandOfTheViewer() {
        for k in ViewerKey.allCases { #expect(k.shortcut.command.scope == .viewer) }
    }

    @Test func aChangedBindingAppliesAndDropsTheDefault() {
        var keys = KeyBindings.defaults
        keys.set(KeyChord("k", [.control, .command]), for: .viewerZoomIn)
        #expect(key(40, "k", [.control, .command], keys) == .zoomIn)
        #expect(key(24, "=", .command, keys) == nil)
        // The alias goes with the default.
        #expect(key(24, "=", [.command, .shift], keys) == nil)
        keys.set(nil, for: .viewerZoomOut)
        #expect(key(27, "-", .command, keys) == nil)
        keys.reset(.viewerZoomOut)
        #expect(key(27, "-", .command, keys) == .zoomOut)
    }
}

@Suite struct ViewerCopyTests {
    @Test func subtitleCountsAndPlurals() {
        #expect(ViewerCopy.subtitle(enabled: 4, total: 4) == "4 of 4 secrets blacked out")
        #expect(ViewerCopy.subtitle(enabled: 3, total: 4) == "3 of 4 secrets blacked out · 1 left visible")
        #expect(ViewerCopy.subtitle(enabled: 1, total: 1) == "1 of 1 secret blacked out")
        #expect(ViewerCopy.subtitle(enabled: 0, total: 0) == "No secrets found")
    }

    @Test func testShotWords() {
        #expect(ViewerCopy.testShotHeadline(secrets: 5, durationMS: 212) == "5 secrets blacked out in 212 ms.")
        #expect(ViewerCopy.testShotHeadline(secrets: 1, durationMS: 90) == "1 secret blacked out in 90 ms.")
        let steps = ViewerCopy.testShotSteps(detectors: 5, secrets: 5, retentionHours: 24)
        #expect(steps.count == 4)
        #expect(steps[1] == "5 detectors matched 5 secrets")
        #expect(steps[3] == "Clean image on the clipboard; original in the Journal for 24 h")
        #expect(ViewerCopy.testShotSteps(detectors: 1, secrets: 2, retentionHours: 168)[3].hasSuffix("7 days"))
    }

    @Test func originalExpiryCountsDown() {
        let created = Date(timeIntervalSince1970: 1_000_000)
        #expect(ViewerCopy.originalExpiry(createdAt: created, retentionHours: 24, available: true, now: created.addingTimeInterval(3600 * 0.5)) == "deleted in 23 h")
        #expect(ViewerCopy.originalExpiry(createdAt: created, retentionHours: 1, available: true, now: created.addingTimeInterval(60 * 50)) == "deleted in 10 min")
        #expect(ViewerCopy.originalExpiry(createdAt: created, retentionHours: 24, available: false) == "deleted")
    }

    @Test func tooltipsNameTheFindingAndTheClickResult() {
        #expect(ViewerCopy.findingTip(number: 2, name: "Phone number", enabled: true) == "2 · Phone number — blacked out. Click to leave it visible.")
        #expect(ViewerCopy.findingTip(number: 4, name: "Card security code", enabled: false) == "4 · Card security code — left visible. Click to black it out.")
    }

    @Test func stripOffersEveryChipCountDownToZero() {
        #expect(FindingsStrip.visibleCounts(total: 3) == [3, 2, 1, 0])
        #expect(FindingsStrip.visibleCounts(total: 0) == [0])
    }
}

// MARK: - Badges on the bars

@Suite @MainActor struct FindingMarksTests {
    private func finding(_ x: CGFloat, _ y: CGFloat, enabled: Bool = true) -> Finding {
        Finding(id: UUID(), entryID: UUID(), lineIndex: 0, rect: CGRect(x: x, y: y, width: 200, height: 40),
                detectorIDs: ["payments.stripe.secretkey"], category: "payments", enabled: enabled)
    }

    @Test func pixelRectsMapToDocumentPointsAndHitTest() {
        let v = FindingMarksView(frame: NSRect(x: 0, y: 0, width: 960, height: 230))
        let a = finding(400, 100), b = finding(400, 300, enabled: false)
        // A 2× image: 1920 px wide shown as 960 pt.
        v.update(findings: [a, b], names: [:], pixelSize: CGSize(width: 1920, height: 460), documentSize: CGSize(width: 960, height: 230))
        #expect(v.documentRect(a) == CGRect(x: 200, y: 50, width: 100, height: 20))
        #expect(v.finding(at: CGPoint(x: 250, y: 60))?.id == a.id)
        #expect(v.finding(at: CGPoint(x: 250, y: 160))?.id == b.id)
        // The covered bar holds its badge at its leading end; the left-visible one's badge sits past its trailing end,
        // off its text, and is clickable too. The gutter left of the bars (where a key name is) is not a badge.
        let badges = v.badgeFrames(m: 1)
        #expect(badges[0] == CGRect(x: 203, y: 51, width: 18, height: 18))
        #expect(badges[1] == CGRect(x: 300 + FindingMarksView.badgeGap, y: 151, width: 18, height: 18))
        #expect(v.finding(at: CGPoint(x: 315, y: 160))?.id == b.id)
        #expect(v.finding(at: CGPoint(x: 185, y: 58)) == nil)
        #expect(v.finding(at: CGPoint(x: 600, y: 200)) == nil)
    }

    @Test func badgesKeepTheirScreenSizeAtAnyZoom() {
        let v = FindingMarksView(frame: NSRect(x: 0, y: 0, width: 960, height: 230))
        let a = finding(400, 100)
        v.update(findings: [a], names: [:], pixelSize: CGSize(width: 960, height: 230), documentSize: CGSize(width: 960, height: 230))
        // At 4× the badge is 18/4 document points and fits on the 40-point bar's top-leading corner.
        #expect(v.badgeFrames(m: 4) == [CGRect(x: 400.75, y: 100.75, width: 4.5, height: 4.5)])
        v.magnification = { 4 }
        #expect(v.finding(at: CGPoint(x: 403, y: 103))?.id == a.id)
        #expect(v.finding(at: CGPoint(x: 380, y: 102)) == nil)
        // At ¼× it is 72 points, taller than the bar, so it moves past the bar's trailing end, one badge gap on screen clear.
        #expect(v.badgeFrames(m: 0.25) == [CGRect(x: 600 + FindingMarksView.badgeGap / 0.25, y: 84, width: 72, height: 72)])
        v.magnification = { 0.25 }
        #expect(v.finding(at: CGPoint(x: 660, y: 120))?.id == a.id)
    }

    @Test func eachFindingIsAnAccessibleButton() {
        let v = FindingMarksView(frame: NSRect(x: 0, y: 0, width: 960, height: 230))
        let a = finding(400, 100), b = finding(400, 300, enabled: false)
        v.update(findings: [a, b], names: [a.id: "Stripe secret key", b.id: "Card security code"],
                 pixelSize: CGSize(width: 960, height: 460), documentSize: CGSize(width: 960, height: 460))
        let children = (v.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        #expect(children.count == 2)
        #expect(children.first?.accessibilityLabel() == "Finding 1, Stripe secret key, blacked out")
        #expect(children.last?.accessibilityLabel() == "Finding 2, Card security code, left visible")
        v.isHidden = true
        #expect(v.accessibilityChildren()?.isEmpty == true)
    }
}
