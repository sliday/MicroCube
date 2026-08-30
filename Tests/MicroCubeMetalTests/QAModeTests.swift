import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import MicroCubeMetal

final class QAModeTests: XCTestCase {
    func testParsesDeterministicCaptureArguments() throws {
        let mode = try QAMode.parse([
            "--qa-scene", "hero", "--qa-time", "1", "--qa-step", "0.008333333333333333",
            "--qa-camera", "reset", "--qa-window-points", "1280x800",
            "--qa-drawable", "1280x800", "--qa-scale", "1", "--qa-view", "final",
            "--qa-frames", "1", "--qa-capture-scope", "drawable",
            "--qa-capture", "/tmp/hero.png", "--qa-report", "/tmp/hero.json"
        ])

        XCTAssertEqual(mode.scene, .hero)
        XCTAssertEqual(mode.features, .all)
        XCTAssertEqual(mode.fixedTime, 1)
        XCTAssertEqual(mode.fixedStep, 1.0 / 120.0, accuracy: 1e-15)
        XCTAssertEqual(mode.camera, .reset)
        XCTAssertEqual(mode.windowPoints, SIMD2(1280, 800))
        XCTAssertEqual(mode.drawablePixels, SIMD2(1280, 800))
        XCTAssertEqual(mode.renderScale, 1)
        XCTAssertEqual(mode.view, .final)
        XCTAssertEqual(mode.frames, 1)
        XCTAssertEqual(mode.captureScope, .drawable)
        XCTAssertEqual(mode.capturePath, "/tmp/hero.png")
        XCTAssertEqual(mode.reportPath, "/tmp/hero.json")
    }

    func testParsesEverySceneViewFeatureAndBenchmarkOption() throws {
        let scenes = [
            "hero", "shadow-fixture", "mixed-fixture", "optics-fixture",
            "fog-clear", "fog-blocked", "gaussian-fixture", "fractal-fixture"
        ]
        let views = [
            "final", "grid", "pyramid", "steps", "cost", "primitive-id",
            "normals", "shadow-mismatch"
        ]

        for scene in scenes {
            XCTAssertEqual(try QAMode.parse(["--qa-scene", scene]).scene.rawValue, scene)
        }
        for view in views {
            XCTAssertEqual(try QAMode.parse(["--qa-view", view]).view.rawValue, view)
        }

        let mode = try QAMode.parse([
            "--qa-features", "shadows,lights,optics,sdf,gaussian",
            "--qa-camera", "1,2,3,0.5,-0.25",
            "--benchmark", "--benchmark-warmup", "180", "--benchmark-samples", "900"
        ])
        XCTAssertEqual(mode.features, .all)
        XCTAssertEqual(mode.camera, .custom(position: SIMD3(1, 2, 3), yaw: 0.5, pitch: -0.25))
        XCTAssertEqual(mode.benchmark, QABenchmark(warmupFrames: 180, measuredFrames: 900))
        XCTAssertEqual(mode.requestedFrameCount, 1_080)
    }

    func testParsesAllAndNoneFeatureAliases() throws {
        XCTAssertEqual(try QAMode.parse(["--qa-features", "all"]).featureMask, "all")
        XCTAssertEqual(try QAMode.parse(["--qa-features", "none"]).featureMask, "none")
        XCTAssertEqual(
            try QAMode.parse(["--qa-features", "lights,shadows"]).featureMask,
            "shadows,lights"
        )
    }

    func testRejectsMalformedQAArguments() {
        let invalidArguments = [
            ["--qa-scene"],
            ["--qa-scene", "unknown"],
            ["--qa-window-points", "1280"],
            ["--qa-drawable", "0x800"],
            ["--qa-scale", "0.34"],
            ["--qa-scale", "1.01"],
            ["--qa-frames", "0"],
            ["--qa-features", "lights,unknown"],
            ["--qa-camera", "1,2,3,4"],
            ["--qa-view", "beauty"],
            ["--qa-capture-scope", "screen"],
            ["--benchmark-warmup", "-1"],
            ["--benchmark-samples", "0"],
            ["--qa-unknown", "value"]
        ]

        for arguments in invalidArguments {
            XCTAssertThrowsError(try QAMode.parse(arguments), "Accepted \(arguments)") { error in
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
    }

    func testParseFailureWritesReadableStderrAndFailingReport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reportPath = directory.appendingPathComponent("parse-failure.json").path
        let arguments = ["--qa-scene", "unknown", "--qa-report", reportPath]
        let pipe = Pipe()

        do {
            _ = try QAMode.parse(arguments)
            XCTFail("Expected parser failure")
        } catch {
            QAMode.handleParseFailure(error, arguments: arguments, standardError: pipe.fileHandleForWriting)
        }
        pipe.fileHandleForWriting.closeFile()

        let stderr = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(stderr.contains("Invalid value 'unknown' for --qa-scene"))
        let data = try Data(contentsOf: URL(fileURLWithPath: reportPath))
        let report = try JSONDecoder().decode(QAFrameReport.self, from: data)
        XCTAssertEqual(report.status, "fail")
        XCTAssertEqual(report.passCount, 0)
        XCTAssertEqual(report.windowCount, 0)
        XCTAssertTrue(report.failure?.contains("Invalid value 'unknown' for --qa-scene") == true)
    }

    func testParseFailureUsesLastUsableRawReportPathAndSkipsMalformedPair() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reportPath = directory.appendingPathComponent("usable.json").path
        let arguments = ["--qa-report", reportPath, "--qa-report", "--qa-scene"]
        let pipe = Pipe()

        XCTAssertEqual(QAMode.rawReportPath(in: arguments), reportPath)
        QAMode.handleParseFailure(
            QAError.missingValue("--qa-report"),
            arguments: ["--qa-report", "--qa-scene"],
            standardError: pipe.fileHandleForWriting
        )
        pipe.fileHandleForWriting.closeFile()

        XCTAssertFalse(FileManager.default.fileExists(atPath: reportPath))
        XCTAssertTrue(
            String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .contains("Missing value for --qa-report")
        )
    }

    func testNonQAArgumentsDoNotRequestAutomation() throws {
        XCTAssertNil(try QAMode.parseIfRequested(["-ApplePersistenceIgnoreState", "YES"]))
        XCTAssertNotNil(try QAMode.parseIfRequested(["--benchmark"]))
    }

    func testFixedClockUsesOnlyConfiguredTimeAndStep() {
        var clock = QAFixedClock(time: 4.5, step: 1.0 / 120.0)

        XCTAssertEqual(clock.currentTime, 4.5)
        clock.advance()
        XCTAssertEqual(clock.currentTime, 4.5 + 1.0 / 120.0, accuracy: 1e-15)
        clock.advance()
        XCTAssertEqual(clock.currentTime, 4.5 + 2.0 / 120.0, accuracy: 1e-15)
    }

    func testFrameReportEncodesRequiredCaptureAndBenchmarkFields() throws {
        let report = QAFrameReport(
            status: "pass",
            failure: nil,
            device: "Apple M4 Max",
            os: "macOS 15.6",
            scene: "hero",
            fixedTime: 0,
            drawablePixels: [1280, 800],
            renderScale: 1,
            windowCount: 1,
            productionKernels: ["injectVolumeLighting", "raycastHybrid"],
            featureMask: "all",
            passCount: 2,
            stepCounters: ["voxelSteps": 12],
            shadowSampleCounts: ["sun": 1],
            budgetOverflows: 0,
            commandErrors: 0,
            droppedDrawables: 0,
            semaphoreTimeouts: 0,
            capturePath: "/tmp/hero.png",
            fixedStep: 1.0 / 120.0,
            warmupFrames: 180,
            measuredFrames: 3,
            gpuMilliseconds: [1.0, 2.0, 3.0],
            thermalStateBefore: "nominal",
            thermalStateAfter: "nominal"
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: report.encodedJSON()) as? [String: Any]
        )
        let requiredKeys: Set<String> = [
            "schemaVersion", "status", "failure", "device", "os", "scene", "fixedTime",
            "drawablePixels", "renderScale", "windowCount", "productionKernels", "featureMask",
            "passCount", "stepCounters", "shadowSampleCounts", "budgetOverflows", "commandErrors",
            "droppedDrawables", "semaphoreTimeouts", "capturePath", "gpuMilliseconds"
        ]
        XCTAssertTrue(requiredKeys.isSubset(of: Set(object.keys)))
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["windowCount"] as? Int, 1)
        XCTAssertEqual(object["passCount"] as? Int, 2)
        XCTAssertEqual(object["percentileMethod"] as? String, "nearest-rank")
        XCTAssertEqual(object["p95GPUms"] as? Double, 3)
    }

    func testNearestRankP95UsesSpecifiedIndex() {
        XCTAssertEqual(QAFrameReport.nearestRankP95(Array(1...100).map(Double.init)), 95)
    }

    func testProbeEnvelopeWritesOneValidatedUTF8JSONObject() throws {
        let envelope = ProbeEnvelope(
            probe: "shadow",
            device: "Apple M4 Max",
            metrics: ShadowProbeMetrics(
                sampleCount: 10_380,
                legacyMismatch: 404,
                falseShadows: 0,
                missedShadows: 0,
                maxHitDistanceError: 0.001
            )
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("shadow.json").path
        try envelope.write(to: path)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try ProbeEnvelope<ShadowProbeMetrics>.decodeValidated(data)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.fixtureVersion, 1)
        XCTAssertEqual(decoded.status, "pass")
        XCTAssertNil(decoded.failure)
        XCTAssertEqual(decoded.metrics.sampleCount, 10_380)
        XCTAssertEqual(String(decoding: data, as: UTF8.self).first, "{")
        XCTAssertEqual(String(decoding: data, as: UTF8.self).last, "\n")
    }

    func testMetalProbeHarnessWritesNamedEvidenceFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try ProbeEnvelope(
            probe: "shadow",
            device: "Apple M4 Max",
            metrics: ShadowProbeMetrics(
                sampleCount: 10_380,
                legacyMismatch: 404,
                falseShadows: 0,
                missedShadows: 0,
                maxHitDistanceError: 0.001
            )
        ).encodedJSON()

        try MetalProbeHarness.writeEvidence(data, named: "shadow", directory: directory.path)

        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("shadow.json")),
            data
        )
    }

    func testProbeEnvelopeRejectsUnknownSchemaAndInconsistentStatus() throws {
        let unknownSchema = Data("""
        {"schemaVersion":2,"probe":"shadow","fixtureVersion":1,"status":"pass","failure":null,"device":"GPU","metrics":{"sampleCount":10380,"legacyMismatch":404,"falseShadows":0,"missedShadows":0,"maxHitDistanceError":0}}
        """.utf8)
        let inconsistentStatus = Data("""
        {"schemaVersion":1,"probe":"shadow","fixtureVersion":1,"status":"pass","failure":"failed","device":"GPU","metrics":{"sampleCount":10380,"legacyMismatch":404,"falseShadows":0,"missedShadows":0,"maxHitDistanceError":0}}
        """.utf8)

        XCTAssertThrowsError(try ProbeEnvelope<ShadowProbeMetrics>.decodeValidated(unknownSchema))
        XCTAssertThrowsError(try ProbeEnvelope<ShadowProbeMetrics>.decodeValidated(inconsistentStatus))
    }

    func testProbeEvaluationAppliesEveryRequiredGate() {
        let steps = TraversalStepMetrics(voxelSteps: 1, sdfSteps: 1, gaussianSamples: 1)
        let voxelOnly = TraversalStepMetrics(voxelSteps: 1, sdfSteps: 0, gaussianSamples: 0)
        let sdfOnly = TraversalStepMetrics(voxelSteps: 0, sdfSteps: 1, gaussianSamples: 0)
        let gaussianOnly = TraversalStepMetrics(voxelSteps: 0, sdfSteps: 0, gaussianSamples: 1)
        let empty = TraversalStepMetrics(voxelSteps: 0, sdfSteps: 0, gaussianSamples: 0)
        let passing: [String] = [
            ProbeEnvelope.evaluated(
                probe: "shadow", device: "GPU",
                metrics: ShadowProbeMetrics(sampleCount: 10_380, legacyMismatch: 404, falseShadows: 0, missedShadows: 0, maxHitDistanceError: 0.002)
            ).status,
            ProbeEnvelope.evaluated(
                probe: "mixed", device: "GPU",
                metrics: MixedProbeMetrics(mixedLeafVoxel: true, mixedLeafSDFRefs: 2, wrongNearestHits: 0, maxHitDistanceError: 0.002, voxelOnly: voxelOnly, sdfOnly: sdfOnly, gaussianOnly: gaussianOnly, mixed: steps, empty: empty)
            ).status,
            ProbeEnvelope.evaluated(
                probe: "budgets", device: "GPU",
                metrics: BudgetProbeMetrics(overflowCount: 0, smoothSteps: 24, creatureSteps: 32, fractalSteps: 48, fractalIterations: 8, hierarchicalSteps: 4_096, surfaceLights: 4, localShadowRays: 1, sunShadowRays: 1, secondarySceneRays: 1)
            ).status,
            ProbeEnvelope.evaluated(
                probe: "sdf", device: "GPU",
                metrics: SDFProbeMetrics(maxDistanceError: 0.0001, maxNormalAngleDegrees: 0.5, maxNormalLengthError: 0.001, nonFiniteCount: 0, negativeExteriorStepCount: 0, fractalCoverage: 0.099)
            ).status,
            ProbeEnvelope.evaluated(
                probe: "optics", device: "GPU",
                metrics: OpticsProbeMetrics(maxReflectionDirectionError: 0.0001, maxRefractionDirectionError: 0.0001, tirFailureCount: 0, recursiveSecondaryRayCount: 0)
            ).status,
            ProbeEnvelope.evaluated(
                probe: "volume", device: "GPU",
                metrics: VolumeProbeMetrics(maxHomogeneousRelativeError: 0.02, maxGaussianRelativeError: 0.02, maxSurfaceTransmittanceRelativeError: 0.02, sunShadowRadianceRatio: 0.349, localShadowRadianceRatio: 0.349, smokeSunReceiverRatio: 0.999, smokeLocalReceiverRatio: 0.999, nonFiniteCount: 0)
            ).status,
            ProbeEnvelope.evaluated(
                probe: "motion", device: "GPU",
                metrics: MotionProbeMetrics(creatureCount: 6, lightCount: 6, repeatMismatchCount: 0, poseDeltaAtOneSecond: 0.001, lightDeltaAtOneSecond: 0.001)
            ).status,
            ProbeEnvelope.evaluated(
                probe: "ui", device: "GPU",
                metrics: UIProbeMetrics(stateMismatchCount: 0, focusFailureCount: 0, modifierLeakCount: 0, accessibilityFailureCount: 0, responsiveLayoutFailureCount: 0, adaptiveScaleFailureCount: 0, fixedScaleFailureCount: 0, reduceMotionFailureCount: 0, windowCount: 1)
            ).status,
        ]
        let failures: [String] = [
            ProbeEnvelope.evaluated(
                probe: "shadow", device: "GPU",
                metrics: ShadowProbeMetrics(sampleCount: 10_380, legacyMismatch: 404, falseShadows: 1, missedShadows: 0, maxHitDistanceError: 0)
            ).status,
            ProbeEnvelope.evaluated(
                probe: "mixed", device: "GPU",
                metrics: MixedProbeMetrics(mixedLeafVoxel: true, mixedLeafSDFRefs: 2, wrongNearestHits: 0, maxHitDistanceError: 0, voxelOnly: steps, sdfOnly: sdfOnly, gaussianOnly: gaussianOnly, mixed: steps, empty: empty)
            ).status,
            ProbeEnvelope.evaluated(
                probe: "budgets", device: "GPU",
                metrics: BudgetProbeMetrics(overflowCount: 0, smoothSteps: 25, creatureSteps: 32, fractalSteps: 48, fractalIterations: 8, hierarchicalSteps: 4_096, surfaceLights: 4, localShadowRays: 1, sunShadowRays: 1, secondarySceneRays: 1)
            ).status,
            ProbeEnvelope.evaluated(
                probe: "sdf", device: "GPU",
                metrics: SDFProbeMetrics(maxDistanceError: 0, maxNormalAngleDegrees: 0, maxNormalLengthError: 0, nonFiniteCount: 0, negativeExteriorStepCount: 0, fractalCoverage: 0.10)
            ).status,
            ProbeEnvelope.evaluated(
                probe: "sdf", device: "GPU",
                metrics: SDFProbeMetrics(maxDistanceError: 0, maxNormalAngleDegrees: 0, maxNormalLengthError: 0, nonFiniteCount: 0, negativeExteriorStepCount: 0, fractalCoverage: 0)
            ).status,
            ProbeEnvelope.evaluated(
                probe: "volume", device: "GPU",
                metrics: VolumeProbeMetrics(maxHomogeneousRelativeError: 0, maxGaussianRelativeError: 0, maxSurfaceTransmittanceRelativeError: 0, sunShadowRadianceRatio: 0.35, localShadowRadianceRatio: 0, smokeSunReceiverRatio: 0, smokeLocalReceiverRatio: 0, nonFiniteCount: 0)
            ).status,
            ProbeEnvelope.evaluated(
                probe: "motion", device: "GPU",
                metrics: MotionProbeMetrics(creatureCount: 6, lightCount: 6, repeatMismatchCount: 0, poseDeltaAtOneSecond: 0, lightDeltaAtOneSecond: 1)
            ).status,
            ProbeEnvelope.evaluated(
                probe: "ui", device: "GPU",
                metrics: UIProbeMetrics(stateMismatchCount: 0, focusFailureCount: 0, modifierLeakCount: 0, accessibilityFailureCount: 0, responsiveLayoutFailureCount: 0, adaptiveScaleFailureCount: 0, fixedScaleFailureCount: 0, reduceMotionFailureCount: 0, windowCount: 2)
            ).status,
        ]

        XCTAssertEqual(passing, Array(repeating: "pass", count: 8))
        XCTAssertEqual(failures, Array(repeating: "fail", count: 8))
    }

    func testRendererErrorsKeepTheMetalDiagnostic() {
        let diagnostic = "program_source:17:4: error: use of undeclared identifier"

        XCTAssertTrue(RendererError.compiler(diagnostic).localizedDescription.contains(diagnostic))
        XCTAssertTrue(RendererError.pipeline("raycastHybrid", diagnostic).localizedDescription.contains(diagnostic))
        XCTAssertTrue(RendererError.allocation("volume texture").localizedDescription.contains("volume texture"))
    }

    func testRenderPlanKeepsFixedClockDrawableScaleAndBenchmarkBoundaries() throws {
        let mode = try QAMode.parse([
            "--qa-time", "4.5", "--qa-step", "0.008333333333333333",
            "--qa-drawable", "1280x800", "--qa-scale", "0.75",
            "--benchmark", "--benchmark-warmup", "180", "--benchmark-samples", "900"
        ])
        let plan = QARenderPlan(mode: mode)

        XCTAssertEqual(plan.time(forFrame: 0), 4.5)
        XCTAssertEqual(plan.time(forFrame: 1), 4.5 + 1.0 / 120.0, accuracy: 1e-15)
        XCTAssertEqual(plan.drawablePixels, SIMD2(1280, 800))
        XCTAssertEqual(plan.renderScale, 0.75)
        XCTAssertFalse(plan.measuresGPU(frame: 179))
        XCTAssertTrue(plan.measuresGPU(frame: 180))
        XCTAssertTrue(plan.isFinal(frame: 1_079))
        XCTAssertFalse(plan.isFinal(frame: 1_078))
    }

    func testBothCaptureScopesRequestTheFinalDrawable() {
        for scope in [QAMode.CaptureScope.drawable, .window] {
            var mode = QAMode()
            mode.captureScope = scope
            mode.capturePath = "/tmp/capture.png"
            let plan = QARenderPlan(mode: mode)

            XCTAssertTrue(plan.capturesDrawable(frame: 0))
        }
    }

    func testDrawableCaptureWritesDecodablePNG() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("pixel.png").path
        let capture = QADrawableCapture(
            width: 1,
            height: 1,
            bytesPerRow: 4,
            bgra8: Data([0, 0, 255, 255])
        )

        try capture.writePNG(to: path)

        let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: path))))
        XCTAssertEqual(image.pixelsWide, 1)
        XCTAssertEqual(image.pixelsHigh, 1)
        let color = try XCTUnwrap(image.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent, 0.95)
        XCTAssertGreaterThan(color.redComponent - color.greenComponent, 0.75)
        XCTAssertLessThan(color.blueComponent, 0.01)
    }

    func testDrawableCaptureCreatesReusableCGImage() throws {
        let capture = QADrawableCapture(
            width: 1,
            height: 1,
            bytesPerRow: 4,
            bgra8: Data([0, 255, 0, 255])
        )

        let image = try capture.makeCGImage(path: "memory")

        XCTAssertEqual(image.width, 1)
        XCTAssertEqual(image.height, 1)
        XCTAssertEqual(image.bytesPerRow, 4)
    }

    func testQASceneSelectionBuildsTheRequestedDeterministicFixture() throws {
        let shadow = try Renderer.makeScene(for: .shadowFixture)
        let mixed = try Renderer.makeScene(for: .mixedFixture)
        let optics = try Renderer.makeScene(for: .opticsFixture)
        let gaussian = try Renderer.makeScene(for: .gaussianFixture)
        let fractal = try Renderer.makeScene(for: .fractalFixture)

        XCTAssertTrue(shadow.sdfInstances.isEmpty)
        XCTAssertTrue(shadow.gaussians.isEmpty)
        XCTAssertGreaterThan(mixed.sdfInstances.count, 1)
        XCTAssertGreaterThan(mixed.gaussians.count, 0)
        XCTAssertEqual(optics.sdfInstances.map(\.metadata.x), [4])
        XCTAssertTrue(optics.gaussians.isEmpty)
        XCTAssertTrue(gaussian.sdfInstances.isEmpty)
        XCTAssertGreaterThan(gaussian.gaussians.count, 0)
        XCTAssertEqual(fractal.sdfInstances.map(\.metadata.x), [3])
        XCTAssertTrue(fractal.gaussians.isEmpty)
    }
}

final class ScriptContractTests: XCTestCase {
    private enum FakeProcessMode: Equatable {
        case launched
        case multiple
        case unrelated
        case zero
        case occupied
        case lingering
    }

    private struct CaptureSpec {
        let row: String
        let stem: String
        let scene: String
        let featureMask: String
        let time: String
        let view: String
        let captureScope: String
        let window: String

        var path: String { "captures/\(stem).png" }
        var reportPath: String { "captures/\(stem).json" }
        var fixedTime: Double { Double(time)! }
        var windowPoints: [Int] { window.split(separator: "x").compactMap { Int($0) } }
    }

    private let captureRows = [
        "Shadow beauty and mismatch",
        "Mixed primitive ID and steps",
        "Monsters",
        "Optics",
        "Fog blocker",
        "Gaussian",
        "Smoke-cast surface shadow",
        "Fractal normals",
        "Hero final field",
        "Five evidence views",
        "Explainer responsive states",
    ]

    private let captureSpecs = [
        CaptureSpec(row: "Shadow beauty and mismatch", stem: "shadow-beauty-and-mismatch-beauty", scene: "shadow-fixture", featureMask: "shadows", time: "0", view: "final", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Shadow beauty and mismatch", stem: "shadow-beauty-and-mismatch-mismatch", scene: "shadow-fixture", featureMask: "shadows", time: "0", view: "shadow-mismatch", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Mixed primitive ID and steps", stem: "mixed-primitive-id-and-steps-primitive-id", scene: "mixed-fixture", featureMask: "all", time: "0", view: "primitive-id", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Mixed primitive ID and steps", stem: "mixed-primitive-id-and-steps-steps", scene: "mixed-fixture", featureMask: "all", time: "0", view: "steps", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Monsters", stem: "monsters-t0", scene: "hero", featureMask: "sdf,lights,gaussian,shadows", time: "0", view: "final", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Monsters", stem: "monsters-t1", scene: "hero", featureMask: "sdf,lights,gaussian,shadows", time: "1", view: "final", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Optics", stem: "optics-optics", scene: "optics-fixture", featureMask: "optics", time: "0", view: "final", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Optics", stem: "optics-none", scene: "optics-fixture", featureMask: "none", time: "0", view: "final", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Fog blocker", stem: "fog-blocker-clear", scene: "fog-clear", featureMask: "gaussian,lights,shadows", time: "0", view: "final", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Fog blocker", stem: "fog-blocker-blocked", scene: "fog-blocked", featureMask: "gaussian,lights,shadows", time: "0", view: "final", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Gaussian", stem: "gaussian-gaussian", scene: "gaussian-fixture", featureMask: "gaussian", time: "0", view: "final", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Gaussian", stem: "gaussian-none", scene: "gaussian-fixture", featureMask: "none", time: "0", view: "final", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Smoke-cast surface shadow", stem: "smoke-cast-surface-shadow-smoke", scene: "gaussian-fixture", featureMask: "gaussian,lights,shadows", time: "0", view: "final", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Smoke-cast surface shadow", stem: "smoke-cast-surface-shadow-clear", scene: "gaussian-fixture", featureMask: "lights,shadows", time: "0", view: "final", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Fractal normals", stem: "fractal-normals-normals", scene: "fractal-fixture", featureMask: "sdf", time: "0", view: "normals", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Hero final field", stem: "hero-final-field-final", scene: "hero", featureMask: "all", time: "0", view: "final", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Five evidence views", stem: "five-evidence-views-final", scene: "hero", featureMask: "all", time: "0", view: "final", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Five evidence views", stem: "five-evidence-views-grid", scene: "hero", featureMask: "all", time: "0", view: "grid", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Five evidence views", stem: "five-evidence-views-pyramid", scene: "hero", featureMask: "all", time: "0", view: "pyramid", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Five evidence views", stem: "five-evidence-views-steps", scene: "hero", featureMask: "all", time: "0", view: "steps", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Five evidence views", stem: "five-evidence-views-cost", scene: "hero", featureMask: "all", time: "0", view: "cost", captureScope: "drawable", window: "1280x800"),
        CaptureSpec(row: "Explainer responsive states", stem: "explainer-responsive-states-expanded", scene: "hero", featureMask: "all", time: "0", view: "final", captureScope: "window", window: "1280x800"),
        CaptureSpec(row: "Explainer responsive states", stem: "explainer-responsive-states-collapsed", scene: "hero", featureMask: "all", time: "0", view: "final", captureScope: "window", window: "1099x800"),
    ]

    func testCompletionVerifierAcceptsValidEvidenceAndWritesHashLinkedReport() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

        XCTAssertEqual(result.status, 0, result.output)
        let report = try json(at: fixture.evidence.appendingPathComponent("completion.json"))
        XCTAssertEqual(report["status"] as? String, "pass")
        let inputs = try XCTUnwrap(report["inputs"] as? [String: String])
        let visualReview = fixture.evidence.appendingPathComponent("visual-review.json")
        let firstCapture = fixture.evidence.appendingPathComponent(captureSpecs[0].path)
        XCTAssertEqual(inputs["visual-review.json"], sha256(try Data(contentsOf: visualReview)))
        XCTAssertEqual(inputs[captureSpecs[0].path], sha256(try Data(contentsOf: firstCapture)))
    }

    func testCompletionVerifierAcceptsCanonicalFeatureOrderFromQAReport() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let spec = try XCTUnwrap(captureSpecs.first { $0.stem == "monsters-t0" })
        let reportURL = fixture.evidence.appendingPathComponent(spec.reportPath)
        var report = try json(at: reportURL)
        report["featureMask"] = "shadows,lights,sdf,gaussian"
        try writeJSON(report, to: reportURL)

        let reviewURL = fixture.evidence.appendingPathComponent("visual-review.json")
        var review = try json(at: reviewURL)
        var rows = try XCTUnwrap(review["rows"] as? [[String: Any]])
        let rowIndex = try XCTUnwrap(rows.firstIndex { $0["name"] as? String == spec.row })
        var captures = try XCTUnwrap(rows[rowIndex]["captures"] as? [[String: Any]])
        let captureIndex = try XCTUnwrap(captures.firstIndex { $0["reportPath"] as? String == spec.reportPath })
        captures[captureIndex]["reportSHA256"] = sha256(try Data(contentsOf: reportURL))
        rows[rowIndex]["captures"] = captures
        review["rows"] = rows
        try writeJSON(review, to: reviewURL)

        let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testCompletionVerifierCanonicalizesEvidenceDirectoryBeforeMatchingCapturePath() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let aliasedEvidence = fixture.evidence.appendingPathComponent("../evidence").path

        let result = try runScript("verify-completion.sh", arguments: [aliasedEvidence])

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testCompletionVerifierRejectsEmptyProbeMetrics() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probeURL = fixture.evidence.appendingPathComponent("shadow.json")
        var probe = try json(at: probeURL)
        probe["metrics"] = [String: Any]()
        try writeJSON(probe, to: probeURL)

        let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("shadow.json is not valid probe evidence"), result.output)
    }

    func testCompletionVerifierRejectsWrongProbeSchema() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probeURL = fixture.evidence.appendingPathComponent("shadow.json")
        var probe = try json(at: probeURL)
        probe["schemaVersion"] = 2
        try writeJSON(probe, to: probeURL)

        let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("shadow.json is not valid probe evidence"), result.output)
    }

    func testCompletionVerifierRejectsMismatchedProbeName() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probeURL = fixture.evidence.appendingPathComponent("shadow.json")
        var probe = try json(at: probeURL)
        probe["probe"] = "mixed"
        try writeJSON(probe, to: probeURL)

        let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("shadow.json is not valid probe evidence"), result.output)
    }

    func testCompletionVerifierRejectsConcatenatedProbeObjects() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probeURL = fixture.evidence.appendingPathComponent("shadow.json")
        var data = Data("{\"status\":\"pass\"}\n".utf8)
        data.append(try Data(contentsOf: probeURL))
        try data.write(to: probeURL)

        let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("shadow.json is not valid probe evidence"), result.output)
    }

    func testCompletionVerifierRejectsExtraProbeEnvelopeKey() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probeURL = fixture.evidence.appendingPathComponent("shadow.json")
        var probe = try json(at: probeURL)
        probe["unreviewed"] = true
        try writeJSON(probe, to: probeURL)

        let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("shadow.json is not valid probe evidence"), result.output)
    }

    func testCompletionVerifierRejectsStaleCaptureHashAndInvalidBenchmarkSamples() throws {
        let staleFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: staleFixture.root) }
        try Data("changed".utf8).write(to: staleFixture.capture)

        let stale = try runScript("verify-completion.sh", arguments: [staleFixture.evidence.path])
        XCTAssertNotEqual(stale.status, 0, stale.output)
        XCTAssertEqual(
            try json(at: staleFixture.evidence.appendingPathComponent("completion.json"))["status"] as? String,
            "fail"
        )

        let benchmarkFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: benchmarkFixture.root) }
        let benchmark = benchmarkFixture.evidence.appendingPathComponent("benchmark-1280x800-run1.json")
        var invalid = try json(at: benchmark)
        invalid["gpuMilliseconds"] = Array(repeating: 1.0, count: 899)
        try writeJSON(invalid, to: benchmark)

        let invalidResult = try runScript("verify-completion.sh", arguments: [benchmarkFixture.evidence.path])
        XCTAssertNotEqual(invalidResult.status, 0, invalidResult.output)
        XCTAssertTrue(invalidResult.output.contains("not a valid M4 Max benchmark report"), invalidResult.output)
        let invalidCompletion = try json(at: benchmarkFixture.evidence.appendingPathComponent("completion.json"))
        XCTAssertEqual(invalidCompletion["status"] as? String, "fail")
        XCTAssertFalse((invalidCompletion["inputs"] as? [String: String] ?? [:]).isEmpty)

        let windowFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: windowFixture.root) }
        try writeJSON(["status": "pass", "processCount": 1, "windowCount": 2], to: windowFixture.evidence.appendingPathComponent("package-verification.json"))

        let windowResult = try runScript("verify-completion.sh", arguments: [windowFixture.evidence.path])
        XCTAssertNotEqual(windowResult.status, 0, windowResult.output)
        XCTAssertTrue(windowResult.output.contains("one process and one window"), windowResult.output)
        let windowCompletion = try json(at: windowFixture.evidence.appendingPathComponent("completion.json"))
        XCTAssertEqual(windowCompletion["status"] as? String, "fail")
        XCTAssertFalse((windowCompletion["inputs"] as? [String: String] ?? [:]).isEmpty)
    }

    func testCompletionVerifierRejectsCaptureStateMismatch() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reviewURL = fixture.evidence.appendingPathComponent("visual-review.json")
        var review = try json(at: reviewURL)
        var rows = try XCTUnwrap(review["rows"] as? [[String: Any]])
        var captures = try XCTUnwrap(rows[0]["captures"] as? [[String: Any]])
        captures[0]["scene"] = "hero"
        rows[0]["captures"] = captures
        review["rows"] = rows
        try writeJSON(review, to: reviewURL)

        let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("capture matrix"), result.output)
    }

    func testCompletionVerifierRejectsCaptureReportWithDifferentStem() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reviewURL = fixture.evidence.appendingPathComponent("visual-review.json")
        let alternateReport = fixture.evidence.appendingPathComponent("captures/alternate.json")
        try FileManager.default.copyItem(
            at: fixture.evidence.appendingPathComponent(captureSpecs[0].reportPath),
            to: alternateReport
        )
        var review = try json(at: reviewURL)
        var rows = try XCTUnwrap(review["rows"] as? [[String: Any]])
        var captures = try XCTUnwrap(rows[0]["captures"] as? [[String: Any]])
        captures[0]["reportPath"] = "captures/alternate.json"
        captures[0]["reportSHA256"] = sha256(try Data(contentsOf: alternateReport))
        rows[0]["captures"] = captures
        review["rows"] = rows
        try writeJSON(review, to: reviewURL)

        let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("capture matrix"), result.output)
    }

    func testCompletionVerifierRejectsWrongKernelSetAndBudgetOverflow() throws {
        for mutation in ["kernels", "budget", "step"] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let reportURL = fixture.evidence.appendingPathComponent(captureSpecs[0].reportPath)
            var report = try json(at: reportURL)
            if mutation == "kernels" {
                report["productionKernels"] = ["one", "two", "three", "four", "five", "six"]
            } else if mutation == "budget" {
                report["budgetOverflows"] = "invalid"
            } else {
                report["fixedStep"] = 0.1
            }
            try writeJSON(report, to: reportURL)
            let reviewURL = fixture.evidence.appendingPathComponent("visual-review.json")
            var review = try json(at: reviewURL)
            var rows = try XCTUnwrap(review["rows"] as? [[String: Any]])
            var captures = try XCTUnwrap(rows[0]["captures"] as? [[String: Any]])
            captures[0]["reportSHA256"] = sha256(try Data(contentsOf: reportURL))
            rows[0]["captures"] = captures
            review["rows"] = rows
            try writeJSON(review, to: reviewURL)

            let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("does not match its reviewed capture state"), result.output)
        }
    }

    func testCompletionVerifierRejectsNegativeAndFractionalBudgetOverflow() throws {
        for budgetOverflows in [-1.0, 1.5] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let reportURL = fixture.evidence.appendingPathComponent(captureSpecs[0].reportPath)
            var report = try json(at: reportURL)
            report["budgetOverflows"] = budgetOverflows
            try writeJSON(report, to: reportURL)
            let reviewURL = fixture.evidence.appendingPathComponent("visual-review.json")
            var review = try json(at: reviewURL)
            var rows = try XCTUnwrap(review["rows"] as? [[String: Any]])
            var captures = try XCTUnwrap(rows[0]["captures"] as? [[String: Any]])
            captures[0]["reportSHA256"] = sha256(try Data(contentsOf: reportURL))
            rows[0]["captures"] = captures
            review["rows"] = rows
            try writeJSON(review, to: reviewURL)

            let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

            XCTAssertNotEqual(result.status, 0, "budgetOverflows=\(budgetOverflows): \(result.output)")
            XCTAssertTrue(result.output.contains("does not match its reviewed capture state"), result.output)
        }
    }

    func testCompletionVerifierRejectsCapturePathEscape() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let escaped = fixture.root.appendingPathComponent("outside.png")
        try Data("outside".utf8).write(to: escaped)
        let reviewURL = fixture.evidence.appendingPathComponent("visual-review.json")
        var review = try json(at: reviewURL)
        var rows = try XCTUnwrap(review["rows"] as? [[String: Any]])
        var captures = try XCTUnwrap(rows[0]["captures"] as? [[String: Any]])
        captures[0]["path"] = "../outside.png"
        captures[0]["sha256"] = sha256(try Data(contentsOf: escaped))
        rows[0]["captures"] = captures
        review["rows"] = rows
        try writeJSON(review, to: reviewURL)

        let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("invalid capture path"), result.output)
    }

    func testCompletionVerifierRequiresTraceReviewerAndTime() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let traceReview = fixture.evidence.appendingPathComponent("trace-review.json")
        var trace = try json(at: traceReview)
        trace.removeValue(forKey: "reviewer")
        trace.removeValue(forKey: "reviewedAt")
        try writeJSON(trace, to: traceReview)

        let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("trace-review.json is invalid"), result.output)
    }

    func testCompletionVerifierRejectsMalformedTraceReviewTime() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let traceReview = fixture.evidence.appendingPathComponent("trace-review.json")
        var trace = try json(at: traceReview)
        trace["reviewedAt"] = "2026-02-29T00:00:00Z"
        try writeJSON(trace, to: traceReview)

        let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("trace-review.json is invalid"), result.output)
    }

    func testCompletionVerifierRejectsUnreviewedVisualRowsAndMalformedReviewTimes() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reviewURL = fixture.evidence.appendingPathComponent("visual-review.json")
        var review = try json(at: reviewURL)
        var rows = try XCTUnwrap(review["rows"] as? [[String: Any]])
        rows[0]["reviewer"] = " UnReviewed "
        rows[1]["reviewedAt"] = "2026-02-29T00:00:00Z"
        review["rows"] = rows
        try writeJSON(review, to: reviewURL)

        let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("invalid review matrix"), result.output)
    }

    func testCompletionVerifierRejectsTracePathEscape() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let escaped = fixture.root.appendingPathComponent("outside.gputrace")
        try Data("outside trace".utf8).write(to: escaped)
        let traceReview = fixture.evidence.appendingPathComponent("trace-review.json")
        var trace = try json(at: traceReview)
        trace["tracePath"] = "../outside.gputrace"
        trace["traceSHA256"] = sha256(try Data(contentsOf: escaped))
        try writeJSON(trace, to: traceReview)

        let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Trace artifact is missing"), result.output)
    }

    func testCompletionVerifierRequiresPackageProcessCount() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let package = fixture.evidence.appendingPathComponent("package-verification.json")
        try writeJSON(["status": "pass", "windowCount": 1], to: package)

        let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("one process"), result.output)
    }

    func testCompletionVerifierRejectsPassingPackageWithFailure() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let package = fixture.evidence.appendingPathComponent("package-verification.json")
        try writeJSON([
            "status": "pass",
            "failure": "Launch fault",
            "processCount": 1,
            "windowCount": 1,
        ], to: package)

        let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("one process"), result.output)
    }

    func testCompletionVerifierRequiresBenchmarkOS() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let benchmark = fixture.evidence.appendingPathComponent("benchmark-1280x800-run1.json")
        var report = try json(at: benchmark)
        report.removeValue(forKey: "os")
        try writeJSON(report, to: benchmark)

        let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("not a valid M4 Max benchmark report"), result.output)
    }

    func testCompletionVerifierRejectsPassingBenchmarkWithFailure() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let benchmark = fixture.evidence.appendingPathComponent("benchmark-1280x800-run1.json")
        var report = try json(at: benchmark)
        report["failure"] = "GPU fault"
        try writeJSON(report, to: benchmark)

        let result = try runScript("verify-completion.sh", arguments: [fixture.evidence.path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("not a valid M4 Max benchmark report"), result.output)
    }

    func testPackageVerifierRejectsMissingKernelAndWrongArchitecture() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let app = fixture.root.appendingPathComponent("MicroCube Metal.app", isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/MicroCubeMetal")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("incomplete kernel source".utf8).write(to: resources.appendingPathComponent("MicroCube.metal"))

        let result = try runScript("verify-app.sh", arguments: [app.path, fixture.root.appendingPathComponent("package.json").path])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("not an arm64 executable"), result.output)
        XCTAssertTrue(result.output.contains("Production kernel generateTerrain is missing"), result.output)
        XCTAssertEqual(
            try json(at: fixture.root.appendingPathComponent("package.json"))["status"] as? String,
            "fail"
        )
    }

    func testPackageVerifierAcceptsValidBundleAndRecordsOneProcess() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let app = try makeValidFakeApp(in: fixture.root)
        let tools = try makeFakeTools(in: fixture.root)
        let reportURL = fixture.root.appendingPathComponent("package-valid.json")

        let result = try runScript(
            "verify-app.sh",
            arguments: [app.path, reportURL.path],
            environment: ["PATH": toolPath(tools), "TMPDIR": fixture.root.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
        let report = try json(at: reportURL)
        XCTAssertEqual(report["status"] as? String, "pass")
        XCTAssertEqual(report["processCount"] as? Int, 1)
        XCTAssertEqual(report["windowCount"] as? Int, 1)
        let invocation = try String(
            contentsOf: fixture.root.appendingPathComponent("package-invocations.log"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "--qa-scene hero --qa-features all --qa-time 0 --qa-step 0.008333333333333333 --qa-camera reset --qa-window-points 1280x800 --qa-drawable 1280x800 --qa-scale 1 --qa-view final --qa-frames 120 --qa-capture-scope drawable --qa-report "
        XCTAssertTrue(invocation.hasPrefix(prefix), invocation)
        let qaReport = String(invocation.dropFirst(prefix.count))
        XCTAssertTrue(qaReport.hasPrefix("\(fixture.root.path)/microcube-package-qa."), invocation)
        XCTAssertFalse(qaReport.contains(where: \.isWhitespace), invocation)
    }

    func testPackageVerifierRejectsNegativeAndFractionalBudgetOverflow() throws {
        for budgetOverflowsJSON in ["-1", "1.5"] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let app = try makeValidFakeApp(in: fixture.root, budgetOverflowsJSON: budgetOverflowsJSON)
            let tools = try makeFakeTools(in: fixture.root)
            let reportURL = fixture.root.appendingPathComponent("package-invalid-counter.json")

            let result = try runScript(
                "verify-app.sh",
                arguments: [app.path, reportURL.path],
                environment: ["PATH": toolPath(tools)]
            )

            XCTAssertNotEqual(result.status, 0, "budgetOverflows=\(budgetOverflowsJSON): \(result.output)")
            XCTAssertTrue(result.output.contains("does not prove one window and two passes"), result.output)
        }
    }

    func testPackageVerifierRejectsMultipleProcesses() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let app = try makeValidFakeApp(in: fixture.root, extraProcess: true)
        defer { terminateFixtureChild(in: fixture.root) }
        let tools = try makeFakeTools(in: fixture.root, processMode: .multiple)
        let reportURL = fixture.root.appendingPathComponent("package-multiple.json")

        let result = try runScript(
            "verify-app.sh",
            arguments: [app.path, reportURL.path],
            environment: ["PATH": toolPath(tools)]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("one application process"), result.output)
        XCTAssertEqual(try json(at: reportURL)["status"] as? String, "fail")
    }

    func testPackageVerifierRejectsUnrelatedAndZeroProcessSamples() throws {
        for mode in [FakeProcessMode.unrelated, .zero] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let app = try makeValidFakeApp(in: fixture.root, extraProcess: mode == .unrelated)
            defer { terminateFixtureChild(in: fixture.root) }
            let tools = try makeFakeTools(in: fixture.root, processMode: mode)
            let reportURL = fixture.root.appendingPathComponent("package-attribution.json")

            let result = try runScript(
                "verify-app.sh",
                arguments: [app.path, reportURL.path],
                environment: ["PATH": toolPath(tools)]
            )

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("one application process"), result.output)
            XCTAssertEqual(try json(at: reportURL)["status"] as? String, "fail")
        }
    }

    func testPackageVerifierRejectsOccupiedBaselineWithoutKillingIt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let occupied = Process()
        occupied.executableURL = URL(fileURLWithPath: "/bin/sleep")
        occupied.arguments = ["30"]
        try occupied.run()
        defer {
            occupied.terminate()
            occupied.waitUntilExit()
        }
        let app = try makeValidFakeApp(in: fixture.root)
        let tools = try makeFakeTools(in: fixture.root, processMode: .occupied, occupiedPID: occupied.processIdentifier)
        let reportURL = fixture.root.appendingPathComponent("package-occupied.json")

        let result = try runScript(
            "verify-app.sh",
            arguments: [app.path, reportURL.path],
            environment: ["PATH": toolPath(tools)]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("already running"), result.output)
        XCTAssertTrue(occupied.isRunning)
    }

    func testPackageVerifierRejectsLingeringChildWithoutKillingUnownedSample() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let app = try makeValidFakeApp(in: fixture.root, extraProcess: true)
        defer { terminateFixtureChild(in: fixture.root) }
        let tools = try makeFakeTools(in: fixture.root, processMode: .lingering)
        let reportURL = fixture.root.appendingPathComponent("package-lingering.json")

        let result = try runScript(
            "verify-app.sh",
            arguments: [app.path, reportURL.path],
            environment: ["PATH": toolPath(tools)]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("surviving application process"), result.output)
        let childPIDText = try String(contentsOf: fixture.root.appendingPathComponent("package-child.pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(Int32(childPIDText))
        XCTAssertEqual(kill(childPID, 0), 0)
    }

    func testPackageVerifierTimesOutHungLaunch() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let app = try makeValidFakeApp(in: fixture.root, hang: true, ignoreTerm: true)
        let tools = try makeFakeTools(in: fixture.root)
        let reportURL = fixture.root.appendingPathComponent("package-timeout.json")

        let result = try runScript(
            "verify-app.sh",
            arguments: [app.path, reportURL.path],
            environment: [
                "PATH": toolPath(tools),
                "MICROCUBE_VERIFY_MAX_POLLS": "3",
                "MICROCUBE_VERIFY_TERM_GRACE_POLLS": "3",
            ]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("timed out"), result.output)
        XCTAssertEqual(try json(at: reportURL)["status"] as? String, "fail")
    }

    func testPackageVerifierInterruptKillsAndReapsItsLaunch() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let app = try makeValidFakeApp(in: fixture.root, hang: true, ignoreTerm: true)
        let tools = try makeFakeTools(in: fixture.root)
        let reportURL = fixture.root.appendingPathComponent("package-interrupt.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL("verify-app.sh").path, app.path, reportURL.path]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": toolPath(tools),
            "MICROCUBE_VERIFY_TERM_GRACE_POLLS": "3",
        ]) { _, value in value }
        process.standardOutput = Pipe()
        process.standardError = process.standardOutput
        try process.run()
        let pidFile = fixture.root.appendingPathComponent("package-launch.pid")
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: pidFile.path) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let launchPIDText = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let launchPID = try XCTUnwrap(Int32(launchPIDText))
        defer { kill(launchPID, SIGKILL) }

        process.interrupt()
        process.waitUntilExit()

        XCTAssertEqual(kill(launchPID, 0), -1)
    }

    func testCaptureScriptWritesElevenApprovedRowsFromQAReports() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let app = try makeFakeQAApp(in: fixture.root)

        let result = try runScript(
            "capture-qa.sh",
            arguments: [app.path],
            environment: [
                "MICROCUBE_EVIDENCE_DIR": fixture.evidence.path,
                "QA_REVIEWER": "Fixture Reviewer",
                "QA_REVIEW_STATUS": "pass",
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        let review = try json(at: fixture.evidence.appendingPathComponent("visual-review.json"))
        let rows = try XCTUnwrap(review["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 11)
        XCTAssertEqual(review["status"] as? String, "pass")
        let captures = rows.flatMap { $0["captures"] as? [[String: Any]] ?? [] }
        XCTAssertEqual(captures.count, 23)
        for spec in captureSpecs {
            let capture = try XCTUnwrap(captures.first { $0["path"] as? String == spec.path })
            XCTAssertEqual(capture["reportPath"] as? String, spec.reportPath)
            XCTAssertEqual(capture["scene"] as? String, spec.scene)
            XCTAssertEqual(capture["featureMask"] as? String, spec.featureMask)
            XCTAssertEqual((capture["fixedTime"] as? NSNumber)?.doubleValue, spec.fixedTime)
            XCTAssertEqual(capture["view"] as? String, spec.view)
            XCTAssertEqual(capture["captureScope"] as? String, spec.captureScope)
            XCTAssertEqual(capture["windowPoints"] as? [Int], spec.windowPoints)
        }
        let invocations = try String(contentsOf: fixture.root.appendingPathComponent("qa-invocations.log"), encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let expectedInvocations = captureSpecs.map { spec in
            let capture = fixture.evidence.appendingPathComponent(spec.path).path
            let report = fixture.evidence.appendingPathComponent(spec.reportPath).path
            return "--qa-scene \(spec.scene) --qa-features \(spec.featureMask) --qa-time \(spec.time) --qa-step 0.008333333333333333 --qa-camera reset --qa-window-points \(spec.window) --qa-drawable 1280x800 --qa-scale 1 --qa-view \(spec.view) --qa-frames 1 --qa-capture-scope \(spec.captureScope) --qa-capture \(capture) --qa-report \(report)"
        }
        XCTAssertEqual(
            invocations.map { $0.replacingOccurrences(of: "/private/var/", with: "/var/") },
            expectedInvocations.map { $0.replacingOccurrences(of: "/private/var/", with: "/var/") }
        )
    }

    func testCaptureScriptAcceptsCanonicalFeatureOrderFromQAReport() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let app = try makeFakeQAApp(in: fixture.root, canonicalFeatureOrder: true)

        let result = try runScript(
            "capture-qa.sh",
            arguments: [app.path],
            environment: [
                "MICROCUBE_EVIDENCE_DIR": fixture.evidence.path,
                "QA_REVIEWER": "Fixture Reviewer",
                "QA_REVIEW_STATUS": "pass",
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testCaptureScriptRejectsMissingFeatureSetMember() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let app = try makeFakeQAApp(in: fixture.root, reportedFeatureMask: "shadows,lights,sdf")

        let result = try runScript(
            "capture-qa.sh",
            arguments: [app.path],
            environment: ["MICROCUBE_EVIDENCE_DIR": fixture.evidence.path]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
    }

    func testProbeCaptureScriptWritesPassingXCTestSummary() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = try makeFakeProbeRunner(in: fixture.root)

        let result = try runScript(
            "capture-probes.sh",
            arguments: [fixture.evidence.path],
            environment: ["MICROCUBE_TEST_RUNNER": runner.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
        let report = try json(at: fixture.evidence.appendingPathComponent("xctest.json"))
        XCTAssertEqual(report["status"] as? String, "pass")
        XCTAssertNil(report["failure"] as? String)
    }

    func testProbeCaptureScriptRejectsMissingCurrentProbeOutput() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = try makeFakeProbeRunner(in: fixture.root, omitProbe: "ui")

        let result = try runScript(
            "capture-probes.sh",
            arguments: [fixture.evidence.path],
            environment: ["MICROCUBE_TEST_RUNNER": runner.path]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Missing current probe evidence: ui.json"), result.output)
    }

    func testProbeCaptureScriptRejectsFailingProbeEnvelope() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = try makeFakeProbeRunner(in: fixture.root, failingProbe: "ui")

        let result = try runScript(
            "capture-probes.sh",
            arguments: [fixture.evidence.path],
            environment: ["MICROCUBE_TEST_RUNNER": runner.path]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Invalid current probe evidence: ui.json"), result.output)
    }

    func testProbeCaptureScriptRejectsEmptyProbeMetrics() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = try makeFakeProbeRunner(in: fixture.root, emptyMetricsProbe: "shadow")

        let result = try runScript(
            "capture-probes.sh",
            arguments: [fixture.evidence.path],
            environment: ["MICROCUBE_TEST_RUNNER": runner.path]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Invalid current probe evidence: shadow.json"), result.output)
    }

    func testProbeCaptureScriptRejectsConcatenatedProbeObjects() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = try makeFakeProbeRunner(in: fixture.root, concatenatedProbe: "shadow")

        let result = try runScript(
            "capture-probes.sh",
            arguments: [fixture.evidence.path],
            environment: ["MICROCUBE_TEST_RUNNER": runner.path]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Invalid current probe evidence: shadow.json"), result.output)
    }

    func testProbeCaptureScriptWritesFailingXCTestSummaryWhenRunnerFails() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = try makeFakeProbeRunner(in: fixture.root, exitCode: 7)

        let result = try runScript(
            "capture-probes.sh",
            arguments: [fixture.evidence.path],
            environment: ["MICROCUBE_TEST_RUNNER": runner.path]
        )

        XCTAssertEqual(result.status, 7, result.output)
        let report = try json(at: fixture.evidence.appendingPathComponent("xctest.json"))
        XCTAssertEqual(report["status"] as? String, "fail")
        XCTAssertEqual(report["failure"] as? String, "XCTest exited with code 7.")
    }

    func testCaptureScriptRejectsStaleOutputWhenExecutableWritesNothing() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let app = try makeFakeQAApp(in: fixture.root, skipFirstOutput: true)

        let result = try runScript(
            "capture-qa.sh",
            arguments: [app.path],
            environment: [
                "MICROCUBE_EVIDENCE_DIR": fixture.evidence.path,
                "QA_REVIEWER": "Fixture Reviewer",
                "QA_REVIEW_STATUS": "pass",
            ]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
    }

    func testCaptureScriptRequiresNamedReviewerForPassingReview() throws {
        for reviewer in [nil, " UnReviewed "] as [String?] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let app = try makeFakeQAApp(in: fixture.root)
            var environment = [
                "MICROCUBE_EVIDENCE_DIR": fixture.evidence.path,
                "QA_REVIEW_STATUS": "pass",
            ]
            environment["QA_REVIEWER"] = reviewer

            let result = try runScript(
                "capture-qa.sh",
                arguments: [app.path],
                environment: environment
            )

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("QA_REVIEWER"), result.output)
        }
    }

    func testCaptureScriptRejectsWrongKernelSetAndMalformedBudgetOverflow() throws {
        for options in [(validKernels: false, budgetOverflowsJSON: "6701"), (validKernels: true, budgetOverflowsJSON: "\"invalid\"")] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let app = try makeFakeQAApp(
                in: fixture.root,
                validKernels: options.validKernels,
                budgetOverflowsJSON: options.budgetOverflowsJSON
            )

            let result = try runScript(
                "capture-qa.sh",
                arguments: [app.path],
                environment: [
                    "MICROCUBE_EVIDENCE_DIR": fixture.evidence.path,
                    "QA_REVIEWER": "Fixture Reviewer",
                    "QA_REVIEW_STATUS": "pass",
                ]
            )

            XCTAssertNotEqual(result.status, 0, result.output)
        }
    }

    func testCaptureScriptRejectsNegativeAndFractionalBudgetOverflow() throws {
        for budgetOverflowsJSON in ["-1", "1.5"] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let app = try makeFakeQAApp(in: fixture.root, budgetOverflowsJSON: budgetOverflowsJSON)

            let result = try runScript(
                "capture-qa.sh",
                arguments: [app.path],
                environment: [
                    "MICROCUBE_EVIDENCE_DIR": fixture.evidence.path,
                    "QA_REVIEWER": "Fixture Reviewer",
                    "QA_REVIEW_STATUS": "pass",
                ]
            )

            XCTAssertNotEqual(result.status, 0, "budgetOverflows=\(budgetOverflowsJSON): \(result.output)")
        }
    }

    func testBenchmarkScriptRunsSixValidReports() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let script = try copyScript("benchmark.sh", into: fixture.root)
        let app = try makeFakeBenchmarkApp(in: fixture.root, os: "macOS Fixture")
        let tools = try makeFakeTools(in: fixture.root)

        let result = try runScript(
            at: script,
            arguments: [app.path],
            environment: ["PATH": toolPath(tools)]
        )

        XCTAssertEqual(result.status, 0, result.output)
        let evidence = fixture.root.appendingPathComponent("dist/evidence")
        let reports = try FileManager.default.contentsOfDirectory(atPath: evidence.path)
            .filter { $0.hasPrefix("benchmark-") && $0.hasSuffix(".json") }
        XCTAssertEqual(reports.count, 6)
        let invocations = try String(contentsOf: fixture.root.appendingPathComponent("benchmark-invocations.log"), encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let expected = ["1280x800", "2560x1600"].flatMap { size in
            (1...3).map { run in
                let report = fixture.root.resolvingSymlinksInPath().appendingPathComponent("dist/evidence/benchmark-\(size)-run\(run).json").path
                return "--qa-scene hero --qa-features all --qa-time 0 --qa-step 0.008333333333333333 --qa-camera reset --qa-window-points \(size) --qa-drawable \(size) --qa-scale 1 --qa-view final --benchmark --benchmark-warmup 180 --benchmark-samples 900 --qa-report \(report)"
            }
        }
        XCTAssertEqual(
            invocations.map { $0.replacingOccurrences(of: "/private/var/", with: "/var/") },
            expected.map { $0.replacingOccurrences(of: "/private/var/", with: "/var/") }
        )
    }

    func testBenchmarkScriptRejectsMissingOS() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let script = try copyScript("benchmark.sh", into: fixture.root)
        let app = try makeFakeBenchmarkApp(in: fixture.root, os: "")
        let tools = try makeFakeTools(in: fixture.root)

        let result = try runScript(
            at: script,
            arguments: [app.path],
            environment: ["PATH": toolPath(tools)]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
    }

    func testBenchmarkScriptRejectsNonArm64Executable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let script = try copyScript("benchmark.sh", into: fixture.root)
        let app = try makeFakeBenchmarkApp(in: fixture.root, os: "macOS Fixture")
        let tools = try makeFakeTools(in: fixture.root, architecture: "x86_64")

        let result = try runScript(
            at: script,
            arguments: [app.path],
            environment: ["PATH": toolPath(tools)]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("arm64"), result.output)
    }

    func testBenchmarkScriptRejectsInvalidRuntimeEvidence() throws {
        let cases: [(device: String, thermal: String, samples: Int?, p95: Double, validKernels: Bool, budgetOverflowsJSON: String, failure: String?)] = [
            ("Fixture GPU", "nominal", nil, 1, true, "6701", nil),
            ("Apple M4 Max", "serious", nil, 1, true, "6701", nil),
            ("Apple M4 Max", "nominal", 899, 1, true, "6701", nil),
            ("Apple M4 Max", "nominal", nil, 20, true, "6701", nil),
            ("Apple M4 Max", "nominal", nil, 1, false, "6701", nil),
            ("Apple M4 Max", "nominal", nil, 1, true, "\"invalid\"", nil),
            ("Apple M4 Max", "nominal", nil, 1, true, "6701", "GPU fault"),
        ]
        for testCase in cases {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let script = try copyScript("benchmark.sh", into: fixture.root)
            let app = try makeFakeBenchmarkApp(
                in: fixture.root,
                os: "macOS Fixture",
                device: testCase.device,
                thermal: testCase.thermal,
                measuredSampleCount: testCase.samples,
                p95: testCase.p95,
                validKernels: testCase.validKernels,
                budgetOverflowsJSON: testCase.budgetOverflowsJSON,
                failure: testCase.failure
            )
            let tools = try makeFakeTools(in: fixture.root)

            let result = try runScript(
                at: script,
                arguments: [app.path],
                environment: ["PATH": toolPath(tools)]
            )

            XCTAssertNotEqual(result.status, 0, "\(testCase): \(result.output)")
        }
    }

    func testBenchmarkScriptRejectsNegativeAndFractionalBudgetOverflow() throws {
        for budgetOverflowsJSON in ["-1", "1.5"] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let script = try copyScript("benchmark.sh", into: fixture.root)
            let app = try makeFakeBenchmarkApp(
                in: fixture.root,
                os: "macOS Fixture",
                budgetOverflowsJSON: budgetOverflowsJSON
            )
            let tools = try makeFakeTools(in: fixture.root)

            let result = try runScript(
                at: script,
                arguments: [app.path],
                environment: ["PATH": toolPath(tools)]
            )

            XCTAssertNotEqual(result.status, 0, "budgetOverflows=\(budgetOverflowsJSON): \(result.output)")
        }
    }

    func testBenchmarkScriptRejectsStaleOutputWhenExecutableWritesNothing() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let script = try copyScript("benchmark.sh", into: fixture.root)
        let app = try makeFakeBenchmarkApp(in: fixture.root, os: "macOS Fixture", skipFirstOutput: true)
        let tools = try makeFakeTools(in: fixture.root)
        let evidence = fixture.root.appendingPathComponent("dist/evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try writeJSON(benchmarkReport(size: "1280x800"), to: evidence.appendingPathComponent("benchmark-1280x800-run1.json"))

        let result = try runScript(
            at: script,
            arguments: [app.path],
            environment: ["PATH": toolPath(tools)]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
    }

    private func makeFixture() throws -> (root: URL, evidence: URL, capture: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let evidence = root.appendingPathComponent("evidence", isDirectory: true)
        let captures = evidence.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)

        for probe in ["shadow", "mixed", "budgets", "sdf", "optics", "volume", "motion", "ui"] {
            try writeJSON(validProbeEnvelope(probe), to: evidence.appendingPathComponent("\(probe).json"))
        }
        var entriesByRow = Dictionary(uniqueKeysWithValues: captureRows.map { ($0, [[String: Any]]()) })
        for spec in captureSpecs {
            let capture = evidence.appendingPathComponent(spec.path)
            let report = evidence.appendingPathComponent(spec.reportPath)
            try Data("fixture-png-\(spec.stem)".utf8).write(to: capture)
            try writeJSON(qaReport(for: spec, capturePath: capture.path), to: report)
            entriesByRow[spec.row, default: []].append([
                "path": spec.path,
                "sha256": sha256(try Data(contentsOf: capture)),
                "reportPath": spec.reportPath,
                "reportSHA256": sha256(try Data(contentsOf: report)),
                "scene": spec.scene,
                "featureMask": spec.featureMask,
                "fixedTime": spec.fixedTime,
                "view": spec.view,
                "captureScope": spec.captureScope,
                "windowPoints": spec.windowPoints,
                "drawablePixels": [1280, 800],
            ])
        }
        let visualRows: [[String: Any]] = captureRows.map { name in
            [
                "name": name,
                "captures": entriesByRow[name]!,
                "reviewer": "Fixture Reviewer",
                "reviewedAt": "2026-08-30T00:00:00Z",
                "status": "pass",
                "notes": "fixture",
            ]
        }
        try writeJSON(["status": "pass", "rows": visualRows], to: evidence.appendingPathComponent("visual-review.json"))
        for size in ["1280x800", "2560x1600"] {
            for run in 1...3 {
                try writeJSON(benchmarkReport(size: size), to: evidence.appendingPathComponent("benchmark-\(size)-run\(run).json"))
            }
        }
        let trace = evidence.appendingPathComponent("trace.gputrace")
        try Data("trace".utf8).write(to: trace)
        try writeJSON([
            "status": "pass",
            "tracePath": "trace.gputrace",
            "traceSHA256": sha256(try Data(contentsOf: trace)),
            "reviewer": "Trace Reviewer",
            "reviewedAt": "2026-08-30T00:00:00Z",
            "steadyStatePassCount": 2,
            "perFrameCPUTextureUploads": 0,
            "steadyStateWaitUntilCompleted": 0,
        ], to: evidence.appendingPathComponent("trace-review.json"))
        try writeJSON(["status": "pass"], to: evidence.appendingPathComponent("xctest.json"))
        try writeJSON(["status": "pass", "processCount": 1, "windowCount": 1], to: evidence.appendingPathComponent("package-verification.json"))
        return (root, evidence, evidence.appendingPathComponent(captureSpecs[0].path))
    }

    private func makeFakeProbeRunner(
        in root: URL,
        omitProbe: String? = nil,
        failingProbe: String? = nil,
        emptyMetricsProbe: String? = nil,
        concatenatedProbe: String? = nil,
        exitCode: Int = 0
    ) throws -> URL {
        let fixtures = root.appendingPathComponent("probe-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        for probe in ["shadow", "mixed", "budgets", "sdf", "optics", "volume", "motion", "ui"] {
            var envelope = validProbeEnvelope(probe)
            if probe == failingProbe {
                envelope["status"] = "fail"
                envelope["failure"] = "fixture failure"
            }
            if probe == emptyMetricsProbe {
                envelope["metrics"] = [String: Any]()
            }
            let fixtureURL = fixtures.appendingPathComponent("\(probe).json")
            try writeJSON(envelope, to: fixtureURL)
            if probe == concatenatedProbe {
                var data = Data("{\"status\":\"pass\"}\n".utf8)
                data.append(try Data(contentsOf: fixtureURL))
                try data.write(to: fixtureURL)
            }
        }
        let runner = root.appendingPathComponent("fake-probe-tests-\(UUID().uuidString)")
        let script = #"""
        #!/bin/zsh
        if [ "\#(exitCode)" -ne 0 ]; then exit "\#(exitCode)"; fi
        mkdir -p "$MICROCUBE_EVIDENCE_DIR"
        for probe in shadow mixed budgets sdf optics volume motion ui; do
            if [ "$probe" != "\#(omitProbe ?? "")" ]; then
                cp "\#(fixtures.path)/$probe.json" "$MICROCUBE_EVIDENCE_DIR/$probe.json"
            fi
        done
        """#
        try writeExecutable(script, to: runner)
        return runner
    }

    private var productionKernels: [String] {
        ["generateTerrain", "reduceOccupancy", "buildMixedOccupancy", "reduceMixedOccupancy", "clearVolumeLighting", "injectVolumeLighting", "raycastHybrid"]
    }

    private func validProbeEnvelope(_ probe: String) -> [String: Any] {
        let steps = ["voxelSteps": 1, "sdfSteps": 1, "gaussianSamples": 1]
        let metrics: [String: Any]
        switch probe {
        case "shadow":
            metrics = ["sampleCount": 10_380, "legacyMismatch": 404, "falseShadows": 0, "missedShadows": 0, "maxHitDistanceError": 0.001]
        case "mixed":
            metrics = [
                "mixedLeafVoxel": true, "mixedLeafSDFRefs": 2, "wrongNearestHits": 0, "maxHitDistanceError": 0.001,
                "voxelOnly": ["voxelSteps": 1, "sdfSteps": 0, "gaussianSamples": 0],
                "sdfOnly": ["voxelSteps": 0, "sdfSteps": 1, "gaussianSamples": 0],
                "gaussianOnly": ["voxelSteps": 0, "sdfSteps": 0, "gaussianSamples": 1],
                "mixed": steps,
                "empty": ["voxelSteps": 0, "sdfSteps": 0, "gaussianSamples": 0],
            ]
        case "budgets":
            metrics = ["overflowCount": 0, "smoothSteps": 24, "creatureSteps": 32, "fractalSteps": 48, "fractalIterations": 8, "hierarchicalSteps": 4_096, "surfaceLights": 4, "localShadowRays": 1, "sunShadowRays": 1, "secondarySceneRays": 1]
        case "sdf":
            metrics = ["maxDistanceError": 0.0001, "maxNormalAngleDegrees": 0.5, "maxNormalLengthError": 0.001, "nonFiniteCount": 0, "negativeExteriorStepCount": 0, "fractalCoverage": 0.05]
        case "optics":
            metrics = ["maxReflectionDirectionError": 0.0001, "maxRefractionDirectionError": 0.0001, "tirFailureCount": 0, "recursiveSecondaryRayCount": 0]
        case "volume":
            metrics = ["maxHomogeneousRelativeError": 0.02, "maxGaussianRelativeError": 0.02, "maxSurfaceTransmittanceRelativeError": 0.02, "sunShadowRadianceRatio": 0.34, "localShadowRadianceRatio": 0.34, "smokeSunReceiverRatio": 0.99, "smokeLocalReceiverRatio": 0.99, "nonFiniteCount": 0]
        case "motion":
            metrics = ["creatureCount": 6, "lightCount": 6, "repeatMismatchCount": 0, "poseDeltaAtOneSecond": 0.1, "lightDeltaAtOneSecond": 0.1]
        case "ui":
            metrics = ["stateMismatchCount": 0, "focusFailureCount": 0, "modifierLeakCount": 0, "accessibilityFailureCount": 0, "responsiveLayoutFailureCount": 0, "adaptiveScaleFailureCount": 0, "fixedScaleFailureCount": 0, "reduceMotionFailureCount": 0, "windowCount": 1]
        default:
            metrics = [:]
        }
        return [
            "schemaVersion": 1,
            "probe": probe,
            "fixtureVersion": 1,
            "status": "pass",
            "failure": NSNull(),
            "device": "Apple M4 Max",
            "metrics": metrics,
        ]
    }

    private func qaReport(for spec: CaptureSpec, capturePath: String) -> [String: Any] {
        [
            "schemaVersion": 1,
            "status": "pass",
            "failure": NSNull(),
            "device": "Fixture GPU",
            "os": "macOS Fixture",
            "scene": spec.scene,
            "fixedTime": spec.fixedTime,
            "drawablePixels": [1280, 800],
            "renderScale": 1.0,
            "windowCount": 1,
            "productionKernels": productionKernels,
            "featureMask": spec.featureMask,
            "passCount": 2,
            "stepCounters": [String: Int](),
            "shadowSampleCounts": [String: Int](),
            "budgetOverflows": 0,
            "commandErrors": 0,
            "droppedDrawables": 0,
            "semaphoreTimeouts": 0,
            "capturePath": capturePath,
            "fixedStep": 1.0 / 120.0,
            "warmupFrames": 0,
            "measuredFrames": 0,
            "percentileMethod": "nearest-rank",
            "gpuMilliseconds": [Double](),
            "p95GPUms": 0.0,
            "thermalStateBefore": NSNull(),
            "thermalStateAfter": NSNull(),
        ]
    }

    private func benchmarkReport(size: String, os: String = "macOS Fixture") -> [String: Any] {
        let pixels = size.split(separator: "x").compactMap { Int($0) }
        return [
            "schemaVersion": 1,
            "status": "pass",
            "failure": NSNull(),
            "device": "Apple M4 Max",
            "os": os,
            "scene": "hero",
            "fixedTime": 0.0,
            "thermalStateBefore": "nominal",
            "thermalStateAfter": "nominal",
            "drawablePixels": pixels,
            "renderScale": 1.0,
            "windowCount": 1,
            "productionKernels": productionKernels,
            "fixedStep": 1.0 / 120.0,
            "warmupFrames": 180,
            "measuredFrames": 900,
            "percentileMethod": "nearest-rank",
            "gpuMilliseconds": Array(repeating: 1.0, count: 900),
            "p95GPUms": 1.0,
            "commandErrors": 0,
            "droppedDrawables": 0,
            "semaphoreTimeouts": 0,
            "passCount": 2,
            "featureMask": "all",
            "stepCounters": [String: Int](),
            "shadowSampleCounts": [String: Int](),
            "budgetOverflows": 0,
            "capturePath": NSNull(),
        ]
    }

    private func makeFakeQAApp(
        in root: URL,
        skipFirstOutput: Bool = false,
        validKernels: Bool = true,
        budgetOverflowsJSON: String = "6701",
        canonicalFeatureOrder: Bool = false,
        reportedFeatureMask: String? = nil
    ) throws -> URL {
        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/MicroCubeMetal")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invocationLog = root.appendingPathComponent("qa-invocations.log")
        let counter = root.appendingPathComponent("qa-invocation-count")
        let kernels = validKernels ? productionKernels : ["one", "two", "three", "four", "five", "six", "seven"]
        let kernelsJSON = String(decoding: try JSONSerialization.data(withJSONObject: kernels), as: UTF8.self)
        let script = #"""
        #!/bin/sh
        printf '%s\n' "$*" >> "\#(invocationLog.path)"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --qa-scene) scene="$2"; shift 2 ;;
                --qa-features) features="$2"; shift 2 ;;
                --qa-time) fixed_time="$2"; shift 2 ;;
                --qa-step) fixed_step="$2"; shift 2 ;;
                --qa-window-points) window="$2"; shift 2 ;;
                --qa-drawable) drawable="$2"; shift 2 ;;
                --qa-view) view="$2"; shift 2 ;;
                --qa-capture-scope) scope="$2"; shift 2 ;;
                --qa-capture) capture="$2"; shift 2 ;;
                --qa-report) report="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        count=0
        [ -f "\#(counter.path)" ] && count=$(cat "\#(counter.path)")
        count=$((count + 1))
        printf '%s' "$count" > "\#(counter.path)"
        if [ "\#(skipFirstOutput ? "1" : "0")" = 1 ] && [ "$count" = 1 ]; then
            exit 0
        fi
        if [ "$features" = "sdf,lights,gaussian,shadows" ] && [ -n "\#(reportedFeatureMask ?? "")" ]; then
            report_features="\#(reportedFeatureMask ?? "")"
        elif [ "\#(canonicalFeatureOrder ? "1" : "0")" = 1 ] && [ "$features" = "sdf,lights,gaussian,shadows" ]; then
            report_features="shadows,lights,sdf,gaussian"
        else
            report_features="$features"
        fi
        mkdir -p "$(dirname "$capture")" "$(dirname "$report")"
        printf fixture > "$capture"
        width=${drawable%x*}
        height=${drawable#*x}
        jq -n --arg scene "$scene" --arg featureMask "$report_features" --argjson fixedTime "$fixed_time" --argjson fixedStep "$fixed_step" --argjson drawablePixels "[$width, $height]" --arg capturePath "$capture" --argjson productionKernels '\#(kernelsJSON)' --argjson budgetOverflows '\#(budgetOverflowsJSON)' '{
            schemaVersion: 1, status: "pass", failure: null, device: "Fixture GPU", os: "macOS Fixture",
            scene: $scene, fixedTime: $fixedTime, drawablePixels: $drawablePixels, renderScale: 1,
            windowCount: 1, productionKernels: $productionKernels,
            featureMask: $featureMask, passCount: 2, stepCounters: {}, shadowSampleCounts: {}, budgetOverflows: $budgetOverflows,
            commandErrors: 0, droppedDrawables: 0, semaphoreTimeouts: 0, capturePath: $capturePath,
            fixedStep: $fixedStep, warmupFrames: 0, measuredFrames: 0, percentileMethod: "nearest-rank",
            gpuMilliseconds: [], p95GPUms: 0, thermalStateBefore: null, thermalStateAfter: null
        }' > "$report"
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return app
    }

    private func makeFakeBenchmarkApp(
        in root: URL,
        os: String,
        device: String = "Apple M4 Max",
        thermal: String = "nominal",
        measuredSampleCount: Int? = nil,
        p95: Double = 1,
        validKernels: Bool = true,
        budgetOverflowsJSON: String = "6701",
        failure: String? = nil,
        skipFirstOutput: Bool = false
    ) throws -> URL {
        let app = root.appendingPathComponent("Benchmark.app", isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/MicroCubeMetal")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invocationLog = root.appendingPathComponent("benchmark-invocations.log")
        let counter = root.appendingPathComponent("benchmark-invocation-count")
        let measuredFrames = measuredSampleCount.map(String.init) ?? "$samples"
        let kernels = validKernels ? productionKernels : ["one", "two", "three", "four", "five", "six", "seven"]
        let kernelsJSON = String(decoding: try JSONSerialization.data(withJSONObject: kernels), as: UTF8.self)
        let script = #"""
        #!/bin/sh
        printf '%s\n' "$*" >> "\#(invocationLog.path)"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --qa-scene) scene="$2"; shift 2 ;;
                --qa-features) features="$2"; shift 2 ;;
                --qa-time) fixed_time="$2"; shift 2 ;;
                --qa-step) fixed_step="$2"; shift 2 ;;
                --qa-camera) camera="$2"; shift 2 ;;
                --qa-window-points) window="$2"; shift 2 ;;
                --qa-drawable) drawable="$2"; shift 2 ;;
                --qa-scale) scale="$2"; shift 2 ;;
                --qa-view) view="$2"; shift 2 ;;
                --benchmark) benchmark=1; shift ;;
                --benchmark-warmup) warmup="$2"; shift 2 ;;
                --benchmark-samples) samples="$2"; shift 2 ;;
                --qa-report) report="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        count=0
        [ -f "\#(counter.path)" ] && count=$(cat "\#(counter.path)")
        count=$((count + 1))
        printf '%s' "$count" > "\#(counter.path)"
        if [ "\#(skipFirstOutput ? "1" : "0")" = 1 ] && [ "$count" = 1 ]; then
            exit 0
        fi
        [ "$camera" = reset ] && [ "$window" = "$drawable" ] && [ "$view" = final ] && [ "$benchmark" = 1 ] || exit 3
        mkdir -p "$(dirname "$report")"
        width=${drawable%x*}
        height=${drawable#*x}
        measured_frames=\#(measuredFrames)
        jq -n --arg device "\#(device)" --arg os "\#(os)" --arg scene "$scene" --arg featureMask "$features" \
            --arg thermal "\#(thermal)" --argjson fixedTime "$fixed_time" --argjson fixedStep "$fixed_step" \
            --argjson drawablePixels "[$width, $height]" --argjson renderScale "$scale" --argjson warmupFrames "$warmup" \
            --arg failure "\#(failure ?? "")" --argjson measuredFrames "$measured_frames" --argjson p95GPUms "\#(p95)" \
            --argjson productionKernels '\#(kernelsJSON)' --argjson budgetOverflows '\#(budgetOverflowsJSON)' '{
            schemaVersion: 1, status: "pass", failure: (if $failure == "" then null else $failure end), device: $device, os: $os,
            scene: $scene, fixedTime: $fixedTime, drawablePixels: $drawablePixels, renderScale: $renderScale, windowCount: 1,
            productionKernels: $productionKernels,
            featureMask: $featureMask, passCount: 2, stepCounters: {}, shadowSampleCounts: {}, budgetOverflows: $budgetOverflows,
            commandErrors: 0, droppedDrawables: 0, semaphoreTimeouts: 0, capturePath: null,
            fixedStep: $fixedStep, warmupFrames: $warmupFrames, measuredFrames: $measuredFrames, percentileMethod: "nearest-rank",
            gpuMilliseconds: [range(0; $measuredFrames) | $p95GPUms], p95GPUms: $p95GPUms,
            thermalStateBefore: $thermal, thermalStateAfter: $thermal
        }' > "$report"
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return app
    }

    private func makeValidFakeApp(
        in root: URL,
        extraProcess: Bool = false,
        hang: Bool = false,
        ignoreTerm: Bool = false,
        budgetOverflowsJSON: String = "6701"
    ) throws -> URL {
        let app = root.appendingPathComponent("Valid.app", isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/MicroCubeMetal")
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.vseplet.microcube.metal",
            "LSMinimumSystemVersion": "14.0",
            "CFBundleExecutable": "MicroCubeMetal",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("fixture".utf8).write(to: resources.appendingPathComponent("SceneTypes.metal"))
        try Data("fixture".utf8).write(to: resources.appendingPathComponent("HybridTraversal.metal"))
        let kernels = productionKernels.map { "kernel void \($0)() {}" }.joined(separator: "\n")
        try Data(kernels.utf8).write(to: resources.appendingPathComponent("MicroCube.metal"))
        try FileManager.default.copyItem(
            at: projectURL.appendingPathComponent("Sources/MicroCubeMetal/Resources/WhyRays.en.txt"),
            to: resources.appendingPathComponent("WhyRays.en.txt")
        )
        let pidFile = root.appendingPathComponent("package-launch.pid")
        let childPIDFile = root.appendingPathComponent("package-child.pid")
        let invocationLog = root.appendingPathComponent("package-invocations.log")
        let script = #"""
        #!/bin/sh
        [ "\#(ignoreTerm ? "1" : "0")" = 1 ] && trap '' TERM
        printf '%s' "$$" > "\#(pidFile.path)"
        if [ "\#(extraProcess ? "1" : "0")" = 1 ]; then
            sleep 30 &
            printf '%s' "$!" > "\#(childPIDFile.path)"
        fi
        printf '%s\n' "$*" >> "\#(invocationLog.path)"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --qa-scene) scene="$2"; shift 2 ;;
                --qa-features) features="$2"; shift 2 ;;
                --qa-time) fixed_time="$2"; shift 2 ;;
                --qa-step) fixed_step="$2"; shift 2 ;;
                --qa-camera) camera="$2"; shift 2 ;;
                --qa-window-points) window="$2"; shift 2 ;;
                --qa-drawable) drawable="$2"; shift 2 ;;
                --qa-scale) scale="$2"; shift 2 ;;
                --qa-view) view="$2"; shift 2 ;;
                --qa-frames) frames="$2"; shift 2 ;;
                --qa-capture-scope) scope="$2"; shift 2 ;;
                --qa-report) report="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        mkdir -p "$(dirname "$report")"
        width=${drawable%x*}
        height=${drawable#*x}
        jq -n --arg scene "$scene" --arg featureMask "$features" --argjson fixedTime "$fixed_time" \
            --argjson fixedStep "$fixed_step" --argjson drawablePixels "[$width, $height]" --argjson renderScale "$scale" '{
            schemaVersion: 1, status: "pass", failure: null, device: "Fixture GPU", os: "macOS Fixture",
            scene: $scene, fixedTime: $fixedTime, drawablePixels: $drawablePixels, renderScale: $renderScale,
            windowCount: 1, productionKernels: ["generateTerrain", "reduceOccupancy", "buildMixedOccupancy", "reduceMixedOccupancy", "clearVolumeLighting", "injectVolumeLighting", "raycastHybrid"],
            featureMask: $featureMask, passCount: 2, stepCounters: {}, shadowSampleCounts: {}, budgetOverflows: \#(budgetOverflowsJSON),
            commandErrors: 0, droppedDrawables: 0, semaphoreTimeouts: 0, capturePath: null,
            fixedStep: $fixedStep, warmupFrames: 0, measuredFrames: 0, percentileMethod: "nearest-rank",
            gpuMilliseconds: [], p95GPUms: 0, thermalStateBefore: null, thermalStateAfter: null
        }' > "$report"
        if [ "\#(hang ? "1" : "0")" = 1 ]; then
            while :; do sleep 1; done
        fi
        sleep 0.2
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return app
    }

    private func makeFakeTools(
        in root: URL,
        processMode: FakeProcessMode = .launched,
        architecture: String = "arm64",
        occupiedPID: Int32? = nil
    ) throws -> URL {
        let tools = root.appendingPathComponent("fake-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try writeExecutable("#!/bin/sh\nprintf '%s\\n' '\(architecture)'\n", to: tools.appendingPathComponent("lipo"))
        try writeExecutable("#!/bin/sh\nexit 0\n", to: tools.appendingPathComponent("codesign"))
        try writeExecutable("#!/bin/sh\nprintf '%s\\n' 'Apple M4 Max'\n", to: tools.appendingPathComponent("sysctl"))
        let pidFile = root.appendingPathComponent("package-launch.pid").path
        let childPIDFile = root.appendingPathComponent("package-child.pid").path
        let pgrepScript: String
        switch processMode {
        case .launched:
            pgrepScript = "#!/bin/sh\n[ -f '\(pidFile)' ] || exit 1\npid=$(cat '\(pidFile)')\nkill -0 \"$pid\" 2>/dev/null || exit 1\nprintf '%s\\n' \"$pid\"\n"
        case .multiple:
            pgrepScript = "#!/bin/sh\n[ -f '\(pidFile)' ] && [ -f '\(childPIDFile)' ] || exit 1\npid=$(cat '\(pidFile)')\nchild=$(cat '\(childPIDFile)')\nkill -0 \"$pid\" 2>/dev/null || exit 1\nprintf '%s\\n%s\\n' \"$pid\" \"$child\"\n"
        case .unrelated:
            pgrepScript = "#!/bin/sh\n[ -f '\(childPIDFile)' ] || exit 1\nchild=$(cat '\(childPIDFile)')\nkill -0 \"$child\" 2>/dev/null || exit 1\nprintf '%s\\n' \"$child\"\n"
        case .zero:
            pgrepScript = "#!/bin/sh\nexit 1\n"
        case .occupied:
            pgrepScript = "#!/bin/sh\nkill -0 '\(occupiedPID ?? 0)' 2>/dev/null || exit 1\nprintf '%s\\n' '\(occupiedPID ?? 0)'\n"
        case .lingering:
            pgrepScript = "#!/bin/sh\n[ -f '\(pidFile)' ] || exit 1\npid=$(cat '\(pidFile)')\nif kill -0 \"$pid\" 2>/dev/null; then printf '%s\\n' \"$pid\"; exit 0; fi\n[ -f '\(childPIDFile)' ] || exit 1\nchild=$(cat '\(childPIDFile)')\nkill -0 \"$child\" 2>/dev/null || exit 1\nprintf '%s\\n' \"$child\"\n"
        }
        try writeExecutable(pgrepScript, to: tools.appendingPathComponent("pgrep"))
        return tools
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func terminateFixtureChild(in root: URL) {
        let pidFile = root.appendingPathComponent("package-child.pid")
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        kill(pid, SIGTERM)
    }

    private func toolPath(_ tools: URL) -> String {
        "\(tools.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
    }

    private func copyScript(_ name: String, into root: URL) throws -> URL {
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let destination = scripts.appendingPathComponent(name)
        try FileManager.default.copyItem(at: scriptURL(name), to: destination)
        return destination
    }

    private func runScript(
        _ name: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        try runScript(at: scriptURL(name), arguments: arguments, environment: environment)
    }

    private func runScript(
        at script: URL,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private var projectURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func scriptURL(_ name: String) -> URL {
        projectURL.appendingPathComponent("scripts/\(name)")
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url)
    }

    private func json(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
