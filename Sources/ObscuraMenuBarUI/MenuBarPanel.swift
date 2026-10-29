// The 310 pt menu bar panel (B-6; design/mockups/unified/menubar.html, picked from menubar/r3-a).
// It reads AppModel, turns it into a PanelSnapshot, and draws that; every action goes back through the model or
// model.router. `MenuBarController` hosts it in Obscura's own panel window (G-14) and is told about each action, so the
// panel closes when `PanelPresentation` says (ARCHITECTURE.md §8).
public import SwiftUI
public import ObscuraUIKit
import AppKit
import ObscuraEngine
import ObscuraCapture

/// Told just before an action runs and again once it has finished.
typealias PanelActionHook = @MainActor (PanelAction, PanelActionPhase) -> Void

enum PanelActionPhase: Equatable, Sendable { case willPerform, didPerform }

public struct MenuBarPanel: View {
    private let model: AppModel
    private let memory: PanelMemory
    private var actionHook: PanelActionHook?

    public init(model: AppModel) {
        self.model = model
        self.memory = PanelMemory.shared(for: model)
    }

    init(model: AppModel, actionHook: @escaping PanelActionHook) {
        self.init(model: model)
        self.actionHook = actionHook
    }

    /// "just now" turns into a time after a minute; ten seconds is fine enough for that.
    static let refreshInterval: TimeInterval = 10

    public var body: some View {
        TimelineView(.periodic(from: .now, by: Self.refreshInterval)) { context in
            PanelContent(snapshot: snapshot(at: context.date),
                         perform: { action in perform(action) },
                         loadThumbnail: { entry in await model.thumbnail(for: entry) },
                         pauseChoices: Bindable(memory).pauseChoices)
        }
        .overlay(alignment: ToastPlacement.bottom.alignment) { toast }
        .onAppear {
            memory.isPanelOpen = true
            memory.pauseChoices.reset(trigger: model.settings.pauseChoicesOpen)
        }
        .onDisappear {
            memory.isPanelOpen = false
            memory.pauseChoices.reset(trigger: model.settings.pauseChoicesOpen)
            memory.markSeen(Date())
        }
        .onChange(of: model.settings.pauseChoicesOpen) { _, trigger in memory.pauseChoices.reset(trigger: trigger) }
        .onChange(of: checkingCount, initial: true) { _, count in memory.observeChecking(count) }
    }

    // MARK: State

    private var isPaused: Bool {
        if case .paused = model.status.protection { return true }
        return false
    }

    private var checkingCount: Int { isPaused ? 0 : max(model.status.inFlight, model.status.queueDepth) }

    func snapshot(at now: Date) -> PanelSnapshot {
        PanelSnapshot.make(Self.inputs(model: model, memory: memory, now: now))
    }

    static func inputs(model: AppModel, memory: PanelMemory, now: Date) -> PanelInputs {
        let needsFolders = model.status.problems.contains { $0.kind == .folderAccess }
        return PanelInputs(
            status: model.status,
            entries: model.entries,
            settings: model.settings,
            updateOffer: model.updateOffer,
            pause: model.pause,
            focusHolding: model.focusHolding,
            memory: .init(lastSeen: memory.lastSeen, pauseChoice: memory.pauseChoice, checkingPeak: memory.checkingPeak),
            setup: model.setupSummary,
            now: now,
            // Only a folder problem needs the screenshot folder, and reading it touches the disk.
            screenshotFolder: needsFolders ? ScreenshotFolder.current() : URL(fileURLWithPath: "/", isDirectory: true))
    }

    private func perform(_ action: PanelAction) {
        let performer = PanelActionPerformer(model: model, memory: memory)
        let hook = actionHook
        hook?(action, .willPerform)
        Task {
            await performer.perform(action)
            hook?(action, .didPerform)
        }
    }

    // MARK: Toast

    /// The shared toast presentation (ObscuraUIKit `ToastStack`): one fade, one place; the model expires its toast.
    private var toast: some View {
        ToastStack(model.toast.map { [$0.item] } ?? [], placement: .bottom)
    }
}
