import AppKit
import Metal
import XCTest
@testable import MicroCubeMetal

private final class CaptureColorView: NSView {
    let color: NSColor

    init(frame: NSRect, color: NSColor) {
        self.color = color
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}

final class UIStateTests: XCTestCase {
    func testPanelTabLoopIncludesCloseEvidenceFeaturesAndNativeLinks() {
        let panel = ExplainerPanel(copy: "Quoted copy", actionHandler: { _ in })
        let controls: [NSView] = [panel.closeButton]
            + panel.evidenceButtons
            + panel.featureButtons
            + panel.sourceLinkFields

        XCTAssertEqual(panel.evidenceButtons.count, 5)
        XCTAssertEqual(panel.featureButtons.count, 5)
        XCTAssertEqual(panel.sourceLinkFields.count, 3)
        XCTAssertTrue(controls.allSatisfy(\.acceptsFirstResponder))
        for (control, nextControl) in zip(controls, Array(controls.dropFirst()) + [panel.closeButton]) {
            XCTAssertTrue(
                control.nextKeyView === nextControl,
                "Expected \(control) to advance to \(nextControl), got \(String(describing: control.nextKeyView))"
            )
        }
    }

    func testPanelUsesThirteenPointBodyTextAndRequiredDisclosures() {
        let panel = ExplainerPanel(copy: "Quoted copy", actionHandler: { _ in })

        XCTAssertFalse(panel.bodyTextFields.isEmpty)
        XCTAssertTrue(panel.bodyTextFields.allSatisfy { ($0.font?.pointSize ?? 0) >= 13 })
        XCTAssertEqual(Set(panel.disclosureLabels.map(\.stringValue)), Set([
            "SOURCE QUOTE · ORIGINAL AUTHOR'S DEMO",
            "SOURCE CLAIM · NOT A RESULT FROM THIS MAC APP",
            "CURRENT MAC APP · 1 HYBRID IMAGE KERNEL + 1 VOLUME LIGHT KERNEL",
            "CONCEPT IN THIS MAC DEMO · NO PHYSICS OR AUDIO SYSTEM RUNS HERE",
        ]))
    }

    func testQuotedPassagesCarryAdjacentSourceCurrentAndConceptDisclosures() throws {
        let panel = ExplainerPanel(copy: try ExplainerCopy.text(), actionHandler: { _ in })
        let scrollView = try XCTUnwrap(panel.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scrollView.documentView)
        let stack = try XCTUnwrap(document.subviews.compactMap { $0 as? NSStackView }.first)
        let fields = stack.arrangedSubviews.compactMap { $0 as? NSTextField }
        let source = "SOURCE QUOTE · ORIGINAL AUTHOR'S DEMO"
        let current = "CURRENT MAC APP · 1 HYBRID IMAGE KERNEL + 1 VOLUME LIGHT KERNEL"
        let claim = "SOURCE CLAIM · NOT A RESULT FROM THIS MAC APP"
        let concept = "CONCEPT IN THIS MAC DEMO · NO PHYSICS OR AUDIO SYSTEM RUNS HERE"

        func index(containing text: String) throws -> Int {
            try XCTUnwrap(fields.firstIndex { $0.stringValue.contains(text) }, "Missing visible text: \(text)")
        }

        for passageStart in [
            "Why do I use ray tracing",
            "I set myself a condition",
            "I managed to feel my way",
        ] {
            let passageIndex = try index(containing: passageStart)
            XCTAssertEqual(fields[passageIndex - 1].stringValue, source)
        }
        XCTAssertEqual(fields[try index(containing: "exactly two technical advantages") + 1].stringValue, current)
        XCTAssertEqual(fields[try index(containing: "renders voxels, SDFs, Gaussians") + 1].stringValue, current)
        XCTAssertEqual(fields[try index(containing: "1,073,741,824 colored voxels") + 1].stringValue, claim)
        XCTAssertEqual(fields[try index(containing: "all together in one frame") + 1].stringValue, current)
        XCTAssertEqual(fields[try index(containing: "collisions and force directions") + 1].stringValue, concept)
    }

    func testPanelUsesNativeLinkFieldsWithSpecifiedTargets() throws {
        let panel = ExplainerPanel(copy: "Quoted copy", actionHandler: { _ in })
        let expected = [
            "https://iquilezles.org/articles/raymarchingdf/",
            "https://advsys.net/ken/voxlap.htm",
            "https://www.youtube.com/watch?v=IM1Dr98f3xU",
        ]

        XCTAssertEqual(panel.sourceLinks.map(\.url.absoluteString), expected)
        XCTAssertEqual(panel.sourceLinkFields.count, expected.count)
        for (field, target) in zip(panel.sourceLinkFields, expected) {
            XCTAssertTrue(field.isSelectable)
            let link = field.attributedStringValue.attribute(
                .link,
                at: 0,
                effectiveRange: nil
            ) as? URL
            XCTAssertEqual(link?.absoluteString, target)
        }
    }

    func testPanelAppliesLiveEvidenceAndFeatureStateWithTextAndAccessibilityValues() {
        let panel = ExplainerPanel(copy: "Quoted copy", actionHandler: { _ in })
        var state = RenderState()
        state.apply(.evidence(.steps))
        state.apply(.toggleFeature(.gaussian))
        state.apply(.toggleFeature(.lights))

        panel.apply(renderState: state)

        XCTAssertEqual(panel.evidenceButtons.map(\.title), ["1 FINAL", "2 GRID", "3 MIPS", "4 STEPS", "5 COST"])
        XCTAssertEqual(panel.evidenceButtons.map(\.state), [.off, .off, .off, .on, .off])
        XCTAssertEqual(panel.featureButtons.map(\.title), ["G OFF", "K ON", "L OFF", "O ON", "X ON"])
        XCTAssertEqual(panel.featureButtons.map(\.state), [.off, .on, .off, .on, .on])
        XCTAssertEqual(panel.featureButtons.map { $0.accessibilityValue() as? String }, ["Off", "On", "Off", "On", "On"])

        panel.apply(renderState: RenderState())

        XCTAssertEqual(panel.evidenceButtons.map(\.state), [.on, .off, .off, .off, .off])
        XCTAssertEqual(panel.featureButtons.map(\.title), ["G ON", "K ON", "L ON", "O ON", "X ON"])
    }

    func testProductionCompactLayoutOpensPanelAndReturnsFocusToRailOnCloseAndEscape() throws {
        let delegate = AppDelegate()
        delegate.configureWindow()
        let window = try XCTUnwrap(delegate.window)
        defer { window.close() }
        window.setContentSize(NSSize(width: 1099, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        delegate.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        window.contentView?.layoutSubtreeIfNeeded()
        let panel = try XCTUnwrap(delegate.explainerPanel)
        let rail = try XCTUnwrap(delegate.explainerRail)
        let metalView = try XCTUnwrap(delegate.metalView)
        let hud = try XCTUnwrap(delegate.hudOverlay)

        XCTAssertTrue(panel.isHidden)
        XCTAssertFalse(rail.isHidden)
        XCTAssertEqual(rail.accessibilityLabel(), "Open Why Rays explainer")
        XCTAssertTrue(metalView.nextKeyView === rail)
        XCTAssertTrue(rail.nextKeyView === metalView)

        rail.performClick(nil)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(delegate.renderState.explainerVisible)
        XCTAssertFalse(panel.isHidden)
        XCTAssertTrue(rail.isHidden)
        XCTAssertEqual(panel.frame.width, 424, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxX, window.contentView?.bounds.maxX ?? 0, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(panel.frame.minX - hud.frame.maxX, 16 - 0.5)
        XCTAssertTrue(window.firstResponder === panel.closeButton)

        panel.closeButton.performClick(nil)

        XCTAssertFalse(delegate.renderState.explainerVisible)
        XCTAssertTrue(panel.isHidden)
        XCTAssertFalse(rail.isHidden)
        XCTAssertTrue(window.firstResponder === rail)

        rail.performClick(nil)
        delegate.handleRenderAction(.escape)

        XCTAssertFalse(delegate.renderState.explainerVisible)
        XCTAssertTrue(window.firstResponder === rail)

        window.makeFirstResponder(metalView)
        XCTAssertFalse(delegate.handleRenderAction(.escape))
        XCTAssertTrue(window.firstResponder === metalView)
    }

    func testProductionExpandedLayoutReturnsFocusToMTKViewOnCloseAndEscape() throws {
        let delegate = AppDelegate()
        delegate.configureWindow()
        let window = try XCTUnwrap(delegate.window)
        defer { window.close() }
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        delegate.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        let panel = try XCTUnwrap(delegate.explainerPanel)
        let rail = try XCTUnwrap(delegate.explainerRail)
        let metalView = try XCTUnwrap(delegate.metalView)
        let hud = try XCTUnwrap(delegate.hudOverlay)

        delegate.handleRenderAction(.toggleExplainer)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertFalse(panel.isHidden)
        XCTAssertTrue(rail.isHidden)
        XCTAssertEqual(panel.frame.width, 424, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxX, window.contentView?.bounds.maxX ?? 0, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(panel.frame.minX - hud.frame.maxX, 16 - 0.5)

        panel.closeButton.performClick(nil)

        XCTAssertFalse(delegate.renderState.explainerVisible)
        XCTAssertTrue(panel.isHidden)
        XCTAssertTrue(rail.isHidden)
        XCTAssertTrue(window.firstResponder === metalView)

        delegate.handleRenderAction(.toggleExplainer)
        delegate.handleRenderAction(.escape)

        XCTAssertTrue(window.firstResponder === metalView)
    }

    func testQAExpandedWindowCaptureOpensExplainerPanel() throws {
        var mode = QAMode()
        mode.captureScope = .window
        mode.windowPoints = SIMD2(1280, 800)
        let delegate = AppDelegate(qaMode: mode)
        delegate.configureWindow()
        let window = try XCTUnwrap(delegate.window)
        defer { window.close() }

        XCTAssertTrue(delegate.renderState.explainerVisible)
        XCTAssertFalse(try XCTUnwrap(delegate.explainerPanel).isHidden)
        XCTAssertTrue(try XCTUnwrap(delegate.explainerRail).isHidden)
    }

    func testQACollapsedWindowCaptureRetainsExplainerRail() throws {
        var mode = QAMode()
        mode.captureScope = .window
        mode.windowPoints = SIMD2(1099, 800)
        let delegate = AppDelegate(qaMode: mode)
        delegate.configureWindow()
        let window = try XCTUnwrap(delegate.window)
        defer { window.close() }

        XCTAssertFalse(delegate.renderState.explainerVisible)
        XCTAssertTrue(try XCTUnwrap(delegate.explainerPanel).isHidden)
        XCTAssertFalse(try XCTUnwrap(delegate.explainerRail).isHidden)
    }

    func testWindowCaptureComposesDrawableBeneathAppKitOverlays() throws {
        let bounds = NSRect(x: 0, y: 0, width: 8, height: 8)
        let contentView = CaptureColorView(frame: bounds, color: .black)
        let metalView = CaptureColorView(frame: bounds, color: .black)
        let overlay = CaptureColorView(
            frame: NSRect(x: 0, y: 0, width: 4, height: 4),
            color: .blue
        )
        contentView.addSubview(metalView)
        contentView.addSubview(overlay, positioned: .above, relativeTo: metalView)
        let baseline = try XCTUnwrap(contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds))
        contentView.cacheDisplay(in: contentView.bounds, to: baseline)
        let baselineOutside = try XCTUnwrap(baseline.colorAt(
            x: baseline.pixelsWide - 2,
            y: baseline.pixelsHigh - 2
        )?.usingColorSpace(.deviceRGB))
        let baselineOverlay = try XCTUnwrap(baseline.colorAt(
            x: 1,
            y: baseline.pixelsHigh - 2
        )?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(baselineOutside.blueComponent, 0.05)
        XCTAssertGreaterThan(baselineOverlay.blueComponent, 0.9)
        let capture = QADrawableCapture(
            width: 8,
            height: 8,
            bytesPerRow: 32,
            bgra8: Data(Array(repeating: [0, 0, 255, 255], count: 64).joined())
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("window.png").path

        try writeQAWindowCapture(
            contentView: contentView,
            metalView: metalView,
            drawableCapture: capture,
            to: path
        )

        let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: path))))
        let drawableColor = try XCTUnwrap(image.colorAt(
            x: image.pixelsWide - 2,
            y: image.pixelsHigh - 2
        )?.usingColorSpace(.deviceRGB))
        let overlayColor = try XCTUnwrap(image.colorAt(
            x: 1,
            y: image.pixelsHigh - 2
        )?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(drawableColor.redComponent, 0.9)
        XCTAssertLessThan(drawableColor.blueComponent, 0.05)
        XCTAssertGreaterThan(overlayColor.blueComponent, 0.9)
        XCTAssertLessThan(overlayColor.redComponent, 0.05)
        XCTAssertEqual(contentView.subviews.count, 2)
    }

    func testProductionActionsKeepOpenPanelControlsInSyncWithRenderState() throws {
        let delegate = AppDelegate()
        delegate.configureWindow()
        let window = try XCTUnwrap(delegate.window)
        defer { window.close() }
        window.setContentSize(NSSize(width: 1099, height: 700))
        delegate.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        let panel = try XCTUnwrap(delegate.explainerPanel)
        let rail = try XCTUnwrap(delegate.explainerRail)

        delegate.handleRenderAction(.evidence(.pyramid))
        delegate.handleRenderAction(.toggleFeature(.gaussian))
        rail.performClick(nil)

        XCTAssertEqual(panel.evidenceButtons.map(\.state), [.off, .off, .on, .off, .off])
        XCTAssertEqual(panel.featureButtons.first?.title, "G OFF")

        delegate.handleRenderAction(.evidence(.cost))
        delegate.handleRenderAction(.toggleFeature(.shadows))

        XCTAssertEqual(panel.evidenceButtons.map(\.state), [.off, .off, .off, .off, .on])
        XCTAssertEqual(panel.featureButtons.map(\.title), ["G OFF", "K OFF", "L ON", "O ON", "X ON"])
    }

    func testAccessibilityDisplayNotificationUpdatesPanelAndEffectiveRendererWhileMovementInputStaysActive() throws {
        var options = AccessibilityDisplayOptions(increasedContrast: false, reduceMotion: false)
        let delegate = AppDelegate(accessibilityDisplayOptionsProvider: { options })
        delegate.configureWindow()
        let window = try XCTUnwrap(delegate.window)
        defer { window.close() }
        let panel = try XCTUnwrap(delegate.explainerPanel)
        let renderer = try XCTUnwrap(delegate.renderer)
        let metalView = try XCTUnwrap(delegate.metalView)
        let normalAlpha = panel.alphaValue

        options = AccessibilityDisplayOptions(increasedContrast: true, reduceMotion: true)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )

        XCTAssertGreaterThan(panel.alphaValue, normalAlpha)
        XCTAssertTrue(renderer.currentRenderState().paused)
        let keyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        ))
        metalView.keyDown(with: keyDown)
        XCTAssertTrue(metalView.input.snapshot().keys.contains(13))
    }

    func testReduceMotionPauseToggleDoesNotAnnounceResumeWhileEffectiveStateStaysPaused() {
        let options = AccessibilityDisplayOptions(increasedContrast: false, reduceMotion: true)
        var announcements = [String]()
        let delegate = AppDelegate(
            accessibilityDisplayOptionsProvider: { options },
            accessibilityAnnouncementPoster: { announcements.append($0) }
        )

        delegate.handleRenderAction(.togglePause)
        delegate.handleRenderAction(.togglePause)

        XCTAssertFalse(delegate.renderState.paused)
        XCTAssertEqual(announcements.last, "Scene motion remains held by Reduce Motion. Camera remains active.")
        XCTAssertFalse(announcements.contains("Scene motion resumed."))
    }

    func testDefaultAnnouncementHandlerUsesInjectedAccessibilityPoster() {
        var posted = [String]()
        let delegate = AppDelegate(accessibilityAnnouncementPoster: { posted.append($0) })

        delegate.handleRenderAction(.evidence(.grid))

        XCTAssertEqual(posted, ["Evidence view changed to GRID."])
    }

    func testEvidenceKeysOnlyChangeEvidenceView() {
        var state = RenderState()

        state.apply(.evidence(.pyramid))

        XCTAssertEqual(state.evidenceView, .pyramid)
        XCTAssertEqual(state.features, .all)
        XCTAssertFalse(state.paused)
        XCTAssertTrue(state.hudVisible)
        XCTAssertFalse(state.explainerVisible)
    }

    func testFeatureActionsToggleOnlyTheirDocumentedFeature() {
        let cases: [(RenderFeatures, RenderFeatures)] = [
            (.gaussian, .all.subtracting(.gaussian)),
            (.shadows, .all.subtracting(.shadows)),
            (.lights, .all.subtracting(.lights)),
            (.optics, .all.subtracting(.optics)),
            (.sdf, .all.subtracting(.sdf)),
        ]

        for (feature, expected) in cases {
            var state = RenderState()
            state.apply(.toggleFeature(feature))

            XCTAssertEqual(state.features, expected)
            XCTAssertEqual(state.evidenceView, .final)
            XCTAssertFalse(state.paused)
            XCTAssertTrue(state.hudVisible)
            XCTAssertFalse(state.explainerVisible)
        }
    }

    func testPauseHUDAndExplainerActionsChangeOnlyTheirDocumentedState() {
        var paused = RenderState()
        paused.apply(.togglePause)
        XCTAssertTrue(paused.paused)
        XCTAssertEqual(paused.evidenceView, .final)
        XCTAssertEqual(paused.features, .all)
        XCTAssertTrue(paused.hudVisible)
        XCTAssertFalse(paused.explainerVisible)

        var hud = RenderState()
        hud.apply(.toggleHUD)
        XCTAssertFalse(hud.hudVisible)
        XCTAssertEqual(hud.evidenceView, .final)
        XCTAssertEqual(hud.features, .all)
        XCTAssertFalse(hud.paused)
        XCTAssertFalse(hud.explainerVisible)

        var explainer = RenderState()
        explainer.apply(.toggleExplainer)
        XCTAssertTrue(explainer.explainerVisible)
        XCTAssertEqual(explainer.evidenceView, .final)
        XCTAssertEqual(explainer.features, .all)
        XCTAssertFalse(explainer.paused)
        XCTAssertTrue(explainer.hudVisible)
    }

    func testEscapeClosesExplainerBeforeItFallsThroughToMouseCapture() {
        var state = RenderState()
        state.apply(.toggleExplainer)

        XCTAssertTrue(state.apply(.escape))
        XCTAssertFalse(state.explainerVisible)
        XCTAssertFalse(state.apply(.escape))
    }

    func testAdaptiveScaleMovesWithinBoundsAndFixedModeDoesNotMove() {
        var adaptive = RenderScaleController(scale: 0.70, mode: .adaptive)
        adaptive.record(gpuMilliseconds: 12)
        XCTAssertLessThan(adaptive.scale, 0.70)
        XCTAssertGreaterThanOrEqual(adaptive.scale, 0.35)

        var fixed = RenderScaleController(scale: 1.0, mode: .fixed)
        for _ in 0..<900 {
            fixed.record(gpuMilliseconds: 30)
        }
        XCTAssertEqual(fixed.scale, 1.0)
    }

    func testAdaptiveScaleMovesUpForLowTimesAndClampsAtBothBounds() {
        var low = RenderScaleController(scale: 0.70, mode: .adaptive)
        low.record(gpuMilliseconds: 4)
        XCTAssertGreaterThan(low.scale, 0.70)

        for _ in 0..<900 {
            low.record(gpuMilliseconds: 1)
        }
        XCTAssertEqual(low.scale, 1.0)

        var high = RenderScaleController(scale: 0.70, mode: .adaptive)
        for _ in 0..<900 {
            high.record(gpuMilliseconds: 30)
        }
        XCTAssertEqual(high.scale, 0.35)
    }

    func testHUDClaimsDescribeLiveViewAndOmitCountersWhenAggregationIsDisabled() {
        let hud = HUDState(
            renderState: RenderState(),
            framesPerSecond: 60,
            gpuMilliseconds: 8.25,
            drawableWidth: 896,
            drawableHeight: 560,
            renderScale: 0.70,
            counters: nil
        )

        XCTAssertTrue(hud.text.hasPrefix(
            "SCENE 1/5 · FINAL FIELD · 2 COMPUTE PASSES · 60 FPS · 8.25 MS GPU · 896×560\n" +
            "MIXED 64³ MIP 6→0 · VOXELS 512³ MIP 9→0 · VOXEL DDA + SDF RM + GAUSSIAN"
        ))
        XCTAssertFalse(hud.text.contains("VOXEL STEPS"))
        XCTAssertTrue(hud.text.contains("70% SCALE"))
    }

    func testHUDUsesViewSpecificInvestigationLegends() {
        let legends: [(EvidenceView, String)] = [
            (.final, "HYBRID FIELD · SURFACE + VOLUME"),
            (.grid, "CELL FLAGS · VOXEL GREEN · SDF MAGENTA · VOLUME CYAN · LIGHT AMBER · FRACTAL RED"),
            (.pyramid, "COARSE → FINE · MIXED 6→0 · VOXELS 9→0"),
            (.steps, "R MACRO · G SOLID/SDF · B VOLUME/RAYS"),
            (.cost, "COOL LIGHT WORK · HOT HEAVY WORK"),
        ]

        for (view, legend) in legends {
            var state = RenderState()
            state.apply(.evidence(view))
            let hud = HUDState(
                renderState: state,
                framesPerSecond: 60,
                gpuMilliseconds: 8,
                drawableWidth: 896,
                drawableHeight: 560,
                renderScale: 0.70,
                counters: nil
            )

            XCTAssertTrue(hud.text.contains(legend), "Missing legend for \(view)")
        }
    }

    func testPausedHUDPersistsCameraLiveStatus() {
        var state = RenderState()
        state.apply(.togglePause)
        let hud = HUDState(
            renderState: state,
            framesPerSecond: 60,
            gpuMilliseconds: 8,
            drawableWidth: 896,
            drawableHeight: 560,
            renderScale: 0.70,
            counters: nil
        )

        XCTAssertTrue(hud.text.contains("MOTION HELD · CAMERA LIVE"))
    }

    func testProductionHUDLabelCanDisplayMaximumSixLineHUDState() {
        var state = RenderState()
        state.apply(.evidence(.steps))
        state.apply(.togglePause)
        let hud = HUDState(
            renderState: state,
            framesPerSecond: 60,
            gpuMilliseconds: 8,
            drawableWidth: 896,
            drawableHeight: 560,
            renderScale: 0.70,
            counters: FrameCounters(
                macroSkips: 1,
                macroDescents: 2,
                voxelSteps: 3,
                sdfSamples: 4,
                gaussianSamples: 5,
                secondaryRays: 1,
                surfaceSunShadows: 1,
                surfaceLocalShadows: 1,
                volumeSunShadows: 1,
                volumeLocalShadows: 1,
                budgetOverflows: 0,
                reserved: 0
            )
        )
        let lineCount = hud.text.split(separator: "\n").count
        let label = makeHUDStatusLabel(text: hud.text)

        XCTAssertEqual(lineCount, 6)
        XCTAssertEqual(label.stringValue, hud.text)
        XCTAssertTrue(
            label.maximumNumberOfLines == 0 || label.maximumNumberOfLines >= lineCount,
            "Production HUD label caps a six-line state at \(label.maximumNumberOfLines) lines"
        )
    }

    func testPauseTransitionsUseInjectableAccessibilityAnnouncements() {
        let delegate = AppDelegate()
        var announcements = [String]()
        delegate.accessibilityAnnouncementHandler = { announcements.append($0) }

        delegate.handleRenderAction(.togglePause)
        delegate.handleRenderAction(.togglePause)

        XCTAssertEqual(announcements, [
            "Scene motion paused. Camera remains active.",
            "Scene motion resumed.",
        ])
    }

    func testEvidenceAndFeatureTransitionsUseAccessibilityAnnouncements() {
        let delegate = AppDelegate()
        var announcements = [String]()
        delegate.accessibilityAnnouncementHandler = { announcements.append($0) }

        delegate.handleRenderAction(.evidence(.grid))
        delegate.handleRenderAction(.toggleFeature(.lights))
        delegate.handleRenderAction(.toggleFeature(.lights))

        XCTAssertEqual(announcements, [
            "Evidence view changed to GRID.",
            "Lights disabled.",
            "Lights enabled.",
        ])
    }

    func testViewMenuCommandsHaveNoModifiedKeyEquivalentFallback() throws {
        let application = NSApplication.shared
        let previousMenu = application.mainMenu
        defer { application.mainMenu = previousMenu }
        let delegate = AppDelegate()

        delegate.configureMenu()

        let viewMenu = try XCTUnwrap(application.mainMenu?.items.first { $0.submenu?.title == "View" }?.submenu)
        let explainer = try XCTUnwrap(viewMenu.item(withTitle: "Why Rays Explainer"))
        let hud = try XCTUnwrap(viewMenu.item(withTitle: "Toggle HUD"))
        XCTAssertEqual(explainer.keyEquivalent, "")
        XCTAssertEqual(hud.keyEquivalent, "")
        XCTAssertNil(RenderShortcut.action(keyCode: 34, modifiers: .command))
        XCTAssertNil(RenderShortcut.action(keyCode: 4, modifiers: .command))
    }

    func testUIProbeWritesMeasuredReleaseEvidence() throws {
        func failure(_ condition: Bool) -> Int { condition ? 0 : 1 }

        var state = RenderState()
        state.apply(.evidence(.pyramid))
        let stateMismatchCount = failure(
            state.evidenceView == .pyramid && state.features == .all && !state.paused && state.hudVisible
        )
        let modifierLeakCount = failure(
            RenderShortcut.action(keyCode: 34, modifiers: .command) == nil &&
            RenderShortcut.action(keyCode: 4, modifiers: .control) == nil &&
            RenderShortcut.action(keyCode: 7, modifiers: .option) == nil
        )

        var adaptive = RenderScaleController(scale: 0.70, mode: .adaptive)
        adaptive.record(gpuMilliseconds: 12)
        let adaptiveScaleFailureCount = failure(adaptive.scale < 0.70 && adaptive.scale >= 0.35)
        var fixed = RenderScaleController(scale: 1.0, mode: .fixed)
        for _ in 0..<900 { fixed.record(gpuMilliseconds: 30) }
        let fixedScaleFailureCount = failure(fixed.scale == 1.0)
        let reduceMotionFailureCount = failure(effectiveRenderState(RenderState(), reduceMotion: true).paused)

        let delegate = AppDelegate()
        delegate.configureWindow()
        let window = try XCTUnwrap(delegate.window)
        defer { window.close() }
        window.setContentSize(NSSize(width: 1099, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        delegate.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        window.contentView?.layoutSubtreeIfNeeded()
        let panel = try XCTUnwrap(delegate.explainerPanel)
        let rail = try XCTUnwrap(delegate.explainerRail)
        let hud = try XCTUnwrap(delegate.hudOverlay)
        let collapsedLayout = panel.isHidden && !rail.isHidden
        rail.performClick(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let openFocus = window.firstResponder === panel.closeButton
        let responsiveLayoutFailureCount = failure(
            collapsedLayout && panel.frame.width >= 423.5 && panel.frame.width <= 424.5 &&
            panel.frame.minX - hud.frame.maxX >= 15.5
        )
        panel.closeButton.performClick(nil)
        let focusFailureCount = failure(openFocus && window.firstResponder === rail)
        let accessibilityFailureCount = failure(
            rail.accessibilityLabel() == "Open Why Rays explainer" &&
            panel.closeButton.accessibilityLabel() == "Close Why Rays explainer" &&
            panel.bodyTextFields.allSatisfy { ($0.font?.pointSize ?? 0) >= 13 } &&
            panel.sourceLinkFields.count == 3
        )
        let metrics = UIProbeMetrics(
            stateMismatchCount: stateMismatchCount,
            focusFailureCount: focusFailureCount,
            modifierLeakCount: modifierLeakCount,
            accessibilityFailureCount: accessibilityFailureCount,
            responsiveLayoutFailureCount: responsiveLayoutFailureCount,
            adaptiveScaleFailureCount: adaptiveScaleFailureCount,
            fixedScaleFailureCount: fixedScaleFailureCount,
            reduceMotionFailureCount: reduceMotionFailureCount,
            windowCount: 1
        )
        let data = try ProbeEnvelope.evaluated(
            probe: "ui", device: try XCTUnwrap(MTLCreateSystemDefaultDevice()).name, metrics: metrics
        ).encodedJSON()
        try MetalProbeHarness.writeEvidence(data, named: "ui")

        XCTAssertEqual(try ProbeEnvelope<UIProbeMetrics>.decodeValidated(data).status, "pass")
    }
}
