import Metal
import XCTest
@testable import MicroCubeMetal

final class SceneDataTests: XCTestCase {
    func testHeroSceneFitsStaticCapsAndReferencesStayInBounds() throws {
        let scene = try SceneData.makeHero()

        XCTAssertEqual(scene.cellHeaders.count, 64 * 64 * 64)
        XCTAssertLessThanOrEqual(scene.sdfInstances.count, 16)
        XCTAssertLessThanOrEqual(scene.gaussians.count, 48)
        XCTAssertLessThanOrEqual(scene.lights.count, 6)
        XCTAssertLessThanOrEqual(scene.activeVolumeCells.count, 4_096)

        for header in scene.cellHeaders {
            let sdfCount = Int(header.packedCounts & 0xffff)
            let gaussianCount = Int(header.packedCounts >> 16)
            XCTAssertLessThanOrEqual(sdfCount, 8)
            XCTAssertLessThanOrEqual(gaussianCount, 16)
            XCTAssertLessThanOrEqual(Int(header.sdfOffset) + sdfCount, scene.cellSDFRefs.count)
            XCTAssertLessThanOrEqual(Int(header.gaussianOffset) + gaussianCount, scene.cellGaussianRefs.count)
            XCTAssertEqual(header.reserved, 0)
        }
    }

    func testCellHeaderPacksCountsAndReferencesInStableIDOrder() throws {
        let scene = try SceneData.build(
            sdfInstances: [makeSDF(stableID: 9), makeSDF(stableID: 2)],
            gaussians: [makeGaussian(stableID: 8), makeGaussian(stableID: 1), makeGaussian(stableID: 4)],
            lights: [],
            materials: [makeMaterial()]
        )
        let header = scene.cellHeaders[Int(SceneData.linearIndex(x: 1, y: 2, z: 3))]
        let sdfRange = Int(header.sdfOffset)..<(Int(header.sdfOffset) + 2)
        let gaussianRange = Int(header.gaussianOffset)..<(Int(header.gaussianOffset) + 3)

        XCTAssertEqual(header.packedCounts, 0x0003_0002)
        XCTAssertEqual(scene.cellSDFRefs[sdfRange].map { scene.sdfInstances[Int($0)].metadata.w }, [2, 9])
        XCTAssertEqual(scene.cellGaussianRefs[gaussianRange].map { scene.gaussians[Int($0)].motionPhase.w }, [1, 4, 8])
    }

    func testActiveVolumeCellsContainExactOneCellHalo() throws {
        let scene = try SceneData.build(
            sdfInstances: [],
            gaussians: [makeGaussian(stableID: 0)],
            lights: [],
            materials: [makeMaterial()]
        )
        var expected = Set<UInt32>()
        for z in 2...4 {
            for y in 1...3 {
                for x in 0...2 {
                    expected.insert(SceneData.linearIndex(x: x, y: y, z: z))
                }
            }
        }

        XCTAssertEqual(Set(scene.activeVolumeCells), expected)
    }

    func testCountAndSceneCapsFailInsteadOfTruncating() throws {
        XCTAssertThrowsError(try SceneData.packCounts(sdfCount: 65_536, gaussianCount: 0)) {
            XCTAssertEqual($0 as? SceneBuildError, .referenceCountOverflow(kind: "sdf", count: 65_536))
        }
        XCTAssertThrowsError(try SceneData.build(
            sdfInstances: (0..<17).map { makeSDF(stableID: UInt32($0)) },
            gaussians: [],
            lights: [],
            materials: [makeMaterial()]
        )) {
            XCTAssertEqual($0 as? SceneBuildError, .capExceeded(name: "SDF instances", count: 17, maximum: 16))
        }
    }

    func testMixedOccupancyCombinesAllLeafFlagsAndReducesWithBitwiseOR() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: ShaderSourceLoader.load(), options: nil)
        let buildPipeline = try device.makeComputePipelineState(
            function: XCTUnwrap(library.makeFunction(name: "buildMixedOccupancy"))
        )
        let reducePipeline = try device.makeComputePipelineState(
            function: XCTUnwrap(library.makeFunction(name: "reduceMixedOccupancy"))
        )
        let scene = try SceneData.build(
            sdfInstances: [makeSDF(stableID: 0, kind: 3, flags: 1)],
            gaussians: [makeGaussian(stableID: 0)],
            lights: [],
            materials: [makeMaterial()]
        )
        let voxels = try makeVoxelTexture(device: device)
        let mixed = try makeMixedTexture(device: device)
        let target = SIMD3<Int>(1, 2, 3)
        var voxelMip = [UInt8](repeating: 0, count: 64 * 64 * 64)
        voxelMip[Int(SceneData.linearIndex(x: target.x, y: target.y, z: target.z))] = 7
        voxels.replace(
            region: MTLRegionMake3D(0, 0, 0, 64, 64, 64),
            mipmapLevel: 3,
            slice: 0,
            withBytes: voxelMip,
            bytesPerRow: 64,
            bytesPerImage: 64 * 64
        )

        let commandQueue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())
        let buildEncoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        buildEncoder.setComputePipelineState(buildPipeline)
        buildEncoder.setTexture(voxels, index: 0)
        buildEncoder.setTexture(mixed, index: 1)
        buildEncoder.setBuffer(try makeBuffer(device: device, values: scene.cellHeaders), offset: 0, index: 0)
        buildEncoder.setBuffer(try makeBuffer(device: device, values: scene.cellSDFRefs), offset: 0, index: 1)
        buildEncoder.setBuffer(try makeBuffer(device: device, values: scene.sdfInstances), offset: 0, index: 2)
        buildEncoder.dispatchThreads(
            MTLSize(width: 64, height: 64, depth: 64),
            threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 4)
        )
        buildEncoder.endEncoding()

        for level in 1..<7 {
            let source = try XCTUnwrap(mixed.makeTextureView(
                pixelFormat: .r8Uint,
                textureType: .type3D,
                levels: (level - 1)..<level,
                slices: 0..<1
            ))
            let destination = try XCTUnwrap(mixed.makeTextureView(
                pixelFormat: .r8Uint,
                textureType: .type3D,
                levels: level..<(level + 1),
                slices: 0..<1
            ))
            let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
            encoder.setComputePipelineState(reducePipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(destination, index: 1)
            encoder.dispatchThreads(
                MTLSize(width: destination.width, height: destination.height, depth: destination.depth),
                threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 4)
            )
            encoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, commandBuffer.error?.localizedDescription ?? "")
        XCTAssertEqual(readByte(texture: mixed, level: 0, x: target.x, y: target.y, z: target.z), 0b1_1111)
        XCTAssertEqual(readByte(texture: mixed, level: 6, x: 0, y: 0, z: 0), 0b1_1111)
    }

    func testSceneGPUResourcesAllocateExactTextureAndBufferSizes() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let scene = try SceneData.makeHero()
        let resources = try SceneGPUResources(device: device, scene: scene)

        XCTAssertEqual(resources.mixedOccupancy.width, 64)
        XCTAssertEqual(resources.mixedOccupancy.height, 64)
        XCTAssertEqual(resources.mixedOccupancy.depth, 64)
        XCTAssertEqual(resources.mixedOccupancy.mipmapLevelCount, 7)
        XCTAssertEqual(resources.mixedOccupancy.pixelFormat, .r8Uint)
        XCTAssertEqual(resources.cellHeaders.length, scene.cellHeaders.count * MemoryLayout<CellHeader>.stride)
        XCTAssertEqual(resources.cellSDFRefs.length, scene.cellSDFRefs.count * MemoryLayout<UInt32>.stride)
        XCTAssertEqual(resources.cellGaussianRefs.length, scene.cellGaussianRefs.count * MemoryLayout<UInt32>.stride)
        XCTAssertEqual(resources.sdfInstances.length, scene.sdfInstances.count * MemoryLayout<SDFInstance>.stride)
        XCTAssertEqual(resources.gaussians.length, scene.gaussians.count * MemoryLayout<Gaussian>.stride)
        XCTAssertEqual(resources.materials.length, scene.materials.count * MemoryLayout<Material>.stride)
        XCTAssertEqual(resources.activeVolumeCells.length, scene.activeVolumeCells.count * MemoryLayout<UInt32>.stride)
    }

    private func makeSDF(
        stableID: UInt32,
        kind: UInt32 = 0,
        flags: UInt32 = 0
    ) -> SDFInstance {
        SDFInstance(
            sweptBoundsMin: SIMD4<Float>(9, 17, 25, 0),
            sweptBoundsMax: SIMD4<Float>(10, 18, 26, 0),
            positionScale: SIMD4<Float>(9.5, 17.5, 25.5, 0.5),
            rotationQuaternion: SIMD4<Float>(0, 0, 0, 1),
            parameters: .zero,
            metadata: SIMD4<UInt32>(kind, 0, flags, stableID)
        )
    }

    private func makeGaussian(stableID: UInt32) -> Gaussian {
        Gaussian(
            localCenterSigma: SIMD4<Float>(9.5, 17.5, 25.5, 0.1),
            colorDensity: SIMD4<Float>(0.6, 0.7, 0.8, 0.4),
            motionPhase: SIMD4<Float>(0, 0, 0, Float(stableID))
        )
    }

    private func makeMaterial() -> Material {
        Material(
            baseColorRoughness: SIMD4<Float>(0.5, 0.5, 0.5, 0.5),
            emissionMetalness: .zero,
            opticalAbsorptionIOR: SIMD4<Float>(0, 0, 0, 1),
            transmissionAcoustic: .zero
        )
    }

    private func makeVoxelTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r8Uint
        descriptor.width = 512
        descriptor.height = 512
        descriptor.depth = 512
        descriptor.mipmapLevelCount = 10
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func makeMixedTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r8Uint
        descriptor.width = 64
        descriptor.height = 64
        descriptor.depth = 64
        descriptor.mipmapLevelCount = 7
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func makeBuffer<T>(device: MTLDevice, values: [T]) throws -> MTLBuffer {
        try values.withUnsafeBytes { bytes in
            try XCTUnwrap(device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count))
        }
    }

    private func readByte(texture: MTLTexture, level: Int, x: Int, y: Int, z: Int) -> UInt8 {
        var value: UInt8 = 0
        texture.getBytes(
            &value,
            bytesPerRow: 1,
            bytesPerImage: 1,
            from: MTLRegionMake3D(x, y, z, 1, 1, 1),
            mipmapLevel: level,
            slice: 0
        )
        return value
    }
}
