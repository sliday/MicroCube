import Metal
import XCTest
@testable import MicroCubeMetal

final class MixedTraversalTests: XCTestCase {
    func testMixedProbeEnvelopeUsesRequiredMetricKeysFromGPUResult() throws {
        let report = try runMixedProbe()
        let mixed = TraversalStepMetrics(
            voxelSteps: report.voxelSteps,
            sdfSteps: report.sdfSamples,
            gaussianSamples: report.gaussianSamples
        )
        let metrics = MixedProbeMetrics(
            mixedLeafVoxel: report.mixedLeafVoxel == 1,
            mixedLeafSDFRefs: report.mixedLeafSDFRefs,
            wrongNearestHits: report.hit == 1 && report.stableID == 3 ? 0 : 1,
            maxHitDistanceError: Double(abs(report.hitDistance - 8.5)),
            voxelOnly: TraversalStepMetrics(voxelSteps: report.voxelSteps, sdfSteps: 0, gaussianSamples: 0),
            sdfOnly: TraversalStepMetrics(voxelSteps: 0, sdfSteps: report.sdfSamples, gaussianSamples: 0),
            gaussianOnly: TraversalStepMetrics(voxelSteps: 0, sdfSteps: 0, gaussianSamples: report.gaussianSamples),
            mixed: mixed,
            empty: TraversalStepMetrics(voxelSteps: 0, sdfSteps: 0, gaussianSamples: 0)
        )
        let data = try ProbeEnvelope.evaluated(probe: "mixed", device: "test-device", metrics: metrics).encodedJSON()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedMetrics = try XCTUnwrap(object["metrics"] as? [String: Any])

        XCTAssertEqual(object["status"] as? String, "pass")
        XCTAssertEqual(
            Set(encodedMetrics.keys),
            ["mixedLeafVoxel", "mixedLeafSDFRefs", "wrongNearestHits", "maxHitDistanceError",
             "voxelOnly", "sdfOnly", "gaussianOnly", "mixed", "empty"]
        )
        XCTAssertEqual(
            try ProbeEnvelope<MixedProbeMetrics>.decodeValidated(data).metrics.mixed,
            mixed
        )
    }

    func testMixedLeafChoosesNearestOfVoxelAndTwoSDFs() throws {
        let report = try runMixedProbe()

        XCTAssertEqual(report.mixedLeafVoxel, 1)
        XCTAssertEqual(report.mixedLeafSDFRefs, 2)
        XCTAssertEqual(report.hit, 1)
        XCTAssertEqual(report.primitiveKind, 1)
        XCTAssertEqual(report.stableID, 3)
        XCTAssertEqual(report.hitDistance, 8.5, accuracy: 0.002)
        XCTAssertGreaterThan(report.voxelSteps, 0)
        XCTAssertGreaterThan(report.sdfSamples, 0)
        XCTAssertGreaterThan(report.gaussianSamples, 0)
    }

    func testMixedTraversalStaysInsideFixedBudgets() throws {
        let report = try runMixedProbe()

        XCTAssertLessThanOrEqual(report.hierarchicalSteps, 4_096)
        XCTAssertLessThanOrEqual(report.sdfSamples, 24 * 2)
        XCTAssertEqual(report.budgetOverflows, 0)
    }

    func testOpticsOnlyKeepsGlassAndDisabledSDFRevealsVoxelBehindIt() throws {
        let report = try runMixedProbe()

        XCTAssertEqual(report.opticsOnlyHit, 1)
        XCTAssertEqual(report.opticsOnlyPrimitiveKind, 2)
        XCTAssertEqual(report.opticsOnlyStableID, 8)
        XCTAssertEqual(report.sdfDisabledHit, 1)
        XCTAssertEqual(report.sdfDisabledPrimitiveKind, 0)
        XCTAssertEqual(report.sdfDisabledHitDistance, 12.5, accuracy: 0.002)
    }

    func testHierarchyCountsActualEmptySkipsAndOccupiedDescents() throws {
        let report = try runMixedProbe()

        XCTAssertGreaterThan(report.macroSkips, 0)
        XCTAssertGreaterThan(report.macroDescents, 0)
        XCTAssertGreaterThanOrEqual(report.hierarchicalSteps, report.macroSkips + report.macroDescents)
    }

    private func runMixedProbe() throws -> Report {
        let probeSource = """
        kernel void probeMixed(
            texture3d<uint, access::read> voxels [[texture(0)]],
            texture3d<uint, access::read> mixed [[texture(1)]],
            device float *output [[buffer(0)]],
            constant SceneUniforms &scene [[buffer(1)]],
            device const CellHeader *headers [[buffer(2)]],
            device const uint *sdfRefs [[buffer(3)]],
            device const uint *gaussianRefs [[buffer(4)]],
            device const SDFInstance *sdfs [[buffer(5)]],
            device const Gaussian *gaussians [[buffer(6)]],
            uint gid [[thread_position_in_grid]]) {
            if (gid != 0u) return;
            HybridHit hit;
            TraceCounts counts = {};
            bool found = traceMixedScene(
                voxels, mixed, headers, sdfRefs, gaussianRefs, sdfs, gaussians, scene,
                float3(0.5f, 17.5f, 25.5f), float3(1.0f, 0.0f, 0.0f), 64.0f, hit, counts
            );
            uint cellIndex = 1u + 64u * (2u + 64u * 3u);
            output[0] = mixed.read(uint3(1u, 2u, 3u), 0u).x & 1u;
            output[1] = float(headers[cellIndex].packedCounts & 0xffffu);
            output[2] = found ? 1.0f : 0.0f;
            output[3] = float(hit.primitiveKind);
            output[4] = float(hit.stableID);
            output[5] = hit.t;
            output[6] = float(counts.voxelSteps);
            output[7] = float(counts.sdfSamples);
            output[8] = float(counts.gaussianSamples);
            output[9] = float(counts.hierarchicalSteps);
            output[10] = float(counts.budgetOverflows);
            HybridHit opticsOnlyHit;
            TraceCounts opticsOnlyCounts = {};
            bool opticsOnlyFound = traceMixedScene(
                voxels, mixed, headers, sdfRefs, gaussianRefs, sdfs, gaussians, scene,
                float3(0.5f, 17.5f, 25.5f), float3(1.0f, 0.0f, 0.0f), 64.0f, 0.0f, 2u,
                opticsOnlyHit, opticsOnlyCounts
            );
            HybridHit sdfDisabledHit;
            TraceCounts sdfDisabledCounts = {};
            bool sdfDisabledFound = traceMixedScene(
                voxels, mixed, headers, sdfRefs, gaussianRefs, sdfs, gaussians, scene,
                float3(0.5f, 17.5f, 25.5f), float3(1.0f, 0.0f, 0.0f), 64.0f, 0.0f, 0u,
                sdfDisabledHit, sdfDisabledCounts
            );
            output[11] = opticsOnlyFound ? 1.0f : 0.0f;
            output[12] = float(opticsOnlyHit.primitiveKind);
            output[13] = float(opticsOnlyHit.stableID);
            output[14] = sdfDisabledFound ? 1.0f : 0.0f;
            output[15] = float(sdfDisabledHit.primitiveKind);
            output[16] = sdfDisabledHit.t;
            output[17] = float(counts.macroSkips);
            output[18] = float(counts.macroDescents);
        }
        """
        let (device, library) = try MetalProbeHarness.makeLibrary(extraSource: probeSource)
        let reduceVoxel = try MetalProbeHarness.makePipeline(name: "reduceOccupancy", library: library, device: device)
        let buildMixed = try MetalProbeHarness.makePipeline(name: "buildMixedOccupancy", library: library, device: device)
        let reduceMixed = try MetalProbeHarness.makePipeline(name: "reduceMixedOccupancy", library: library, device: device)
        let probe = try MetalProbeHarness.makePipeline(name: "probeMixed", library: library, device: device)
        let scene = try makeFixtureScene()
        let voxels = try makeTexture(device: device, size: 512, mipLevels: 10)
        let mixed = try makeTexture(device: device, size: 64, mipLevels: 7)
        var voxel: UInt8 = 1
        voxels.replace(
            region: MTLRegionMake3D(13, 17, 25, 1, 1, 1),
            mipmapLevel: 0,
            slice: 0,
            withBytes: &voxel,
            bytesPerRow: 1,
            bytesPerImage: 1
        )
        let output = try XCTUnwrap(device.makeBuffer(length: 19 * MemoryLayout<Float>.stride, options: .storageModeShared))
        let headers = try makeBuffer(device: device, values: scene.cellHeaders)
        let sdfRefs = try makeBuffer(device: device, values: scene.cellSDFRefs)
        let gaussianRefs = try makeBuffer(device: device, values: scene.cellGaussianRefs)
        let sdfs = try makeBuffer(device: device, values: scene.sdfInstances)
        let gaussians = try makeBuffer(device: device, values: scene.gaussians)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())

        encodeReductions(texture: voxels, pipeline: reduceVoxel, commandBuffer: commandBuffer)
        let buildEncoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        buildEncoder.setComputePipelineState(buildMixed)
        buildEncoder.setTexture(voxels, index: 0)
        buildEncoder.setTexture(mixed, index: 1)
        buildEncoder.setBuffer(headers, offset: 0, index: 0)
        buildEncoder.setBuffer(sdfRefs, offset: 0, index: 1)
        buildEncoder.setBuffer(sdfs, offset: 0, index: 2)
        buildEncoder.dispatchThreads(
            MTLSize(width: 64, height: 64, depth: 64),
            threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 4)
        )
        buildEncoder.endEncoding()
        encodeReductions(texture: mixed, pipeline: reduceMixed, commandBuffer: commandBuffer)

        var uniforms = SceneUniforms(
            counts: SIMD4<UInt32>(UInt32(scene.sdfInstances.count), UInt32(scene.gaussians.count), 0, 1),
            grid: SIMD4<UInt32>(64, 8, 6, UInt32(scene.activeVolumeCells.count)),
            fog: SIMD4<Float>(0.02, 0.6, 0, 0),
            budgets: SIMD4<UInt32>(24, 32, 48, 8)
        )
        let probeEncoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        probeEncoder.setComputePipelineState(probe)
        probeEncoder.setTexture(voxels, index: 0)
        probeEncoder.setTexture(mixed, index: 1)
        probeEncoder.setBuffer(output, offset: 0, index: 0)
        probeEncoder.setBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 1)
        probeEncoder.setBuffer(headers, offset: 0, index: 2)
        probeEncoder.setBuffer(sdfRefs, offset: 0, index: 3)
        probeEncoder.setBuffer(gaussianRefs, offset: 0, index: 4)
        probeEncoder.setBuffer(sdfs, offset: 0, index: 5)
        probeEncoder.setBuffer(gaussians, offset: 0, index: 6)
        probeEncoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        probeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, commandBuffer.error?.localizedDescription ?? "")

        let pointer = output.contents().bindMemory(to: Float.self, capacity: 19)
        let values = Array(UnsafeBufferPointer(start: pointer, count: 19))
        return Report(values: values)
    }

    private func makeFixtureScene() throws -> SceneData {
        func sphere(centerX: Float, kind: UInt32, stableID: UInt32) -> SDFInstance {
            SDFInstance(
                sweptBoundsMin: SIMD4<Float>(centerX - 0.5, 17, 25, 0),
                sweptBoundsMax: SIMD4<Float>(centerX + 0.5, 18, 26, 0),
                positionScale: SIMD4<Float>(centerX, 17.5, 25.5, 0.5),
                rotationQuaternion: SIMD4<Float>(0, 0, 0, 1),
                parameters: .zero,
                metadata: SIMD4<UInt32>(kind, 0, 0, stableID)
            )
        }
        let gaussian = Gaussian(
            localCenterSigma: SIMD4<Float>(12, 17.5, 25.5, 0.1),
            colorDensity: SIMD4<Float>(0.5, 0.6, 0.7, 0.4),
            motionPhase: .zero
        )
        let material = Material(
            baseColorRoughness: SIMD4<Float>(0.5, 0.5, 0.5, 0.5),
            emissionMetalness: .zero,
            opticalAbsorptionIOR: SIMD4<Float>(0, 0, 0, 1),
            transmissionAcoustic: .zero
        )
        return try SceneData.build(
            sdfInstances: [
                sphere(centerX: 9.5, kind: 0, stableID: 3),
                sphere(centerX: 11.5, kind: 4, stableID: 8),
            ],
            gaussians: [gaussian],
            lights: [],
            materials: [material]
        )
    }

    private func makeTexture(device: MTLDevice, size: Int, mipLevels: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r8Uint
        descriptor.width = size
        descriptor.height = size
        descriptor.depth = size
        descriptor.mipmapLevelCount = mipLevels
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func encodeReductions(
        texture: MTLTexture,
        pipeline: MTLComputePipelineState,
        commandBuffer: MTLCommandBuffer
    ) {
        for level in 1..<texture.mipmapLevelCount {
            let source = texture.makeTextureView(
                pixelFormat: .r8Uint,
                textureType: .type3D,
                levels: (level - 1)..<level,
                slices: 0..<1
            )!
            let destination = texture.makeTextureView(
                pixelFormat: .r8Uint,
                textureType: .type3D,
                levels: level..<(level + 1),
                slices: 0..<1
            )!
            let encoder = commandBuffer.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(destination, index: 1)
            encoder.dispatchThreads(
                MTLSize(width: destination.width, height: destination.height, depth: destination.depth),
                threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 4)
            )
            encoder.endEncoding()
        }
    }

    private func makeBuffer<T>(device: MTLDevice, values: [T]) throws -> MTLBuffer {
        try values.withUnsafeBytes { bytes in
            try XCTUnwrap(device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count))
        }
    }
}

private struct Report {
    let mixedLeafVoxel: Int
    let mixedLeafSDFRefs: Int
    let hit: Int
    let primitiveKind: Int
    let stableID: Int
    let hitDistance: Float
    let voxelSteps: Int
    let sdfSamples: Int
    let gaussianSamples: Int
    let hierarchicalSteps: Int
    let budgetOverflows: Int
    let opticsOnlyHit: Int
    let opticsOnlyPrimitiveKind: Int
    let opticsOnlyStableID: Int
    let sdfDisabledHit: Int
    let sdfDisabledPrimitiveKind: Int
    let sdfDisabledHitDistance: Float
    let macroSkips: Int
    let macroDescents: Int

    init(values: [Float]) {
        mixedLeafVoxel = Int(values[0])
        mixedLeafSDFRefs = Int(values[1])
        hit = Int(values[2])
        primitiveKind = Int(values[3])
        stableID = Int(values[4])
        hitDistance = values[5]
        voxelSteps = Int(values[6])
        sdfSamples = Int(values[7])
        gaussianSamples = Int(values[8])
        hierarchicalSteps = Int(values[9])
        budgetOverflows = Int(values[10])
        opticsOnlyHit = Int(values[11])
        opticsOnlyPrimitiveKind = Int(values[12])
        opticsOnlyStableID = Int(values[13])
        sdfDisabledHit = Int(values[14])
        sdfDisabledPrimitiveKind = Int(values[15])
        sdfDisabledHitDistance = values[16]
        macroSkips = Int(values[17])
        macroDescents = Int(values[18])
    }
}
