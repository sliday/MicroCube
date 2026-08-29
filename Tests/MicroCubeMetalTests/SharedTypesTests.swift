import XCTest
@testable import MicroCubeMetal

final class InputStateTests: XCTestCase {
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
