// "Confirm before Undo" (G-19 #11, ruled 2026-10-27: Undo acts at once by default, with a setting to ask first).
// Every surface's Undo goes through `AppModel.undo(_:)`, which asks through `AppModel.confirmUndo` when
// `Settings.confirmsUndo` is on; the words are decided here, purely, and `UndoAlert` shows them as the system alert
// that system.html's `.alert` draws (icon, bold title, one line, Cancel and Undo).
import AppKit
import Foundation
public import ObscuraJournal
public import ObscuraPrefs
import ObscuraSupport

/// What the user is asked before an Undo shows original(s). Detector names and counts only, never recognized text.
public struct UndoConfirmation: Equatable, Sendable {
    public var title: String
    public var message: String
    public var confirmTitle: String
    public var cancelTitle: String

    /// The gate: whether an Undo must ask first.
    public static func isRequired(_ settings: ObscuraPrefs.Settings) -> Bool { settings.confirmsUndo }

    /// open-calls.html #11: "Show the original? The Stripe secret key will be visible in the file." The place follows
    /// where the original goes back: the file, the clean copy beside it, or the clipboard.
    public init(entries: [Entry]) {
        confirmTitle = String(localized: "Undo")
        cancelTitle = String(localized: "Cancel")
        guard entries.count == 1, let entry = entries.first else {
            title = String(localized: "Show \(entries.count) originals?")
            message = String(localized: "Every secret in them will be visible again where they were saved or copied.")
            return
        }
        title = String(localized: "Show the original?")
        let place: String
        switch (entry.source, entry.cleanCopyPath != nil) {
        case (.clipboard, _): place = String(localized: "on the clipboard")
        case (_, true): place = String(localized: "in the clean copy")
        default: place = String(localized: "in the file")
        }
        let covered = entry.enabledFindings
        if covered.count == 1, let finding = covered.first {
            message = String(localized: "The \(DetectorNames.title(for: finding.detectorIDs.first ?? "")) will be visible \(place).")
        } else {
            let n = max(covered.count, entry.findings.count)
            message = String(localized: "\(n) secrets will be visible \(place).")
        }
    }
}

/// The system alert for an `UndoConfirmation`: a sheet on the Obscura window in front when there is one, else a
/// window-less alert brought forward (from the panel, the floating thumbnail or a notification). Undo is the default
/// button (Return), Cancel answers Escape.
@MainActor
public enum UndoAlert {
    public static func confirm(_ request: UndoConfirmation) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.title
        alert.informativeText = request.message
        alert.addButton(withTitle: request.confirmTitle)
        alert.addButton(withTitle: request.cancelTitle).keyEquivalent = "\u{1b}"
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.styleMask.contains(.titled), !(window is NSPanel) {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in continuation.resume(returning: response == .alertFirstButtonReturn) }
            }
        }
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
