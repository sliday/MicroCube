import Metal
import XCTest
@testable import MicroCubeMetal

final class TerrainDetailTests: XCTestCase {
    func testGeneratedSurfaceUsesSingleVoxelHeightResolution() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let library = try makeLibrary(device: device)
        let terrainPipeline = try makePipeline(name: "generateTerrain", library: library, device: device)
        let probePipeline = try makePipeline(name: "probeTerrainSurfaceDetail", library: library, device: device)
        let commandQueue = try XCTUnwrap(device.makeCommandQueue())

        let volumeDescriptor = MTLTextureDescriptor()
        volumeDescriptor.textureType = .type3D
        volumeDescriptor.pixelFormat = .r8Uint
        volumeDescriptor.width = 512
        volumeDescriptor.height = 512
        volumeDescriptor.depth = 512
        volumeDescriptor.storageMode = .private
        volumeDescriptor.usage = [.shaderRead, .shaderWrite]
        let volume = try XCTUnwrap(device.makeTexture(descriptor: volumeDescriptor))
        let counters = try XCTUnwrap(device.makeBuffer(length: MemoryLayout<UInt32>.size * 2, options: .storageModeShared))
        counters.contents().initializeMemory(as: UInt32.self, repeating: 0, count: 2)
        let commandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())

        let terrainEncoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        var fixtureSelector: UInt32 = 0
        terrainEncoder.setComputePipelineState(terrainPipeline)
        terrainEncoder.setTexture(volume, index: 0)
        terrainEncoder.setBytes(&fixtureSelector, length: MemoryLayout<UInt32>.stride, index: 0)
        terrainEncoder.dispatchThreads(
            MTLSize(width: 512, height: 512, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )
        terrainEncoder.endEncoding()

        let probeEncoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        probeEncoder.setComputePipelineState(probePipeline)
        probeEncoder.setTexture(volume, index: 0)
        probeEncoder.setBuffer(counters, offset: 0, index: 0)
        probeEncoder.dispatchThreads(
            MTLSize(width: 512, height: 512, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )
        probeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, commandBuffer.error?.localizedDescription ?? "")

        let values = counters.contents().bindMemory(to: UInt32.self, capacity: 2)
        XCTAssertGreaterThan(values[0], 1_000)
        XCTAssertEqual(values[1], values[0])
    }

    private func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        var source = try ShaderSourceLoader.load()
        source += """

        kernel void probeTerrainSurfaceDetail(
            texture3d<uint, access::read> volume [[texture(0)]],
            device atomic_uint *counters [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]]) {
            if (any(gid >= uint2(kWorldSize))) {
                return;
            }
            int wx = int(gid.x) - 256;
            int wz = int(gid.y) - 256;
            int height = clamp(int(round(terrainHeight(float(wx), float(wz)))), 1, 511);
            if ((height & 3) == 0) {
                return;
            }
            int belowY = height - 1;
            float cave = abs(noise3D(float(wx) / 36.0f, float(belowY) / 36.0f, float(wz) / 36.0f, 41) - 0.5f);
            bool caveCarved = cave < 0.045f && (belowY < height - 8 || cave < 0.01575f);
            bool islandAbove = islandDensity(float(wx), float(height), float(wz)) > 0.7f;
            if (caveCarved || islandAbove) {
                return;
            }
            atomic_fetch_add_explicit(counters, 1u, memory_order_relaxed);
            uint below = volume.read(uint3(gid.x, uint(belowY), gid.y)).x;
            uint above = volume.read(uint3(gid.x, uint(height), gid.y)).x;
            if (below != 0u && above == 0u) {
                atomic_fetch_add_explicit(counters + 1, 1u, memory_order_relaxed);
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
}
