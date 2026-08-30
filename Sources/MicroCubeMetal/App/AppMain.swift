import AppKit
import Darwin
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

struct AccessibilityDisplayOptions: Equatable {
    var increasedContrast: Bool
    var reduceMotion: Bool

    static var current: Self {
        Self(
            increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
}

func postAccessibilityAnnouncement(_ announcement: String) {
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

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let input = InputState()
    private let accessibilityDisplayOptionsProvider: () -> AccessibilityDisplayOptions
    private let qaMode: QAMode?
    private let startupError: String?
    private let automationRequested: Bool
    private let thermalStateBefore: String
    private(set) var exitStatus: Int32 = 0
    private var automationFinished = false
    private(set) var renderState = RenderState()
    private(set) var window: NSWindow?
    private(set) var metalView: MetalInputView?
    private(set) var renderer: Renderer?
    private(set) weak var hudOverlay: NSView?
    private weak var hudLabel: NSTextField?
    private weak var legendLabel: NSTextField?
    private(set) weak var explainerPanel: ExplainerPanel?
    private(set) weak var explainerRail: NSButton?
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
    var accessibilityAnnouncementHandler: (String) -> Void

    init(
        accessibilityDisplayOptionsProvider: @escaping () -> AccessibilityDisplayOptions = { .current },
        accessibilityAnnouncementPoster: @escaping (String) -> Void = postAccessibilityAnnouncement,
        qaMode: QAMode? = nil,
        startupError: String? = nil,
        automationRequested: Bool = false
    ) {
        self.accessibilityDisplayOptionsProvider = accessibilityDisplayOptionsProvider
        self.qaMode = qaMode
        self.startupError = startupError
        self.automationRequested = automationRequested || qaMode != nil || startupError != nil
        thermalStateBefore = Self.thermalStateName(ProcessInfo.processInfo.thermalState)
        accessibilityAnnouncementHandler = { announcement in
            accessibilityAnnouncementPoster(announcement)
        }
        super.init()
    }

    static func main() {
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        let requested = arguments.contains {
            $0 == "--benchmark" || $0.hasPrefix("--qa-") || $0.hasPrefix("--benchmark-")
        }
        let mode: QAMode?
        let startupError: String?
        do {
            mode = try QAMode.parseIfRequested(arguments)
            startupError = nil
        } catch {
            mode = nil
            startupError = error.localizedDescription
        }
        let application = NSApplication.shared
        let delegate = AppDelegate(
            qaMode: mode,
            startupError: startupError,
            automationRequested: requested
        )
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
        if delegate.automationRequested {
            exit(delegate.exitStatus)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        configureWindow()
        NSApp.activate(ignoringOtherApps: true)
        if let startupError {
            setHUDText(startupError)
            DispatchQueue.main.async { [weak self] in
                self?.finishAutomation(status: 2)
            }
        }
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

    func configureWindow() {
        let contentSize = qaMode?.windowPoints ?? SIMD2<Int>(1280, 800)
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: contentSize.x,
            height: contentSize.y
        )
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
            if qaMode != nil {
                finishQA(
                    RendererQAResult(
                        final: true,
                        failure: "MicroCube Metal requires a Metal-capable Mac.",
                        drawableCapture: nil,
                        gpuMilliseconds: [],
                        stepCounters: [:],
                        budgetOverflows: 0,
                        commandErrors: 1,
                        droppedDrawables: 0,
                        semaphoreTimeouts: 0
                    )
                )
            }
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
            guard self?.qaMode == nil else { return true }
            return self?.handleRenderAction(action) ?? false
        }
        window.onKeyDown = { [weak self, weak metalView] event in
            guard self?.qaMode == nil else { return true }
            return metalView?.handleRendererShortcut(event) ?? false
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

        let renderer: Renderer
        do {
            renderer = try Renderer(
                metalView: metalView,
                input: input,
                qaScene: qaMode?.scene,
                hudUpdate: { [weak self] text in
                    self?.setHUDText(text)
                }
            )
        } catch {
            setHUDText(error.localizedDescription)
            window.makeKeyAndOrderFront(nil)
            if qaMode != nil {
                finishQA(
                    RendererQAResult(
                        final: true,
                        failure: error.localizedDescription,
                        drawableCapture: nil,
                        gpuMilliseconds: [],
                        stepCounters: [:],
                        budgetOverflows: 0,
                        commandErrors: 1,
                        droppedDrawables: 0,
                        semaphoreTimeouts: 0
                    )
                )
            }
            return
        }

        self.renderer = renderer
        metalView.delegate = renderer
        if let qaMode {
            renderState.features = qaMode.features
            renderState.paused = true
        }
        setRendererState()

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(metalView)
        if let qaMode {
            setHUDText(
                "QA \(qaMode.scene.rawValue) · T \(qaMode.fixedTime) · \(qaMode.drawablePixels.x)×\(qaMode.drawablePixels.y) · \(qaMode.featureMask)"
            )
            renderer.configureQA(qaMode) { [weak self] result in
                self?.handleQAResult(result)
            }
            container.layoutSubtreeIfNeeded()
            DispatchQueue.main.async { [weak metalView] in
                metalView?.draw()
            }
        }
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
        let legendAlpha = accessibilityDisplayOptionsProvider().increasedContrast ? 1.0 : 0.8
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
        panel.apply(renderState: renderState)
        panel.updateAppearance(increasedContrast: accessibilityDisplayOptionsProvider().increasedContrast)

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
            metalView?.nextKeyView = nil
            explainerRail?.nextKeyView = nil
        case .rail:
            explainerPanel?.isHidden = true
            explainerRail?.isHidden = false
            hudPanelClearanceConstraint?.isActive = false
            metalView?.nextKeyView = explainerRail
            explainerRail?.nextKeyView = metalView
        case .panel:
            explainerPanel?.isHidden = false
            explainerRail?.isHidden = true
            hudPanelClearanceConstraint?.isActive = true
            metalView?.nextKeyView = nil
            explainerRail?.nextKeyView = nil
        }
    }

    private func setRendererState() {
        let options = accessibilityDisplayOptionsProvider()
        renderer?.setRenderState(effectiveRenderState(
            renderState,
            reduceMotion: options.reduceMotion
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
        let options = accessibilityDisplayOptionsProvider()
        explainerPanel?.updateAppearance(increasedContrast: options.increasedContrast)
        setRendererState()
    }

    @discardableResult
    func handleRenderAction(_ action: RenderAction) -> Bool {
        let consumed = renderState.apply(action)
        explainerPanel?.apply(renderState: renderState)
        setRendererState()
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
                window?.makeFirstResponder(explainerPanel?.closeButton)
                accessibilityAnnouncementHandler("Why Rays explainer opened.")
            } else if action == .toggleExplainer || consumed {
                switch ExplainerLayout.presentation(
                    windowWidth: window?.contentLayoutRect.width ?? 1100,
                    explainerVisible: false
                ) {
                case .rail:
                    window?.makeFirstResponder(explainerRail)
                case .hidden, .panel:
                    window?.makeFirstResponder(metalView)
                }
                accessibilityAnnouncementHandler("Why Rays explainer closed.")
            }
        case .togglePause:
            let effective = renderer?.currentRenderState() ?? effectiveRenderState(
                renderState,
                reduceMotion: accessibilityDisplayOptionsProvider().reduceMotion
            )
            if renderState.paused {
                accessibilityAnnouncementHandler("Scene motion paused. Camera remains active.")
            } else if effective.paused {
                accessibilityAnnouncementHandler("Scene motion remains held by Reduce Motion. Camera remains active.")
            } else {
                accessibilityAnnouncementHandler("Scene motion resumed.")
            }
        case .evidence(let view):
            accessibilityAnnouncementHandler("Evidence view changed to \(view.title).")
        case .toggleFeature(let feature):
            let enabled = renderState.features.contains(feature)
            accessibilityAnnouncementHandler("\(featureName(feature)) \(enabled ? "enabled" : "disabled").")
        }
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

    private func handleQAResult(_ result: RendererQAResult) {
        guard result.final else {
            metalView?.draw()
            return
        }
        finishQA(result)
    }

    private func finishQA(_ result: RendererQAResult) {
        guard let qaMode else {
            finishAutomation(status: 2)
            return
        }
        var failure = result.failure
        if failure == nil, let capturePath = qaMode.capturePath {
            do {
                switch qaMode.captureScope {
                case .drawable:
                    guard let capture = result.drawableCapture else {
                        throw QAError.writeFailed(
                            path: capturePath,
                            diagnostic: "renderer did not return the completed drawable"
                        )
                    }
                    try capture.writePNG(to: capturePath)
                case .window:
                    try writeWindowCapture(to: capturePath)
                }
            } catch {
                failure = error.localizedDescription
            }
        }

        let thermalStateAfter = Self.thermalStateName(ProcessInfo.processInfo.thermalState)
        if failure == nil, let benchmark = qaMode.benchmark {
            if result.gpuMilliseconds.count != benchmark.measuredFrames {
                failure = "Benchmark recorded \(result.gpuMilliseconds.count) GPU samples; expected \(benchmark.measuredFrames)."
            } else if result.gpuMilliseconds.contains(where: { !$0.isFinite || $0 <= 0 }) {
                failure = "Benchmark GPU samples must be finite and positive."
            } else if qaMode.featureMask != "all" || qaMode.renderScale != 1 || qaMode.view != .final {
                failure = "Benchmark requires featureMask all, renderScale 1.0, and final view."
            } else if thermalStateBefore != "nominal" || thermalStateAfter != "nominal" {
                failure = "Benchmark requires nominal thermal state before and after the run."
            }
        }
        if failure == nil, result.commandErrors > 0 {
            failure = "Renderer reported \(result.commandErrors) command-buffer errors."
        }
        if failure == nil, result.droppedDrawables > 0 {
            failure = "Renderer dropped \(result.droppedDrawables) drawables."
        }
        if failure == nil, result.semaphoreTimeouts > 0 {
            failure = "Renderer reported \(result.semaphoreTimeouts) in-flight semaphore timeouts."
        }

        let benchmark = qaMode.benchmark
        let report = QAFrameReport(
            status: failure == nil ? "pass" : "fail",
            failure: failure,
            device: metalView?.device?.name ?? "No Metal device",
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            scene: qaMode.scene.rawValue,
            fixedTime: qaMode.fixedTime,
            drawablePixels: [qaMode.drawablePixels.x, qaMode.drawablePixels.y],
            renderScale: qaMode.renderScale,
            windowCount: NSApplication.shared.windows.count,
            productionKernels: [
                "generateTerrain",
                "reduceOccupancy",
                "buildMixedOccupancy",
                "reduceMixedOccupancy",
                "clearVolumeLighting",
                "injectVolumeLighting",
                "raycastHybrid",
            ],
            featureMask: qaMode.featureMask,
            passCount: 2,
            stepCounters: result.stepCounters,
            shadowSampleCounts: [
                "surfaceSun": result.stepCounters["surfaceSunShadows"] ?? 0,
                "surfaceLocal": result.stepCounters["surfaceLocalShadows"] ?? 0,
                "volumeSun": result.stepCounters["volumeSunShadows"] ?? 0,
                "volumeLocal": result.stepCounters["volumeLocalShadows"] ?? 0,
            ],
            budgetOverflows: result.budgetOverflows,
            commandErrors: result.commandErrors,
            droppedDrawables: result.droppedDrawables,
            semaphoreTimeouts: result.semaphoreTimeouts,
            capturePath: qaMode.capturePath,
            fixedStep: qaMode.fixedStep,
            warmupFrames: benchmark?.warmupFrames ?? 0,
            measuredFrames: benchmark?.measuredFrames ?? 0,
            gpuMilliseconds: result.gpuMilliseconds,
            thermalStateBefore: benchmark == nil ? nil : thermalStateBefore,
            thermalStateAfter: benchmark == nil ? nil : thermalStateAfter
        )
        if let reportPath = qaMode.reportPath {
            do {
                try report.write(to: reportPath)
            } catch {
                failure = error.localizedDescription
                FileHandle.standardError.write(Data("\(failure!)\n".utf8))
            }
        }
        finishAutomation(status: failure == nil ? 0 : 1)
    }

    private func writeWindowCapture(to path: String) throws {
        guard let contentView = window?.contentView else {
            throw QAError.writeFailed(path: path, diagnostic: "the existing window has no content view")
        }
        contentView.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            throw QAError.writeFailed(path: path, diagnostic: "AppKit could not allocate a window bitmap")
        }
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw QAError.writeFailed(path: path, diagnostic: "AppKit PNG encoding failed")
        }
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw QAError.writeFailed(path: path, diagnostic: error.localizedDescription)
        }
    }

    private func finishAutomation(status: Int32) {
        guard automationRequested, !automationFinished else { return }
        automationFinished = true
        exitStatus = status
        let application = NSApplication.shared
        application.stop(nil)
        if let wakeEvent = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) {
            application.postEvent(wakeEvent, atStart: false)
        }
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
