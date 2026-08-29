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

struct SceneUniforms {
    var counts: SIMD4<UInt32>
    var grid: SIMD4<UInt32>
    var fog: SIMD4<Float>
    var budgets: SIMD4<UInt32>
}

struct CellHeader {
    var sdfOffset: UInt32
    var gaussianOffset: UInt32
    var packedCounts: UInt32
    var reserved: UInt32
}

struct SDFInstance {
    var sweptBoundsMin: SIMD4<Float>
    var sweptBoundsMax: SIMD4<Float>
    var positionScale: SIMD4<Float>
    var rotationQuaternion: SIMD4<Float>
    var parameters: SIMD4<Float>
    var metadata: SIMD4<UInt32>
}

struct Gaussian {
    var localCenterSigma: SIMD4<Float>
    var colorDensity: SIMD4<Float>
    var motionPhase: SIMD4<Float>
}

struct Light {
    var positionRadius: SIMD4<Float>
    var colorIntensity: SIMD4<Float>
}

struct Material {
    var baseColorRoughness: SIMD4<Float>
    var emissionMetalness: SIMD4<Float>
    var opticalAbsorptionIOR: SIMD4<Float>
    var transmissionAcoustic: SIMD4<Float>
}

struct FrameCounters {
    var macroSkips: UInt32
    var macroDescents: UInt32
    var voxelSteps: UInt32
    var sdfSamples: UInt32
    var gaussianSamples: UInt32
    var secondaryRays: UInt32
    var surfaceSunShadows: UInt32
    var surfaceLocalShadows: UInt32
    var volumeSunShadows: UInt32
    var volumeLocalShadows: UInt32
    var budgetOverflows: UInt32
    var reserved: UInt32
}

struct RenderFeatures: OptionSet {
    let rawValue: UInt32

    static let shadows = Self(rawValue: 1 << 0)
    static let lights = Self(rawValue: 1 << 1)
    static let optics = Self(rawValue: 1 << 2)
    static let sdf = Self(rawValue: 1 << 3)
    static let gaussian = Self(rawValue: 1 << 4)
    static let all: Self = [.shadows, .lights, .optics, .sdf, .gaussian]
}

enum EvidenceView: UInt32, CaseIterable {
    case final
    case grid
    case pyramid
    case steps
    case cost
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
