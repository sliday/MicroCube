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

    var title: String {
        switch self {
        case .final: "FINAL FIELD"
        case .grid: "GRID"
        case .pyramid: "PYRAMID"
        case .steps: "RAY STEPS"
        case .cost: "COST"
        }
    }
}

enum RenderAction: Equatable {
    case evidence(EvidenceView)
    case toggleFeature(RenderFeatures)
    case togglePause
    case toggleHUD
    case toggleExplainer
    case toggleFullscreen
    case reset
    case escape
}

struct RenderState: Equatable {
    var evidenceView: EvidenceView = .final
    var features: RenderFeatures = .all
    var paused = false
    var hudVisible = true
    var explainerVisible = false

    var counterAggregationEnabled: Bool {
        evidenceView == .steps || evidenceView == .cost
    }

    @discardableResult
    mutating func apply(_ action: RenderAction) -> Bool {
        switch action {
        case .evidence(let view):
            evidenceView = view
        case .toggleFeature(let feature):
            features.formSymmetricDifference(feature)
        case .togglePause:
            paused.toggle()
        case .toggleHUD:
            hudVisible.toggle()
        case .toggleExplainer:
            explainerVisible.toggle()
        case .escape:
            guard explainerVisible else { return false }
            explainerVisible = false
            return true
        case .toggleFullscreen, .reset:
            break
        }
        return false
    }
}

enum RenderScaleMode {
    case adaptive
    case fixed
}

struct RenderScaleController {
    private(set) var scale: Double
    let mode: RenderScaleMode

    init(scale: Double, mode: RenderScaleMode) {
        self.scale = min(1.0, max(0.35, scale))
        self.mode = mode
    }

    mutating func record(gpuMilliseconds: Double) {
        guard mode == .adaptive, gpuMilliseconds.isFinite, gpuMilliseconds > 0.0 else { return }
        let correction = sqrt(8.0 / gpuMilliseconds)
        scale = min(1.0, max(0.35, scale * min(1.05, max(0.90, correction))))
    }
}

struct RenderShortcutModifiers: OptionSet {
    let rawValue: UInt8

    static let command = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)
}

enum RenderShortcut {
    static func action(
        keyCode: UInt16,
        modifiers: RenderShortcutModifiers = []
    ) -> RenderAction? {
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        return switch keyCode {
        case 18: .evidence(.final)
        case 19: .evidence(.grid)
        case 20: .evidence(.pyramid)
        case 21: .evidence(.steps)
        case 23: .evidence(.cost)
        case 5: .toggleFeature(.gaussian)
        case 40: .toggleFeature(.shadows)
        case 37: .toggleFeature(.lights)
        case 31: .toggleFeature(.optics)
        case 7: .toggleFeature(.sdf)
        case 35: .togglePause
        case 34: .toggleExplainer
        case 4: .toggleHUD
        case 3: .toggleFullscreen
        case 15: .reset
        case 53: .escape
        default: nil
        }
    }
}

struct HUDState {
    var renderState: RenderState
    var framesPerSecond: Double
    var gpuMilliseconds: Double
    var drawableWidth: Int
    var drawableHeight: Int
    var renderScale: Double
    var counters: FrameCounters?

    var text: String {
        let ordinal = Int(renderState.evidenceView.rawValue) + 1
        let lineOne = String(
            format: "SCENE %d/5 · %@ · 2 COMPUTE PASSES · %.0f FPS · %.2f MS GPU · %d×%d",
            ordinal,
            renderState.evidenceView.title,
            framesPerSecond,
            gpuMilliseconds,
            drawableWidth,
            drawableHeight
        )
        let enabled = [
            renderState.features.contains(.shadows) ? "SHADOWS" : nil,
            renderState.features.contains(.lights) ? "LIGHTS" : nil,
            renderState.features.contains(.optics) ? "OPTICS" : nil,
            renderState.features.contains(.sdf) ? "SDF" : nil,
            renderState.features.contains(.gaussian) ? "GAUSSIAN" : nil,
        ].compactMap { $0 }.joined(separator: "/")
        let featuresText = enabled.isEmpty ? "FEATURES OFF" : "\(enabled) ON"
        var lines = [
            lineOne,
            "MIXED 64³ MIP 6→0 · VOXELS 512³ MIP 9→0 · VOXEL DDA + SDF RM + GAUSSIAN",
            String(format: "%.0f%% SCALE · %@", renderScale * 100.0, featuresText),
        ]
        if let counters {
            lines.append(
                "MACRO SKIPS \(counters.macroSkips) · DESCENTS \(counters.macroDescents) · " +
                "VOXEL STEPS \(counters.voxelSteps) · SDF \(counters.sdfSamples) · " +
                "GAUSSIAN \(counters.gaussianSamples) · SECONDARY \(counters.secondaryRays)"
            )
        }
        return lines.joined(separator: "\n")
    }
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
