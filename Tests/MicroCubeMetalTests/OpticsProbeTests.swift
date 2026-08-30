import Metal
import simd
import XCTest
@testable import MicroCubeMetal

final class OpticsProbeTests: XCTestCase {
    func testOpticalDirectionsMatchAnalyticReferences() throws {
        let report = try runOpticsProbe()
        XCTAssertLessThanOrEqual(report.maxReflectionDirectionError, 0.0001)
        XCTAssertLessThanOrEqual(report.maxRefractionDirectionError, 0.0001)
        XCTAssertEqual(report.tirFailureCount, 0)
    }

    func testSecondaryHitsDoNotSpawnOpticalRays() throws {
        XCTAssertEqual(try runOpticsProbe().recursiveSecondaryRayCount, 0)
    }

    func testAllowedOpticalSceneDispatchAdvancesBudgetToSecondaryDepth() throws {
        XCTAssertEqual(try runOpticsProbe().secondaryShadeRayDepth, 1)
    }

    func testSecondaryOpticalLaunchInstrumentationCountsRecursion() throws {
        XCTAssertEqual(try runOpticsProbe().instrumentedSecondaryLaunchCount, 1)
    }

    func testSecondaryMixedSceneLaunchInstrumentationCountsRecursion() throws {
        XCTAssertEqual(try runOpticsProbe().instrumentedSecondarySceneLaunchCount, 1)
    }

    func testTotalInternalReflectionDoesNotLaunchAnInteriorSecondaryRay() throws {
        let report = try runOpticsProbe()
        XCTAssertEqual(report.tirSecondaryRayCount, 0)
        XCTAssertGreaterThanOrEqual(report.tirSecondaryOriginDistance, 1.0001)
    }

    private func runOpticsProbe() throws -> Report {
        let source = """
        kernel void probeOptics(
            device float *output [[buffer(0)]],
            device const Light *lights [[buffer(1)]],
            constant SceneUniforms &scene [[buffer(2)]],
            device const CellHeader *headers [[buffer(3)]],
            device const uint *sdfRefs [[buffer(4)]],
            device const uint *gaussianRefs [[buffer(5)]],
            device const SDFInstance *sdfs [[buffer(6)]],
            device const Gaussian *gaussians [[buffer(7)]],
            texture3d<uint, access::read> voxels [[texture(0)]],
            texture3d<uint, access::read> mixed [[texture(1)]],
            uint gid [[thread_position_in_grid]]) {
            if (gid != 0u) return;
            OpticalPath externalPath;
            OpticalPath internalPath;
            OpticalRayBudget primaryBudget = {0u, 0u};
            OpticalRayBudget secondaryShadeBudget = {0u, 0u};
            float3 origin(-3.0f, 0.25f, 0.0f);
            float3 direction = normalize(float3(1.0f, 0.0f, 0.0f));
            bool crossed = traceOpticalSphere(
                origin, direction, float3(0.0f), 1.0f, 1.5f, float3(0.18f, 0.07f, 0.03f), externalPath, primaryBudget
            );
            bool totalInternalReflection = traceOpticalSphere(
                float3(0.0f, 0.8f, 0.0f), normalize(float3(1.0f, 0.0f, 0.0f)),
                float3(0.0f), 1.0f, 1.5f, float3(0.18f, 0.07f, 0.03f), internalPath, primaryBudget
            );
            HybridHit secondaryShadeHit;
            TraceCounts secondaryShadeCounts = {};
            traceOpticalScene(
                voxels, mixed, headers, sdfRefs, gaussianRefs, sdfs, gaussians, scene,
                float3(-1.0f), float3(-1.0f, 0.0f, 0.0f), 1.0f, 0.0f,
                secondaryShadeHit, secondaryShadeCounts, secondaryShadeBudget
            );
            shadeSecondaryHit(
                float3(0.0f), float3(0.0f, 1.0f, 0.0f), float3(1.0f),
                float3(0.0f, 1.0f, 0.0f), 0.42f, lights, scene, 0.0f, secondaryShadeBudget
            );
            uint recursiveCountAfterShading = secondaryShadeBudget.recursiveSecondaryRayCount;
            uint rayDepthAfterShading = secondaryShadeBudget.rayDepth;
            OpticalPath instrumentedPath;
            bool instrumentedSecondaryLaunch = traceOpticalSphere(
                origin, direction, float3(0.0f), 1.0f, 1.5f, float3(0.18f, 0.07f, 0.03f),
                instrumentedPath, secondaryShadeBudget
            );
            OpticalRayBudget instrumentedSceneBudget = {0u, 0u};
            HybridHit sceneHit;
            TraceCounts sceneCounts = {};
            traceOpticalScene(
                voxels, mixed, headers, sdfRefs, gaussianRefs, sdfs, gaussians, scene,
                float3(-1.0f), float3(-1.0f, 0.0f, 0.0f), 1.0f, 0.0f,
                sceneHit, sceneCounts, instrumentedSceneBudget
            );
            traceOpticalScene(
                voxels, mixed, headers, sdfRefs, gaussianRefs, sdfs, gaussians, scene,
                float3(-1.0f), float3(-1.0f, 0.0f, 0.0f), 1.0f, 0.0f,
                sceneHit, sceneCounts, instrumentedSceneBudget
            );
            output[0] = crossed ? externalPath.entryDirection.x : NAN;
            output[1] = crossed ? externalPath.entryDirection.y : NAN;
            output[2] = crossed ? externalPath.entryDirection.z : NAN;
            output[3] = crossed ? externalPath.exitDirection.x : NAN;
            output[4] = crossed ? externalPath.exitDirection.y : NAN;
            output[5] = crossed ? externalPath.exitDirection.z : NAN;
            output[6] = crossed ? externalPath.reflectionDirection.x : NAN;
            output[7] = crossed ? externalPath.reflectionDirection.y : NAN;
            output[8] = crossed ? externalPath.reflectionDirection.z : NAN;
            output[9] = totalInternalReflection && internalPath.totalInternalReflection != 0u ? 0.0f : 1.0f;
            output[10] = totalInternalReflection ? float(internalPath.canTraceSecondary) : 1.0f;
            output[11] = float(recursiveCountAfterShading);
            output[12] = totalInternalReflection ? length(internalPath.secondaryOrigin) : 0.0f;
            output[13] = instrumentedSecondaryLaunch
                ? float(secondaryShadeBudget.recursiveSecondaryRayCount) : NAN;
            output[14] = float(instrumentedSceneBudget.recursiveSecondaryRayCount);
            output[15] = float(rayDepthAfterShading);
        }
        """
        let (device, library) = try MetalProbeHarness.makeLibrary(extraSource: source)
        let pipeline = try MetalProbeHarness.makePipeline(name: "probeOptics", library: library, device: device)
        let output = try XCTUnwrap(device.makeBuffer(length: 16 * MemoryLayout<Float>.stride, options: .storageModeShared))
        let lights = try XCTUnwrap(device.makeBuffer(length: MemoryLayout<Light>.stride, options: .storageModeShared))
        let scratch = try XCTUnwrap(device.makeBuffer(length: 256, options: .storageModeShared))
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.textureType = .type3D
        textureDescriptor.pixelFormat = .r8Uint
        textureDescriptor.width = 1
        textureDescriptor.height = 1
        textureDescriptor.depth = 1
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = .shaderRead
        let voxels = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
        let mixed = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
        var scene = SceneUniforms(counts: .zero, grid: .zero, fog: .zero, budgets: .zero)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBuffer(lights, offset: 0, index: 1)
        encoder.setBytes(&scene, length: MemoryLayout<SceneUniforms>.stride, index: 2)
        encoder.setBuffer(scratch, offset: 0, index: 3)
        encoder.setBuffer(scratch, offset: 0, index: 4)
        encoder.setBuffer(scratch, offset: 0, index: 5)
        encoder.setBuffer(scratch, offset: 0, index: 6)
        encoder.setBuffer(scratch, offset: 0, index: 7)
        encoder.setTexture(voxels, index: 0)
        encoder.setTexture(mixed, index: 1)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, commandBuffer.error?.localizedDescription ?? "")

        let values = output.contents().bindMemory(to: Float.self, capacity: 16)
        let direction = SIMD3<Float>(1, 0, 0)
        let entryNormal = SIMD3<Float>(-sqrt(1 - 0.25 * 0.25), 0.25, 0)
        let expectedEntry = refract(direction, normal: entryNormal, eta: 1 / 1.5)
        let entryPoint = SIMD3<Float>(entryNormal.x, entryNormal.y, 0)
        let exitDistance = -2 * simd_dot(entryPoint, expectedEntry)
        let exitNormal = entryPoint + expectedEntry * exitDistance
        let expectedExit = refract(expectedEntry, normal: -exitNormal, eta: 1.5)
        let expectedReflection = reflect(direction, normal: entryNormal)
        let entry = SIMD3<Float>(values[0], values[1], values[2])
        let exit = SIMD3<Float>(values[3], values[4], values[5])
        let reflection = SIMD3<Float>(values[6], values[7], values[8])
        return Report(
            maxReflectionDirectionError: simd_length(reflection - expectedReflection),
            maxRefractionDirectionError: max(simd_length(entry - expectedEntry), simd_length(exit - expectedExit)),
            tirFailureCount: Int(values[9]),
            tirSecondaryRayCount: Int(values[10]),
            recursiveSecondaryRayCount: Int(values[11]),
            tirSecondaryOriginDistance: values[12],
            instrumentedSecondaryLaunchCount: Int(values[13]),
            instrumentedSecondarySceneLaunchCount: Int(values[14]),
            secondaryShadeRayDepth: Int(values[15])
        )
    }

    private func reflect(_ incident: SIMD3<Float>, normal: SIMD3<Float>) -> SIMD3<Float> {
        incident - 2 * simd_dot(incident, normal) * normal
    }

    private func refract(_ incident: SIMD3<Float>, normal: SIMD3<Float>, eta: Float) -> SIMD3<Float> {
        let cosine = -simd_dot(normal, incident)
        let discriminant = 1 - eta * eta * (1 - cosine * cosine)
        return eta * incident + (eta * cosine - sqrt(discriminant)) * normal
    }

    private struct Report {
        let maxReflectionDirectionError: Float
        let maxRefractionDirectionError: Float
        let tirFailureCount: Int
        let tirSecondaryRayCount: Int
        let recursiveSecondaryRayCount: Int
        let tirSecondaryOriginDistance: Float
        let instrumentedSecondaryLaunchCount: Int
        let instrumentedSecondarySceneLaunchCount: Int
        let secondaryShadeRayDepth: Int
    }
}
