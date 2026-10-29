// Setup's progress as the menu bar panel shows it while setup is unfinished (G-19 M-19): "Setup · 4 of 8 done", the
// next step's name. ObscuraSetupUI computes it from the same rules as the setup window's rail (`SetupProgress`), and
// the app puts it on `AppModel.setupSummary`, so the panel never imports the setup module (G-7).
import Foundation

public struct SetupSummary: Equatable, Sendable {
    /// Rail rows finished, the Done row included.
    public var done: Int
    /// Rail rows in all (eight).
    public var total: Int
    /// The rail label of the step setup resumes at; nil when there is none to name.
    public var next: String?

    public init(done: Int, total: Int, next: String?) {
        self.done = done
        self.total = total
        self.next = next
    }
}
