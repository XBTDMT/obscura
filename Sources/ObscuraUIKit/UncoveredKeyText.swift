// G-17 (option A, behind a switch): a finding left visible shows its key as text with a Copy button, read again from
// the original on demand. The text lives only in this view state: never in the Journal, a file, UserDefaults or a
// log. It goes when the finding is covered again, when the switch is turned off, and when the window closes (`clear`).
public import AppKit
public import Observation
public import SwiftUI
public import ObscuraJournal
import ObscuraSupport

/// Puts a key on a pasteboard as plain text marked concealed and transient (nspasteboard.org), so clipboard managers
/// and Obscura's own clipboard guard skip it and it is never kept in a clipboard history.
public enum KeyPasteboard {
    public static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    public static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Replaces the pasteboard's contents with `text`. Returns whether the string was written.
    @MainActor @discardableResult
    public static func write(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.declareTypes([.string, concealedType, transientType], owner: nil)
        let wrote = pasteboard.setString(text, forType: .string)
        // The markers carry no data of their own; their presence is the signal.
        pasteboard.setData(Data(), forType: concealedType)
        pasteboard.setData(Data(), forType: transientType)
        return wrote
    }
}

/// One finding's key text as the view shows it.
public enum KeyTextState: Equatable, Sendable {
    /// The re-read is running (the field shows the delayed spinner).
    case reading
    /// The text read from the picture.
    case text(String)
    /// The re-read found nothing or failed ("Couldn't read this one.").
    case unreadable
}

/// The words of the key-text field, in one place.
public enum KeyTextCopy {
    public static let note = String(localized: "Read from the picture — check before using.")
    public static let unreadable = String(localized: "Couldn't read this one.")
    public static let copy = String(localized: "Copy")
    public static let copied = String(localized: "Key copied.")
    public static let copyFailed = String(localized: "Couldn't copy the key.")
    public static let reading = String(localized: "Reading the key")
    public static let fieldLabel = String(localized: "Key text, read from the picture")
    public static let copyHelp = String(localized: "Copy the key as text. Clipboard managers are asked not to keep it")
}

/// The key texts one window shows, keyed by finding id. A window owns one (`JournalController`, the viewer's scene).
@MainActor
@Observable
public final class UncoveredKeyText {
    /// Reads one finding's text: (finding id, entry id) → text. The app passes `AppModel.readKeyText`.
    public typealias Reader = @MainActor @Sendable (UUID, UUID) async throws -> String

    private let read: Reader
    private var states: [UUID: KeyTextState] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    public init(read: @escaping Reader) { self.read = read }

    /// Reads through the app model (its engine).
    public convenience init(model: AppModel) {
        self.init { [weak model] findingID, entryID in
            guard let model else { throw CancellationError() }
            return try await model.readKeyText(findingID, in: entryID)
        }
    }

    /// Whether a finding shows its key as text: the switch is on and the finding is left visible.
    public nonisolated static func shows(_ finding: Finding, switchOn: Bool) -> Bool { switchOn && !finding.enabled }

    /// What the field shows for `finding`; nil when it shows no field.
    public func state(for finding: Finding, switchOn: Bool) -> KeyTextState? {
        guard Self.shows(finding, switchOn: switchOn) else { return nil }
        return states[finding.id] ?? .reading
    }

    /// Starts reading `finding` when it shows its text and nothing is held for it yet. A read that ends after the
    /// finding was covered again (or the window closed) is dropped.
    public func request(_ finding: Finding, in entryID: UUID, switchOn: Bool) {
        guard Self.shows(finding, switchOn: switchOn), states[finding.id] == nil else { return }
        let id = finding.id
        states[id] = .reading
        tasks[id] = Task { [weak self, read] in
            let result: KeyTextState?
            do {
                result = .text(try await read(id, entryID))
            } catch is CancellationError {
                result = nil
            } catch {
                result = .unreadable
            }
            guard let self, !Task.isCancelled, self.states[id] == .reading else { return }
            if let result { self.states[id] = result } else { self.states[id] = nil }
            self.tasks[id] = nil
        }
    }

    /// Drops every text whose finding no longer shows one (covered again, gone from the entry, or the switch off).
    /// `findings` are every finding on screen.
    public func sync(_ findings: [Finding], switchOn: Bool) {
        let showing = Set(findings.filter { Self.shows($0, switchOn: switchOn) }.map(\.id))
        for id in Array(states.keys) where !showing.contains(id) { forget(id) }
    }

    /// Drops everything (the window closed).
    public func clear() {
        for id in Array(states.keys) { forget(id) }
    }

    /// Copies a finding's text, marked concealed. Returns false when there is no text to copy.
    @discardableResult
    public func copy(_ findingID: UUID, to pasteboard: NSPasteboard = .general) -> Bool {
        guard case .text(let text)? = states[findingID] else { return false }
        let wrote = KeyPasteboard.write(text, to: pasteboard)
        Log.app.info("key text copied finding=\(findingID.uuidString, privacy: .public) ok=\(wrote)")
        return wrote
    }

    /// Finding ids holding any state (reading or read); for tests and the window's bookkeeping.
    public var heldIDs: Set<UUID> { Set(states.keys) }

    /// Waits for every read in flight (tests).
    public func settle() async {
        for task in Array(tasks.values) { await task.value }
    }

    private func forget(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        states.removeValue(forKey: id)
    }
}

/// The key under a finding left visible: a small selectable monospaced field with Copy and the note, a delayed spinner
/// while it is read, or "Couldn't read this one.". It appears with the one fade; VoiceOver reads the key only when the
/// user moves to the field (nothing is announced on its own).
public struct UncoveredKeyField: View {
    public var state: KeyTextState
    public var copy: () -> Void

    public init(state: KeyTextState, copy: @escaping () -> Void) {
        self.state = state
        self.copy = copy
    }

    public var body: some View {
        Group {
            switch state {
            case .reading:
                HStack(spacing: 6) { DelayedProgress() }
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(KeyTextCopy.reading))
            case .text(let text):
                VStack(alignment: .leading, spacing: 5) {
                    // The whole key, wrapped at any character (a key has no words to break at), never truncated.
                    KeyTextLabel(text: text)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous).fill(OColor.field))
                        .overlay(RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous)
                            .strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(KeyTextCopy.note)
                            .font(.system(size: 11))
                            .foregroundStyle(OColor.text3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(KeyTextCopy.copy, action: copy)
                            .buttonStyle(OButtonStyle(.quiet, size: .small))
                            .help(KeyTextCopy.copyHelp)
                            .accessibilityLabel(Text(KeyTextCopy.copy))
                            .accessibilityHint(Text(KeyTextCopy.copyHelp))
                    }
                }
            case .unreadable:
                Text(KeyTextCopy.unreadable)
                    .font(.system(size: 11))
                    .foregroundStyle(OColor.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .transition(OMotion.appear)
        .oFade(value: state)
    }
}

/// The key as a selectable, non-editable AppKit label in the mono face, wrapped at any character: SwiftUI's `Text`
/// breaks only at word boundaries (a key broke at its hyphens and was cut off with "…"). Its accessibility value is the
/// key, read when the user moves to it; it posts no announcement of its own.
struct KeyTextLabel: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.isEditable = false
        field.isSelectable = true
        field.drawsBackground = false
        field.isBordered = false
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.textColor = .labelColor
        field.lineBreakMode = .byCharWrapping
        field.cell?.wraps = true
        field.cell?.lineBreakMode = .byCharWrapping
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(KeyTextCopy.fieldLabel)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? field.intrinsicContentSize.width
        guard width.isFinite, width > 0 else { return nil }
        field.preferredMaxLayoutWidth = width
        let height = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
            ?? field.intrinsicContentSize.height
        return CGSize(width: width, height: ceil(height))
    }
}
