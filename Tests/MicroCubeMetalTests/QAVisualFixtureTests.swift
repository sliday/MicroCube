import Metal
import XCTest
@testable import MicroCubeMetal

final class QAVisualFixtureTests: XCTestCase {
    func testQAEvidencePresentationsEncodeTheRequestedGPUEvidence() throws {
        let probeSource = """

        kernel void probeQAEvidencePresentations(
            device float4 *output [[buffer(0)]],
            uint gid [[thread_position_in_grid]]) {
            if (gid != 0u) return;
            output[0] = float4(qaPrimitiveIDColor(true, 0u, 0xffffffffu), 1.0f);
            output[1] = float4(qaPrimitiveIDColor(true, 1u, 7u), 1.0f);
            output[2] = float4(qaPrimitiveIDColor(true, 1u, 7u), 1.0f);
            output[3] = float4(qaPrimitiveIDColor(true, 1u, 8u), 1.0f);
            output[4] = float4(qaPrimitiveIDColor(false, 0u, 0u), 1.0f);
            output[5] = float4(qaNormalColor(true, float3(1.0f, 0.0f, 0.0f)), 1.0f);
            output[6] = float4(qaNormalColor(false, float3(1.0f, 0.0f, 0.0f)), 1.0f);
            output[7] = float4(qaShadowMismatchColor(true, true, false), 1.0f);
            output[8] = float4(qaShadowMismatchColor(true, false, true), 1.0f);
            output[9] = float4(qaShadowMismatchColor(true, true, true), 1.0f);
        }
        """
        let (device, library) = try MetalProbeHarness.makeLibrary(extraSource: probeSource)
        let pipeline = try MetalProbeHarness.makePipeline(
            name: "probeQAEvidencePresentations",
            library: library,
            device: device
        )
        let output = try XCTUnwrap(device.makeBuffer(
            length: 10 * MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModeShared
        ))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, commandBuffer.error?.localizedDescription ?? "")

        let values = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: 10)
        XCTAssertNotEqual(values[0], values[1])
        XCTAssertEqual(values[1], values[2])
        XCTAssertNotEqual(values[2], values[3])
        XCTAssertEqual(values[4], SIMD4<Float>(0, 0, 0, 1))
        XCTAssertEqual(values[5], SIMD4<Float>(1, 0.5, 0.5, 1))
        XCTAssertEqual(values[6], SIMD4<Float>(0, 0, 0, 1))
        XCTAssertEqual(values[7], SIMD4<Float>(1, 0.25, 0, 1))
        XCTAssertEqual(values[8], SIMD4<Float>(1, 0, 1, 1))
        XCTAssertEqual(values[9], SIMD4<Float>(0, 0, 0, 1))
    }

    func testFogBlockedTerrainFixtureChangesInjectedVolumeLighting() throws {
        let clear = try runFogFixture(selector: 1)
        let blocked = try runFogFixture(selector: 2)

        XCTAssertEqual(clear.w, 1, accuracy: 0.001)
        XCTAssertEqual(blocked.w, 0.08, accuracy: 0.01)
        XCTAssertGreaterThan(clear.x - blocked.x, 0.5)
    }

    private func runFogFixture(selector: UInt32) throws -> SIMD4<Float> {
        let (device, library) = try MetalProbeHarness.makeLibrary()
        let terrain = try MetalProbeHarness.makePipeline(name: "generateTerrain", library: library, device: device)
        let reduce = try MetalProbeHarness.makePipeline(name: "reduceOccupancy", library: library, device: device)
        let inject = try MetalProbeHarness.makePipeline(name: "injectVolumeLighting", library: library, device: device)
        let voxelDescriptor = MTLTextureDescriptor()
        voxelDescriptor.textureType = .type3D
        voxelDescriptor.pixelFormat = .r8Uint
        voxelDescriptor.width = 512
        voxelDescriptor.height = 512
        voxelDescriptor.depth = 512
        voxelDescriptor.mipmapLevelCount = 10
        voxelDescriptor.storageMode = .shared
        voxelDescriptor.usage = [.shaderRead, .shaderWrite]
        let voxels = try XCTUnwrap(device.makeTexture(descriptor: voxelDescriptor))
        let lightingDescriptor = MTLTextureDescriptor()
        lightingDescriptor.textureType = .type3D
        lightingDescriptor.pixelFormat = .rgba16Float
        lightingDescriptor.width = 64
        lightingDescriptor.height = 64
        lightingDescriptor.depth = 64
        lightingDescriptor.storageMode = .shared
        lightingDescriptor.usage = [.shaderRead, .shaderWrite]
        let lighting = try XCTUnwrap(device.makeTexture(descriptor: lightingDescriptor))
        var activeCell = SceneData.linearIndex(x: 35, y: 12, z: 37)
        let activeCells = try XCTUnwrap(device.makeBuffer(
            bytes: &activeCell,
            length: MemoryLayout<UInt32>.stride
        ))
        let scratch = try XCTUnwrap(device.makeBuffer(length: 256, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())

        let terrainEncoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        var fixtureSelector = selector
        terrainEncoder.setComputePipelineState(terrain)
        terrainEncoder.setTexture(voxels, index: 0)
        terrainEncoder.setBytes(&fixtureSelector, length: MemoryLayout<UInt32>.stride, index: 0)
        terrainEncoder.dispatchThreads(
            MTLSize(width: 512, height: 512, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )
        terrainEncoder.endEncoding()

        for level in 1..<10 {
            let source = try XCTUnwrap(voxels.makeTextureView(
                pixelFormat: .r8Uint,
                textureType: .type3D,
                levels: (level - 1)..<level,
                slices: 0..<1
            ))
            let destination = try XCTUnwrap(voxels.makeTextureView(
                pixelFormat: .r8Uint,
                textureType: .type3D,
                levels: level..<(level + 1),
                slices: 0..<1
            ))
            let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
            encoder.setComputePipelineState(reduce)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(destination, index: 1)
            encoder.dispatchThreads(
                MTLSize(width: destination.width, height: destination.height, depth: destination.depth),
                threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 4)
            )
            encoder.endEncoding()
        }

        var frame = FrameUniforms(
            cameraPositionAndTime: .zero,
            cameraForwardAndFOV: .zero,
            cameraRightAndAspect: .zero,
            cameraUpAndMaxDistance: .zero,
            sunDirectionAndAmbient: SIMD4<Float>(0.42, 0.82, 0.38, 0.42),
            viewportAndOptions: SIMD4<UInt32>(1, 1, 0, RenderFeatures.all.rawValue | (1 << 31)),
            fogAndExposure: SIMD4<Float>(0.83, 1, 1, 1)
        )
        var scene = SceneUniforms(
            counts: .zero,
            grid: SIMD4<UInt32>(64, 8, 6, 1),
            fog: SIMD4<Float>(0.018, 0.62, 0, 0),
            budgets: SIMD4<UInt32>(24, 32, 48, 8)
        )
        let injectEncoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        injectEncoder.setComputePipelineState(inject)
        injectEncoder.setTexture(voxels, index: 0)
        injectEncoder.setTexture(lighting, index: 2)
        injectEncoder.setBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        injectEncoder.setBytes(&scene, length: MemoryLayout<SceneUniforms>.stride, index: 1)
        injectEncoder.setBuffer(scratch, offset: 0, index: 6)
        injectEncoder.setBuffer(scratch, offset: 0, index: 7)
        injectEncoder.setBuffer(activeCells, offset: 0, index: 9)
        injectEncoder.setBuffer(scratch, offset: 0, index: 10)
        injectEncoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
        )
        injectEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, commandBuffer.error?.localizedDescription ?? "")

        var values = [Float16](repeating: 0, count: 4)
        lighting.getBytes(
            &values,
            bytesPerRow: 4 * MemoryLayout<Float16>.stride,
            bytesPerImage: 4 * MemoryLayout<Float16>.stride,
            from: MTLRegionMake3D(35, 12, 37, 1, 1, 1),
            mipmapLevel: 0,
            slice: 0
        )
        return SIMD4<Float>(Float(values[0]), Float(values[1]), Float(values[2]), Float(values[3]))
    }
}
