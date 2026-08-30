import Metal
import XCTest
@testable import MicroCubeMetal

final class ShadowTraversalTests: XCTestCase {
    func testExactShadowBatchHasNoFalseOrMissedOcclusions() throws {
        let report = try runExactShadowBatch()

        XCTAssertEqual(report.sampleCount, 10_380)
        XCTAssertEqual(report.legacyMismatch, 404)
        XCTAssertEqual(report.referenceMismatch, 0)
        XCTAssertEqual(report.falseShadows, 0)
        XCTAssertEqual(report.missedShadows, 0)
        XCTAssertLessThanOrEqual(report.maxHitDistanceError, 0.002)
        let data = try ProbeEnvelope.evaluated(
            probe: "shadow",
            device: try XCTUnwrap(MTLCreateSystemDefaultDevice()).name,
            metrics: ShadowProbeMetrics(
                sampleCount: report.sampleCount,
                legacyMismatch: report.legacyMismatch,
                falseShadows: report.falseShadows,
                missedShadows: report.missedShadows,
                maxHitDistanceError: Double(report.maxHitDistanceError)
            )
        ).encodedJSON()
        try MetalProbeHarness.writeEvidence(data, named: "shadow")
    }

    func testOffRayVoxelInsideOccupiedMipCellDoesNotDarkenSurface() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let library = try makeLibrary(device: device)
        let fixturePipeline = try makePipeline(name: "generateShadowFixture", library: library, device: device)
        let reductionPipeline = try makePipeline(name: "reduceOccupancy", library: library, device: device)
        let raycastPipeline = try makePipeline(name: "raycastShadowFixture", library: library, device: device)
        let commandQueue = try XCTUnwrap(device.makeCommandQueue())

        let clearPath = try render(
            includeOffRayVoxel: false,
            device: device,
            commandQueue: commandQueue,
            fixturePipeline: fixturePipeline,
            reductionPipeline: reductionPipeline,
            raycastPipeline: raycastPipeline
        )
        let occupiedNeighborCell = try render(
            includeOffRayVoxel: true,
            device: device,
            commandQueue: commandQueue,
            fixturePipeline: fixturePipeline,
            reductionPipeline: reductionPipeline,
            raycastPipeline: raycastPipeline
        )

        XCTAssertEqual(occupiedNeighborCell.x, clearPath.x, accuracy: 0.001)
        XCTAssertEqual(occupiedNeighborCell.y, clearPath.y, accuracy: 0.001)
        XCTAssertEqual(occupiedNeighborCell.z, clearPath.z, accuracy: 0.001)
    }

    private func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        var source = try ShaderSourceLoader.load()
        source += """

        kernel void generateShadowFixture(
            texture3d<uint, access::write> volume [[texture(0)]],
            constant uint &includeOffRayVoxel [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]]) {
            if (any(gid >= uint2(kWorldSize))) {
                return;
            }
            for (uint y = 0u; y < kWorldSize; ++y) {
                bool receiver = gid.x == 4u && y == 0u && gid.y == 0u;
                bool neighbor = includeOffRayVoxel != 0u && gid.x == 10u && y == 1u && gid.y == 0u;
                volume.write(uint4(receiver || neighbor ? 1u : 0u), uint3(gid.x, y, gid.y));
            }
        }

        kernel void raycastShadowFixture(
            texture3d<uint, access::read> volume [[texture(0)]],
            texture2d<float, access::write> output [[texture(1)]],
            constant FrameUniforms &uniforms [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]]) {
            if (any(gid >= uniforms.viewportAndOptions.xy)) return;
            float2 pixel = float2(gid) + 0.5f;
            float horizontal = (2.0f * pixel.x / float(uniforms.viewportAndOptions.x) - 1.0f)
                * uniforms.cameraForwardAndFOV.w * uniforms.cameraRightAndAspect.w;
            float vertical = (1.0f - 2.0f * pixel.y / float(uniforms.viewportAndOptions.y))
                * uniforms.cameraForwardAndFOV.w;
            float3 direction = normalize(uniforms.cameraForwardAndFOV.xyz
                + uniforms.cameraRightAndAspect.xyz * horizontal
                + uniforms.cameraUpAndMaxDistance.xyz * vertical);
            float3 origin = uniforms.cameraPositionAndTime.xyz;
            float3 sunDirection = normalize(uniforms.sunDirectionAndAmbient.xyz);
            float3 color = skyColor(direction, sunDirection);
            TraceHit hit;
            if (traceVolume(volume, origin, direction, uniforms.cameraUpAndMaxDistance.w, 0u, hit)) {
                float3 point = origin + direction * hit.t;
                float diffuse = max(0.0f, dot(hit.normal, sunDirection));
                float lighting = uniforms.sunDirectionAndAmbient.w
                    + (1.0f - uniforms.sunDirectionAndAmbient.w) * diffuse;
                lighting *= voxelAO(volume, point, hit.normal);
                TraceHit shadowHit;
                if (diffuse > 0.0f && traceOcclusionExact(
                    volume, point + hit.normal * 0.035f, sunDirection, 100.0f, shadowHit
                )) {
                    lighting *= 0.45f;
                }
                color = kPalette[min(hit.material, 42u)] * lighting;
            }
            output.write(float4(color, 1.0f), gid);
        }
        """
        return try device.makeLibrary(source: source, options: nil)
    }

    private func makePipeline(
        name: String,
        library: MTLLibrary,
        device: MTLDevice
    ) throws -> MTLComputePipelineState {
        let function = try XCTUnwrap(library.makeFunction(name: name))
        return try device.makeComputePipelineState(function: function)
    }

    private func runExactShadowBatch() throws -> ShadowBatchReport {
        let source = """
        kernel void probeShadowBatch(
            texture3d<uint, access::read> volume [[texture(0)]],
            device float4 *output [[buffer(0)]],
            uint gid [[thread_position_in_grid]]) {
            if (gid >= 10380u) return;
            float y = gid < 404u ? 0.5f : (gid < 1404u ? 1.5f : 3.5f);
            float3 origin(0.5f, y, gid < 1404u ? 0.5f : 3.5f);
            TraceHit legacyHit;
            TraceHit exactHit;
            TraceHit referenceHit;
            bool legacy = traceVolume(volume, origin, float3(1.0f, 0.0f, 0.0f), 32.0f, 1u, legacyHit);
            bool exact = traceOcclusionExact(volume, origin, float3(1.0f, 0.0f, 0.0f), 32.0f, exactHit);
            bool reference = traceOcclusionReference(
                volume, origin, float3(1.0f, 0.0f, 0.0f), 32.0f, referenceHit
            );
            output[gid] = float4(legacy ? 1.0f : 0.0f, exact ? 1.0f : 0.0f,
                                 exact ? exactHit.t : -1.0f, reference ? 1.0f : 0.0f);
        }
        """
        let (device, library) = try MetalProbeHarness.makeLibrary(extraSource: source)
        let reduction = try MetalProbeHarness.makePipeline(name: "reduceOccupancy", library: library, device: device)
        let probe = try MetalProbeHarness.makePipeline(name: "probeShadowBatch", library: library, device: device)
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r8Uint
        descriptor.width = 512
        descriptor.height = 512
        descriptor.depth = 512
        descriptor.mipmapLevelCount = 10
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let volume = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var occupied: UInt8 = 1
        volume.replace(
            region: MTLRegionMake3D(10, 1, 0, 1, 1, 1),
            mipmapLevel: 0,
            slice: 0,
            withBytes: &occupied,
            bytesPerRow: 1,
            bytesPerImage: 1
        )
        let output = try XCTUnwrap(device.makeBuffer(
            length: 10_380 * MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModeShared
        ))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        for level in 1..<10 {
            let sourceTexture = try XCTUnwrap(volume.makeTextureView(
                pixelFormat: .r8Uint,
                textureType: .type3D,
                levels: (level - 1)..<level,
                slices: 0..<1
            ))
            let destination = try XCTUnwrap(volume.makeTextureView(
                pixelFormat: .r8Uint,
                textureType: .type3D,
                levels: level..<(level + 1),
                slices: 0..<1
            ))
            let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
            encoder.setComputePipelineState(reduction)
            encoder.setTexture(sourceTexture, index: 0)
            encoder.setTexture(destination, index: 1)
            encoder.dispatchThreads(
                MTLSize(width: destination.width, height: destination.height, depth: destination.depth),
                threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 4)
            )
            encoder.endEncoding()
        }
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(probe)
        encoder.setTexture(volume, index: 0)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: 10_380, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: min(256, probe.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, commandBuffer.error?.localizedDescription ?? "")

        let values = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: 10_380)
        var report = ShadowBatchReport(sampleCount: 10_380)
        for index in 0..<10_380 {
            let value = values[index]
            let legacy = value.x != 0
            let exact = value.y != 0
            let measuredReference = value.w != 0
            let reference = (404..<1404).contains(index)
            if legacy != reference { report.legacyMismatch += 1 }
            if measuredReference != reference { report.referenceMismatch += 1 }
            if exact && !reference { report.falseShadows += 1 }
            if !exact && reference { report.missedShadows += 1 }
            if reference && exact {
                report.maxHitDistanceError = max(report.maxHitDistanceError, abs(value.z - 9.5))
            }
        }
        return report
    }

    private func render(
        includeOffRayVoxel: Bool,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        fixturePipeline: MTLComputePipelineState,
        reductionPipeline: MTLComputePipelineState,
        raycastPipeline: MTLComputePipelineState
    ) throws -> SIMD3<Float> {
        let volumeDescriptor = MTLTextureDescriptor()
        volumeDescriptor.textureType = .type3D
        volumeDescriptor.pixelFormat = .r8Uint
        volumeDescriptor.width = 512
        volumeDescriptor.height = 512
        volumeDescriptor.depth = 512
        volumeDescriptor.mipmapLevelCount = 10
        volumeDescriptor.storageMode = .private
        volumeDescriptor.usage = [.shaderRead, .shaderWrite]
        let volume = try XCTUnwrap(device.makeTexture(descriptor: volumeDescriptor))

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: 1,
            height: 1,
            mipmapped: false
        )
        outputDescriptor.storageMode = .shared
        outputDescriptor.usage = .shaderWrite
        let output = try XCTUnwrap(device.makeTexture(descriptor: outputDescriptor))
        let commandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())

        let fixtureEncoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        var fixtureFlag: UInt32 = includeOffRayVoxel ? 1 : 0
        fixtureEncoder.setComputePipelineState(fixturePipeline)
        fixtureEncoder.setTexture(volume, index: 0)
        fixtureEncoder.setBytes(&fixtureFlag, length: MemoryLayout<UInt32>.size, index: 0)
        fixtureEncoder.dispatchThreads(
            MTLSize(width: 512, height: 512, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )
        fixtureEncoder.endEncoding()

        for destinationLevel in 1..<volume.mipmapLevelCount {
            let source = try XCTUnwrap(volume.makeTextureView(
                pixelFormat: .r8Uint,
                textureType: .type3D,
                levels: (destinationLevel - 1)..<destinationLevel,
                slices: 0..<1
            ))
            let destination = try XCTUnwrap(volume.makeTextureView(
                pixelFormat: .r8Uint,
                textureType: .type3D,
                levels: destinationLevel..<(destinationLevel + 1),
                slices: 0..<1
            ))
            let reductionEncoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
            reductionEncoder.setComputePipelineState(reductionPipeline)
            reductionEncoder.setTexture(source, index: 0)
            reductionEncoder.setTexture(destination, index: 1)
            reductionEncoder.dispatchThreads(
                MTLSize(width: destination.width, height: destination.height, depth: destination.depth),
                threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 4)
            )
            reductionEncoder.endEncoding()
        }

        let raycastEncoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        var uniforms = FrameUniforms(
            cameraPositionAndTime: SIMD4<Float>(6.5, 0.5, 0.5, 0.0),
            cameraForwardAndFOV: SIMD4<Float>(-1.0, 0.0, 0.0, 0.5),
            cameraRightAndAspect: SIMD4<Float>(0.0, 0.0, 1.0, 1.0),
            cameraUpAndMaxDistance: SIMD4<Float>(0.0, 1.0, 0.0, 32.0),
            sunDirectionAndAmbient: SIMD4<Float>(1.0, 0.0, 0.0, 0.42),
            viewportAndOptions: SIMD4<UInt32>(1, 1, 0, 0b111),
            fogAndExposure: SIMD4<Float>(0.83, 1.0, 1.0, 1.0)
        )
        raycastEncoder.setComputePipelineState(raycastPipeline)
        raycastEncoder.setTexture(volume, index: 0)
        raycastEncoder.setTexture(output, index: 1)
        raycastEncoder.setBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        raycastEncoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
        )
        raycastEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, commandBuffer.error?.localizedDescription ?? "")

        var pixel = [Float](repeating: 0.0, count: 4)
        output.getBytes(
            &pixel,
            bytesPerRow: MemoryLayout<Float>.size * 4,
            from: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0
        )
        return SIMD3<Float>(pixel[0], pixel[1], pixel[2])
    }
}

private struct ShadowBatchReport {
    let sampleCount: Int
    var legacyMismatch = 0
    var referenceMismatch = 0
    var falseShadows = 0
    var missedShadows = 0
    var maxHitDistanceError: Float = 0
}
