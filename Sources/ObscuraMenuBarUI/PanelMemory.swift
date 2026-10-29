// View state the menu bar label and panel share, beyond what AppModel mirrors (B-6, design/mockups/unified/menubar.html).
// The pause (since / resumes at) and the update offer (with Later) are the model's (AppModel.pause, .updateOffer); this
// holds only what the panel alone needs: when it was last opened, the pause duration last chosen, the checking peak.
import Foundation
import Observation
import ObscuraUIKit

/// How long Pause Protection lasts. The pop lists them in this order.
enum PauseChoice: String, CaseIterable, Sendable, Hashable, Identifiable {
    case fifteenMinutes, oneHour, untilTomorrow, untilResumed

    var id: String { rawValue }

    /// The item in the duration pop.
    var menuTitle: String {
        switch self {
        case .fifteenMinutes: return String(localized: "For 15 Minutes")
        case .oneHour: return String(localized: "For 1 Hour")
        case .untilTomorrow: return String(localized: "Until Tomorrow")
        case .untilResumed: return String(localized: "Until I Resume")
        }
    }

    /// The short value at the right of the Pause Protection row.
    var shortTitle: String {
        switch self {
        case .fifteenMinutes: return String(localized: "15 min")
        case .oneHour: return String(localized: "1 hour")
        case .untilTomorrow: return String(localized: "Until tomorrow")
        case .untilResumed: return String(localized: "Until I resume")
        }
    }

    /// When protection comes back on by itself; nil means it stays paused until the user resumes.
    func resumeDate(from now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .fifteenMinutes: return now.addingTimeInterval(15 * 60)
        case .oneHour: return now.addingTimeInterval(60 * 60)
        case .untilTomorrow:
            let today = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: 1, to: today)
        case .untilResumed: return nil
        }
    }
}

/// Shared, per-model view state for the label and the panel.
@MainActor
@Observable
final class PanelMemory {
    /// Catches created after this were not yet seen in the panel ("unreviewed" for the Recent card and the count badge).
    private(set) var lastSeen: Date
    /// The duration the pop last used; the row shows it and the pop checks it.
    private(set) var pauseChoice: PauseChoice
    /// The panel window is showing (the count badge hides while it is).
    var isPanelOpen = false
    /// The largest queue seen in the current checking run, for "1 of 3".
    private(set) var checkingPeak = 0
    /// Whether the pause choices are open (G-19 M-15a). Starts closed on every opening of the panel.
    var pauseChoices = PauseChoicesPresentation(trigger: .hover)

    /// Escape while the pause choices are open closes only them; returns true when it did.
    func consumeEscape() -> Bool { pauseChoices.escape() }

    @ObservationIgnored private let defaults: UserDefaults

    enum Keys {
        static let lastSeen = "menuBar.lastSeen"
        static let pauseChoice = "menuBar.pauseChoice"
    }

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        if defaults.object(forKey: Keys.lastSeen) != nil {
            lastSeen = Date(timeIntervalSinceReferenceDate: defaults.double(forKey: Keys.lastSeen))
        } else {
            lastSeen = now
            defaults.set(now.timeIntervalSinceReferenceDate, forKey: Keys.lastSeen)
        }
        pauseChoice = defaults.string(forKey: Keys.pauseChoice).flatMap(PauseChoice.init(rawValue:)) ?? .fifteenMinutes
    }

    func markSeen(_ date: Date) {
        lastSeen = date
        defaults.set(date.timeIntervalSinceReferenceDate, forKey: Keys.lastSeen)
    }

    func choosePause(_ choice: PauseChoice) {
        pauseChoice = choice
        defaults.set(choice.rawValue, forKey: Keys.pauseChoice)
    }

    /// Feeds the current queue size; the peak resets when checking ends.
    func observeChecking(_ count: Int) {
        checkingPeak = count == 0 ? 0 : max(checkingPeak, count)
    }

    // MARK: One memory per model

    private struct Slot {
        weak var model: AppModel?
        let memory: PanelMemory
    }

    /// Keyed by identity; the weak reference guards against a new model reusing a freed model's address.
    private static var registry: [ObjectIdentifier: Slot] = [:]

    static func shared(for model: AppModel) -> PanelMemory {
        let key = ObjectIdentifier(model)
        if let slot = registry[key], slot.model === model { return slot.memory }
        let memory = PanelMemory()
        registry[key] = Slot(model: model, memory: memory)
        return memory
    }

    /// Tests and previews hand in a memory on their own defaults suite.
    static func register(_ memory: PanelMemory, for model: AppModel) {
        registry[ObjectIdentifier(model)] = Slot(model: model, memory: memory)
    }
}
