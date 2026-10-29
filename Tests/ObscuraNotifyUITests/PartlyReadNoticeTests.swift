// Fail-open #1: a catch from a picture only part of which could be read is announced as a catch AND as not checked,
// whoever announces the catch (the banner, or the screenshot thumbnail, which suppresses the banner). Made-up entries.
import Foundation
import Testing
import ObscuraCapture
import ObscuraEngine
import ObscuraPrefs
@testable import ObscuraNotifyUI

@MainActor
@Suite struct PartlyReadNoticeTests {
    @Test func aPartlyReadScreenshotPostsTheNotCheckedNoticeEvenWhenTheThumbnailAnnouncesTheCatch() async throws {
        var settings = ObscuraPrefs.Settings.default
        settings.thumbnailEnabled = true
        let client = RecordingClient()
        let (notifier, model) = try await NotifierTests().makeNotifier(settings: settings, client: client)
        let entry = try #require(model.entries.first { $0.source == .file })
        let shot = URL(fileURLWithPath: "/home/example/Desktop/\(entry.displayName)")
        let report = ScanReport(key: CaptureKey(file: shot), displayName: entry.displayName,
                                outcome: .redacted(entryID: entry.id, findings: 4, duration: .milliseconds(100)),
                                fileURL: shot, origin: .screenshotFolder, notes: [.partlyRead, .partlyReadTimedOut])
        notifier.thumbnailClaims = { _ in true }
        notifier.handle(report)
        await notifier.drain()
        #expect(client.added.count == 1, "the thumbnail announces the catch; the not-checked notice still posts")
        let notice = try #require(client.added.first)
        #expect(notice.title == "Couldn't check all of one screenshot")
        #expect(notice.body.contains("took over") && notice.body.contains("blacked out"))
    }

    @Test func aCatchReadWholePostsNoNotCheckedNotice() async throws {
        let client = RecordingClient()
        let (notifier, model) = try await NotifierTests().makeNotifier(client: client)
        let entry = try #require(model.entries.first { $0.source == .file })
        let shot = URL(fileURLWithPath: "/home/example/Downloads/\(entry.displayName)")
        let report = ScanReport(key: CaptureKey(file: shot), displayName: entry.displayName,
                                outcome: .redacted(entryID: entry.id, findings: 4, duration: .milliseconds(100)),
                                fileURL: shot, origin: .downloads)
        notifier.handle(report)
        await notifier.drain()
        #expect(client.added.map(\.kind) == [.catchOne])
    }

    @Test func aPartlyReadClipboardCatchSaysTheRestIsUnchecked() async throws {
        let client = RecordingClient()
        let (notifier, model) = try await NotifierTests().makeNotifier(client: client)
        let entry = try #require(model.entries.first { $0.source == .clipboard } ?? model.entries.first)
        let report = ScanReport(key: .pasteboard(changeCount: 7), displayName: "Clipboard",
                                outcome: .redacted(entryID: entry.id, findings: 1, duration: .milliseconds(100)), notes: [.partlyRead])
        notifier.handle(report)
        await notifier.drain()
        let notice = try #require(client.added.first { $0.title == "Couldn't check all of the image you copied" })
        #expect(notice.body.contains("couldn't be read") && notice.body.contains("unchecked"))
    }
}
