// README media (docs/media/viewer.png, viewer-dark.png): the Viewer on a sample catch with one finding left visible, so
// its dashed outline, the numbered badges and the inspector show. Drawn by the window's own code through ViewSnapshot;
// the toolbar is window chrome (not in the content snapshot), so its own pieces are drawn into the title band the
// window keeps for it. Every value is made up (SampleData). Skipped unless OBSCURA_RENDER_MEDIA=1 (docs/media/README.md).
import AppKit
import Foundation
import SwiftUI
import Testing
import ObscuraUIKit
import ObscuraTestSupport
@testable import ObscuraViewerUI

@Suite(.serialized) @MainActor struct ViewerMediaTests {
    static let toolbarHeight: CGFloat = 52

    @Test(.enabled(if: MediaOutput.enabled), arguments: [false, true])
    func viewerWithAFindingLeftVisible(dark: Bool) async throws {
        let model = try await SampleData.model(entries: 6)
        let entry = try #require(model.entries.first { $0.findings.contains { !$0.enabled } })
        let (window, host) = await Snapshot.host(ViewerWindow(model: model, entryID: entry.id), width: 880, dark: dark)
        let rep = try #require(Snapshot.bitmap(host))
        window.close()
        let content = try #require(rep.cgImage)
        let size = host.bounds.size

        let bar = HStack(spacing: 12) {
            TitleBlock(name: entry.displayName, subtitle: ViewerCopy.subtitle(enabled: entry.enabledFindings.count, total: entry.findings.count),
                       isLive: false)
            Spacer()
            ToolbarCenter(mode: .redacted, originalAvailable: true, isPeeking: false) { _ in }
            Spacer()
            ToolbarTrailing(keys: .defaults, zoomLabel: "Fit", zoomEnabled: true, inspectorOn: true, zoomOut: {}, zoomIn: {}, actual: {}, fit: {},
                            copy: {}, toggleInspector: {})
        }
        .padding(.leading, 84).padding(.trailing, 14)
        .frame(width: size.width, height: Self.toolbarHeight)
        // Hosted alone in a borderless window, so the picture is exactly the band (a titled window adds its own title bar).
        let barHost = NSHostingView(rootView: bar.environment(\.colorScheme, dark ? .dark : .light))
        barHost.frame = CGRect(x: 0, y: 0, width: size.width, height: Self.toolbarHeight)
        let barWindow = NSWindow(contentRect: barHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        barWindow.isReleasedWhenClosed = false
        barWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        barWindow.contentView = barHost
        await Snapshot.spin(barHost)
        let barRep = try #require(ViewSnapshot.bitmap(barHost))
        barWindow.close()
        let toolbar = try #require(barRep.cgImage)
        let barSize = barRep.size

        let framed = try #require(MediaOutput.framedWindow(content, pointSize: size, dark: dark) { ctx, window in
            let band = CGRect(x: window.minX, y: window.maxY - Self.toolbarHeight + (Self.toolbarHeight - barSize.height) / 2,
                              width: barSize.width, height: barSize.height)
            ctx.draw(toolbar, in: band)
        })
        try MediaOutput.writePNG(framed, name: dark ? "viewer-dark" : "viewer")
    }
}
