// Obscura's own menu bar item and panel (G-14, ruled 2026-10-27), replacing SwiftUI's MenuBarExtra so the panel
// can close when an action opens a window, return focus, and fade (G-15). The decisions live in `PanelPresentation`
// (pure, tested); this file only carries them out with public AppKit: an NSStatusItem whose button shows the unchanged
// `MenuBarLabel`, and a borderless non-activating NSPanel hosting `MenuBarPanel`.
public import SwiftUI
public import ObscuraUIKit
public import AppKit
import ObscuraPrefs

@MainActor
public final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let labelHost: LabelHostingView
    /// A clear image the size of the label, so the status bar sizes and pads the item exactly as it does an image item.
    private var labelSize = CGSize(width: 18, height: 18)
    private let accessibilityLabel: @MainActor () -> String
    /// When the item's spoken label next needs reading again even if nothing observed changes (a time-based state).
    private let accessibilityRefresh: @MainActor () -> TimeInterval?
    private let appearance: @MainActor () -> NSAppearance?
    private let makeContent: @MainActor (_ hook: @escaping PanelActionHook) -> AnyView
    /// Something inside the panel that Escape closes before the panel (the pause choices); true when it took it.
    private let consumesEscape: @MainActor () -> Bool
    /// Runs just before the panel opens (the app refreshes setup's progress for the setup card here).
    public var willOpen: (@MainActor () -> Void)?

    private var panel: PanelWindow?
    private var presentation = PanelPresentation()
    private var monitors: [Any] = []
    private var observers: [any NSObjectProtocol] = []
    private var resignKeyObserver: (any NSObjectProtocol)?
    /// Bumped on every open and close, so a fade that finishes late never acts on a newer presentation.
    private var generation = 0
    private var pendingFinish: (@MainActor () -> Void)?
    private var accessibilityTask: Task<Void, Never>?
    /// The mark's presenter, told the bar's appearance and highlight so a coloured mark's plain part follows them (G-21).
    private var markPresenter: MenuBarMarkPresenter?
    private var appearanceObservation: NSKeyValueObservation?

    /// The panel is showing (or fading in).
    public var isOpen: Bool { presentation.isOpen }

    /// The running app's item: the mark in its state, and the panel drawn from `model`.
    /// - Parameters:
    ///   - labelAccessory: a zero-size view mounted beside the label for the app's lifetime (the router binder).
    ///   - colorScheme: the app's Appearance setting; nil follows the Mac.
    public convenience init(model: AppModel, labelAccessory: AnyView, colorScheme: @escaping @MainActor () -> ColorScheme?) {
        // The mark's presenter owns its timing (gated checking, caught window) and the words VoiceOver reads for it.
        let presenter = MenuBarMarkPresenter.shared(for: model)
        let memory = PanelMemory.shared(for: model)
        self.init(
            label: AnyView(ZStack { labelAccessory; MenuBarLabel(model: model) }),
            accessibilityLabel: { presenter.accessibilityLabel },
            accessibilityRefresh: {
                // "Caught" ends by time, not by a change the observation sees; read the words again when it does.
                guard let end = model.caughtUntil, end > Date() else { return nil }
                return end.timeIntervalSinceNow + 0.05
            },
            colorScheme: colorScheme,
            consumesEscape: { memory.consumeEscape() },
            content: { hook in
                AnyView(MenuBarPanel(model: model, actionHook: hook).preferredColorScheme(colorScheme()))
            })
        follow(presenter)
    }

    /// Keeps the presenter told what the bar looks like: the button's effective appearance (the menu bar's, which can
    /// differ from the app's) and whether it is highlighted on an emphasized background (AppKit's own signal for drawing
    /// template content white). A template image is tinted by macOS itself; a coloured mark draws its plain part in
    /// `MarkPalette.ink` for this appearance.
    private func follow(_ presenter: MenuBarMarkPresenter) {
        markPresenter = presenter
        guard let button = statusItem.button else { return }
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateBarAppearance() }
        }
        updateBarAppearance()
    }

    private func updateBarAppearance() {
        guard let button = statusItem.button, let markPresenter else { return }
        let emphasized = button.isHighlighted && (button.cell as? NSButtonCell)?.interiorBackgroundStyle == .emphasized
        markPresenter.barAppearance = MarkAppearance(button.effectiveAppearance, emphasized: emphasized)
    }

    /// An item with its own label and panel content (the startup-failure panel, which has no actions).
    public convenience init(label: AnyView, accessibilityLabel: String, content: @escaping @MainActor () -> AnyView) {
        self.init(label: label, accessibilityLabel: { accessibilityLabel }, accessibilityRefresh: { nil },
                  colorScheme: { nil }, consumesEscape: { false }, content: { _ in content() })
    }

    private init(label: AnyView, accessibilityLabel: @escaping @MainActor () -> String,
                 accessibilityRefresh: @escaping @MainActor () -> TimeInterval?,
                 colorScheme: @escaping @MainActor () -> ColorScheme?,
                 consumesEscape: @escaping @MainActor () -> Bool,
                 content: @escaping @MainActor (_ hook: @escaping PanelActionHook) -> AnyView) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityRefresh = accessibilityRefresh
        self.appearance = { colorScheme().map { $0 == .dark ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua) } ?? nil }
        makeContent = content
        self.consumesEscape = consumesEscape
        labelHost = LabelHostingView(rootView: AnyView(EmptyView()))
        super.init()
        // The label's own SwiftUI view runs its tasks (the checking sweep, the caught window) exactly as in the
        // MenuBarExtra; it is hidden from VoiceOver because the item itself carries the words (below).
        labelHost.rootView = AnyView(label.fixedSize().accessibilityHidden(true)
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { [weak self] size in self?.labelResized(size) }))
        statusItem.autosaveName = "ObscuraStatusItem"
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.image = placeholder(labelSize)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            labelHost.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(labelHost)
            NSLayoutConstraint.activate([
                labelHost.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                labelHost.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }
        updateAccessibility()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(.appResignedActive) }
        })
    }

    // MARK: Opening and closing

    @objc private func statusItemClicked(_ sender: Any?) {
        if presentation.isOpen { close(.statusItemClicked) } else { open() }
    }

    /// Opens the panel under the item (also used when Obscura is opened again while it runs).
    public func open() {
        finishPendingClose()
        if !presentation.isOpen { willOpen?() }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard presentation.open(frontmostApp: frontmost, ownPID: ProcessInfo.processInfo.processIdentifier) else { return }
        generation &+= 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.appearance = appearance()
        // A fresh view per opening, as MenuBarExtra did: onAppear/onDisappear mark the panel open and seen, and no
        // hover highlight or scroll state survives from the last time (recon M-16).
        let host = NSHostingController(rootView: AnyView(
            PanelChrome(content: makeContent { [weak self] action, phase in self?.panelAction(action, phase) },
                        onResize: { [weak self] size in self?.contentResized(size) })))
        host.sizingOptions = []
        panel.contentViewController = host
        let size = host.sizeThatFits(in: CGSize(width: OMetric.menuBarPanelWidth, height: .greatestFiniteMagnitude))
        panel.setFrame(frame(for: size, panel: panel), display: false)
        panel.ignoresMouseEvents = false
        let reduceMotion = OMotion.systemReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.makeKeyAndOrderFront(nil)
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = OMotion.fadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        installMonitors()
        highlightItem(true)
    }

    /// Closes the panel because a window is about to open (the router calls this before every window it opens).
    public func closeForWindowOpening() { close(.windowOpening) }

    func close(_ reason: PanelPresentation.CloseReason) {
        guard let focus = presentation.close(reason) else { return }
        generation &+= 1
        let generation = self.generation
        removeMonitors()
        highlightItem(false)
        guard let panel else { return }
        panel.ignoresMouseEvents = true
        let finish: @MainActor () -> Void = { [weak self, weak panel] in
            guard let self, self.generation == generation else { return }
            self.pendingFinish = nil
            panel?.orderOut(nil)
            // Tears the SwiftUI view down: MenuBarPanel's onDisappear marks the catches seen.
            panel?.contentViewController = nil
            panel?.contentView = NSView()
        }
        pendingFinish = finish
        if OMotion.systemReduceMotion {
            finish()
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = OMotion.fadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in finish() }
            })
        }
        if case .activate(let pid) = focus { returnFocus(to: pid) }
    }

    /// A close still fading out finishes now (a quick reopen starts clean).
    private func finishPendingClose() {
        pendingFinish?()
        pendingFinish = nil
    }

    private func panelAction(_ action: PanelAction, _ phase: PanelActionPhase) {
        if PanelPresentation.closes(action, at: phase) { close(.action(action)) }
    }

    private func returnFocus(to pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        if NSApp.isActive { NSApp.yieldActivation(to: app) }
        app.activate()
    }

    // MARK: Events while open

    private func installMonitors() {
        removeMonitors()
        // A click in another app (or on the desktop, or another menu bar item) closes the panel. A click on Obscura's own
        // item arrives here too on macOS 27 (the menu bar draws it), so it is told apart by position: the item's own
        // action toggles.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            let window = event.window, location = event.locationInWindow
            MainActor.assumeIsolated {
                guard let self, !self.isOnItem(Self.screenPoint(location, in: window)) else { return }
                self.close(.clickedOutside)
            }
        }) { monitors.append(global) }
        // A click in one of Obscura's own windows closes it too; clicks in the panel and on the item do not.
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            let window = event.window, location = event.locationInWindow
            MainActor.assumeIsolated {
                guard let self, window !== self.panel, window !== self.statusItem.button?.window,
                      !self.isOnItem(Self.screenPoint(location, in: window)) else { return }
                self.close(.clickedOutside)
            }
            return event
        }) { monitors.append(local) }
        // Escape closes it. The pause choices drawn inside the panel take the first Escape (closing only them); a
        // pop-up menu open inside the panel tracks its own events, so Escape there closes only that menu.
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let window = event.window
            let keyCode = event.keyCode, flags = event.modifierFlags, base = event.characters(byApplyingModifiers: [])
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, Self.isClose(keyCode: keyCode, baseCharacters: base, flags: flags), window === self.panel else { return false }
                if self.consumesEscape() { return true }
                self.close(.escape)
                return true
            }
            return consumed ? nil : event
        }) { monitors.append(keys) }
        if let panel {
            resignKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close(.panelResignedKey) }
            }
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = nil
    }

    /// Whether a screen point is on the menu bar item (`PanelPresentation.isOnItem`), the bar taken from the item's screen:
    /// from the bar's bottom (or the item's, when the bar hides itself and the visible frame reaches the top) to the top.
    private func isOnItem(_ point: CGPoint) -> Bool {
        guard let item = itemRect(),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(item.insetBy(dx: -1, dy: -1)) }) else { return false }
        let bottom = min(screen.visibleFrame.maxY, item.minY)
        let bar = CGRect(x: screen.frame.minX, y: bottom, width: screen.frame.width, height: screen.frame.maxY - bottom)
        return PanelPresentation.isOnItem(point, item: item, menuBar: bar)
    }

    /// A mouse event's location in screen coordinates (a global monitor's event has no window: it is already there).
    private static func screenPoint(_ location: CGPoint, in window: NSWindow?) -> CGPoint {
        guard let window else { return location }
        return window.convertPoint(toScreen: location)
    }

    /// Whether a key press is the panel's Close (Esc, fixed in the catalogue: `.panelClose`). Caps Lock does not count.
    nonisolated static func isClose(keyCode: UInt16, baseCharacters: String?, flags: NSEvent.ModifierFlags) -> Bool {
        guard let chord = KeyChord.from(keyCode: keyCode, baseCharacters: baseCharacters, modifiers: .init(flags)) else { return false }
        return KeyBindings.defaults.chords(for: .panelClose).contains(chord)
    }

    // MARK: Panel window

    private func makePanel() -> PanelWindow {
        let panel = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: OMetric.menuBarPanelWidth, height: 200),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.title = "Obscura"
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Obscura fades the panel itself (OMotion); AppKit's own window animation would be a second motion.
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace, .fullScreenAuxiliary]
        return panel
    }

    private func frame(for size: CGSize, panel: NSWindow) -> CGRect {
        let item = itemRect() ?? CGRect(x: (NSScreen.main?.visibleFrame.maxX ?? 1440) - size.width, y: NSScreen.main?.visibleFrame.maxY ?? 900, width: 0, height: 0)
        let screen = NSScreen.screens.first { $0.frame.intersects(item.insetBy(dx: -1, dy: -1)) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
        return PanelPresentation.frame(contentSize: size, item: item, visible: visible)
    }

    /// The item's button in screen coordinates, or nil when the item has no window yet.
    private func itemRect() -> CGRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        return rect.width > 1 && rect.height > 1 ? rect : nil
    }

    /// The panel's content changed height (a banner came or went): the top edge stays put.
    private func contentResized(_ size: CGSize) {
        guard presentation.isOpen, let panel, size.height > 0 else { return }
        let frame = frame(for: CGSize(width: OMetric.menuBarPanelWidth, height: size.height), panel: panel)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    // MARK: The item

    private func highlightItem(_ on: Bool) {
        statusItem.button?.highlight(on)
        updateBarAppearance()
        // A mouse-down action runs inside the button's own tracking, which resets the highlight on mouse-up; set it
        // again once tracking has ended (the default run loop mode only runs then).
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.statusItem.button?.highlight(self.presentation.isOpen)
                self.updateBarAppearance()
            }
        }
    }

    private func labelResized(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != labelSize else { return }
        labelSize = size
        statusItem.button?.image = placeholder(size)
        updateAccessibility()
    }

    private func placeholder(_ size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.isTemplate = true
        return image
    }

    /// The words VoiceOver reads for the item, kept current with the model.
    private func updateAccessibility() {
        let words = withObservationTracking { accessibilityLabel() } onChange: { [weak self] in
            Task { @MainActor in self?.updateAccessibility() }
        }
        statusItem.button?.setAccessibilityLabel(words)
        statusItem.button?.image?.accessibilityDescription = words
        accessibilityTask?.cancel()
        accessibilityTask = nil
        if let delay = accessibilityRefresh() {
            accessibilityTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.updateAccessibility()
            }
        }
    }
}

/// The non-activating panel: it takes the keyboard (arrow keys, Return, the ⌘ shortcuts, Escape) without making Obscura
/// the active app, so the app the user came from keeps its place and gets ⌘V after Copy Clean.
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The label's host inside the status item button: it draws, and lets every click through to the button.
final class LabelHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The panel's material, corner and hairline (menubar.html `.panel`: 12 pt radius, the popover blur, a 0.5 pt edge).
struct PanelChrome: View {
    var content: AnyView
    var onResize: @MainActor (CGSize) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelPresentation.cornerRadius, style: .continuous)
        content
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(shape)
            .background(PanelMaterial(cornerRadius: PanelPresentation.cornerRadius))
            .overlay(shape.strokeBorder(colorScheme == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.12), lineWidth: 0.5))
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { size in onResize(size) })
    }
}

/// The popover material behind the panel's content, always drawn active (the panel is key while another app is active).
/// Its rounded corners come from the effect view's own mask image, the supported way to shape a behind-window material.
private struct PanelMaterial: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(radius: cornerRadius)
        return view
    }

    /// A stretchable rounded-rectangle mask: only the corners keep their shape when the panel changes height.
    static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
