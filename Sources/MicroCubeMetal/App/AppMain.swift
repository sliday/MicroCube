import AppKit
import Metal
import MetalKit

private final class PassthroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class RendererShortcutWindow: NSWindow {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}

func makeHUDStatusLabel(text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    label.textColor = .white
    label.maximumNumberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

func effectiveRenderState(_ state: RenderState, reduceMotion: Bool) -> RenderState {
    var effective = state
    if reduceMotion {
        effective.paused = true
    }
    return effective
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let input = InputState()
    private(set) var renderState = RenderState()
    private var window: NSWindow?
    private var metalView: MetalInputView?
    private var renderer: Renderer?
    private weak var hudOverlay: NSView?
    private weak var hudLabel: NSTextField?
    private weak var legendLabel: NSTextField?
    private weak var explainerPanel: ExplainerPanel?
    private weak var explainerRail: NSButton?
    private var hudPanelClearanceConstraint: NSLayoutConstraint?
    private(set) var hudTrailingAnchor: NSLayoutXAxisAnchor?
    var onHUDTrailingAnchorReady: ((NSLayoutXAxisAnchor) -> Void)? {
        didSet {
            if let hudTrailingAnchor {
                onHUDTrailingAnchorReady?(hudTrailingAnchor)
            }
        }
    }
    var onRenderStateChanged: ((RenderState) -> Void)?
    var accessibilityAnnouncementHandler: (String) -> Void = { announcement in
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo:
            [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        configureWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        metalView?.releaseMouse()
    }

    func configureMenu() {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(
            withTitle: "Quit MicroCube Metal",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let fullscreenItem = viewMenu.addItem(
            withTitle: "Toggle Full Screen",
            action: #selector(toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullscreenItem.keyEquivalentModifierMask = [.control, .command]
        fullscreenItem.target = self
        viewMenu.addItem(.separator())
        let explainerItem = viewMenu.addItem(
            withTitle: "Why Rays Explainer",
            action: #selector(toggleExplainer(_:)),
            keyEquivalent: ""
        )
        explainerItem.target = self
        let hudItem = viewMenu.addItem(
            withTitle: "Toggle HUD",
            action: #selector(toggleHUD(_:)),
            keyEquivalent: ""
        )
        hudItem.target = self
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    private func configureWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = RendererShortcutWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MicroCube Metal"
        window.minSize = NSSize(width: 800, height: 500)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.center()
        window.delegate = self
        self.window = window

        let container = NSView(frame: contentRect)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = container

        guard let device = MTLCreateSystemDefaultDevice() else {
            installMetalUnavailableLabel(in: container)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let metalView = MetalInputView(frame: .zero, device: device, input: input)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.autoresizingMask = [.width, .height]
        metalView.clearColor = MTLClearColorMake(0.015, 0.02, 0.03, 1)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .invalid
        metalView.framebufferOnly = false
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.preferredFramesPerSecond = max(60, NSScreen.main?.maximumFramesPerSecond ?? 60)
        metalView.setAccessibilityElement(true)
        metalView.setAccessibilityLabel("MicroCube Metal voxel viewport")
        metalView.setAccessibilityHelp(
            "Click or press Return or Space to capture the mouse. Press Escape to release it. Use W, S, A, D, Q, and E to move."
        )
        metalView.onRenderAction = { [weak self] action in
            self?.handleRenderAction(action) ?? false
        }
        window.onKeyDown = { [weak metalView] event in
            metalView?.handleRendererShortcut(event) ?? false
        }
        container.addSubview(metalView)
        self.metalView = metalView

        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            metalView.topAnchor.constraint(equalTo: container.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        installOverlay(in: container)
        installExplainer(in: container)
        metalView.onCaptureChanged = { [weak self] captured in
            self?.setCaptureLegend(captured: captured)
        }

        guard let renderer = Renderer(
            metalView: metalView,
            input: input,
            hudUpdate: { [weak self] text in
                self?.setHUDText(text)
            }
        ) else {
            setHUDText("Metal renderer initialization failed")
            window.makeKeyAndOrderFront(nil)
            return
        }

        self.renderer = renderer
        metalView.delegate = renderer
        setRendererState()

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(metalView)
    }

    private func installOverlay(in container: NSView) {
        let overlay = PassthroughVisualEffectView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.material = .hudWindow
        overlay.blendingMode = .withinWindow
        overlay.state = .active
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 9
        overlay.layer?.masksToBounds = true
        self.hudOverlay = overlay

        let hudLabel = makeHUDStatusLabel(text: "Starting Metal renderer...")
        self.hudLabel = hudLabel

        let controlsLabel = NSTextField(
            labelWithString: captureLegend(captured: false)
        )
        controlsLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let legendAlpha = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1.0 : 0.8
        controlsLabel.textColor = NSColor.white.withAlphaComponent(legendAlpha)
        controlsLabel.maximumNumberOfLines = 2
        controlsLabel.lineBreakMode = .byWordWrapping
        controlsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.legendLabel = controlsLabel

        let stack = NSStackView(views: [hudLabel, controlsLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        overlay.addSubview(stack)
        container.addSubview(overlay)

        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            overlay.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            overlay.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            overlay.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            stack.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -9)
        ])
        hudTrailingAnchor = overlay.trailingAnchor
        onHUDTrailingAnchorReady?(overlay.trailingAnchor)
    }

    private func installExplainer(in container: NSView) {
        let copy = (try? ExplainerCopy.text()) ?? "English explainer copy is unavailable."
        let panel = ExplainerPanel(copy: copy) { [weak self] action in
            self?.handleRenderAction(action)
        }
        let rail = ExplainerPanel.makeCollapsedRail { [weak self] in
            self?.handleRenderAction(.toggleExplainer)
        }
        panel.isHidden = true
        rail.isHidden = true
        container.addSubview(panel, positioned: .above, relativeTo: metalView)
        container.addSubview(rail, positioned: .above, relativeTo: panel)
        explainerPanel = panel
        explainerRail = rail

        NSLayoutConstraint.activate([
            panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            panel.topAnchor.constraint(equalTo: container.topAnchor),
            panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            panel.widthAnchor.constraint(equalToConstant: 424),
            rail.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            rail.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            rail.widthAnchor.constraint(equalToConstant: 126),
            rail.heightAnchor.constraint(equalToConstant: 34),
        ])

        onHUDTrailingAnchorReady = { [weak self, weak panel] trailingAnchor in
            guard let self, let panel else { return }
            hudPanelClearanceConstraint?.isActive = false
            hudPanelClearanceConstraint = trailingAnchor.constraint(
                lessThanOrEqualTo: panel.leadingAnchor,
                constant: -ExplainerLayout.hudClearance
            )
            updateExplainerLayout()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        updateExplainerLayout()
    }

    private func installMetalUnavailableLabel(in container: NSView) {
        let label = NSTextField(labelWithString: "MicroCube Metal requires a Metal-capable Mac.")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        label.textColor = .white
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
    }

    private func setHUDText(_ text: String) {
        if Thread.isMainThread {
            hudLabel?.stringValue = text
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.hudLabel?.stringValue = text
        }
    }

    private func setCaptureLegend(captured: Bool) {
        legendLabel?.stringValue = captureLegend(captured: captured)
    }

    private func captureLegend(captured: Bool) -> String {
        let state = captured ? "MOUSE CAPTURED · ESC TO RELEASE" : "CLICK TO LOOK · RETURN/SPACE"
        return "\(state)   1–5  Views   G/K/L/O/X  Features   P  Pause   I  Explain   H  HUD   F  Fullscreen   R  Reset"
    }

    private func updateExplainerLayout() {
        guard let window else { return }
        switch ExplainerLayout.presentation(
            windowWidth: window.contentLayoutRect.width,
            explainerVisible: renderState.explainerVisible
        ) {
        case .hidden:
            explainerPanel?.isHidden = true
            explainerRail?.isHidden = true
            hudPanelClearanceConstraint?.isActive = false
        case .rail:
            explainerPanel?.isHidden = true
            explainerRail?.isHidden = false
            hudPanelClearanceConstraint?.isActive = false
        case .panel:
            explainerPanel?.isHidden = false
            explainerRail?.isHidden = true
            hudPanelClearanceConstraint?.isActive = true
        }
    }

    private func setRendererState() {
        renderer?.setRenderState(effectiveRenderState(
            renderState,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ))
    }

    private func featureName(_ feature: RenderFeatures) -> String {
        switch feature {
        case .gaussian: "Gaussian volumes"
        case .shadows: "Shadows"
        case .lights: "Lights"
        case .optics: "Optics"
        case .sdf: "SDF surfaces"
        default: "Feature"
        }
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        explainerPanel?.updateAppearance(
            increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        setRendererState()
    }

    @discardableResult
    func handleRenderAction(_ action: RenderAction) -> Bool {
        let consumed = renderState.apply(action)
        switch action {
        case .toggleFullscreen:
            window?.toggleFullScreen(nil)
        case .reset:
            renderer?.resetCamera()
        case .toggleHUD:
            hudOverlay?.isHidden = !renderState.hudVisible
            accessibilityAnnouncementHandler(renderState.hudVisible ? "HUD shown." : "HUD hidden.")
        case .toggleExplainer, .escape:
            updateExplainerLayout()
            if renderState.explainerVisible {
                metalView?.releaseMouse()
                accessibilityAnnouncementHandler("Why Rays explainer opened.")
            } else if let metalView {
                window?.makeFirstResponder(metalView)
                if action == .toggleExplainer || consumed {
                    accessibilityAnnouncementHandler("Why Rays explainer closed.")
                }
            }
        case .togglePause:
            accessibilityAnnouncementHandler(
                renderState.paused
                    ? "Scene motion paused. Camera remains active."
                    : "Scene motion resumed."
            )
        case .evidence(let view):
            accessibilityAnnouncementHandler("Evidence view changed to \(view.title).")
        case .toggleFeature(let feature):
            let enabled = renderState.features.contains(feature)
            accessibilityAnnouncementHandler("\(featureName(feature)) \(enabled ? "enabled" : "disabled").")
        }
        setRendererState()
        onRenderStateChanged?(renderState)
        return consumed
    }

    func windowDidResize(_ notification: Notification) {
        updateExplainerLayout()
    }

    @objc private func toggleFullScreen(_ sender: Any?) {
        window?.toggleFullScreen(sender)
    }

    @objc private func toggleExplainer(_ sender: Any?) {
        handleRenderAction(.toggleExplainer)
    }

    @objc private func toggleHUD(_ sender: Any?) {
        handleRenderAction(.toggleHUD)
    }
}
