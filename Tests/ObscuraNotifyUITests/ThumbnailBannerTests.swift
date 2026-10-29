import Foundation
import Testing
import ObscuraCapture
import ObscuraJournal
import ObscuraPrefs
import ObscuraUIKit
@testable import ObscuraEngine
@testable import ObscuraNotifyUI

/// With Obscura's floating thumbnail on, a screenshot catch posts no banner (the thumbnail is the notice); every other
/// source, every problem, and every screenshot catch with the thumbnail off keeps its banner (B-9, G-8, r3-a). The
/// notifier decides from the report's own origin and keeps no memory of scan starts (G-9).
@MainActor
@Suite struct ThumbnailBannerTests {
    static let shot = URL(fileURLWithPath: "/home/example/Desktop/Screenshot 2026-10-26 at 9.41.12 AM.png")

    func run(origin: FileOrigin?, thumbnailOn: Bool,
             outcome: (UUID) -> ScanOutcome = { .redacted(entryID: $0, findings: 4, duration: .milliseconds(100)) }) async throws -> [NotificationPlan] {
        var settings = ObscuraPrefs.Settings.default
        settings.thumbnailEnabled = thumbnailOn
        let model = try await SampleData.model(entries: 3, settings: settings)
        let client = RecordingClient()
        let notifier = Notifier(model: model, client: client, now: { Date() })
        let entry = try #require(model.entries.first { $0.source == .file })
        let key: CaptureKey = origin == nil ? .pasteboard(changeCount: 7) : CaptureKey(file: Self.shot)
        notifier.handle(ScanReport(key: key, displayName: entry.displayName, outcome: outcome(entry.id),
                                   fileURL: origin == nil ? nil : Self.shot, origin: origin))
        await notifier.drain()
        return client.added
    }

    @Test func aScreenshotCatchPostsNoBannerWhileTheThumbnailIsOn() async throws {
        #expect(try await run(origin: .screenshotFolder, thumbnailOn: true).isEmpty)
    }

    @Test func withTheThumbnailOffScreenshotsGetTheBannerAgain() async throws {
        #expect(try await run(origin: .screenshotFolder, thumbnailOn: false).map(\.kind) == [.catchOne])
    }

    @Test func otherSourcesKeepTheirBanners() async throws {
        #expect(try await run(origin: .downloads, thumbnailOn: true).map(\.kind) == [.catchOne])
        #expect(try await run(origin: .watched(URL(fileURLWithPath: "/home/example/Shots")), thumbnailOn: true).map(\.kind) == [.catchOne])
        #expect(try await run(origin: nil, thumbnailOn: true).map(\.kind) == [.catchOne], "clipboard")
    }

    @Test func importsKeepTheirBanners() async throws {
        #expect(try await run(origin: .imported, thumbnailOn: true).map(\.kind) == [.catchOne])
    }

    @Test func repeatedScreenshotReportsAreEachDecidedAlone() async throws {
        // Two reports of the same file (a re-scan after an edit): each is quiet on its own origin, with no start
        // bookkeeping left behind to go stale and quiet a later Downloads catch of a file with the same path.
        var settings = ObscuraPrefs.Settings.default
        settings.thumbnailEnabled = true
        let model = try await SampleData.model(entries: 3, settings: settings)
        let client = RecordingClient()
        let notifier = Notifier(model: model, client: client, now: { Date() })
        let entry = try #require(model.entries.first { $0.source == .file })
        let key = CaptureKey(file: Self.shot)
        for _ in 0..<2 {
            notifier.handle(ScanReport(key: key, displayName: entry.displayName,
                                       outcome: .redacted(entryID: entry.id, findings: 1, duration: .milliseconds(90)),
                                       fileURL: Self.shot, origin: .screenshotFolder))
        }
        notifier.handle(ScanReport(key: key, displayName: entry.displayName,
                                   outcome: .redacted(entryID: entry.id, findings: 1, duration: .milliseconds(90)),
                                   fileURL: Self.shot, origin: .downloads))
        await notifier.drain()
        #expect(client.added.map(\.kind) == [.catchOne])
    }

    @Test func screenshotProblemsKeepTheirAlerts() async throws {
        let plans = try await run(origin: .screenshotFolder, thumbnailOn: true) { _ in .skipped(.ocrTimeout) }
        #expect(plans.map(\.kind) == [.problem])
    }

    @Test func theRuleOnlyQuietsCatches() {
        let id = UUID()
        #expect(!CatchBannerRule.posts(.caught(entryID: id), origin: .screenshotFolder, thumbnailOn: true))
        #expect(CatchBannerRule.posts(.caught(entryID: id), origin: .screenshotFolder, thumbnailOn: false))
        #expect(CatchBannerRule.posts(.caught(entryID: id), origin: .downloads, thumbnailOn: true))
        #expect(CatchBannerRule.posts(.caught(entryID: id), origin: nil, thumbnailOn: true), "clipboard")
        #expect(CatchBannerRule.posts(.writeFailed(path: Self.shot.path), origin: .screenshotFolder, thumbnailOn: true))
        #expect(CatchBannerRule.posts(.unchecked(.timedOut, path: Self.shot.path), origin: .screenshotFolder, thumbnailOn: true))
    }
}
