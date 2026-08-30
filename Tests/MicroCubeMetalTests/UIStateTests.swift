import XCTest
@testable import MicroCubeMetal

final class UIStateTests: XCTestCase {
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
}
