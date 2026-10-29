import CoreGraphics
import Foundation
import ImageIO
import ObscuraCapture
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraRender
import ObscuraSupport
import UniformTypeIdentifiers
@testable import ObscuraEngine

/// Everything a test needs to drive the engine without Vision, AppKit or a real home folder.
enum Fixture {
    /// Made-up Stripe-shaped key (also a positive line in Tests/Fixtures/text/payments.stripe.secretkey.json).
    static let fakeKey = "sk_live_gHBJ59jWkyqhEGdgw5UhJjnc"
    static let keyLine = OCRLine(index: 0, text: "STRIPE_SECRET_KEY=\(fakeKey)", rect: CGRect(x: 20, y: 20, width: 440, height: 28))
    static let plainLine = OCRLine(index: 1, text: "nothing to see here, just a plain sentence", rect: CGRect(x: 20, y: 70, width: 400, height: 28))

    static let imageSize = (width: 480, height: 120)

    /// A white PNG with a grey band so the renderer has something to sample; carries no text at all.
    static func pngData() -> Data {
        let image = whiteImage()
        return try! ImageCodec.encode(image, as: .png, dpi: nil, quality: nil)
    }

    static func whiteImage() -> CGImage {
        let ctx = CGContext(data: nil, width: imageSize.width, height: imageSize.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height))
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.85, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: imageSize.width, height: 10))
        return ctx.makeImage()!
    }

    /// A PNG signature followed by garbage: an image container that does not decode.
    static let corruptPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x41, count: 64)

    static func tempDirectory(_ label: String) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let dir = base.appendingPathComponent("obscura-engine-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// RGBA bytes read by drawing (never by trusting the source layout).
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

    /// Pixels (top-left origin) where the two images differ by more than `tolerance` on any channel.
    static func differingPixels(_ a: CGImage, _ b: CGImage, tolerance: Int = 2) -> [CGPoint] {
        let pa = pixels(a), pb = pixels(b)
        guard pa.count == pb.count else { return [CGPoint(x: -1, y: -1)] }
        var out: [CGPoint] = []
        let w = a.width
        for i in stride(from: 0, to: pa.count, by: 4) {
            for c in 0..<4 where abs(Int(pa[i + c]) - Int(pb[i + c])) > tolerance {
                let p = i / 4
                out.append(CGPoint(x: p % w, y: w == 0 ? 0 : p / w))
                break
            }
        }
        return out
    }

    static func decode(_ data: Data) throws -> CGImage { try ImageCodec.decode(data).image }
}

/// A recognizer that throws what it is told to, or waits before answering (to keep a scan in flight).
struct ScriptedRecognizer: TextRecognizer {
    var lines: [OCRLine] = []
    var error: OCRError? = nil
    var delay: Duration? = nil

    func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine] {
        if let delay { try await Task.sleep(for: delay) }
        if let error { throw error }
        return lines
    }
}

/// The screenshot folder and Downloads a test engine sees: folders of the test's own, never the user's. Until a test
/// says otherwise they name a folder that does not exist, so no file is inside either.
final class TestFolders: @unchecked Sendable {
    private let lock = NSLock()
    private var screenshot = FileManager.default.temporaryDirectory.appendingPathComponent("obscura-no-screenshots-\(UUID().uuidString)")
    private var downloadsFolder = FileManager.default.temporaryDirectory.appendingPathComponent("obscura-no-downloads-\(UUID().uuidString)")

    var screenshotFolder: URL {
        get { lock.withLock { screenshot } }
        set { lock.withLock { screenshot = newValue } }
    }
    var downloads: URL {
        get { lock.withLock { downloadsFolder } }
        set { lock.withLock { downloadsFolder = newValue } }
    }
    var locations: FolderLocations { FolderLocations(screenshotFolder: { self.screenshotFolder }, downloads: { self.downloads }) }

    /// The person's confirmations of Downloads and added folders (G-36), in memory.
    let approvals = InMemoryFolderApprovalStore()

    /// Makes `folder` a watched folder of `origin` in `settings` (F26: the engine writes only files in folders it watches),
    /// confirmed as the person would in Obscura (G-36).
    func watch(_ folder: URL, as origin: FileOrigin, in settings: InMemorySettingsStore) {
        switch origin {
        case .screenshotFolder:
            screenshotFolder = folder
            settings.update { $0.guardsScreenshotFolder = true }
        case .downloads:
            downloads = folder
            confirm(folder)
            settings.update { $0.guardsDownloads = true }
        case .watched(let root):
            confirm(root)
            settings.update { s in if !s.extraFolders.contains(root.path) { s.extraFolders.append(root.path) } }
        case .imported:
            break
        }
    }

    /// Confirms `folder` as the person would in Obscura (an open-panel pick).
    func confirm(_ folder: URL) {
        guard let approval = FolderApproval.current(folder, at: Date()) else { return }
        let current = (try? approvals.load()) ?? []
        try? approvals.save(current.filter { $0.path != approval.path } + [approval])
    }
}

/// One engine with its collaborators, on a temp Journal root that is removed on `tearDown`.
struct Harness {
    let root: URL
    let journal: SQLiteJournalStore
    let settings: InMemorySettingsStore
    let clock: ManualClock
    let engine: ShieldEngine
    let folders = TestFolders()

    init(recognizer: any TextRecognizer = StubTextRecognizer(lines: [Fixture.keyLine, Fixture.plainLine]),
         settings: Settings = .default, sources: [any CaptureSource] = [], folderWatcher: FolderWatcher? = nil,
         ruleKeys: any RuleKeyStore = InMemoryRuleKeyStore(), root existing: URL? = nil) throws {
        root = try existing ?? Fixture.tempDirectory("journal")
        clock = ManualClock()
        journal = try SQLiteJournalStore(root: root, ruleKeys: ruleKeys, clock: clock)
        self.settings = InMemorySettingsStore(settings)
        // A test's starting settings stand for a person who set them up in Obscura: their added folders are confirmed.
        for url in ShieldEngine.extraFolderURLs(settings) { folders.confirm(url) }
        engine = ShieldEngine(sources: sources, recognizer: recognizer, journal: journal, settings: self.settings, clock: clock,
                              folderWatcher: folderWatcher, clipboardGuard: nil, locations: folders.locations,
                              folderApprovals: folders.approvals)
    }

    /// Makes `folder` a watched folder of `origin`, as the person's settings would.
    func watch(_ folder: URL, as origin: FileOrigin) { folders.watch(folder, as: origin, in: settings) }

    /// A file scanned with an origin came from a watched folder of that origin: the folder is watched first, as it is in
    /// the app (the folder watcher only hands over files from watched folders).
    func scan(_ data: Data = Fixture.pngData(), name: String = "Screenshot.png", filePath: URL? = nil, origin: FileOrigin? = nil) async -> ScanOutcome {
        if let filePath, let origin { watch(filePath.deletingLastPathComponent(), as: origin) }
        return await engine.scan(imageData: data, source: .file, displayName: name, filePath: filePath, origin: origin)
    }

    func tearDown() { try? FileManager.default.removeItem(at: root) }
}

/// Collects `count` reports from an outcomes stream, or whatever arrived before `timeout`.
func collect(_ stream: AsyncStream<ScanReport>, count: Int, timeout: Duration) async -> [ScanReport] {
    let box = ReportBox()
    let task = Task {
        for await report in stream {
            if box.append(report) >= count { break }
        }
    }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline, box.count < count {
        try? await Task.sleep(for: .milliseconds(20))
    }
    task.cancel()
    return box.all
}

final class ReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [ScanReport] = []
    func append(_ r: ScanReport) -> Int { lock.withLock { reports.append(r); return reports.count } }
    var count: Int { lock.withLock { reports.count } }
    var all: [ScanReport] { lock.withLock { reports } }
}
