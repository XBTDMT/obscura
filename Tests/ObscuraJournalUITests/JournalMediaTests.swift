// README media (docs/media/journal.png, journal-dark.png): the Journal window over the sample Journal (SampleData, six
// made-up catches), drawn by the window's own code through ViewSnapshot and framed on the design system's desk.
// Skipped unless OBSCURA_RENDER_MEDIA=1 (docs/media/README.md).
import AppKit
import Foundation
import SwiftUI
import Testing
import ObscuraUIKit
import ObscuraTestSupport
@testable import ObscuraJournalUI

@Suite(.serialized) @MainActor struct JournalMediaTests {
    @Test(.enabled(if: MediaOutput.enabled), arguments: [false, true])
    func journalWindow(dark: Bool) async throws {
        let (model, controller) = try await Fixtures.sampleController()
        controller.viewMode = .grid
        let first = try #require(model.entries.first?.id)
        var selection: Set<UUID> = [first]
        await controller.preload(selection: selection)
        let size = OMetric.journalSize
        let view = JournalContent(controller: controller, selection: Binding(get: { selection }, set: { selection = $0 }), onImport: {})
        let rep = try #require(Fixtures.snapshot(view, size: size, dark: dark))
        let content = try #require(rep.cgImage)
        let framed = try #require(MediaOutput.framedWindow(content, pointSize: size, dark: dark))
        try MediaOutput.writePNG(framed, name: dark ? "journal-dark" : "journal")
    }
}
