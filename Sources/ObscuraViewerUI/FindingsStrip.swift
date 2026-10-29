// The 44 pt strip under the image: the verdict pill, the findings as named chips (numbered order = badge order), and
// the trailing caption or Black Out All. Chips that do not fit collapse into "+N", which opens the inspector.
import SwiftUI
import ObscuraUIKit
import ObscuraPrefs
import ObscuraJournal

struct FindingsStrip: View {
    var keys: KeyBindings
    var findings: [Finding]
    var names: [UUID: String]
    /// The pill: the file's verdict, or Original showing while the original is on screen.
    var pillVerdict: Verdict
    /// Trailing text when there is nothing to do ("the file matches this preview", the test-shot line).
    var caption: String?
    var showsBlackOutAll: Bool
    var blackOutAll: () -> Void
    var openInspector: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Pill(pillVerdict.title, tone: pillVerdict.tone, symbol: pillVerdict.symbol)
            chips
            Spacer(minLength: 6)
            if showsBlackOutAll {
                Button(ViewerCopy.blackOutAll, action: blackOutAll)
                    .buttonStyle(OButtonStyle(.plain))
                    .controlSize(.small)
                    .font(.system(size: 11.5, weight: .medium))
            } else if let caption {
                // Shown whole or not at all: the chips matter more than the reassurance line.
                ViewThatFits(in: .horizontal) {
                    Text(caption).font(.system(size: 11.5)).foregroundStyle(OColor.text2).lineLimit(1).fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
                .layoutPriority(-1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(OColor.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(OColor.separator).frame(height: OMetric.hairline) }
    }

    /// As many chips as fit, then "+N".
    private var chips: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Self.visibleCounts(total: findings.count), id: \.self) { shown in
                HStack(spacing: 6) {
                    ForEach(findings.prefix(shown)) { f in
                        FindingChip(name: names[f.id] ?? "", visible: !f.enabled)
                    }
                    if shown < findings.count {
                        Button(action: openInspector) {
                            Text(verbatim: "+\(findings.count - shown)")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(OColor.text2)
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                                .background(Capsule().fill(OColor.fill))
                        }
                        .buttonStyle(.plain)
                        .help(ShortcutText.withChord(String(localized: "Show every finding"), .viewerFindings, keys))
                        .accessibilityLabel(Text("\(findings.count - shown) more findings"))
                    }
                }
                .fixedSize()
            }
        }
    }

    /// Candidate chip counts, all first, then one fewer each time; never fewer than zero.
    nonisolated static func visibleCounts(total: Int) -> [Int] {
        total <= 0 ? [0] : Array((0...total).reversed())
    }
}
