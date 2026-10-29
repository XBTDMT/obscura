// ObscuraSetupUI — the first-run setup window (design/mockups/unified/onboarding.html; G-6 pick onboarding r3-a).
// A status rail in three parts beside one step at a time; every step can be left, nothing blocks, and the window
// opens at the first unfinished row.
import AppKit
public import Foundation
public import SwiftUI
public import ObscuraUIKit

/// The setup window's content, 880 × 560. The app hosts it in a titled window named "Obscura Setup".
public struct SetupWindow: View {
    @State private var flow: SetupFlow
    private let onFinish: () -> Void

    /// Shows (`true`) or hides (`false`) the macOS floating thumbnail. The app implements it (`defaults write
    /// com.apple.screencapture show-thumbnail` and the SystemUIServer restart); setup reads the setting back afterwards.
    /// Without it the step explains how to do it by hand.
    public var setFloatingThumbnail: (@MainActor (Bool) async -> Void)?

    /// - Parameters:
    ///   - model: the app's model; settings are written through `model.updateSettings`.
    ///   - runDemo: runs the fake `.env` through the real pipeline and returns the Journal entry and how long it took,
    ///     or nil when it could not run.
    ///   - onFinish: called after "Close setup" has recorded `hasFinishedSetup`.
    public init(model: AppModel, runDemo: @escaping @Sendable () async -> (entryID: UUID, durationMS: Int)?,
                onFinish: @escaping () -> Void) {
        _flow = State(initialValue: SetupFlow(model: model, system: .live, runDemo: runDemo))
        self.onFinish = onFinish
    }

    init(flow: SetupFlow, onFinish: @escaping () -> Void = {}, setFloatingThumbnail: (@MainActor (Bool) async -> Void)? = nil) {
        _flow = State(initialValue: flow)
        self.onFinish = onFinish
        self.setFloatingThumbnail = setFloatingThumbnail
    }

    /// The same window with the floating-thumbnail action set.
    public func onSetFloatingThumbnail(_ action: @escaping @MainActor (Bool) async -> Void) -> SetupWindow {
        var copy = self
        copy.setFloatingThumbnail = action
        return copy
    }

    public var body: some View {
        HStack(spacing: 0) {
            SetupRail(flow: flow)
            Rectangle().fill(OColor.separator).frame(width: OMetric.hairline)
            Group {
                if let step = flow.current {
                    StepPane(step: step, flow: flow, setFloatingThumbnail: setFloatingThumbnail, finish: close)
                        .id(step)
                } else {
                    DelayedProgress().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: OMetric.setupSize.width, height: OMetric.setupSize.height)
        .background(OColor.window)
        .foregroundStyle(OColor.text1)
        .tint(OColor.accent)
        .navigationTitle(Text("Obscura Setup"))
        .task { if flow.current == nil { await flow.start() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await flow.refresh() }
        }
        .task(id: flow.current) {
            // System Settings does not tell us when the login item is approved; read it back while the step is open.
            while flow.current == .openAtLogin, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await flow.refresh()
            }
        }
    }

    private func close() { flow.finish(then: onFinish) }
}

// MARK: - Rail

struct SetupRail: View {
    let flow: SetupFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SetupGroup.allCases, id: \.self) { group in
                Text(group.title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.44)
                    .foregroundStyle(OColor.text3)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(group.steps) { step in
                    RailRow(step: step, state: flow.state(step), isCurrent: flow.current == step) { flow.go(to: step) }
                }
            }
            Spacer(minLength: 8)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock").font(.system(size: 12)).foregroundStyle(OColor.text3).padding(.top, 1)
                    .accessibilityHidden(true)
                Text("Nothing leaves this Mac. Close this window any time; the menu bar brings you back.")
                    .font(.system(size: 11.5)).foregroundStyle(OColor.text2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(width: OMetric.setupRailWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(OColor.sidebar)
    }
}

struct RailRow: View {
    let step: SetupStep
    let state: SetupStepState
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RailDot(state: state, isCurrent: isCurrent)
                Text(step.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? OColor.accentText : OColor.text1)
                Spacer(minLength: 4)
                if step.isOptional, !state.isFinished {
                    Text("optional").font(.system(size: 11)).foregroundStyle(OColor.text3)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: OMetric.Radius.m, style: .continuous).fill(isCurrent ? OColor.accentSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(step.title), \(state.accessibilityWord)\(step.isOptional ? ", " + String(localized: "optional") : "")"))
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        .accessibilityHint(Text("Shows this step"))
    }
}

/// The 16 pt rail dot: empty when pending, accent when current and pending, otherwise the state's colour and symbol.
struct RailDot: View {
    let state: SetupStepState
    let isCurrent: Bool

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 16, height: 16)
            .overlay {
                if let symbol = state.symbol {
                    Image(systemName: symbol).font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.white)
                }
            }
            .accessibilityHidden(true)
    }

    private var fill: Color {
        if let tone = state.tone { return tone == .quiet ? OColor.toggleOff : tone.color }
        return isCurrent ? OColor.accent : OColor.fill2
    }
}
