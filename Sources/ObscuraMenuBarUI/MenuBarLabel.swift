// The menu bar item: the Obscura mark in its state (menubar.html "The menu bar item, in every state").
// A MenuBarExtra label shows images, not live views, so it shows `MenuBarMarkPresenter`'s image for each moment; the
// presenter owns the timing (the gated checking state, the 60 fps sweep that stands still under Reduce Motion, the dot
// fade and the caught window).
public import SwiftUI
public import ObscuraUIKit
import AppKit
import ObscuraPrefs

public struct MenuBarLabel: View {
    private let presenter: MenuBarMarkPresenter

    public init(model: AppModel) {
        self.presenter = MenuBarMarkPresenter.shared(for: model)
    }

    public var body: some View {
        Image(nsImage: presenter.image)
            .accessibilityLabel(Text(presenter.accessibilityLabel))
    }

    /// S-12: with `Settings.reservesBadgeSpace`, the item keeps the badge's width for as long as a badge can appear
    /// (panel-only mode, notifications off), so the items to its left do not move when a count comes or goes. With
    /// notifications on no badge ever shows, so nothing is reserved.
    static func reservesBadgeSpace(_ settings: ObscuraPrefs.Settings) -> Bool {
        settings.reservesBadgeSpace && !settings.showsNotifications
    }

    /// Notifications off ("panel-only"): catches not yet seen in the panel count on the mark, until the panel opens.
    @MainActor
    static func badgeCount(model: AppModel, memory: PanelMemory) -> Int {
        guard !model.settings.showsNotifications, !memory.isPanelOpen else { return 0 }
        return model.entries.filter { $0.createdAt > memory.lastSeen }.count
    }
}
