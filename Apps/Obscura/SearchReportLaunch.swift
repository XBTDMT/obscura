// Debug builds only: `Obscura.app/Contents/MacOS/Obscura -ObscuraSearchReport YES` prints, as JSON, how many Spotlight
// items Obscura holds (Core Spotlight's own answer, which only the app's bundle can ask for) and which covered files
// carry Obscura's Finder tags, then exits. Counts and ids only: no path, no file name, no label. Read-only: the Journal
// database is opened without migrating or writing (G-24 refinement: verify on an installed copy).
#if DEBUG
import Foundation
import ObscuraJournal
import ObscuraSearch

enum SearchReportLaunch {
    static func runAndExit() -> Never {
        let done = DispatchSemaphore(value: 0)
        let output = OutputBox()
        Task.detached {
            var report = (try? SearchReport.make(records: CoveredFilesReader.read(root: JournalLocations.defaultRoot()))) ?? SearchReport()
            report.spotlightIDs = try? await CoreSpotlightIndex.heldIdentifiers()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            output.text = (try? encoder.encode(report)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            done.signal()
        }
        if done.wait(timeout: .now() + 30) == .timedOut { output.text = #"{"error": "timed out"}"# }
        print(output.text)
        exit(0)
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    var text: String {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
#endif
