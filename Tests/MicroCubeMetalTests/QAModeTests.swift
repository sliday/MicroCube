import AppKit
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
