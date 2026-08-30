import Metal
import simd
import XCTest
@testable import MicroCubeMetal

final class SDFProbeTests: XCTestCase {
    func testSDFProbeEnvelopeUsesRequiredMetricKeysFromGPUResult() throws {
        let values = try runProbe()
        let fractalCoverage = try runFractalCoverageProbe()
        let normal = SIMD3<Float>(values[3], values[4], values[5])
        let metrics = SDFProbeMetrics(
            maxDistanceError: Double(max(abs(values[0] - 1), abs(values[1] - 0.5), abs(values[2] - 0.14375))),
            maxNormalAngleDegrees: Double(acos(min(1, max(-1, normal.x))) * 180 / .pi),
            maxNormalLengthError: Double(abs(simd_length(normal) - 1)),
            nonFiniteCount: Int(values[8]),
            negativeExteriorStepCount: Int(values[7]),
            fractalCoverage: fractalCoverage
        )
        let data = try ProbeEnvelope.evaluated(probe: "sdf", device: "test-device", metrics: metrics).encodedJSON()
        let decoded = try ProbeEnvelope<SDFProbeMetrics>.decodeValidated(data)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedMetrics = try XCTUnwrap(object["metrics"] as? [String: Any])

        XCTAssertEqual(object["status"] as? String, "pass")
        XCTAssertEqual(
            Set(encodedMetrics.keys),
            ["maxDistanceError", "maxNormalAngleDegrees", "maxNormalLengthError", "nonFiniteCount",
             "negativeExteriorStepCount", "fractalCoverage"]
        )
        XCTAssertLessThanOrEqual(decoded.metrics.maxDistanceError, 0.0001)
        XCTAssertEqual(decoded.metrics.nonFiniteCount, 0)
        XCTAssertGreaterThan(decoded.metrics.fractalCoverage, 0)
        XCTAssertLessThan(decoded.metrics.fractalCoverage, 0.10)
    }

    func testAnalyticDistancesAndNormalsMatchIndependentReferences() throws {
        let values = try runProbe()

        XCTAssertEqual(values[0], 1.0, accuracy: 0.0001)
        XCTAssertEqual(values[1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(values[2], 0.14375, accuracy: 0.0001)
        XCTAssertEqual(values[3], 1.0, accuracy: 0.0001)
        XCTAssertEqual(values[4], 0.0, accuracy: 0.0001)
        XCTAssertEqual(values[5], 0.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(abs(simd_length(SIMD3<Float>(values[3], values[4], values[5])) - 1), 0.001)
    }

    func testFractalEstimatorAndNormalStayFiniteWithPositiveExteriorSteps() throws {
        let values = try runProbe()

        XCTAssertTrue(values[6].isFinite)
        XCTAssertGreaterThan(values[6], 0)
        XCTAssertEqual(values[7], 0)
        XCTAssertEqual(values[8], 0)
    }

    private func runProbe() throws -> [Float] {
        let source = """
        kernel void probeSDF(device float *output [[buffer(0)]], uint gid [[thread_position_in_grid]]) {
            if (gid != 0u) return;
            SDFInstance sphere;
            sphere.sweptBoundsMin = float4(-2.0f);
            sphere.sweptBoundsMax = float4(2.0f);
            sphere.positionScale = float4(0.0f, 0.0f, 0.0f, 1.0f);
            sphere.rotationQuaternion = float4(0.0f, 0.0f, 0.0f, 1.0f);
            sphere.parameters = float4(0.0f);
            sphere.metadata = uint4(0u);
            output[0] = sdSphere(float3(2.0f, 0.0f, 0.0f), 1.0f);
            output[1] = sdCapsule(float3(2.0f, 0.0f, 0.0f), float3(-1.0f, 0.0f, 0.0f), float3(1.0f, 0.0f, 0.0f), 0.5f);
            output[2] = smoothUnion(0.2f, 0.3f, 0.4f);
            float3 normal = sdfNormal(float3(1.0f, 0.0f, 0.0f), sphere, 8u);
            output[3] = normal.x;
            output[4] = normal.y;
            output[5] = normal.z;
            float exterior = fractalDistance(float3(4.0f, 3.0f, 2.0f), 8u);
            output[6] = exterior;
            output[7] = exterior < 0.0f ? 1.0f : 0.0f;
            output[8] = (!isfinite(exterior) || any(!isfinite(normal))) ? 1.0f : 0.0f;
        }
        """
        let (device, library) = try MetalProbeHarness.makeLibrary(extraSource: source)
        let pipeline = try MetalProbeHarness.makePipeline(name: "probeSDF", library: library, device: device)
        let buffer = try XCTUnwrap(device.makeBuffer(length: 9 * MemoryLayout<Float>.stride, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, commandBuffer.error?.localizedDescription ?? "")
        let pointer = buffer.contents().bindMemory(to: Float.self, capacity: 9)
        return Array(UnsafeBufferPointer(start: pointer, count: 9))
    }

    private func runFractalCoverageProbe() throws -> Double {
        let source = """
        kernel void probeFractalCoverage(
            device atomic_uint *output [[buffer(0)]],
            device const SDFInstance *sdfs [[buffer(1)]],
            constant SceneUniforms &scene [[buffer(2)]],
            constant FrameUniforms &frame [[buffer(3)]],
            uint2 gid [[thread_position_in_grid]]) {
            if (any(gid >= frame.viewportAndOptions.xy)) return;
            float2 pixel = float2(gid) + 0.5f;
            float horizontal = (2.0f * pixel.x / float(frame.viewportAndOptions.x) - 1.0f)
                * frame.cameraForwardAndFOV.w * frame.cameraRightAndAspect.w;
            float vertical = (1.0f - 2.0f * pixel.y / float(frame.viewportAndOptions.y))
                * frame.cameraForwardAndFOV.w;
            float3 direction = normalize(frame.cameraForwardAndFOV.xyz
                + frame.cameraRightAndAspect.xyz * horizontal
                + frame.cameraUpAndMaxDistance.xyz * vertical);
            HybridHit hit;
            TraceCounts counts = {};
            SDFInstance fractal = sdfs[0];
            bool found = traceSDFInstance(
                frame.cameraPositionAndTime.xyz, direction, 0.0f,
                frame.cameraUpAndMaxDistance.w, fractal, scene, hit, counts
            );
            atomic_fetch_add_explicit(&output[0], 1u, memory_order_relaxed);
            if (found && hit.stableID == 1u) {
                atomic_fetch_add_explicit(&output[1], 1u, memory_order_relaxed);
            }
        }
        """
        let (device, library) = try MetalProbeHarness.makeLibrary(extraSource: source)
        let pipeline = try MetalProbeHarness.makePipeline(name: "probeFractalCoverage", library: library, device: device)
        let sceneData = try SceneData.makeHero()
        let fractal = try XCTUnwrap(sceneData.sdfInstances.first { $0.metadata.x == 3 })
        var instance = fractal
        let instances = try XCTUnwrap(device.makeBuffer(
            bytes: &instance,
            length: MemoryLayout<SDFInstance>.stride,
            options: .storageModeShared
        ))
        let output = try XCTUnwrap(device.makeBuffer(
            length: 2 * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ))
        _ = output.contents().initializeMemory(as: UInt32.self, repeating: 0, count: 2)
        let width = 128
        let height = 80
        let yaw: Float = 0.6
        let pitch: Float = -0.18
        let cosPitch = cos(pitch)
        let sinPitch = sin(pitch)
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)
        var scene = SceneUniforms(
            counts: SIMD4<UInt32>(1, 0, 0, 0),
            grid: SIMD4<UInt32>(64, 8, 6, 0),
            fog: .zero,
            budgets: SIMD4<UInt32>(24, 32, 48, 8)
        )
        var frame = FrameUniforms(
            cameraPositionAndTime: SIMD4<Float>(256.5, 112, 256.5, 0),
            cameraForwardAndFOV: SIMD4<Float>(cosPitch * sinYaw, sinPitch, cosPitch * cosYaw, tan(35 * .pi / 180)),
            cameraRightAndAspect: SIMD4<Float>(cosYaw, 0, -sinYaw, Float(width) / Float(height)),
            cameraUpAndMaxDistance: SIMD4<Float>(-sinPitch * sinYaw, cosPitch, -sinPitch * cosYaw, 256),
            sunDirectionAndAmbient: .zero,
            viewportAndOptions: SIMD4<UInt32>(UInt32(width), UInt32(height), 0, 0),
            fogAndExposure: .zero
        )
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBuffer(instances, offset: 0, index: 1)
        encoder.setBytes(&scene, length: MemoryLayout<SceneUniforms>.stride, index: 2)
        encoder.setBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, commandBuffer.error?.localizedDescription ?? "")
        let values = output.contents().bindMemory(to: UInt32.self, capacity: 2)
        return Double(values[1]) / Double(values[0])
    }
}
