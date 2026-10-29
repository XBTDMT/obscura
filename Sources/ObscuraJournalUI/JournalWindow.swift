// ObscuraJournalUI — the Journal window, "The hub" (design/mockups/unified/journal.html, from journal/r3-a).
// Sidebar with sources and the "By state" summary, a day-grouped grid or list, search, and the right inspector.
// Everything that changes an entry goes through AppModel; navigation goes through model.router.
public import SwiftUI
public import ObscuraUIKit
import UniformTypeIdentifiers
import ObscuraJournal
import ObscuraPrefs

/// The Journal window's content (1040 × 660 by default). The app target hosts it in a window with a hidden title bar.
public struct JournalWindow: View {
    private let model: AppModel
    @Binding private var selection: Set<UUID>
    /// A router request still to apply (`Router.openJournal(_:)`): applied when the window appears or when it changes,
    /// then cleared, so it works whether the window was open or not.
    @Binding private var destination: JournalDestination?
    @State private var controller: JournalController
    @State private var importing = false
    @State private var didAutoSelect = false
    @Environment(\.undoManager) private var undoManager

    public init(model: AppModel, selection: Binding<Set<UUID>>, destination: Binding<JournalDestination?> = .constant(nil)) {
        self.model = model
        self._selection = selection
        self._destination = destination
        self._controller = State(initialValue: JournalController(model: model))
    }

    public var body: some View {
        JournalContent(controller: controller, selection: $selection, onImport: { importing = true })
            .background { ShortcutLayer(controller: controller, selection: $selection, onImport: { importing = true }) }
            .onDrop(of: [.fileURL, .image], isTargeted: $controller.isDropTargeted) { providers in
                Task {
                    let urls = await DropLoader.urls(from: providers)
                    let added = await controller.importFiles(urls)
                    if let first = added.first { selection = [first] }
                }
                return true
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task {
                    let added = await controller.importFiles(urls)
                    if let first = added.first { selection = [first] }
                }
            }
            .task {
                controller.undoManager = undoManager
                await controller.sweepStale()
            }
            .onChange(of: undoManager) { _, um in controller.undoManager = um }
            .onChange(of: model.entries) { old, new in
                reconcileSelection(old: old, new: new)
                controller.syncKeyTexts(selection: selection)
            }
            .onChange(of: model.settings.showsUncoveredKeyText) { _, _ in controller.syncKeyTexts(selection: selection) }
            // Key texts are view state of an open window only (G-17).
            .onDisappear { controller.keyTexts.clear() }
            .onChange(of: selection) { _, _ in
                controller.peekLatched = false
                controller.styleDraft = nil
                controller.syncKeyTexts(selection: selection)
            }
            .onAppear {
                applyDestination()
                autoSelect()
            }
            .onChange(of: destination) { _, _ in applyDestination() }
            .onChange(of: model.entries.isEmpty) { _, _ in autoSelect() }
            .navigationTitle(Text("Journal"))
            .frame(minWidth: 760, idealWidth: OMetric.journalSize.width, maxWidth: .infinity,
                   minHeight: 480, idealHeight: OMetric.journalSize.height, maxHeight: .infinity)
    }

    private func applyDestination() {
        guard let pending = destination else { return }
        controller.open(pending)
        destination = nil
    }

    /// Selects the newest catch the first time there is one, so the inspector is never empty on open (not while the Not
    /// checked section is showing, which has no inspector).
    private func autoSelect() {
        guard !didAutoSelect, selection.isEmpty, !controller.sidebar.listsFiles, let first = controller.visibleEntries.first else { return }
        didAutoSelect = true
        selection = [first.id]
    }

    /// Drops ids that are gone; when the whole selection went (a delete), selects the neighbour in the old order.
    private func reconcileSelection(old: [Entry], new: [Entry]) {
        let live = Set(new.map(\.id))
        let kept = selection.intersection(live)
        guard kept != selection else { return }
        if kept.isEmpty, let firstGone = old.firstIndex(where: { selection.contains($0.id) }) {
            let after = old[firstGone...].first { live.contains($0.id) }
            let before = old[..<firstGone].last { live.contains($0.id) }
            selection = (after ?? before).map { [$0.id] } ?? []
        } else {
            selection = kept
        }
    }
}

/// The window's three panes and overlays, without lifecycle (rendered directly by the snapshot tests).
struct JournalContent: View {
    @Bindable var controller: JournalController
    @Binding var selection: Set<UUID>
    var onImport: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            JournalSidebar(controller: controller)
                .frame(width: OMetric.journalSidebarWidth)
            hairline
            VStack(spacing: 0) {
                JournalToolbar(controller: controller, selection: $selection, onImport: onImport)
                centre
                JournalBottomBar(controller: controller, selection: $selection)
            }
            .frame(maxWidth: .infinity)
            .background(OColor.window)
            if controller.showsInspector && !controller.sidebar.listsFiles {
                HStack(spacing: 0) {
                    hairline
                    JournalInspector(controller: controller, selection: $selection)
                        .frame(width: OMetric.journalInspectorWidth)
                }
                // Moves only inside the slide's animation (T-8's opt-in); the default change has none, so it is instant.
                .transition(.move(edge: .trailing))
            }
        }
        .clipped()
        .overlay(alignment: ToastPlacement.ladder.alignment) { UndoLadder(controller: controller) }
        .overlay {
            if controller.isDropTargeted { DropOverlay().padding(2) }
        }
        .background(OColor.window)
        // The Not checked section lists files, not catches: a selection of catches it cannot show would only feed the
        // shortcuts and the selection bar, so it is let go on the way in.
        .onChange(of: controller.sidebar) { _, section in
            if section.listsFiles { selection = [] }
        }
    }

    @ViewBuilder private var centre: some View {
        if controller.sidebar == .notChecked {
            JournalNotChecked(controller: controller)
        } else if controller.sidebar == .notCovered {
            JournalNotCovered(controller: controller)
        } else if controller.allEntries.isEmpty {
            JournalEmptyState(retention: controller.retention,
                              importChord: controller.model.settings.keyBindings.display(for: .journalImport))
        } else if controller.visibleEntries.isEmpty {
            JournalNoMatches(sidebar: controller.sidebar, search: controller.search)
        } else {
            JournalBrowser(controller: controller, selection: $selection)
        }
    }

    private var hairline: some View { Rectangle().fill(OColor.separator).frame(width: OMetric.hairline) }
}

/// The window's keyboard shortcuts, as invisible buttons so they work whether or not the inspector is open.
/// Undo is not here: it is the Edit menu's ⌘Z, which reaches the registrations the controller makes (`.journalUndo` is
/// listed, fixed, in the catalogue so its glyph has one source).
struct ShortcutLayer: View {
    let controller: JournalController
    @Binding var selection: Set<UUID>
    var onImport: () -> Void

    var body: some View {
        let notChecked = controller.sidebar.listsFiles
        let single = selection.count == 1 && !notChecked ? controller.entry(selection.first!) : nil
        let typing = controller.searchFocused
        // Read from the settings each render, so a change in Settings ▸ Keyboard Shortcuts applies at once (G-20).
        let keys = controller.model.settings.keyBindings
        ZStack {
            Button(String(localized: "Import Images…"), action: onImport)
                .shortcut(.journalImport, keys)
            Button(String(localized: "Copy Clean")) { if let single { Task { await controller.copyClean(single.id) } } }
                .shortcut(.journalCopyClean, keys)
                .disabled(typing || single.map { !controller.model.verdict(for: $0).isSafe } ?? true)
            Button(String(localized: "Copy Original")) { if let single { Task { await controller.copyOriginal(single.id) } } }
                .shortcut(.journalCopyOriginal, keys)
                .disabled(single == nil)
            Button(String(localized: "Copy As Shown")) { if let single { Task { await controller.copyAsShown(single.id) } } }
                .shortcut(.journalCopyAsShown, keys)
                .disabled(single == nil)
            Button(String(localized: "Delete")) {
                let ids = Array(selection)
                Task { await controller.delete(ids) }
            }
            .shortcut(.journalDelete, keys)
            .disabled(typing || notChecked || selection.isEmpty)
            Button(String(localized: "Show Details")) {
                if !controller.showsInspector {
                    controller.setShowsInspector(true)
                    controller.detailsExpanded = true
                } else {
                    controller.detailsExpanded.toggle()
                }
            }
            .shortcut(.journalShowDetails, keys)
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// Turns dropped items into file URLs: Finder files as they are, image data (from a browser, say) into a temporary file.
@MainActor
enum DropLoader {
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let url = await fileURL(provider) {
                urls.append(url)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier), let url = await imageFile(provider) {
                urls.append(url)
            }
        }
        return urls
    }

    private static func fileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func imageFile(_ provider: NSItemProvider) async -> URL? {
        let suggested = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("obscura-drop-\(UUID().uuidString)", isDirectory: true)
                let name = suggested.map { $0 + "." + url.pathExtension } ?? url.lastPathComponent
                let target = folder.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: target)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
