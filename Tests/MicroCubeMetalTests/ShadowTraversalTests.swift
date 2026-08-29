import Metal
import XCTest
@testable import MicroCubeMetal

final class ShadowTraversalTests: XCTestCase {
    func testOffRayVoxelInsideOccupiedMipCellDoesNotDarkenSurface() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let library = try makeLibrary(device: device)
        let fixturePipeline = try makePipeline(name: "generateShadowFixture", library: library, device: device)
        let reductionPipeline = try makePipeline(name: "reduceOccupancy", library: library, device: device)
        let raycastPipeline = try makePipeline(name: "raycast", library: library, device: device)
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
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shaderURL = projectRoot
            .appendingPathComponent("Sources/MicroCubeMetal/Shaders/MicroCube.metal")
        var source = try String(contentsOf: shaderURL, encoding: .utf8)
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
