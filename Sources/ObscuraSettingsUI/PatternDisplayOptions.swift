// The two pattern display options, at the foot of both panes they change (Detectors and Custom Rules), where the
// Plain words / Regular expressions control and the test line they act on are (G-19 #2 and #6, ruled
// 2026-10-27: one app-wide choice and the tag shown by default, each switchable).
import SwiftUI
import ObscuraUIKit
import ObscuraPrefs

struct PatternDisplayOptions: View {
    let model: AppModel

    private var s: ObscuraPrefs.Settings { model.settings }

    /// The test line names the pattern that fired in regex mode always, and in plain words unless switched off.
    static func showsPatternNumber(_ settings: ObscuraPrefs.Settings, regexMode: Bool) -> Bool {
        regexMode || settings.showsPatternNumber
    }

    var body: some View {
        GroupHeading(title: String(localized: "Pattern display"))
        Card {
            SettingRow(title: String(localized: "Same choice in Detectors and Custom Rules"),
                       help: String(localized: "Plain words or regular expressions for both panes at once. Off, each pane keeps its own")) {
                AsyncSwitch(label: String(localized: "Same choice in Detectors and Custom Rules"), isOn: s.patternModeScope == .appWide) { on in
                    model.updateSettings { $0.setPatternModeScope(on ? .appWide : .perPane) }
                }
            }
            RowDivider()
            SettingRow(title: String(localized: "Show which pattern matched"),
                       help: String(localized: "In plain words, the test line ends with “pattern 1 of 2” when a detector has several. Regular expressions always show it")) {
                AsyncSwitch(label: String(localized: "Show which pattern matched"), isOn: s.showsPatternNumber) { on in
                    model.updateSettings { $0.showsPatternNumber = on }
                }
            }
        }
    }
}
