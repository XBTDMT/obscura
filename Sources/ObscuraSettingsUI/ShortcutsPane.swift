// Keyboard Shortcuts (G-20, G-19 #20): every command in `ShortcutCatalogue`, grouped by where it works, each
// with a recorder. Click a shortcut, press the new chord: Esc cancels, Delete clears it. A chord another Obscura command
// already answers to in an overlapping scope, one macOS reserves, or one without ⌘ or ⌃ is refused with the reason
// under the row. Changes go straight into the settings, so every menu, button and key handler picks them up at once.
import AppKit
import SwiftUI
import ObscuraUIKit
import ObscuraPrefs

struct ShortcutsPane: View {
    let model: AppModel

    /// The command whose recorder is listening, if any.
    @State private var recording: ShortcutID?
    /// The last refusal, shown under its row until the next press or a different row.
    @State private var refusal: RowMessage?

    private var keys: KeyBindings { model.settings.keyBindings }

    var body: some View {
        PaneScaffold(String(localized: "Keyboard Shortcuts"), header: {
            Button(String(localized: "Restore Defaults")) {
                recording = nil
                refusal = nil
                model.updateSettings { $0.keyBindings.resetAll() }
                ShortcutsCopy.announce(String(localized: "Every shortcut is back to its default."))
            }
            .buttonStyle(OButtonStyle(.quiet, size: .small))
            .disabled(keys.overrides.isEmpty)
        }) {
            Lead(tone: storedConflicts.isEmpty ? .ok : .needs, title: ShortcutsCopy.headline(changed: keys.changedCount),
                 detail: ShortcutsCopy.howTo)
            ForEach(ShortcutCatalogue.groups, id: \.self) { scope in
                GroupHeading(title: scope.title)
                Card {
                    let commands = ShortcutCatalogue.commands(in: scope)
                    ForEach(Array(commands.enumerated()), id: \.element.id) { i, command in
                        if i > 0 { RowDivider() }
                        row(command)
                    }
                }
            }
        }
        .background(KeyCaptureMonitor(active: recording != nil, onKey: handle, onCancel: cancelRecording))
        .onDisappear { recording = nil }
    }

    // MARK: Rows

    private func row(_ command: ShortcutCommand) -> some View {
        SettingRow(title: command.title, help: help(for: command)) {
            if command.isChangeable {
                ShortcutRecorder(title: command.title, chord: keys.chord(for: command.id),
                                 isRecording: recording == command.id, isRefused: refusal?.id == command.id) {
                    refusal = nil
                    recording = command.id
                }
                resetButton(command)
            } else {
                FixedChord(title: command.title, chord: command.defaultChord)
            }
        }
    }

    /// Reset to the default; always takes its space so the recorders line up, and only shows on a changed row.
    private func resetButton(_ command: ShortcutCommand) -> some View {
        let changed = keys.isChanged(command.id)
        let label = ShortcutsCopy.resetLabel(command)
        return IconButton(symbol: "arrow.uturn.backward", label: label) {
            if recording == command.id { recording = nil }
            refusal = nil
            model.updateSettings { $0.keyBindings.reset(command.id) }
            ShortcutsCopy.announce(ShortcutsCopy.resetDone(command))
        }
        .opacity(changed ? 1 : 0)
        .disabled(!changed)
        .accessibilityHidden(!changed)
    }

    /// The line under a title: the refusal, a stored conflict, the default when changed, or why a row is fixed.
    func help(for command: ShortcutCommand) -> String? {
        if let refusal, refusal.id == command.id { return refusal.text }
        if recording == command.id { return ShortcutsCopy.recordingHelp }
        if let other = storedConflicts[command.id] { return ShortcutsCopy.storedConflict(with: other) }
        if let reason = command.fixedReason { return reason }
        if keys.isChanged(command.id) { return ShortcutsCopy.defaultLine(command) }
        return nil
    }

    /// Commands whose stored chord another overlapping command also has (only a hand-edited settings file gets here).
    private var storedConflicts: [ShortcutID: ShortcutID] {
        var map: [ShortcutID: ShortcutID] = [:]
        for (a, b) in ShortcutRules.conflicts(in: keys) { map[a] = b; map[b] = a }
        return map
    }

    // MARK: Recording

    /// One key press while a recorder listens. Returns true: every press is ours while recording (⌘Q must not quit).
    private func handle(_ chord: KeyChord?) -> Bool {
        guard let id = recording else { return false }
        switch ShortcutRecording.interpret(chord) {
        case .ignore:
            break
        case .cancel:
            cancelRecording()
        case .clear:
            model.updateSettings { $0.keyBindings.set(nil, for: id) }
            recording = nil
            refusal = nil
            ShortcutsCopy.announce(ShortcutsCopy.cleared(id.command))
        case .record(let chord):
            if let why = ShortcutRules.refusal(chord, for: id, in: keys) {
                // Stay listening so the person can try another chord at once.
                let text = why.message(for: chord)
                refusal = RowMessage(id: id, text: text)
                ShortcutsCopy.announce(text)
            } else {
                model.updateSettings { $0.keyBindings.set(chord, for: id) }
                recording = nil
                refusal = nil
                ShortcutsCopy.announce(ShortcutsCopy.recorded(id.command, chord))
            }
        }
        return true
    }

    private func cancelRecording() {
        recording = nil
        refusal = nil
    }
}

struct RowMessage: Equatable {
    var id: ShortcutID
    var text: String
}

// MARK: - The recorder

/// What one key press means to a listening recorder. Pure, so the recorder's rules are tested without events.
enum ShortcutRecording {
    enum Outcome: Equatable {
        /// A modifier on its own, or a key that cannot be a shortcut: keep listening.
        case ignore
        /// Esc on its own: stop listening, change nothing.
        case cancel
        /// Delete (or Forward Delete) on its own: remove the shortcut.
        case clear
        /// Any other chord: check it and, if allowed, use it.
        case record(KeyChord)
    }

    static func interpret(_ chord: KeyChord?) -> Outcome {
        guard let chord else { return .ignore }
        guard chord.modifiers.isEmpty else { return .record(chord) }
        switch chord.key {
        case .special(.escape): return .cancel
        case .special(.delete), .special(.forwardDelete): return .clear
        default: return .record(chord)
        }
    }
}

/// `.fld` in the shape of a key cap: the current chord, "None", or "Type Shortcut" while it listens (accent ring).
struct ShortcutRecorder: View {
    var title: String
    var chord: KeyChord?
    var isRecording: Bool
    var isRefused: Bool
    var start: () -> Void

    var body: some View {
        Button(action: start) {
            Text(text)
                .font(.system(size: 12, weight: chord == nil || isRecording ? .regular : .medium))
                .foregroundStyle(isRecording ? OColor.accentText : (chord == nil ? OColor.text3 : OColor.text1))
                .lineLimit(1)
                .frame(minWidth: 96)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous).fill(OColor.field))
                .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous)
                    .strokeBorder(ring, lineWidth: isRecording ? 1.5 : OMetric.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isRecording ? ShortcutsCopy.recordingHelp : ShortcutsCopy.recorderHelp)
        .accessibilityLabel(Text(ShortcutsCopy.recorderLabel(title)))
        .accessibilityValue(Text(isRecording ? ShortcutsCopy.recordingValue : ShortcutsCopy.spoken(chord)))
        .accessibilityHint(Text(ShortcutsCopy.recorderHint))
    }

    private var text: String {
        if isRecording { return ShortcutsCopy.recordingPlaceholder }
        return chord?.display ?? ShortcutsCopy.none
    }

    private var ring: Color {
        if isRecording { return isRefused ? OColor.needs : OColor.accent }
        return OColor.hairline
    }
}

/// A fixed command's chord: a key cap, no recorder.
struct FixedChord: View {
    var title: String
    var chord: KeyChord?
    var body: some View {
        HStack(spacing: 8) {
            KeyCap(chord?.display ?? ShortcutsCopy.none)
            Image(systemName: "lock").font(.system(size: 10.5)).foregroundStyle(OColor.text3)
        }
        // Lines the cap up with the recorders above and below (recorder + reset button).
        .frame(minWidth: 96 + 16 + OMetric.Control.iconButton.width + 8, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ShortcutsCopy.recorderLabel(title)))
        .accessibilityValue(Text(ShortcutsCopy.fixedValue(chord)))
    }
}

/// Listens to the keyboard for its window while `active`: every key press goes to `onKey` (and is swallowed when it
/// returns true, so ⌘Q or ⌘W cannot fire mid-recording); a click anywhere, or the window losing the keyboard, cancels.
struct KeyCaptureMonitor: NSViewRepresentable {
    var active: Bool
    var onKey: @MainActor (KeyChord?) -> Bool
    var onCancel: @MainActor () -> Void

    func makeNSView(context: Context) -> KeyCaptureView { KeyCaptureView() }

    func updateNSView(_ v: KeyCaptureView, context: Context) {
        v.onKey = onKey
        v.onCancel = onCancel
        v.setActive(active)
    }

    static func dismantleNSView(_ v: KeyCaptureView, coordinator: ()) { v.setActive(false) }
}

final class KeyCaptureView: NSView {
    var onKey: (@MainActor (KeyChord?) -> Bool)?
    var onCancel: (@MainActor () -> Void)?
    private var monitors: [Any] = []
    private var resignObserver: (any NSObjectProtocol)?

    func setActive(_ active: Bool) {
        guard active != !monitors.isEmpty else { return }
        if active { install() } else { remove() }
    }

    private func install() {
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let keyCode = event.keyCode, flags = event.modifierFlags, windowNumber = event.windowNumber
            let base = event.characters(byApplyingModifiers: [])
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, windowNumber == window.windowNumber else { return false }
                let chord = KeyChord.from(keyCode: keyCode, baseCharacters: base, modifiers: .init(flags))
                return self.onKey?(chord) ?? false
            }
            return consumed ? nil : event
        }) { monitors.append(keys) }
        // A click cancels; a click on another recorder then starts that one (its action runs after this).
        if let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.onCancel?() }
            return event
        }) { monitors.append(clicks) }
        if let window {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                    queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onCancel?() }
            }
        }
    }

    private func remove() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Words

enum ShortcutsCopy {
    static func sidebarValue(changed: Int) -> String {
        changed == 0 ? String(localized: "Defaults") : String(localized: "\(changed) changed")
    }

    static func headline(changed: Int) -> String {
        switch changed {
        case 0: String(localized: "Every shortcut is at its default")
        case 1: String(localized: "1 shortcut changed")
        default: String(localized: "\(changed) shortcuts changed")
        }
    }

    static var howTo: String {
        String(localized: "Click a shortcut, then press the new keys. Esc cancels, Delete removes it. Changes apply at once.")
    }

    static var none: String { String(localized: "None") }
    static var recordingPlaceholder: String { String(localized: "Type Shortcut") }
    static var recordingHelp: String { String(localized: "Press the new keys. Esc cancels, Delete removes the shortcut.") }
    static var recorderHelp: String { String(localized: "Click to change") }
    static var recordingValue: String { String(localized: "Recording. Press the new shortcut.") }
    static var recorderHint: String { String(localized: "Press to record a new shortcut. Escape cancels, Delete removes it.") }

    static func recorderLabel(_ title: String) -> String { String(localized: "Shortcut for \(title)") }

    static func spoken(_ chord: KeyChord?) -> String { chord?.spokenName ?? String(localized: "None") }

    static func fixedValue(_ chord: KeyChord?) -> String {
        String(localized: "\(spoken(chord)), can't be changed")
    }

    static func defaultLine(_ command: ShortcutCommand) -> String {
        guard let chord = command.defaultChord else { return String(localized: "No shortcut by default") }
        return String(localized: "Default: \(chord.display)")
    }

    static func resetLabel(_ command: ShortcutCommand) -> String {
        guard let chord = command.defaultChord else { return String(localized: "Reset \(command.title)") }
        return String(localized: "Reset \(command.title) to \(chord.display)")
    }

    static func resetDone(_ command: ShortcutCommand) -> String {
        String(localized: "\(command.title) is back to \(spoken(command.defaultChord)).")
    }

    static func cleared(_ command: ShortcutCommand) -> String {
        String(localized: "\(command.title) has no shortcut now.")
    }

    static func recorded(_ command: ShortcutCommand, _ chord: KeyChord) -> String {
        String(localized: "\(command.title) is now \(chord.spokenName).")
    }

    static func storedConflict(with other: ShortcutID) -> String {
        let o = other.command
        return String(localized: "Same keys as \(o.title) \(o.scope.place). Change one of them.")
    }

    /// Tells VoiceOver what just happened (the row's value changes too, but the announcement says why).
    @MainActor static func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}
