// VisionKit Live Text over the ORIGINAL image.
// Text-only interaction (.automaticTextOnly); a drag on text selects, elsewhere it pans; the context menu gains
// "Always Black Out Things Like This" and "Never Black Out This" when text is selected. The selection is never logged.
import AppKit
import VisionKit
import ObscuraSupport

@MainActor
final class LiveTextController: NSObject, ImageAnalysisOverlayViewDelegate {
    let overlay = ImageAnalysisOverlayView()
    /// Called with the selection when one of the two rule items is chosen.
    var onRule: ((String, LiveTextRuleIntent) -> Void)?

    private var analyzer: ImageAnalyzer?
    private var task: Task<Void, Never>?
    private var analyzedURL: URL?
    private var active = false

    static var isSupported: Bool { ImageAnalyzer.isSupported }

    override init() {
        super.init()
        overlay.delegate = self
        overlay.preferredInteractionTypes = .automaticTextOnly
        overlay.autoresizingMask = [.width, .height]
        overlay.isHidden = true
        overlay.isSupplementaryInterfaceHidden = true
    }

    /// Adds the overlay over `imageView`, tracking its image rect.
    func attach(to imageView: NSImageView) {
        overlay.trackingImageView = imageView
        overlay.frame = imageView.bounds
        if overlay.superview !== imageView { imageView.addSubview(overlay) }
    }

    /// Shows or hides the overlay; hiding also clears any selection so nothing stays selected over the redacted image.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if !on, overlay.hasActiveTextSelection { overlay.resetSelection() }
        overlay.isHidden = !on
    }

    /// Reads the text of the original file once (VisionKit analyses from the file URL).
    func analyze(originalAt url: URL) {
        guard Self.isSupported, url != analyzedURL else { return }
        analyzedURL = url
        task?.cancel()
        overlay.analysis = nil
        let analyzer = self.analyzer ?? ImageAnalyzer()
        self.analyzer = analyzer
        task = Task { [weak self] in
            do {
                let configuration = ImageAnalyzer.Configuration([.text])
                let analysis = try await analyzer.analyze(imageAt: url, orientation: .up, configuration: configuration)
                guard !Task.isCancelled, let self else { return }
                self.overlay.analysis = analysis
            } catch {
                Log.app.error("live text analysis failed")
                self?.analyzedURL = nil
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// The selected text while the overlay is active, else nil.
    var selectedText: String? {
        guard active, overlay.hasActiveTextSelection else { return nil }
        let text = overlay.selectedText
        return text.isEmpty ? nil : text
    }

    // MARK: ImageAnalysisOverlayViewDelegate

    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldBeginAt point: CGPoint,
                     forAnalysisType analysisType: ImageAnalysisOverlayView.InteractionTypes) -> Bool {
        overlayView.hasText(at: point) || overlayView.hasInteractiveItem(at: point)
    }

    func overlayView(_ overlayView: ImageAnalysisOverlayView, updatedMenuFor menu: NSMenu, for event: NSEvent, at point: CGPoint) -> NSMenu {
        let text = overlayView.selectedText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return menu }
        menu.addItem(.separator())
        menu.addItem(Self.ruleItem(String(localized: "Always Black Out Things Like This"), symbol: "eye.slash") { [weak self] in
            self?.onRule?(text, .alwaysBlackOut)
        })
        menu.addItem(Self.ruleItem(String(localized: "Never Black Out This"), symbol: "eye") { [weak self] in
            self?.onRule?(text, .neverBlackOut)
        })
        return menu
    }

    static func ruleItem(_ title: String, symbol: String, action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = ActionMenuItem(title: title, handler: action)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError("not used") }

    @MainActor @objc private func run() { handler() }
}
