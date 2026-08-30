import Metal
import simd
import XCTest
@testable import MicroCubeMetal

final class SDFProbeTests: XCTestCase {
    func testSDFProbeEnvelopeUsesRequiredMetricKeysFromGPUResult() throws {
        let values = try runProbe()
        let normal = SIMD3<Float>(values[3], values[4], values[5])
        let metrics = SDFProbeMetrics(
            maxDistanceError: Double(max(abs(values[0] - 1), abs(values[1] - 0.5), abs(values[2] - 0.14375))),
            maxNormalAngleDegrees: Double(acos(min(1, max(-1, normal.x))) * 180 / .pi),
            maxNormalLengthError: Double(abs(simd_length(normal) - 1)),
            nonFiniteCount: Int(values[8]),
            negativeExteriorStepCount: Int(values[7]),
            fractalCoverage: 0
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
}
