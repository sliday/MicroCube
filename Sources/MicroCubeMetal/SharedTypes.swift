import Foundation
import simd

struct FrameUniforms {
    var cameraPositionAndTime: SIMD4<Float>
    var cameraForwardAndFOV: SIMD4<Float>
    var cameraRightAndAspect: SIMD4<Float>
    var cameraUpAndMaxDistance: SIMD4<Float>
    var sunDirectionAndAmbient: SIMD4<Float>
    var viewportAndOptions: SIMD4<UInt32>
    var fogAndExposure: SIMD4<Float>
}

struct InputSnapshot {
    var keys: Set<UInt16>
    var mouseDelta: SIMD2<Float>
    var speedBoost: Bool
}

final class InputState {
    private var keys = Set<UInt16>()
    private var mouseDelta = SIMD2<Float>.zero
    private var speedBoost = false

    func setKey(_ code: UInt16, down: Bool) {
        if down {
            keys.insert(code)
        } else {
            keys.remove(code)
        }
    }

    func setSpeedBoost(_ enabled: Bool) {
        speedBoost = enabled
    }

    func addMouseDelta(x: Float, y: Float) {
        mouseDelta += SIMD2<Float>(x, y)
    }

    func snapshot() -> InputSnapshot {
        defer { mouseDelta = .zero }
        return InputSnapshot(keys: keys, mouseDelta: mouseDelta, speedBoost: speedBoost)
    }
}
