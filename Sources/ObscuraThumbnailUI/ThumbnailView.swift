// ObscuraThumbnailUI — the card as r3-a draws it: macOS's 176 × 110 pt thumbnail with one capsule on the lower-left
// ("Checked", "N covered", "Checking…", or the red "Original showing" with a dashed red frame), a one-click capsule on
// hover (Undo, or Black Out Again), and up to two card edges behind it for a burst. Pointer input is handled by the
// AppKit host (the panel never becomes key); the view carries the look and the VoiceOver actions.
import AppKit
import SwiftUI
import ObscuraUIKit

/// Everything the card draws.
struct ThumbnailContent {
    var displayName: String
    var image: NSImage?
    var capsule: CapsuleKind
    var hoverAction: HoverAction?
    var hovering: Bool
    var edges: Int
}

/// What the card's controls and VoiceOver actions do. The pointer path goes through the AppKit host instead.
struct ThumbnailActions {
    var open: @MainActor () -> Void = {}
    var hoverAction: @MainActor () -> Void = {}
    var copy: @MainActor () -> Void = {}
    var showInFinder: @MainActor () -> Void = {}
    var close: @MainActor () -> Void = {}
}

/// The hosted root: reads the controller's store so the panel redraws on every change.
struct ThumbnailRoot: View {
    let store: ThumbnailStore
    let actions: ThumbnailActions

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let content = store.content {
                ThumbnailView(content: content, actions: actions) { store.hoverActionFrame = $0 }
                    .preferredColorScheme(store.colorScheme)
                    .padding(.leading, store.areaOrigin.x)
                    .padding(.top, store.areaOrigin.y)
            }
        }
        // The panel is larger than the card area (room for the shadow, and reaching the display's edge); the card
        // area sits where the window put it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ThumbnailView: View {
    nonisolated static let space = "obscura.thumbnail"

    let content: ThumbnailContent
    var actions = ThumbnailActions()
    /// The hover capsule's frame in the panel (top-left origin), so the host can route a click on it.
    var onHoverActionFrame: (CGRect?) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private typealias P = ThumbnailPlacement

    var body: some View {
        ZStack(alignment: .topLeading) {
            card
                // The 2 pt hover lift is instant (G-15: nothing moves but the thumbnail's own slide).
                .offset(x: P.marginSide, y: P.marginTop - (content.hovering ? 2 : 0))
        }
        .frame(width: P.panelSize.width, height: P.panelSize.height, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        .onChange(of: showsHoverAction) { _, shown in if !shown { onHoverActionFrame(nil) } }
    }

    /// The one fade (G-15, S-8): checking → result, "Checked" folding, covered ↔ original, the hover capsule and the
    /// burst edges cross-fade; instant under Reduce Motion.
    private var fade: Animation? { OMotion.fade(reduceMotion: reduceMotion) }

    /// Identity of the image on show, so a new image (the clean one replacing the checking blur, or the original after
    /// Undo) cross-fades instead of snapping.
    private var imageIdentity: ObjectIdentifier? { content.image.map(ObjectIdentifier.init) }

    private var showsHoverAction: Bool { content.hovering && content.hoverAction != nil }

    // MARK: Card

    private var card: some View {
        ZStack(alignment: .bottomLeading) {
            image
            capsule.padding(OMetric.FloatingCard.capsuleInset)
            if showsHoverAction, let action = content.hoverAction {
                hoverButton(action)
                    .padding(OMetric.FloatingCard.capsuleInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(width: P.cardSize.width, height: P.cardSize.height)
        .background(alignment: .top) { edges.animation(fade, value: content.edges) }
        .overlay {
            if content.capsule.marksOriginal {
                RoundedRectangle(cornerRadius: OMetric.FloatingCard.corner + 3, style: .continuous)
                    .stroke(OColor.live, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .padding(-3)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .animation(fade, value: content.capsule)
        .animation(fade, value: showsHoverAction)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(ThumbnailCopy.accessibilityLabel(content.displayName)))
        .accessibilityValue(Text(ThumbnailCopy.accessibilityValue(content.capsule)))
        .accessibilityAction(named: Text(ThumbnailCopy.openAction)) { actions.open() }
        .accessibilityAction(named: Text(ThumbnailCopy.copyAction)) { actions.copy() }
        .accessibilityAction(named: Text(ThumbnailCopy.showInFinderAction)) { actions.showInFinder() }
        .accessibilityAction(named: Text(ThumbnailCopy.closeAction)) { actions.close() }
    }

    private var image: some View {
        let shape = RoundedRectangle(cornerRadius: OMetric.FloatingCard.corner, style: .continuous)
        let checking = content.capsule == .checking
        return ZStack {
            OColor.terminal
            if let nsImage = content.image {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    // Anchored top-left, where a screenshot's first lines are (r3-a crops the same way).
                    .frame(width: P.cardSize.width, height: P.cardSize.height, alignment: .topLeading)
                    // Checking: blurred past legibility, so nothing unscanned can be read off the corner.
                    .blur(radius: checking ? 4 : 0, opaque: true)
                    .opacity(checking ? 0.6 : 1)
                    .id(imageIdentity)
                    .transition(.opacity)
            }
            if checking {
                Spinner(size: 22, lineWidth: 2.5, track: .white.opacity(0.3), arc: .white)
                    .transition(.opacity)
            }
        }
        .frame(width: P.cardSize.width, height: P.cardSize.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(OColor.imageEdge, lineWidth: OMetric.hairline))
        .animation(fade, value: imageIdentity)
        .modifier(CardShadow(lifted: content.hovering, dark: colorScheme == .dark))
        .accessibilityHidden(true)
    }

    /// Two card edges behind the newest shot count the others in a burst.
    @ViewBuilder private var edges: some View {
        let edge = UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7, style: .continuous)
        ZStack(alignment: .top) {
            if content.edges >= 2 {
                edge.fill(OColor.card)
                    .overlay(edge.strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
                    .frame(width: P.cardSize.width - 40, height: OMetric.FloatingCard.edgeHeight)
                    .opacity(0.75)
                    .offset(y: -11)
            }
            if content.edges >= 1 {
                edge.fill(OColor.card)
                    .overlay(edge.strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
                    .frame(width: P.cardSize.width - 20, height: OMetric.FloatingCard.edgeHeight)
                    .offset(y: -6)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Capsules

    @ViewBuilder private var capsule: some View {
        switch content.capsule {
        case .checking:
            CardCapsule {
                ObscuraTile()
                Spinner()
                Text(ThumbnailCopy.checking)
            }
        case .checked:
            CardCapsule {
                ObscuraTile()
                Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(OColor.ok)
                Text(ThumbnailCopy.checked)
            }
        case .folded:
            CardCapsule(folded: true) { ObscuraTile() }
        case .covered(let n):
            CardCapsule {
                ObscuraTile()
                CoverBar()
                Text(ThumbnailCopy.covered(n))
            }
        case .original:
            // While hovering, the red capsule keeps its eye and gives its words' room to Black Out Again; the dashed
            // frame and VoiceOver still say "Original showing".
            CardCapsule(tint: OColor.live, foreground: .white, folded: content.hovering) {
                Image(systemName: "eye").font(.system(size: 9, weight: .bold))
                if !content.hovering { Text(ThumbnailCopy.originalShowing) }
            }
        }
    }

    private func hoverButton(_ action: HoverAction) -> some View {
        Button {
            actions.hoverAction()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: action == .undo ? "arrow.uturn.backward" : "eye.slash")
                    .font(.system(size: 9, weight: .bold))
                Text(action == .undo ? ThumbnailCopy.undo : ThumbnailCopy.blackOutAgain)
            }
            .font(OFont.capsule)
            .foregroundStyle(OColor.accentText)
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .frame(height: OMetric.FloatingCard.capsuleHeight)
            .background(Capsule().fill(OColor.popover))
            .overlay(Capsule().strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(action == .undo ? ThumbnailCopy.undoAccessibility : ThumbnailCopy.blackOutAgain))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { onHoverActionFrame($0) }
    }
}

/// r3-a's `.timg` shadow (`.timg.lift` while hovered), drawn by the card so it moves with the slide. CSS blur radii are
/// twice SwiftUI's shadow radius.
private struct CardShadow: ViewModifier {
    var lifted: Bool
    var dark: Bool

    func body(content: Content) -> some View {
        let ink = Color(red: 16 / 255, green: 20 / 255, blue: 36 / 255)
        let far: (Color, CGFloat, CGFloat) = dark
            ? (.black.opacity(lifted ? 0.66 : 0.6), lifted ? 20 : 15, lifted ? 18 : 12)
            : (ink.opacity(lifted ? 0.36 : 0.30), lifted ? 20 : 15, lifted ? 18 : 12)
        let near: (Color, CGFloat, CGFloat) = dark
            ? (.black.opacity(lifted ? 0.4 : 0.35), lifted ? 4 : 3, lifted ? 3 : 2)
            : (.black.opacity(lifted ? 0.16 : 0.14), lifted ? 4 : 3, lifted ? 3 : 2)
        content
            .shadow(color: near.0, radius: near.1, y: near.2)
            .shadow(color: far.0, radius: far.1, y: far.2)
    }
}

/// The Obscura tile: the Glass O ring on an accent square (r3-a `.otile`, 13 pt).
private struct ObscuraTile: View {
    var body: some View {
        let s = OMetric.FloatingCard.tileSize
        RoundedRectangle(cornerRadius: s * 4 / 16, style: .continuous)
            .fill(OColor.accent)
            .overlay(Circle().stroke(.white, lineWidth: s * 2.1 / 16).frame(width: s * 8 / 16, height: s * 8 / 16))
            .frame(width: s, height: s)
    }
}

/// `.cb`: a 12 × 5 pt cover bar in the redaction mark's colour.
private struct CoverBar: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(OColor.mark)
            .overlay(RoundedRectangle(cornerRadius: 1.5, style: .continuous).strokeBorder(OColor.coverBarEdge, lineWidth: OMetric.hairline))
            .frame(width: 12, height: 5)
    }
}

/// The thumbnail's words, all through the String Catalog.
enum ThumbnailCopy {
    static var checking: String { String(localized: "Checking…") }
    static var checked: String { String(localized: "Checked") }
    static func covered(_ n: Int) -> String { String(localized: "\(n) covered") }
    static var originalShowing: String { String(localized: "Original showing") }
    static var undo: String { String(localized: "Undo") }
    static var undoAccessibility: String { String(localized: "Undo: put the original back") }
    static var blackOutAgain: String { String(localized: "Black Out Again") }
    static var openAction: String { String(localized: "Open") }
    static var copyAction: String { String(localized: "Copy") }
    static var showInFinderAction: String { String(localized: "Show in Finder") }
    static var closeAction: String { String(localized: "Close") }

    static func accessibilityLabel(_ name: String) -> String { String(localized: "Screenshot thumbnail, \(name)") }

    static func accessibilityValue(_ capsule: CapsuleKind) -> String {
        switch capsule {
        case .checking: return String(localized: "Checking for secrets")
        case .checked, .folded: return String(localized: "Checked, nothing to cover")
        case .covered(let n): return n == 1 ? String(localized: "1 secret covered") : String(localized: "\(n) secrets covered")
        case .original(let n): return n == 1 ? String(localized: "Original showing, 1 secret visible")
                                             : String(localized: "Original showing, \(n) secrets visible")
        }
    }

    // Menu
    static var copy: String { String(localized: "Copy") }
    static var copyCleanSubtitle: String { String(localized: "The clean image") }
    static var copyOriginalSubtitle: String { String(localized: "The original, with every secret") }
    static var openInViewer: String { String(localized: "Open in Obscura Viewer") }
    static var openInPreview: String { String(localized: "Open in Preview") }
    static var showInFinder: String { String(localized: "Show in Finder") }
    static var openInJournal: String { String(localized: "Open in Journal") }
    static var undoMenu: String { String(localized: "Undo (Show Original)") }
    static var undoSubtitle: String { String(localized: "Puts the original back on disk") }
    static var blackOutSubtitle: String { String(localized: "Covers every secret again") }
    static var delete: String { String(localized: "Delete") }
    static var close: String { String(localized: "Close") }
}
