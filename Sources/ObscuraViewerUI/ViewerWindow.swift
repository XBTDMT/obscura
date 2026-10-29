// ObscuraViewerUI — the viewer window (design/mockups/unified/viewer.html, from viewer/r3-a "The native viewer").
// The app target puts `ViewerWindow` in a window when the router's openViewer(entryID:) is called, and
// `TestShotResultView` after setup's test shot.
public import SwiftUI
public import ObscuraUIKit

/// One caught screenshot: Redacted / Original (Tab), hold-to-peek, Space compare, the zoom set, numbered finding
/// badges that toggle on click, the findings strip with the verdict, the on-demand inspector, Copy, Close (Esc), and
/// Live Text over the original with "Always Black Out Things Like This" and "Never Black Out This".
///
/// 720 pt wide, 880 with the inspector. The window title is the file name; the toolbar carries the count.
public struct ViewerWindow: View {
    let model: AppModel
    let entryID: UUID
    var rulesChanged: (@MainActor () async -> Void)?

    public init(model: AppModel, entryID: UUID) {
        self.model = model
        self.entryID = entryID
    }

    public var body: some View {
        ViewerScene(model: model, entryID: entryID, variant: .standard, rulesChanged: rulesChanged)
    }

    /// Runs after a Live Text rule was added or undone, so the host can recompile the engine's catalogue
    /// (`ShieldEngine.catalogueChanged()`). Without it the rule is stored and takes effect at the next catalogue build.
    public func onRulesChanged(_ action: @escaping @MainActor () async -> Void) -> ViewerWindow {
        var copy = self
        copy.rulesChanged = action
        return copy
    }
}

/// The first-run test shot's result: the viewer with its inspector open on the four-step story,
/// "N secrets blacked out in N ms. This is exactly what your clipboard gets.", Run Again and Continue Setup.
public struct TestShotResultView: View {
    let model: AppModel
    let entryID: UUID
    let durationMS: Int
    var rulesChanged: (@MainActor () async -> Void)?
    var runAgain: (@MainActor () -> Void)?
    var continueSetup: (@MainActor () -> Void)?

    public init(model: AppModel, entryID: UUID, durationMS: Int) {
        self.model = model
        self.entryID = entryID
        self.durationMS = durationMS
    }

    public var body: some View {
        ViewerScene(model: model, entryID: entryID, variant: .testShot(durationMS: durationMS),
                    rulesChanged: rulesChanged, runAgain: runAgain, continueSetup: continueSetup)
    }

    /// Run Again: the host runs the test shot through the pipeline again.
    public func onRunAgain(_ action: @escaping @MainActor () -> Void) -> TestShotResultView {
        var copy = self
        copy.runAgain = action
        return copy
    }

    /// Continue Setup. Defaults to `model.router?.openSetup()`.
    public func onContinueSetup(_ action: @escaping @MainActor () -> Void) -> TestShotResultView {
        var copy = self
        copy.continueSetup = action
        return copy
    }

    /// As `ViewerWindow.onRulesChanged(_:)`.
    public func onRulesChanged(_ action: @escaping @MainActor () async -> Void) -> TestShotResultView {
        var copy = self
        copy.rulesChanged = action
        return copy
    }
}
