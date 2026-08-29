import AppKit
import Metal
import MetalKit

private final class PassthroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let input = InputState()
    private var window: NSWindow?
    private var metalView: MetalInputView?
    private var renderer: Renderer?
    private weak var hudLabel: NSTextField?
    private weak var legendLabel: NSTextField?

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

    private func configureMenu() {
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
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        NSApp.mainMenu = mainMenu
    }

    private func configureWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(
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
        metalView.onToggleFullscreen = { [weak window] in
            window?.toggleFullScreen(nil)
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
        metalView.onReset = { [weak renderer] in
            renderer?.resetCamera()
        }

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

        let hudLabel = NSTextField(labelWithString: "Starting Metal renderer...")
        hudLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        hudLabel.textColor = .white
        hudLabel.lineBreakMode = .byTruncatingTail
        hudLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        return "\(state)   W/S/A/D  Move   Q/E  Vertical   SHIFT  Boost   F  Fullscreen   R  Reset"
    }

    @objc private func toggleFullScreen(_ sender: Any?) {
        window?.toggleFullScreen(sender)
    }
}
