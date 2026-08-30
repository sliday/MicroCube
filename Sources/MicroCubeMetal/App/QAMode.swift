import Foundation
import CoreGraphics
import ImageIO
import simd
import UniformTypeIdentifiers

enum QAError: Error, LocalizedError {
    case missingValue(String)
    case invalidValue(option: String, value: String, expectation: String)
    case unknownOption(String)
    case unsupportedSchema(Int)
    case invalidEnvelope(String)
    case writeFailed(path: String, diagnostic: String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let option):
            "Missing value for \(option)."
        case .invalidValue(let option, let value, let expectation):
            "Invalid value '\(value)' for \(option); expected \(expectation)."
        case .unknownOption(let option):
            "Unknown automation option \(option)."
        case .unsupportedSchema(let version):
            "Unsupported JSON schema version \(version)."
        case .invalidEnvelope(let reason):
            "Invalid probe envelope: \(reason)."
        case .writeFailed(let path, let diagnostic):
            "Could not write \(path): \(diagnostic)"
        }
    }
}

struct QABenchmark: Equatable {
    var warmupFrames: Int
    var measuredFrames: Int
}

struct QAMode: Equatable {
    enum Scene: String, CaseIterable {
        case hero
        case shadowFixture = "shadow-fixture"
        case mixedFixture = "mixed-fixture"
        case opticsFixture = "optics-fixture"
        case fogClear = "fog-clear"
        case fogBlocked = "fog-blocked"
        case gaussianFixture = "gaussian-fixture"
        case fractalFixture = "fractal-fixture"
    }

    enum Camera: Equatable {
        case reset
        case custom(position: SIMD3<Double>, yaw: Double, pitch: Double)
    }

    enum View: String, CaseIterable {
        case final
        case grid
        case pyramid
        case steps
        case cost
        case primitiveID = "primitive-id"
        case normals
        case shadowMismatch = "shadow-mismatch"

        var shaderValue: UInt32 {
            switch self {
            case .final: 0
            case .grid: 1
            case .pyramid: 2
            case .steps: 3
            case .cost: 4
            case .primitiveID: 5
            case .normals: 6
            case .shadowMismatch: 7
            }
        }
    }

    enum CaptureScope: String {
        case drawable
        case window
    }

    var scene: Scene = .hero
    var features: RenderFeatures = .all
    var fixedTime = 0.0
    var fixedStep = 1.0 / 120.0
    var camera: Camera = .reset
    var windowPoints = SIMD2<Int>(1280, 800)
    var drawablePixels = SIMD2<Int>(1280, 800)
    var renderScale = 1.0
    var view: View = .final
    var frames = 1
    var captureScope: CaptureScope = .drawable
    var capturePath: String?
    var reportPath: String?
    var benchmark: QABenchmark?

    var requestedFrameCount: Int {
        benchmark.map { $0.warmupFrames + $0.measuredFrames } ?? frames
    }

    var featureMask: String {
        if features == .all { return "all" }
        if features.isEmpty { return "none" }
        return [
            features.contains(.shadows) ? "shadows" : nil,
            features.contains(.lights) ? "lights" : nil,
            features.contains(.optics) ? "optics" : nil,
            features.contains(.sdf) ? "sdf" : nil,
            features.contains(.gaussian) ? "gaussian" : nil,
        ].compactMap { $0 }.joined(separator: ",")
    }

    static func parseIfRequested(_ arguments: [String]) throws -> QAMode? {
        guard arguments.contains(where: {
            $0 == "--benchmark" || $0.hasPrefix("--qa-") || $0.hasPrefix("--benchmark-")
        }) else {
            return nil
        }
        return try parse(arguments)
    }

    static func parse(_ arguments: [String]) throws -> QAMode {
        var mode = QAMode()
        var index = 0
        var benchmarkRequested = false
        var benchmarkWarmup = 180
        var benchmarkSamples = 900

        func value(after option: String) throws -> String {
            let valueIndex = index + 1
            guard valueIndex < arguments.count, !arguments[valueIndex].hasPrefix("--") else {
                throw QAError.missingValue(option)
            }
            index = valueIndex
            return arguments[valueIndex]
        }

        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--qa-scene":
                let value = try value(after: option)
                guard let scene = Scene(rawValue: value) else {
                    throw QAError.invalidValue(option: option, value: value, expectation: Scene.allCases.map(\.rawValue).joined(separator: "|"))
                }
                mode.scene = scene
            case "--qa-features":
                let value = try value(after: option)
                mode.features = try parseFeatures(value, option: option)
            case "--qa-time":
                mode.fixedTime = try parseFiniteDouble(try value(after: option), option: option)
            case "--qa-step":
                let value = try value(after: option)
                let step = try parseFiniteDouble(value, option: option)
                guard step > 0 else {
                    throw QAError.invalidValue(option: option, value: value, expectation: "a finite positive number")
                }
                mode.fixedStep = step
            case "--qa-camera":
                let value = try value(after: option)
                mode.camera = try parseCamera(value, option: option)
            case "--qa-window-points":
                let value = try value(after: option)
                mode.windowPoints = try parseSize(value, option: option)
            case "--qa-drawable":
                let value = try value(after: option)
                mode.drawablePixels = try parseSize(value, option: option)
            case "--qa-scale":
                let value = try value(after: option)
                let scale = try parseFiniteDouble(value, option: option)
                guard (0.35...1.0).contains(scale) else {
                    throw QAError.invalidValue(option: option, value: value, expectation: "0.35...1.0")
                }
                mode.renderScale = scale
            case "--qa-view":
                let value = try value(after: option)
                guard let view = View(rawValue: value) else {
                    throw QAError.invalidValue(option: option, value: value, expectation: View.allCases.map(\.rawValue).joined(separator: "|"))
                }
                mode.view = view
            case "--qa-frames":
                let value = try value(after: option)
                guard let frames = Int(value), frames > 0 else {
                    throw QAError.invalidValue(option: option, value: value, expectation: "a positive integer")
                }
                mode.frames = frames
            case "--qa-capture-scope":
                let value = try value(after: option)
                guard let scope = CaptureScope(rawValue: value) else {
                    throw QAError.invalidValue(option: option, value: value, expectation: "drawable|window")
                }
                mode.captureScope = scope
            case "--qa-capture":
                mode.capturePath = try value(after: option)
            case "--qa-report":
                mode.reportPath = try value(after: option)
            case "--benchmark":
                benchmarkRequested = true
            case "--benchmark-warmup":
                benchmarkRequested = true
                let value = try value(after: option)
                guard let count = Int(value), count >= 0 else {
                    throw QAError.invalidValue(option: option, value: value, expectation: "a nonnegative integer")
                }
                benchmarkWarmup = count
            case "--benchmark-samples":
                benchmarkRequested = true
                let value = try value(after: option)
                guard let count = Int(value), count > 0 else {
                    throw QAError.invalidValue(option: option, value: value, expectation: "a positive integer")
                }
                benchmarkSamples = count
            default:
                if option.hasPrefix("--qa-") || option.hasPrefix("--benchmark-") {
                    throw QAError.unknownOption(option)
                }
            }
            index += 1
        }

        if benchmarkRequested {
            mode.benchmark = QABenchmark(warmupFrames: benchmarkWarmup, measuredFrames: benchmarkSamples)
        }
        return mode
    }

    private static func parseFiniteDouble(_ value: String, option: String) throws -> Double {
        guard let result = Double(value), result.isFinite else {
            throw QAError.invalidValue(option: option, value: value, expectation: "a finite number")
        }
        return result
    }

    private static func parseSize(_ value: String, option: String) throws -> SIMD2<Int> {
        let parts = value.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Int(parts[0]), width > 0,
              let height = Int(parts[1]), height > 0 else {
            throw QAError.invalidValue(option: option, value: value, expectation: "<positive-width>x<positive-height>")
        }
        return SIMD2(width, height)
    }

    private static func parseCamera(_ value: String, option: String) throws -> Camera {
        if value == "reset" { return .reset }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 5 else {
            throw QAError.invalidValue(option: option, value: value, expectation: "reset|x,y,z,yaw,pitch")
        }
        let values = try parts.map { try parseFiniteDouble(String($0), option: option) }
        return .custom(
            position: SIMD3(values[0], values[1], values[2]),
            yaw: values[3],
            pitch: values[4]
        )
    }

    private static func parseFeatures(_ value: String, option: String) throws -> RenderFeatures {
        if value == "all" { return .all }
        if value == "none" { return [] }
        let names = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !names.isEmpty, !names.contains("") else {
            throw QAError.invalidValue(option: option, value: value, expectation: "all|none|comma-separated shadows,lights,optics,sdf,gaussian")
        }
        var features: RenderFeatures = []
        for name in names {
            switch name {
            case "shadows": features.insert(.shadows)
            case "lights": features.insert(.lights)
            case "optics": features.insert(.optics)
            case "sdf": features.insert(.sdf)
            case "gaussian": features.insert(.gaussian)
            default:
                throw QAError.invalidValue(option: option, value: value, expectation: "all|none|comma-separated shadows,lights,optics,sdf,gaussian")
            }
        }
        return features
    }
}

struct QAFixedClock {
    private(set) var currentTime: Double
    let step: Double

    init(time: Double, step: Double) {
        currentTime = time
        self.step = step
    }

    mutating func advance() {
        currentTime += step
    }
}

struct QARenderPlan {
    let mode: QAMode

    var drawablePixels: SIMD2<Int> { mode.drawablePixels }
    var renderScale: Double { mode.renderScale }
    var frameCount: Int { mode.requestedFrameCount }

    func time(forFrame frame: Int) -> Double {
        mode.fixedTime + Double(frame) * mode.fixedStep
    }

    func measuresGPU(frame: Int) -> Bool {
        guard let benchmark = mode.benchmark else { return false }
        return frame >= benchmark.warmupFrames
            && frame < benchmark.warmupFrames + benchmark.measuredFrames
    }

    func isFinal(frame: Int) -> Bool {
        frame == frameCount - 1
    }
}

struct QADrawableCapture {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bgra8: Data

    func writePNG(to path: String) throws {
        guard width > 0, height > 0, bytesPerRow >= width * 4,
              bgra8.count >= bytesPerRow * height else {
            throw QAError.writeFailed(path: path, diagnostic: "invalid BGRA capture dimensions")
        }
        guard let provider = CGDataProvider(data: bgra8 as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                    .union(.byteOrder32Little),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw QAError.writeFailed(path: path, diagnostic: "could not create a CGImage")
        }
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw QAError.writeFailed(path: path, diagnostic: error.localizedDescription)
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw QAError.writeFailed(path: path, diagnostic: "could not create a PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw QAError.writeFailed(path: path, diagnostic: "PNG encoding failed")
        }
    }
}

struct ProbeEnvelope<Metrics: Codable>: Codable {
    let schemaVersion: Int
    let probe: String
    let fixtureVersion: Int
    let status: String
    let failure: String?
    let device: String
    let metrics: Metrics

    init(probe: String, fixtureVersion: Int = 1, device: String, metrics: Metrics, failure: String? = nil) {
        schemaVersion = 1
        self.probe = probe
        self.fixtureVersion = fixtureVersion
        status = failure == nil ? "pass" : "fail"
        self.failure = failure
        self.device = device
        self.metrics = metrics
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(self)) as! [String: Any]
        if failure == nil {
            object["failure"] = NSNull()
        }
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0a)
        return data
    }

    func write(to path: String) throws {
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encodedJSON().write(to: url, options: .atomic)
        } catch {
            throw QAError.writeFailed(path: path, diagnostic: error.localizedDescription)
        }
    }

    static func decodeValidated(_ data: Data) throws -> Self {
        let envelope = try JSONDecoder().decode(Self.self, from: data)
        guard envelope.schemaVersion == 1 else {
            throw QAError.unsupportedSchema(envelope.schemaVersion)
        }
        guard envelope.fixtureVersion > 0 else {
            throw QAError.invalidEnvelope("fixtureVersion must be positive")
        }
        guard envelope.status == "pass" || envelope.status == "fail" else {
            throw QAError.invalidEnvelope("status must be pass or fail")
        }
        guard (envelope.status == "pass") == (envelope.failure == nil),
              envelope.failure?.isEmpty != true else {
            throw QAError.invalidEnvelope("status and failure disagree")
        }
        return envelope
    }
}

protocol ProbeGateMetrics: Codable {
    var gateFailure: String? { get }
}

extension ProbeEnvelope where Metrics: ProbeGateMetrics {
    static func evaluated(
        probe: String,
        fixtureVersion: Int = 1,
        device: String,
        metrics: Metrics
    ) -> Self {
        Self(
            probe: probe,
            fixtureVersion: fixtureVersion,
            device: device,
            metrics: metrics,
            failure: metrics.gateFailure
        )
    }
}

struct TraversalStepMetrics: Codable, Equatable {
    let voxelSteps: Int
    let sdfSteps: Int
    let gaussianSamples: Int
}

struct ShadowProbeMetrics: ProbeGateMetrics, Equatable {
    let sampleCount: Int
    let legacyMismatch: Int
    let falseShadows: Int
    let missedShadows: Int
    let maxHitDistanceError: Double

    var gateFailure: String? {
        guard sampleCount == 10_380 else { return "sampleCount must equal 10380" }
        guard legacyMismatch == 404 else { return "legacyMismatch must equal 404" }
        guard falseShadows == 0 else { return "falseShadows must equal zero" }
        guard missedShadows == 0 else { return "missedShadows must equal zero" }
        guard maxHitDistanceError.isFinite, maxHitDistanceError <= 0.002 else {
            return "maxHitDistanceError exceeds 0.002"
        }
        return nil
    }
}

struct MixedProbeMetrics: ProbeGateMetrics, Equatable {
    let mixedLeafVoxel: Bool
    let mixedLeafSDFRefs: Int
    let wrongNearestHits: Int
    let maxHitDistanceError: Double
    let voxelOnly: TraversalStepMetrics
    let sdfOnly: TraversalStepMetrics
    let gaussianOnly: TraversalStepMetrics
    let mixed: TraversalStepMetrics
    let empty: TraversalStepMetrics

    var gateFailure: String? {
        guard mixedLeafVoxel else { return "mixedLeafVoxel must be true" }
        guard mixedLeafSDFRefs == 2 else { return "mixedLeafSDFRefs must equal 2" }
        guard wrongNearestHits == 0 else { return "wrongNearestHits must equal zero" }
        guard maxHitDistanceError.isFinite, maxHitDistanceError <= 0.002 else {
            return "maxHitDistanceError exceeds 0.002"
        }
        let steps = [voxelOnly, sdfOnly, gaussianOnly, mixed, empty]
        guard steps.allSatisfy({ $0.voxelSteps >= 0 && $0.sdfSteps >= 0 && $0.gaussianSamples >= 0 }) else {
            return "traversal counters must be nonnegative integers"
        }
        return nil
    }
}

struct BudgetProbeMetrics: ProbeGateMetrics, Equatable {
    let overflowCount: Int
    let smoothSteps: Int
    let creatureSteps: Int
    let fractalSteps: Int
    let fractalIterations: Int
    let hierarchicalSteps: Int
    let surfaceLights: Int
    let localShadowRays: Int
    let sunShadowRays: Int
    let secondarySceneRays: Int

    var gateFailure: String? {
        guard overflowCount == 0 else { return "overflowCount must equal zero" }
        guard smoothSteps <= 24 else { return "smoothSteps exceeds 24" }
        guard creatureSteps <= 32 else { return "creatureSteps exceeds 32" }
        guard fractalSteps <= 48 else { return "fractalSteps exceeds 48" }
        guard fractalIterations <= 8 else { return "fractalIterations exceeds 8" }
        guard hierarchicalSteps <= 4_096 else { return "hierarchicalSteps exceeds 4096" }
        guard surfaceLights <= 4 else { return "surfaceLights exceeds 4" }
        guard localShadowRays <= 1 else { return "localShadowRays exceeds 1" }
        guard sunShadowRays <= 1 else { return "sunShadowRays exceeds 1" }
        guard secondarySceneRays <= 1 else { return "secondarySceneRays exceeds 1" }
        let values = [smoothSteps, creatureSteps, fractalSteps, fractalIterations, hierarchicalSteps,
                      surfaceLights, localShadowRays, sunShadowRays, secondarySceneRays]
        guard values.allSatisfy({ $0 >= 0 }) else { return "budget maxima must be nonnegative" }
        return nil
    }
}

struct SDFProbeMetrics: ProbeGateMetrics, Equatable {
    let maxDistanceError: Double
    let maxNormalAngleDegrees: Double
    let maxNormalLengthError: Double
    let nonFiniteCount: Int
    let negativeExteriorStepCount: Int
    let fractalCoverage: Double

    var gateFailure: String? {
        guard maxDistanceError.isFinite, maxDistanceError <= 0.0001 else {
            return "maxDistanceError exceeds 0.0001"
        }
        guard maxNormalAngleDegrees.isFinite, maxNormalAngleDegrees <= 0.5 else {
            return "maxNormalAngleDegrees exceeds 0.5"
        }
        guard maxNormalLengthError.isFinite, maxNormalLengthError <= 0.001 else {
            return "maxNormalLengthError exceeds 0.001"
        }
        guard nonFiniteCount == 0 else { return "nonFiniteCount must equal zero" }
        guard negativeExteriorStepCount == 0 else { return "negativeExteriorStepCount must equal zero" }
        guard fractalCoverage.isFinite, fractalCoverage < 0.10 else { return "fractalCoverage must be below 0.10" }
        return nil
    }
}

struct OpticsProbeMetrics: ProbeGateMetrics, Equatable {
    let maxReflectionDirectionError: Double
    let maxRefractionDirectionError: Double
    let tirFailureCount: Int
    let recursiveSecondaryRayCount: Int

    var gateFailure: String? {
        guard maxReflectionDirectionError.isFinite, maxReflectionDirectionError <= 0.0001 else {
            return "maxReflectionDirectionError exceeds 0.0001"
        }
        guard maxRefractionDirectionError.isFinite, maxRefractionDirectionError <= 0.0001 else {
            return "maxRefractionDirectionError exceeds 0.0001"
        }
        guard tirFailureCount == 0 else { return "tirFailureCount must equal zero" }
        guard recursiveSecondaryRayCount == 0 else { return "recursiveSecondaryRayCount must equal zero" }
        return nil
    }
}

struct VolumeProbeMetrics: ProbeGateMetrics, Equatable {
    let maxHomogeneousRelativeError: Double
    let maxGaussianRelativeError: Double
    let maxSurfaceTransmittanceRelativeError: Double
    let sunShadowRadianceRatio: Double
    let localShadowRadianceRatio: Double
    let smokeSunReceiverRatio: Double
    let smokeLocalReceiverRatio: Double
    let nonFiniteCount: Int

    var gateFailure: String? {
        guard maxHomogeneousRelativeError.isFinite, maxHomogeneousRelativeError <= 0.02 else {
            return "maxHomogeneousRelativeError exceeds 0.02"
        }
        guard maxGaussianRelativeError.isFinite, maxGaussianRelativeError <= 0.02 else {
            return "maxGaussianRelativeError exceeds 0.02"
        }
        guard maxSurfaceTransmittanceRelativeError.isFinite, maxSurfaceTransmittanceRelativeError <= 0.02 else {
            return "maxSurfaceTransmittanceRelativeError exceeds 0.02"
        }
        guard sunShadowRadianceRatio.isFinite, sunShadowRadianceRatio < 0.35 else {
            return "sunShadowRadianceRatio must be below 0.35"
        }
        guard localShadowRadianceRatio.isFinite, localShadowRadianceRatio < 0.35 else {
            return "localShadowRadianceRatio must be below 0.35"
        }
        guard smokeSunReceiverRatio.isFinite, smokeSunReceiverRatio < 1 else {
            return "smokeSunReceiverRatio must be below 1.0"
        }
        guard smokeLocalReceiverRatio.isFinite, smokeLocalReceiverRatio < 1 else {
            return "smokeLocalReceiverRatio must be below 1.0"
        }
        guard nonFiniteCount == 0 else { return "nonFiniteCount must equal zero" }
        return nil
    }
}

struct MotionProbeMetrics: ProbeGateMetrics, Equatable {
    let creatureCount: Int
    let lightCount: Int
    let repeatMismatchCount: Int
    let poseDeltaAtOneSecond: Float
    let lightDeltaAtOneSecond: Float

    var gateFailure: String? {
        guard creatureCount == 6 else { return "creatureCount must equal 6" }
        guard lightCount == 6 else { return "lightCount must equal 6" }
        guard repeatMismatchCount == 0 else { return "repeatMismatchCount must equal zero" }
        guard poseDeltaAtOneSecond.isFinite, poseDeltaAtOneSecond > 0 else {
            return "poseDeltaAtOneSecond must be positive"
        }
        guard lightDeltaAtOneSecond.isFinite, lightDeltaAtOneSecond > 0 else {
            return "lightDeltaAtOneSecond must be positive"
        }
        return nil
    }
}

struct UIProbeMetrics: ProbeGateMetrics, Equatable {
    let stateMismatchCount: Int
    let focusFailureCount: Int
    let modifierLeakCount: Int
    let accessibilityFailureCount: Int
    let responsiveLayoutFailureCount: Int
    let adaptiveScaleFailureCount: Int
    let fixedScaleFailureCount: Int
    let reduceMotionFailureCount: Int
    let windowCount: Int

    var gateFailure: String? {
        let failures = [
            stateMismatchCount,
            focusFailureCount,
            modifierLeakCount,
            accessibilityFailureCount,
            responsiveLayoutFailureCount,
            adaptiveScaleFailureCount,
            fixedScaleFailureCount,
            reduceMotionFailureCount,
        ]
        guard failures.allSatisfy({ $0 == 0 }) else { return "UI failure counts must equal zero" }
        guard windowCount == 1 else { return "windowCount must equal 1" }
        return nil
    }
}

struct QAFrameReport: Codable {
    let schemaVersion: Int
    let status: String
    let failure: String?
    let device: String
    let os: String
    let scene: String
    let fixedTime: Double
    let drawablePixels: [Int]
    let renderScale: Double
    let windowCount: Int
    let productionKernels: [String]
    let featureMask: String
    let passCount: Int
    let stepCounters: [String: Int]
    let shadowSampleCounts: [String: Int]
    let budgetOverflows: Int
    let commandErrors: Int
    let droppedDrawables: Int
    let semaphoreTimeouts: Int
    let capturePath: String?
    let fixedStep: Double
    let warmupFrames: Int
    let measuredFrames: Int
    let percentileMethod: String
    let gpuMilliseconds: [Double]
    let p95GPUms: Double
    let thermalStateBefore: String?
    let thermalStateAfter: String?

    init(
        status: String,
        failure: String?,
        device: String,
        os: String,
        scene: String,
        fixedTime: Double,
        drawablePixels: [Int],
        renderScale: Double,
        windowCount: Int,
        productionKernels: [String],
        featureMask: String,
        passCount: Int,
        stepCounters: [String: Int],
        shadowSampleCounts: [String: Int],
        budgetOverflows: Int,
        commandErrors: Int,
        droppedDrawables: Int,
        semaphoreTimeouts: Int,
        capturePath: String?,
        fixedStep: Double,
        warmupFrames: Int = 0,
        measuredFrames: Int = 0,
        gpuMilliseconds: [Double] = [],
        thermalStateBefore: String? = nil,
        thermalStateAfter: String? = nil
    ) {
        schemaVersion = 1
        self.status = status
        self.failure = failure
        self.device = device
        self.os = os
        self.scene = scene
        self.fixedTime = fixedTime
        self.drawablePixels = drawablePixels
        self.renderScale = renderScale
        self.windowCount = windowCount
        self.productionKernels = productionKernels
        self.featureMask = featureMask
        self.passCount = passCount
        self.stepCounters = stepCounters
        self.shadowSampleCounts = shadowSampleCounts
        self.budgetOverflows = budgetOverflows
        self.commandErrors = commandErrors
        self.droppedDrawables = droppedDrawables
        self.semaphoreTimeouts = semaphoreTimeouts
        self.capturePath = capturePath
        self.fixedStep = fixedStep
        self.warmupFrames = warmupFrames
        self.measuredFrames = measuredFrames
        percentileMethod = "nearest-rank"
        self.gpuMilliseconds = gpuMilliseconds
        p95GPUms = Self.nearestRankP95(gpuMilliseconds)
        self.thermalStateBefore = thermalStateBefore
        self.thermalStateAfter = thermalStateAfter
    }

    static func nearestRankP95(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let index = Int(ceil(0.95 * Double(sorted.count))) - 1
        return sorted[index]
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(self)) as! [String: Any]
        if failure == nil {
            object["failure"] = NSNull()
        }
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0a)
        return data
    }

    func write(to path: String) throws {
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encodedJSON().write(to: url, options: .atomic)
        } catch {
            throw QAError.writeFailed(path: path, diagnostic: error.localizedDescription)
        }
    }
}
