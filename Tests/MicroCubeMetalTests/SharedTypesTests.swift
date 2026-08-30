import XCTest
@testable import MicroCubeMetal

final class InputStateTests: XCTestCase {
    func testRendererShortcutKeysMapToDocumentedActions() {
        let cases: [(UInt16, RenderAction)] = [
            (18, .evidence(.final)),
            (19, .evidence(.grid)),
            (20, .evidence(.pyramid)),
            (21, .evidence(.steps)),
            (23, .evidence(.cost)),
            (5, .toggleFeature(.gaussian)),
            (40, .toggleFeature(.shadows)),
            (37, .toggleFeature(.lights)),
            (31, .toggleFeature(.optics)),
            (7, .toggleFeature(.sdf)),
            (35, .togglePause),
            (34, .toggleExplainer),
            (4, .toggleHUD),
            (3, .toggleFullscreen),
            (15, .reset),
            (53, .escape),
        ]

        for (keyCode, expected) in cases {
            XCTAssertEqual(RenderShortcut.action(keyCode: keyCode), expected)
        }
    }

    func testRendererShortcutsIgnoreCommandControlAndOptionModifiers() {
        for modifier: RenderShortcutModifiers in [.command, .control, .option] {
            XCTAssertNil(RenderShortcut.action(keyCode: 18, modifiers: modifier))
            XCTAssertNil(RenderShortcut.action(keyCode: 5, modifiers: modifier))
            XCTAssertNil(RenderShortcut.action(keyCode: 53, modifiers: modifier))
        }
        XCTAssertEqual(
            RenderShortcut.action(keyCode: 18, modifiers: [.shift]),
            .evidence(.final)
        )
    }

    func testSnapshotReturnsCurrentInputAndConsumesMouseDelta() {
        let input = InputState()
        input.setKey(13, down: true)
        input.setKey(0, down: true)
        input.setSpeedBoost(true)
        input.addMouseDelta(x: 3.25, y: -1.5)
        input.addMouseDelta(x: -0.25, y: 0.5)

        let first = input.snapshot()
        XCTAssertEqual(first.keys, Set<UInt16>([0, 13]))
        XCTAssertEqual(first.mouseDelta, SIMD2<Float>(3.0, -1.0))
        XCTAssertTrue(first.speedBoost)

        let second = input.snapshot()
        XCTAssertEqual(second.keys, Set<UInt16>([0, 13]))
        XCTAssertEqual(second.mouseDelta, .zero)
        XCTAssertTrue(second.speedBoost)
    }

    func testReleasedKeyAndClearedSpeedBoostDoNotAppearInSnapshot() {
        let input = InputState()
        input.setKey(13, down: true)
        input.setSpeedBoost(true)
        input.setKey(13, down: false)
        input.setSpeedBoost(false)

        let snapshot = input.snapshot()
        XCTAssertFalse(snapshot.keys.contains(13))
        XCTAssertFalse(snapshot.speedBoost)
    }
}

final class FrameUniformsLayoutTests: XCTestCase {
    func testLayoutMatchesMetalFrameUniformsABI() {
        XCTAssertEqual(MemoryLayout<FrameUniforms>.size, 112)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.stride, 112)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.alignment, 16)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.offset(of: \FrameUniforms.cameraPositionAndTime), 0)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.offset(of: \FrameUniforms.cameraForwardAndFOV), 16)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.offset(of: \FrameUniforms.cameraRightAndAspect), 32)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.offset(of: \FrameUniforms.cameraUpAndMaxDistance), 48)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.offset(of: \FrameUniforms.sunDirectionAndAmbient), 64)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.offset(of: \FrameUniforms.viewportAndOptions), 80)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.offset(of: \FrameUniforms.fogAndExposure), 96)
    }
}
