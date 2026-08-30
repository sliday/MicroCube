import AppKit
import XCTest
@testable import MicroCubeMetal

final class UIStateTests: XCTestCase {
    func testPanelLayoutBreakpointAndHUDClearance() {
        XCTAssertEqual(ExplainerLayout.state(windowWidth: 1099), .collapsed)
        XCTAssertEqual(ExplainerLayout.state(windowWidth: 1100), .expanded(width: 424))
        XCTAssertEqual(ExplainerLayout.hudClearance, 16)
    }

    func testCollapsedRailOpensPanelInsideSmallWindowAndEscapeReturnsToRail() {
        XCTAssertEqual(
            ExplainerLayout.presentation(windowWidth: 1099, explainerVisible: false),
            .rail
        )
        XCTAssertEqual(
            ExplainerLayout.presentation(windowWidth: 1099, explainerVisible: true),
            .panel
        )
        XCTAssertEqual(
            ExplainerLayout.presentation(windowWidth: 1100, explainerVisible: false),
            .hidden
        )
    }

    func testPanelProvidesFiveFocusableEvidenceControlsAndFocusChain() {
        let panel = ExplainerPanel(copy: "Quoted copy", actionHandler: { _ in })

        XCTAssertEqual(panel.evidenceButtons.count, 5)
        XCTAssertTrue(panel.evidenceButtons.allSatisfy(\.acceptsFirstResponder))
        for (button, nextButton) in zip(panel.evidenceButtons, panel.evidenceButtons.dropFirst()) {
            XCTAssertTrue(button.nextKeyView === nextButton)
        }
    }

    func testCloseAndCollapsedRailUseAccessibleLabelsAndActions() {
        var actions = [RenderAction]()
        let panel = ExplainerPanel(copy: "Quoted copy", actionHandler: { actions.append($0) })
        let rail = ExplainerPanel.makeCollapsedRail(actionHandler: { actions.append(.toggleExplainer) })

        panel.closeButton.performClick(nil)
        rail.performClick(nil)

        XCTAssertEqual(panel.closeButton.accessibilityLabel(), "Close Why Rays explainer")
        XCTAssertEqual(rail.accessibilityLabel(), "Open Why Rays explainer")
        XCTAssertTrue(rail.acceptsFirstResponder)
        XCTAssertEqual(actions, [.toggleExplainer, .toggleExplainer])
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

        XCTAssertEqual(panel.passageDisclosureTexts, [
            [
                "SOURCE QUOTE · ORIGINAL AUTHOR'S DEMO",
                "CURRENT MAC APP · 1 HYBRID IMAGE KERNEL + 1 VOLUME LIGHT KERNEL",
            ],
            [
                "SOURCE QUOTE · ORIGINAL AUTHOR'S DEMO",
                "CURRENT MAC APP · 1 HYBRID IMAGE KERNEL + 1 VOLUME LIGHT KERNEL",
                "SOURCE CLAIM · NOT A RESULT FROM THIS MAC APP",
            ],
            [
                "SOURCE QUOTE · ORIGINAL AUTHOR'S DEMO",
                "CURRENT MAC APP · 1 HYBRID IMAGE KERNEL + 1 VOLUME LIGHT KERNEL",
                "CONCEPT IN THIS MAC DEMO · NO PHYSICS OR AUDIO SYSTEM RUNS HERE",
            ],
        ])
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

    func testIncreasedContrastRaisesExplainerOverlayOpacity() {
        XCTAssertGreaterThan(
            ExplainerAppearance.overlayAlpha(increasedContrast: true),
            ExplainerAppearance.overlayAlpha(increasedContrast: false)
        )
    }

    func testReduceMotionFreezesSceneStateWithoutChangingCameraInputState() {
        var state = RenderState()
        state.apply(.evidence(.grid))

        let effective = effectiveRenderState(state, reduceMotion: true)

        XCTAssertTrue(effective.paused)
        XCTAssertEqual(effective.evidenceView, .grid)
        XCTAssertEqual(effective.features, state.features)
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
}
