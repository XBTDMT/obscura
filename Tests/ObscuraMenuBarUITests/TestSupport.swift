// Invented data for the menu bar panel tests. Every name, key and file here is made up.
import Foundation
import CoreGraphics
import ObscuraUIKit
import ObscuraEngine
import ObscuraJournal
import ObscuraPrefs
import ObscuraTestSupport
@testable import ObscuraMenuBarUI

enum TestData {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()

    /// The mockup's sample day: Monday October 26 2026, 9:41 AM.
    static func date(_ hour: Int, _ minute: Int, _ second: Int = 0, day: Int = 26) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }

    static let now = date(9, 41, 16)

    static func finding(_ detector: String, enabled: Bool = true, entry: UUID) -> Finding {
        Finding(id: UUID(), entryID: entry, lineIndex: 0, rect: CGRect(x: 10, y: 10, width: 100, height: 20),
                detectorIDs: [detector], category: String(detector.split(separator: ".").first ?? "tokens"), enabled: enabled)
    }

    static func entry(_ name: String, at date: Date, source: EntrySource = .file, cleanCopy: Bool = false,
                      detectors: [(String, Bool)]) -> Entry {
        let id = UUID()
        return Entry(id: id, createdAt: date, source: source, displayName: name,
                     filePath: source == .file ? "/home/example/Desktop/\(name)" : nil,
                     cleanCopyPath: cleanCopy ? "/home/example/Desktop/clean-\(name)" : nil,
                     containerUTI: "public.png", pixelWidth: 1920, pixelHeight: 1080, revision: 1,
                     style: .builtInDefault, trashedAt: nil,
                     findings: detectors.map { finding($0.0, enabled: $0.1, entry: id) })
    }

    /// The mockup's last catch: a Stripe secret key and an email address, 4 seconds ago.
    static let stripeAndEmail = entry("Screenshot 2026-10-26 at 9.41.12 AM.png", at: date(9, 41, 12),
                                      detectors: [("payments.stripe.secretkey", true), ("personal.email.address", true)])

    static func week(today secrets: Int = 1) -> [DayStats] {
        let values = [(2, 9), (0, 4), (1, 6), (3, 11), (0, 2), (0, 3), (secrets, 7)]
        return values.enumerated().map { i, v in
            let d = calendar.date(byAdding: .day, value: i - 6, to: calendar.startOfDay(for: now))!
            let f = DateFormatter()
            f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            return DayStats(day: f.string(from: d), checked: v.1, caught: v.0, secrets: v.0)
        }
    }

    static func settings(_ edit: (inout ObscuraPrefs.Settings) -> Void = { _ in }) -> ObscuraPrefs.Settings {
        var s = ObscuraPrefs.Settings.default
        s.guardsDownloads = true
        s.extraFolders = ["~/Projects/example"]
        s.hasFinishedSetup = true
        edit(&s)
        return s
    }

    static let downloads = URL(fileURLWithPath: "/home/example/Downloads", isDirectory: true)
    static let screenshots = URL(fileURLWithPath: "/home/example/Desktop", isDirectory: true)

    static func inputs(status: EngineStatus = EngineStatus(weekStats: week()),
                       entries: [Entry] = [stripeAndEmail],
                       settings: ObscuraPrefs.Settings = settings(),
                       updateOffer: UpdateOffer? = nil,
                       focusHolding: Bool = false,
                       lastSeen: Date = date(9, 0),
                       pause: PauseState? = nil,
                       pauseChoice: PauseChoice = .fifteenMinutes,
                       checkingPeak: Int = 0,
                       now: Date = now) -> PanelInputs {
        PanelInputs(status: status, entries: entries, settings: settings, updateOffer: updateOffer, pause: pause,
                    focusHolding: focusHolding,
                    memory: .init(lastSeen: lastSeen, pauseChoice: pauseChoice, checkingPeak: checkingPeak),
                    now: now, calendar: calendar, downloadsFolder: downloads, screenshotFolder: screenshots)
    }

    /// A fresh defaults domain so tests never touch the user's, nor leave a file in ~/Library/Preferences.
    @MainActor
    static func memory(now: Date = now) -> PanelMemory {
        PanelMemory(defaults: TestDefaults("panel-memory").defaults, now: now)
    }
}

extension PanelSnapshot {
    var menuTitles: [String] {
        menu.compactMap { if case .row(let r) = $0 { return r.title }; return nil }
    }

    func menuRow(_ id: String) -> MenuRow? {
        for item in menu { if case .row(let r) = item, r.id == id { return r } }
        return nil
    }
}

/// Waits on the main actor until `condition` holds or the timeout passes.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
