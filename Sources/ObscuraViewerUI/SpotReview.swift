// G-40: the viewer for a picture whose only unread parts are small spots no reading could read. The picture as it is on
// disk, each spot outlined (the viewer's left-visible outline: a solid line and a dashed ring clear of the mark), its
// state beside it, and the person's two answers for the spots still waiting: Not Text (checked by the person, never
// "clean" by Obscura) and Cover It (a normal cover over the padded spot, through the entry's picture path, undoable).
// The window opens from the panel's Review…, the Journal's Not checked row, or a catch's viewer.
public import SwiftUI
public import ObscuraUIKit
import AppKit
import ObscuraEngine
import ObscuraJournal

/// What the spot viewer shows for one row, as values (tested without a window).
struct SpotReviewContent: Equatable {
    struct Outline: Equatable, Identifiable {
        var id: Int
        /// The spot's rect in the picture's pixels.
        var rect: CGRect
        var state: SpotState
        /// A waiting spot is drawn in the needs tone; a settled one in the quiet tone.
        var tone: Tone
        var label: String
    }

    var title: String
    var lead: String
    var outlines: [Outline]
    /// Not Text and Cover It act on the spots still waiting; with none waiting the buttons are not shown.
    var showsActions: Bool
    /// Cover It needs the file (it is read again to cover it); a moved or deleted file can only be marked Not Text.
    var canCover: Bool

    init(file: UncheckedFile, fileExists: Bool) {
        let pending = file.pendingSpots
        title = file.displayName
        lead = pending > 0 ? SpotCopy.viewerLead(pending) : SpotCopy.viewerSettled
        outlines = file.spots.enumerated().map { i, spot in
            Outline(id: i, rect: spot.rect, state: spot.state, tone: spot.state == .pending ? .needs : .quiet, label: SpotCopy.state(spot.state))
        }
        showsActions = pending > 0
        canCover = fileExists
    }

    /// An outline's frame on screen for a picture of `pixelSize` drawn at `drawn` size: the spot's rect scaled, grown by
    /// the outline's gap so the line never lies on the mark itself.
    static func frame(_ rect: CGRect, pixelSize: CGSize, drawn: CGSize, gap: CGFloat) -> CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return .zero }
        let sx = drawn.width / pixelSize.width, sy = drawn.height / pixelSize.height
        return CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy).insetBy(dx: -gap, dy: -gap)
    }
}

/// The spot viewer's window content.
public struct SpotReviewWindow: View {
    let model: AppModel
    let fileID: UUID

    @State private var file: UncheckedFile?
    @State private var image: NSImage?
    @State private var loaded = false
    @State private var working = false

    public init(model: AppModel, fileID: UUID) {
        self.model = model
        self.fileID = fileID
    }

    public var body: some View {
        Group {
            if let file {
                content(file)
            } else if loaded {
                Text(ViewerCopy.loadFailed).font(OFont.body).foregroundStyle(OColor.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: OMetric.viewerWidth, idealWidth: OMetric.viewerWidth, maxWidth: .infinity, minHeight: 420, idealHeight: 520, maxHeight: .infinity)
        .background(OColor.window)
        .navigationTitle(file?.displayName ?? String(localized: "Viewer"))
        .oToasts(model.toast.map { [$0.item] } ?? [], placement: .bottom)
        .task(id: fileID) { await reload() }
        // A row settled elsewhere (the Journal, an Undo) shows here as it now is.
        .onChange(of: model.status.unchecked) { _, _ in Task { await reload() } }
    }

    private func reload() async {
        file = await model.spotFile(fileID)
        if image == nil, let url = file?.fileURL { image = NSImage(contentsOf: url) }
        loaded = true
    }

    private func content(_ file: UncheckedFile) -> some View {
        let exists = FileManager.default.fileExists(atPath: file.fileURL.path)
        let shown = SpotReviewContent(file: file, fileExists: exists)
        return VStack(spacing: 0) {
            ZStack {
                OColor.canvas
                if let image { picture(image, outlines: shown.outlines) } else {
                    Text(String(localized: "The file was moved or deleted.")).font(OFont.body).foregroundStyle(OColor.text2)
                }
            }
            bar(file, shown: shown)
        }
    }

    private func picture(_ image: NSImage, outlines: [SpotReviewContent.Outline]) -> some View {
        let pixelSize = ViewerState.pixelSize(of: image) ?? image.size
        return GeometryReader { geo in
            let fit = Self.fitted(pixelSize, in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable().interpolation(.high).frame(width: fit.width, height: fit.height)
                ForEach(outlines) { outline in
                    let r = SpotReviewContent.frame(outline.rect, pixelSize: pixelSize, drawn: fit, gap: 3)
                    SpotOutline(tone: outline.tone)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .help(outline.label)
                        .accessibilityLabel(Text(outline.label))
                }
            }
            .frame(width: fit.width, height: fit.height)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .padding(16)
    }

    private func bar(_ file: UncheckedFile, shown: SpotReviewContent) -> some View {
        HStack(spacing: OMetric.Space.l) {
            Image(systemName: "viewfinder").foregroundStyle(shown.showsActions ? OColor.needsText : OColor.text3).accessibilityHidden(true)
            Text(shown.lead).font(.system(size: 12)).foregroundStyle(OColor.text1).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: OMetric.Space.m)
            if shown.showsActions {
                Button(SpotCopy.notText) { act(file, .notText) }
                    .buttonStyle(OButtonStyle(.quiet)).help(SpotCopy.notTextHelp).disabled(working)
                Button(SpotCopy.coverIt) { act(file, .cover) }
                    .buttonStyle(OButtonStyle(.primary)).help(SpotCopy.coverItHelp).disabled(working || !shown.canCover)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(OColor.window)
        .overlay(alignment: .top) { Rectangle().fill(OColor.separator).frame(height: OMetric.hairline) }
    }

    private func act(_ current: UncheckedFile, _ how: ShieldEngine.SpotSettlement) {
        working = true
        Task {
            if let after = await model.settleSpots(current, how) {
                file = after
                if how == .cover, let url = after.spots.isEmpty ? nil : after.fileURL { image = NSImage(contentsOf: url) }
            }
            working = false
        }
    }

    /// The picture's size fitted inside `bounds`, never enlarged.
    static func fitted(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let s = min(1, min(bounds.width / size.width, bounds.height / size.height))
        return CGSize(width: size.width * s, height: size.height * s)
    }
}

/// G-40, in a catch's viewer: the picture also has spots no reading could read (waiting, covered, or skipped), said in
/// one quiet line with Review… to see them outlined.
struct SpotStrip: View {
    let row: UncheckedFile
    let review: () -> Void

    static func words(_ row: UncheckedFile) -> String {
        row.pendingSpots > 0 ? SpotCopy.title(row.pendingSpots) + " · " + SpotCopy.viewerLead(row.pendingSpots)
                             : SpotCopy.settledSummary(row.spots)
    }

    var body: some View {
        HStack(spacing: OMetric.Space.m) {
            Image(systemName: "viewfinder").foregroundStyle(row.pendingSpots > 0 ? OColor.needsText : OColor.text3).accessibilityHidden(true)
            Text(Self.words(row)).font(.system(size: 11.5)).foregroundStyle(OColor.text2).lineLimit(2)
            Spacer(minLength: OMetric.Space.m)
            Button(SpotCopy.review, action: review).buttonStyle(OButtonStyle(.quiet, size: .small))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(OColor.window)
        .overlay(alignment: .top) { Rectangle().fill(OColor.separator).frame(height: OMetric.hairline) }
    }
}

/// The viewer's outline for a mark to look at (the left-visible outline's look): a solid line and a dashed ring outside
/// it, clear of the mark.
struct SpotOutline: View {
    var tone: Tone

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(tone.color, lineWidth: 1.5)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(tone.color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .padding(-2.5)
        }
    }
}
