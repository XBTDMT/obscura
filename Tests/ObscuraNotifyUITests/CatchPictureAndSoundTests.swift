import CoreGraphics
import Foundation
import ImageIO
import Testing
import ObscuraJournal
import ObscuraPrefs
import ObscuraUIKit
@testable import ObscuraNotifyUI

/// G-19 #10: the catch banner's picture is a crop of the CLEAN image around the finding, from a temporary file that is
/// deleted after posting. Every secret in the sample terminal is made up.
@Suite struct CatchCropTests {
    let image = CGSize(width: 1000, height: 600)

    @Test func aSquareThreeFindingsHighCentredOnTheFinding() throws {
        let rect = try #require(CatchCrop.rect(imageSize: image, finding: CGRect(x: 400, y: 280, width: 300, height: 40)))
        #expect(rect == CGRect(x: 490, y: 240, width: 120, height: 120))
        #expect(rect.midX == 550 && rect.midY == 300)
    }

    @Test func aTinyFindingStillGetsTheMinimumSide() throws {
        let rect = try #require(CatchCrop.rect(imageSize: image, finding: CGRect(x: 500, y: 300, width: 10, height: 6)))
        #expect(rect.width == CatchCrop.minimumSide && rect.height == CatchCrop.minimumSide)
    }

    @Test func theCropIsMovedInsideAtEveryEdge() throws {
        // Centred at (10, 15), a 90-point square would start at (-35, -30): it is moved to the corner.
        let topLeft = try #require(CatchCrop.rect(imageSize: image, finding: CGRect(x: 0, y: 0, width: 20, height: 30)))
        #expect(topLeft == CGRect(x: 0, y: 0, width: 90, height: 90))
        // Only the top edge is crossed: the crop keeps its centre across and moves down.
        let top = try #require(CatchCrop.rect(imageSize: image, finding: CGRect(x: 0, y: 0, width: 200, height: 30)))
        #expect(top == CGRect(x: 55, y: 0, width: 90, height: 90))
        // Centred at (985, 590), a 64-point square would end at (1017, 622): it is moved to the corner.
        let bottomRight = try #require(CatchCrop.rect(imageSize: image, finding: CGRect(x: 970, y: 580, width: 30, height: 20)))
        #expect(bottomRight == CGRect(x: 936, y: 536, width: 64, height: 64))
        let bounds = CGRect(origin: .zero, size: image)
        #expect(bounds.contains(topLeft) && bounds.contains(bottomRight))
    }

    @Test func aFindingTallerThanTheImageIsClampedToItsShorterSide() throws {
        let rect = try #require(CatchCrop.rect(imageSize: CGSize(width: 300, height: 90), finding: CGRect(x: 10, y: 10, width: 280, height: 70)))
        #expect(rect.width == 90 && rect.height == 90)
        #expect(rect.minY == 0 && rect.maxY == 90)
        #expect(rect.minX >= 0 && rect.maxX <= 300)
    }

    @Test func aFindingPartlyOutsideUsesItsVisiblePart() throws {
        let rect = try #require(CatchCrop.rect(imageSize: image, finding: CGRect(x: -50, y: 100, width: 100, height: 30)))
        #expect(rect.minX == 0)
    }

    @Test func nothingToCropGivesNoPicture() {
        #expect(CatchCrop.rect(imageSize: .zero, finding: CGRect(x: 0, y: 0, width: 10, height: 10)) == nil)
        #expect(CatchCrop.rect(imageSize: image, finding: CGRect(x: 2000, y: 2000, width: 10, height: 10)) == nil)
        #expect(CatchCrop.rect(imageSize: image, finding: CGRect(x: 10, y: 10, width: 0, height: 0)) == nil)
    }
}

@MainActor
@Suite(.serialized) struct CatchPictureNotifierTests {
    struct Rig {
        let notifier: Notifier
        let model: AppModel
        let client: RecordingClient
        let folder: URL
    }

    func rig(_ edit: (inout ObscuraPrefs.Settings) -> Void = { _ in }, client: RecordingClient = RecordingClient()) async throws -> Rig {
        var settings = ObscuraPrefs.Settings.default
        edit(&settings)
        let model = try await SampleData.model(entries: 3, settings: settings)
        let notifier = Notifier(model: model, client: client, now: { Date() })
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("obscura-catch-pictures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        notifier.pictureDirectory = folder
        return Rig(notifier: notifier, model: model, client: client, folder: folder)
    }

    static func decode(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes
    }

    @Test func aCoveredCatchCarriesTheCleanCropAndTheFileIsGoneAfter() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.folder) }
        let entry = try #require(r.model.entries.first { $0.source == .file && $0.findings.allSatisfy(\.enabled) })
        await r.notifier.process(.caught(entryID: entry.id), displayName: entry.displayName)

        let plan = try #require(r.client.added.last)
        let file = try #require(plan.pictureFile)
        #expect(!FileManager.default.fileExists(atPath: file.path), "the temporary picture is deleted after posting")
        #expect(try FileManager.default.contentsOfDirectory(atPath: r.folder.path).isEmpty)
        let picture = try Self.decode(try #require(r.client.pictures.last ?? nil))
        #expect(picture.width == picture.height, "a square crop, as the decision page drew")

        // The picture is the clean image's crop around the first finding, pixel for pixel, and not the original's.
        let clean = try Self.decode(try await r.model.journal.cleanData(entry.id))
        let original = try Self.decode(try await r.model.journal.originalData(entry.id))
        let rect = try #require(CatchCrop.rect(imageSize: CGSize(width: clean.width, height: clean.height), finding: entry.findings[0].rect))
        #expect(Self.pixels(picture) == Self.pixels(try #require(clean.cropping(to: rect))))
        #expect(Self.pixels(picture) != Self.pixels(try #require(original.cropping(to: rect))), "never the original")
    }

    @Test func aCatchWithAFindingLeftVisibleHasNoPicture() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.folder) }
        let entry = try #require(r.model.entries.first { $0.findings.contains { !$0.enabled } })
        await r.notifier.process(.caught(entryID: entry.id), displayName: entry.displayName)
        #expect(r.client.added.last?.pictureFile == nil, "its clean image shows a secret, so it is never pictured")
        #expect(try FileManager.default.contentsOfDirectory(atPath: r.folder.path).isEmpty)
    }

    /// Fail-open #14: the banner used to read the entry ("every finding covered") and then the clean bytes in a second
    /// call; an Undo between the two put the original in the crop. The flags and the bytes now come from one read, so a
    /// catch undone before its banner is drawn has no picture, whatever an earlier read of the entry said.
    @Test func aCatchUndoneBeforeItsBannerIsDrawnHasNoPicture() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.folder) }
        let stale = try #require(r.model.entries.first { $0.source == .file && $0.findings.allSatisfy(\.enabled) })
        // The Undo lands (the original becomes the entry's picture, every finding visible) after the entry was read.
        try await r.model.journal.commitRender(stale.id, clean: try await r.model.journal.originalData(stale.id), enabled: [], style: nil,
                                               expectedRevision: stale.revision)
        let staleSaysCovered = stale.findings.allSatisfy(\.enabled)
        #expect(staleSaysCovered, "the earlier read still says covered")
        #expect(await CatchPicture.write(entryID: stale.id, journal: r.model.journal, directory: r.folder) == nil,
                "never a crop of the original")
        await r.notifier.process(.caught(entryID: stale.id), displayName: stale.displayName)
        #expect(r.client.added.last?.pictureFile == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: r.folder.path).isEmpty)
    }

    @Test func notificationsOffWriteNoPicture() async throws {
        let r = try await rig { $0.showsNotifications = false }
        defer { try? FileManager.default.removeItem(at: r.folder) }
        for entry in r.model.entries { await r.notifier.process(.caught(entryID: entry.id), displayName: entry.displayName) }
        #expect(r.client.added.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: r.folder.path).isEmpty)
    }

    // MARK: #8 sound on every catch

    @Test func catchesAreSilentByDefault() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.folder) }
        #expect(ObscuraPrefs.Settings.default.catchSound == false)
        let entry = try #require(r.model.entries.first { $0.source == .file })
        await r.notifier.process(.caught(entryID: entry.id), displayName: entry.displayName)
        #expect(r.client.added.last?.sound == false)
    }

    @Test func theSettingSoundsEveryCatch() async throws {
        let r = try await rig { $0.catchSound = true }
        defer { try? FileManager.default.removeItem(at: r.folder) }
        let entry = try #require(r.model.entries.first { $0.source == .file })
        await r.notifier.process(.caught(entryID: entry.id), displayName: entry.displayName)
        #expect(r.client.added.last?.sound == true)
    }

    @Test func obscurasSoundsOffInSystemSettingsWin() async throws {
        let client = RecordingClient()
        client.snapshotValue.playsSounds = false
        let r = try await rig({ $0.catchSound = true }, client: client)
        defer { try? FileManager.default.removeItem(at: r.folder) }
        let entry = try #require(r.model.entries.first { $0.source == .file })
        await r.notifier.process(.caught(entryID: entry.id), displayName: entry.displayName)
        #expect(r.client.added.last?.sound == false, "the notification sound setting is respected")
    }

    @Test func aBurstSummarySoundsWithTheSettingToo() async throws {
        let r = try await rig { $0.catchSound = true }
        defer { try? FileManager.default.removeItem(at: r.folder) }
        let entry = try #require(r.model.entries.first { $0.source == .file })
        let base = try #require(CatchFacts(entry: entry))
        for i in 0..<3 {
            var facts = base
            facts.entryID = UUID()
            facts.displayName = "Screenshot \(i).png"
            await r.notifier.postCatch(facts)
        }
        let summary = try #require(r.client.added.last { $0.kind == .summary })
        #expect(summary.sound == true)
    }
}

/// G-19 #11 from a banner: Undo asks first with the setting, and a cancel leaves the summary untouched.
@MainActor
@Suite struct NotificationUndoConfirmationTests {
    @Test func aCancelledUndoFromABannerChangesNothing() async throws {
        var settings = ObscuraPrefs.Settings.default
        settings.confirmsUndo = true
        let client = RecordingClient()
        let model = try await SampleData.model(entries: 3, settings: settings)
        let notifier = Notifier(model: model, client: client, now: { Date() })
        var asked = 0
        model.confirmUndo = { _ in asked += 1; return false }
        let entry = try #require(model.entries.first { $0.source == .file })
        let before = client.added.count
        await notifier.perform(.undo(entry.id))
        #expect(asked == 1)
        #expect(client.added.count == before && client.removed.isEmpty)
    }
}
