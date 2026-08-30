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

    func testHeroSceneContainsSixCreaturesAndSixLights() throws {
        let scene = try SceneData.makeHero()

        XCTAssertEqual(scene.sdfInstances.filter { $0.metadata.x == 1 }.count, 6)
        XCTAssertEqual(scene.lights.count, 6)
    }

    func testHeroPresentationScaleKeepsCreaturesGroundedAndAttachedLightsAligned() throws {
        let scene = try SceneData.makeHero()
        let anchor = SIMD3<Float>(288, 102, 302)
        let scale: Float = 1.5
        let originalCreatureCenters = [
            SIMD3<Float>(270, 96, 292),
            SIMD3<Float>(281, 95, 300),
            SIMD3<Float>(293, 96, 294),
            SIMD3<Float>(275, 95, 310),
            SIMD3<Float>(287, 96, 316),
            SIMD3<Float>(299, 95, 308)
        ]
        let creatures = scene.sdfInstances.filter { $0.metadata.x == 1 }

        XCTAssertEqual(SceneData.heroPresentationScale, scale)
        XCTAssertEqual(SceneData.heroAnchor, anchor)
        XCTAssertEqual(creatures.count, originalCreatureCenters.count)
        XCTAssertEqual(scene.lights.count, creatures.count)

        for (index, originalCenter) in originalCreatureCenters.enumerated() {
            let creature = creatures[index]
            let light = scene.lights[index]
            let expectedCenter = anchor + (originalCenter - anchor) * scale
            let originalLowerExtent = originalCenter.y - 12 * 0.5 - 3 * 0.32
            let lowerExtent = creature.positionScale.y
                - creature.parameters.x * 0.5
                - creature.positionScale.w * 0.32

            XCTAssertEqual(creature.positionScale.x, expectedCenter.x, accuracy: 0.0001)
            XCTAssertEqual(creature.positionScale.z, expectedCenter.z, accuracy: 0.0001)
            XCTAssertEqual(creature.positionScale.w, 4.5, accuracy: 0.0001)
            XCTAssertEqual(creature.parameters.x, 18, accuracy: 0.0001)
            XCTAssertEqual(lowerExtent, originalLowerExtent, accuracy: 0.0001)
            XCTAssertEqual(light.positionRadius.x, creature.positionScale.x, accuracy: 0.0001)
            XCTAssertEqual(light.positionRadius.y - creature.positionScale.y, 10.8, accuracy: 0.0001)
            XCTAssertEqual(light.positionRadius.z, creature.positionScale.z, accuracy: 0.0001)
            XCTAssertEqual(light.positionRadius.w, 33, accuracy: 0.0001)
        }
    }

    func testHeroPresentationScaleExpandsSDFsAndGaussiansWithinWorldBounds() throws {
        let scene = try SceneData.makeHero()
        let anchor = SIMD3<Float>(288, 102, 302)
        let scale: Float = 1.5
        let originalSDFs: [(UInt32, SIMD3<Float>, Float, SIMD3<Float>, SIMD3<Float>)] = [
            (0, SIMD3<Float>(281, 98, 293), 7, SIMD3<Float>(274, 88, 286), SIMD3<Float>(288, 108, 300)),
            (3, SIMD3<Float>(299, 98, 321), 7, SIMD3<Float>(292, 86, 314), SIMD3<Float>(306, 110, 328)),
            (4, SIMD3<Float>(287, 111, 305), 5, SIMD3<Float>(282, 106, 300), SIMD3<Float>(292, 116, 310))
        ]
        let originalGaussianCenter = SIMD3<Float>(292, 96, 302)
        let expectedGaussianCenter = anchor + (originalGaussianCenter - anchor) * scale
        let gaussian = try XCTUnwrap(scene.gaussians.first)
        let originalCamera = SIMD3<Float>(256.5, 112, 256.5)
        let dollyCamera = anchor + (originalCamera - anchor) * scale

        XCTAssertEqual(gaussian.localCenterSigma.x, expectedGaussianCenter.x, accuracy: 0.0001)
        XCTAssertEqual(gaussian.localCenterSigma.y, expectedGaussianCenter.y, accuracy: 0.0001)
        XCTAssertEqual(gaussian.localCenterSigma.z, expectedGaussianCenter.z, accuracy: 0.0001)
        XCTAssertEqual(gaussian.localCenterSigma.w, 4.8, accuracy: 0.0001)
        XCTAssertEqual(gaussian.colorDensity.w, 0.34 / 1.5, accuracy: 0.0001)
        XCTAssertEqual(dollyCamera, SIMD3<Float>(240.75, 117, 233.75))
        XCTAssertEqual(Renderer.initialCameraPosition, dollyCamera)

        for (kind, center, radius, minimum, maximum) in originalSDFs {
            let instance = try XCTUnwrap(scene.sdfInstances.first { $0.metadata.x == kind })
            let expectedCenter = anchor + (center - anchor) * scale
            XCTAssertEqual(instance.positionScale.x, expectedCenter.x, accuracy: 0.0001)
            XCTAssertEqual(instance.positionScale.y, expectedCenter.y, accuracy: 0.0001)
            XCTAssertEqual(instance.positionScale.z, expectedCenter.z, accuracy: 0.0001)
            XCTAssertEqual(instance.positionScale.w, radius * scale, accuracy: 0.0001)
            XCTAssertEqual(
                SIMD3<Float>(instance.sweptBoundsMin.x, instance.sweptBoundsMin.y, instance.sweptBoundsMin.z),
                anchor + (minimum - anchor) * scale
            )
            XCTAssertEqual(
                SIMD3<Float>(instance.sweptBoundsMax.x, instance.sweptBoundsMax.y, instance.sweptBoundsMax.z),
                anchor + (maximum - anchor) * scale
            )
        }
        for instance in scene.sdfInstances {
            XCTAssertGreaterThanOrEqual(instance.sweptBoundsMin.x, 0)
            XCTAssertGreaterThanOrEqual(instance.sweptBoundsMin.y, 0)
            XCTAssertGreaterThanOrEqual(instance.sweptBoundsMin.z, 0)
            XCTAssertLessThanOrEqual(instance.sweptBoundsMax.x, 512)
            XCTAssertLessThanOrEqual(instance.sweptBoundsMax.y, 512)
            XCTAssertLessThanOrEqual(instance.sweptBoundsMax.z, 512)
        }
        for gaussian in scene.gaussians {
            let radius = gaussian.localCenterSigma.w * 3
            XCTAssertGreaterThanOrEqual(gaussian.localCenterSigma.x - radius, 0)
            XCTAssertGreaterThanOrEqual(gaussian.localCenterSigma.y - radius, 0)
            XCTAssertGreaterThanOrEqual(gaussian.localCenterSigma.z - radius, 0)
            XCTAssertLessThanOrEqual(gaussian.localCenterSigma.x + radius, 512)
            XCTAssertLessThanOrEqual(gaussian.localCenterSigma.y + radius, 512)
            XCTAssertLessThanOrEqual(gaussian.localCenterSigma.z + radius, 512)
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
        XCTAssertEqual(resources.volumeLighting.width, 64)
        XCTAssertEqual(resources.volumeLighting.height, 64)
        XCTAssertEqual(resources.volumeLighting.depth, 64)
        XCTAssertEqual(resources.volumeLighting.pixelFormat, .rgba16Float)
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
