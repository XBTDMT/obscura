import Foundation

/// Every keyboard shortcut Obscura defines, in one place (G-20). Each surface asks `KeyBindings` for a command's
/// chord; no chord is written anywhere else (ShortcutInventoryTests enforces it).
///
/// Not in the catalogue, on purpose:
/// - Return and Escape as a sheet's default and cancel buttons (`.defaultAction`, `.cancelAction`): button roles the
///   system owns, not commands.
/// - Arrow keys and Return moving through a grid, list or sidebar: navigation, which HIG keeps standard.
/// - The menus macOS adds itself (the app menu's Hide, Quit; Edit; Window ▸ Minimize, Close).
public enum ShortcutID: String, CaseIterable, Sendable, Hashable, Codable, Identifiable {
    // App: in the main menu, so they work in every Obscura window.
    case appOpenJournal = "app.openJournal"
    case appSettings = "app.settings"
    case appQuit = "app.quit"
    // Journal window.
    case journalImport = "journal.import"
    case journalCopyClean = "journal.copyClean"
    case journalCopyOriginal = "journal.copyOriginal"
    case journalCopyAsShown = "journal.copyAsShown"
    case journalDelete = "journal.delete"
    case journalShowDetails = "journal.showDetails"
    case journalUndo = "journal.undo"
    // Viewer window.
    case viewerToggleMode = "viewer.toggleMode"
    case viewerCompare = "viewer.compare"
    case viewerClose = "viewer.close"
    case viewerCopy = "viewer.copy"
    case viewerCopyOriginal = "viewer.copyOriginal"
    case viewerZoomIn = "viewer.zoomIn"
    case viewerZoomOut = "viewer.zoomOut"
    case viewerActualSize = "viewer.actualSize"
    case viewerZoomToFit = "viewer.zoomToFit"
    case viewerFindings = "viewer.findings"
    // Menu bar panel.
    case panelUndo = "panel.undo"
    case panelClose = "panel.close"

    public var id: String { rawValue }

    /// The command's entry in the catalogue.
    public var command: ShortcutCommand { ShortcutCatalogue.command(self) }
}

/// Where a shortcut works. Two commands may share a chord only when their scopes never overlap (`overlaps`).
public enum ShortcutScope: String, CaseIterable, Sendable, Hashable {
    /// The main menu: active in every Obscura window, and shown on the menu bar panel's rows.
    case app
    case journal
    case viewer
    case menuBarPanel

    /// The settings pane's group title.
    public var title: String {
        switch self {
        case .app: String(localized: "App")
        case .journal: String(localized: "Journal")
        case .viewer: String(localized: "Viewer")
        case .menuBarPanel: String(localized: "Menu bar panel")
        }
    }

    /// Where the phrase "in the …" puts a command, for conflict messages.
    public var place: String {
        switch self {
        case .app: String(localized: "in every window")
        case .journal: String(localized: "in the Journal")
        case .viewer: String(localized: "in the Viewer")
        case .menuBarPanel: String(localized: "in the menu bar panel")
        }
    }

    /// The Journal, the Viewer and the panel are separate windows: only one has the keyboard at a time. App commands
    /// live in the main menu, which every window reaches (and the panel shows them), so App overlaps every scope.
    public func overlaps(_ other: ShortcutScope) -> Bool {
        self == other || self == .app || other == .app
    }
}

/// One command: its title, scope, default chord, and whether the person may change it.
public struct ShortcutCommand: Sendable, Hashable, Identifiable {
    public var id: ShortcutID
    public var title: String
    public var scope: ShortcutScope
    /// The chord the command has until the person changes it; nil = no default.
    public var defaultChord: KeyChord?
    /// Extra chords that also trigger the command while it is at its default (⇧⌘= is ⌘+ for Zoom In). A changed or
    /// cleared binding drops them with the default.
    public var defaultAliases: [KeyChord]
    /// Why the command cannot be changed, or nil when it can.
    public var fixedReason: String?

    public var isChangeable: Bool { fixedReason == nil }

    init(_ id: ShortcutID, _ title: String, _ scope: ShortcutScope, _ chord: KeyChord?, aliases: [KeyChord] = [],
         fixed: String? = nil) {
        self.id = id; self.title = title; self.scope = scope; self.defaultChord = chord
        self.defaultAliases = aliases; self.fixedReason = fixed
    }
}

public enum ShortcutCatalogue {
    /// Every command, in the order the Settings pane lists them (grouped by `scope`).
    public static let all: [ShortcutCommand] = ShortcutID.allCases.map(command)

    /// The scopes in the order the pane shows them.
    public static let groups: [ShortcutScope] = [.journal, .viewer, .menuBarPanel, .app]

    public static func commands(in scope: ShortcutScope) -> [ShortcutCommand] { all.filter { $0.scope == scope } }

    // Why some chords stay fixed (HIG, "Keyboard shortcuts": don't repurpose the standard ones):
    private static var standardCopy: String { String(localized: "⌘C is Copy everywhere on a Mac; here it copies the clean image.") }
    private static var standardUndo: String { String(localized: "⌘Z is Undo everywhere on a Mac.") }
    private static var standardMenu: String { String(localized: "Set by macOS for every app.") }
    private static var bareKey: String { String(localized: "A single key that works without ⌘, like Quick Look's.") }
    private static var standardEscape: String { String(localized: "Esc always closes or cancels on a Mac.") }

    /// The catalogue entry of one command.
    public static func command(_ id: ShortcutID) -> ShortcutCommand {
        let cmd: KeyChord.Modifiers = .command
        switch id {
        case .appOpenJournal:
            return .init(id, String(localized: "Open Journal"), .app, KeyChord("j", cmd))
        case .appSettings:
            return .init(id, String(localized: "Settings…"), .app, KeyChord(",", cmd), fixed: standardMenu)
        case .appQuit:
            return .init(id, String(localized: "Quit Obscura"), .app, KeyChord("q", cmd), fixed: standardMenu)

        case .journalImport:
            return .init(id, String(localized: "Import Images…"), .journal, KeyChord("o", cmd))
        case .journalCopyClean:
            return .init(id, String(localized: "Copy Clean"), .journal, KeyChord("c", cmd), fixed: standardCopy)
        case .journalCopyOriginal:
            return .init(id, String(localized: "Copy Original"), .journal, KeyChord("c", [.option, .command]))
        case .journalCopyAsShown:
            return .init(id, String(localized: "Copy As Shown"), .journal, KeyChord("c", [.shift, .command]))
        case .journalDelete:
            return .init(id, String(localized: "Delete"), .journal, KeyChord(.special(.delete), cmd))
        case .journalShowDetails:
            return .init(id, String(localized: "Show Details"), .journal, KeyChord("i", [.option, .command]))
        case .journalUndo:
            return .init(id, String(localized: "Undo"), .journal, KeyChord("z", cmd), fixed: standardUndo)

        case .viewerToggleMode:
            return .init(id, String(localized: "Switch Clean and Original"), .viewer, KeyChord(.special(.tab)), fixed: bareKey)
        case .viewerCompare:
            return .init(id, String(localized: "Compare"), .viewer, KeyChord(.special(.space)), fixed: bareKey)
        case .viewerClose:
            return .init(id, String(localized: "Close"), .viewer, KeyChord(.special(.escape)), fixed: standardEscape)
        case .viewerCopy:
            return .init(id, String(localized: "Copy"), .viewer, KeyChord("c", cmd), fixed: standardCopy)
        case .viewerCopyOriginal:
            return .init(id, String(localized: "Copy Original"), .viewer, KeyChord("c", [.option, .command]))
        case .viewerZoomIn:
            return .init(id, String(localized: "Zoom In"), .viewer, KeyChord("=", cmd), aliases: [KeyChord("=", [.shift, .command])])
        case .viewerZoomOut:
            return .init(id, String(localized: "Zoom Out"), .viewer, KeyChord("-", cmd))
        case .viewerActualSize:
            return .init(id, String(localized: "Actual Size"), .viewer, KeyChord("0", cmd))
        case .viewerZoomToFit:
            return .init(id, String(localized: "Zoom to Fit"), .viewer, KeyChord("9", cmd))
        case .viewerFindings:
            return .init(id, String(localized: "Show Findings"), .viewer, KeyChord("i", [.option, .command]))

        case .panelUndo:
            return .init(id, String(localized: "Undo Last Catch"), .menuBarPanel, KeyChord("z", cmd), fixed: standardUndo)
        case .panelClose:
            return .init(id, String(localized: "Close Panel"), .menuBarPanel, KeyChord(.special(.escape)), fixed: standardEscape)
        }
    }
}
