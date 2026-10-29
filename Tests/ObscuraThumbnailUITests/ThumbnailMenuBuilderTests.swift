import AppKit
import ObscuraPrefs
import Testing
@testable import ObscuraThumbnailUI

/// The card's menu holds Obscura's items only: no context-menu plug-ins, no Writing Tools or Siri items (2026-10-28:
/// a context menu opened with a highlighted "Ask Siri" first, under the pointer).
@MainActor @Suite struct ThumbnailMenuBuilderTests {
    static let covered = CardPhase.covered(entryID: UUID(), findings: 2)

    @Test func theMenuIsObscurasItemsOnly() {
        let items = ThumbnailMenuItem.items(for: Self.covered, clickOpens: .preview)
        let built = ThumbnailMenuBuilder.menu(items, phase: Self.covered) { _ in }
        #expect(!built.menu.allowsContextMenuPlugIns)
        if #available(macOS 15.2, *) { #expect(!built.menu.automaticallyInsertsWritingToolsItems) }
        #expect(built.menu.items.count == items.count)
        let titles = built.menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == items.filter { $0 != .separator }.map { ThumbnailMenuLook($0, phase: Self.covered).title })
        #expect(built.targets.count == titles.count)
    }

    @Test func choosingAnItemPerformsIt() {
        var chosen: [ThumbnailMenuItem] = []
        let built = ThumbnailMenuBuilder.menu([.copy, .separator, .close], phase: Self.covered) { chosen.append($0) }
        let close = built.menu.items.last!
        _ = (close.target as AnyObject).perform(close.action)
        #expect(chosen == [.close])
    }
}
