import Metal
import simd
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
        let expectedCreaturePositions = [
            SIMD2<Float>(261, 287),
            SIMD2<Float>(277.5, 299),
            SIMD2<Float>(295.5, 290),
            SIMD2<Float>(261, 321.5),
            SIMD2<Float>(286.5, 323),
            SIMD2<Float>(304.5, 311)
        ]
        let creatures = scene.sdfInstances.filter { $0.metadata.x == 1 }

        XCTAssertEqual(SceneData.heroPresentationScale, scale)
        XCTAssertEqual(SceneData.heroAnchor, anchor)
        XCTAssertEqual(creatures.count, expectedCreaturePositions.count)
        XCTAssertEqual(scene.lights.count, creatures.count)

        for (index, expectedPosition) in expectedCreaturePositions.enumerated() {
            let creature = creatures[index]
            let light = scene.lights[index]

            XCTAssertEqual(creature.positionScale.x, expectedPosition.x, accuracy: 0.0001)
            XCTAssertEqual(creature.positionScale.z, expectedPosition.y, accuracy: 0.0001)
            XCTAssertEqual(creature.positionScale.w, 4.5, accuracy: 0.0001)
            XCTAssertEqual(creature.parameters.x, 18, accuracy: 0.0001)
            XCTAssertEqual(light.positionRadius.x, creature.positionScale.x, accuracy: 0.0001)
            XCTAssertEqual(light.positionRadius.y - creature.positionScale.y, 10.8, accuracy: 0.0001)
            XCTAssertEqual(light.positionRadius.z, creature.positionScale.z, accuracy: 0.0001)
            XCTAssertEqual(light.positionRadius.w, 33, accuracy: 0.0001)
        }

        XCTAssertLessThanOrEqual(scene.sdfInstances.count, 16)
        XCTAssertLessThanOrEqual(scene.gaussians.count, 48)
        XCTAssertLessThanOrEqual(scene.lights.count, 6)
        XCTAssertLessThanOrEqual(scene.activeVolumeCells.count, 4_096)
        for header in scene.cellHeaders {
            XCTAssertLessThanOrEqual(Int(header.packedCounts & 0xffff), 8)
            XCTAssertLessThanOrEqual(Int(header.packedCounts >> 16), 16)
        }
    }

    func testHeroPresentationScaleExpandsSDFsAndGaussiansWithinWorldBounds() throws {
        let scene = try SceneData.makeHero()
        let anchor = SIMD3<Float>(288, 102, 302)
        let scale: Float = 1.5
        let expectedSDFs: [(UInt32, SIMD3<Float>, Float, SIMD3<Float>, SIMD3<Float>)] = [
            (0, SIMD3<Float>(277.5, 96, 288.5), 10.5, SIMD3<Float>(267, 81, 278), SIMD3<Float>(288, 111, 299)),
            (3, SIMD3<Float>(266.0625, 128.25, 390.3125), 10.5, SIMD3<Float>(255.5625, 110.25, 379.8125), SIMD3<Float>(276.5625, 146.25, 400.8125)),
            (4, SIMD3<Float>(286.5, 115.5, 306.5), 7.5, SIMD3<Float>(279, 108, 299), SIMD3<Float>(294, 123, 314))
        ]
        let originalCamera = SIMD3<Float>(256.5, 112, 256.5)
        let dollyCamera = anchor + (originalCamera - anchor) * scale

        XCTAssertEqual(dollyCamera, SIMD3<Float>(240.75, 117, 233.75))
        XCTAssertEqual(Renderer.initialCameraPosition, dollyCamera)
        let baselineDistance = simd_distance(originalCamera, anchor)
        let newDistance = simd_distance(dollyCamera, anchor)
        let voxelProjectionRatio = baselineDistance / newDistance
        let heroProjectionRatio = (scale / newDistance) / (1 / baselineDistance)
        XCTAssertEqual(voxelProjectionRatio, 2 / 3, accuracy: 0.0001)
        XCTAssertEqual(heroProjectionRatio, 1, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(abs(heroProjectionRatio - 1), 0.1)

        for (kind, center, radius, minimum, maximum) in expectedSDFs {
            let instance = try XCTUnwrap(scene.sdfInstances.first { $0.metadata.x == kind })
            XCTAssertEqual(instance.positionScale.x, center.x, accuracy: 0.0001)
            XCTAssertEqual(instance.positionScale.y, center.y, accuracy: 0.0001)
            XCTAssertEqual(instance.positionScale.z, center.z, accuracy: 0.0001)
            XCTAssertEqual(instance.positionScale.w, radius, accuracy: 0.0001)
            XCTAssertEqual(
                SIMD3<Float>(instance.sweptBoundsMin.x, instance.sweptBoundsMin.y, instance.sweptBoundsMin.z),
                minimum
            )
            XCTAssertEqual(
                SIMD3<Float>(instance.sweptBoundsMax.x, instance.sweptBoundsMax.y, instance.sweptBoundsMax.z),
                maximum
            )
        }
        let expectedGaussianCenters = [
            SIMD3<Float>(294, 93, 302),
            SIMD3<Float>(290.04593, 99, 309.42462),
            SIMD3<Float>(280.5, 93, 312.5),
            SIMD3<Float>(270.95407, 99, 309.42462),
            SIMD3<Float>(267, 93, 302),
            SIMD3<Float>(270.95407, 99, 294.57538),
            SIMD3<Float>(280.5, 93, 291.5),
            SIMD3<Float>(290.04593, 99, 294.57538)
        ]
        for (index, gaussian) in scene.gaussians.enumerated() {
            let expectedCenter = expectedGaussianCenters[index]
            XCTAssertEqual(gaussian.localCenterSigma.x, expectedCenter.x, accuracy: 0.0001)
            XCTAssertEqual(gaussian.localCenterSigma.y, expectedCenter.y, accuracy: 0.0001)
            XCTAssertEqual(gaussian.localCenterSigma.z, expectedCenter.z, accuracy: 0.0001)
            XCTAssertEqual(gaussian.localCenterSigma.w, 4.8, accuracy: 0.0001)
            XCTAssertEqual(gaussian.colorDensity.w, 0.34 / 1.5, accuracy: 0.0001)
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

    func testHeroCreaturesContactProductionTerrainWithinOneVoxel() throws {
        let scene = try SceneData.makeHero()
        let creatures = scene.sdfInstances.filter { $0.metadata.x == 1 }
        let (device, library) = try MetalProbeHarness.makeLibrary(extraSource: """
        kernel void probeHeroCreatureTerrain(
            device const float2 *positions [[buffer(0)]],
            device float *heights [[buffer(1)]],
            uint index [[thread_position_in_grid]]) {
            if (index >= 6u) return;
            float2 position = positions[index] - float2(256.0f);
            heights[index] = terrainHeight(position.x, position.y);
        }
        """)
        let pipeline = try MetalProbeHarness.makePipeline(
            name: "probeHeroCreatureTerrain",
            library: library,
            device: device
        )
        let expectedTerrainHeights: [Float] = [87, 88, 93, 88, 86, 101]
        let positions = creatures.map { SIMD2<Float>($0.positionScale.x, $0.positionScale.z) }
        let positionBuffer = try positions.withUnsafeBytes { bytes in
            try XCTUnwrap(device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared))
        }
        let heightBuffer = try XCTUnwrap(device.makeBuffer(
            length: MemoryLayout<Float>.stride * creatures.count,
            options: .storageModeShared
        ))
        let commandBuffer = try XCTUnwrap(try XCTUnwrap(device.makeCommandQueue()).makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(positionBuffer, offset: 0, index: 0)
        encoder.setBuffer(heightBuffer, offset: 0, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: creatures.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, commandBuffer.error?.localizedDescription ?? "")

        let heights = heightBuffer.contents().bindMemory(to: Float.self, capacity: creatures.count)
        for (index, creature) in creatures.enumerated() {
            let lowerExtent = creature.positionScale.y
                - creature.parameters.x * 0.5
                - creature.positionScale.w * 0.32
            XCTAssertEqual(heights[index], expectedTerrainHeights[index], accuracy: 0.0001)
            XCTAssertEqual(lowerExtent, heights[index], accuracy: 1, "creature \(index) terrain \(heights[index])")
        }
    }

    func testHeroProductionTraversalShowsEveryCreatureAtBothAnimationTimes() throws {
        let report = try runHeroVisibilityProbe()

        for timeIndex in 0..<2 {
            for creatureIndex in 0..<6 {
                let stableID = creatureIndex + 2
                let index = timeIndex * 6 + creatureIndex
                let diagnostic = "stable ID \(stableID), time \(timeIndex): isolated \(report.isolated[index]), binned without terrain \(report.binnedWithoutTerrain[index]), full \(report.full[index]), terrain replacements \(report.terrainReplacements[index]), SDF replacements \(report.sdfReplacements[index])"
                XCTAssertGreaterThan(report.isolated[index], 0, diagnostic)
                XCTAssertGreaterThan(report.binnedWithoutTerrain[index], 0, diagnostic)
                XCTAssertGreaterThan(report.full[index], 0, diagnostic)
            }
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

    private struct HeroVisibilityReport {
        let full: [UInt32]
        let binnedWithoutTerrain: [UInt32]
        let isolated: [UInt32]
        let terrainReplacements: [UInt32]
        let sdfReplacements: [UInt32]
        let binnedReplacements: [UInt32]
        let binnedMisses: [UInt32]
    }

    private func runHeroVisibilityProbe() throws -> HeroVisibilityReport {
        let source = """
        kernel void probeHeroVisibility(
            texture3d<uint, access::read> terrain [[texture(0)]],
            texture3d<uint, access::read> mixed [[texture(1)]],
            texture3d<uint, access::read> emptyVoxels [[texture(2)]],
            device atomic_uint *output [[buffer(0)]],
            constant SceneUniforms &scene [[buffer(1)]],
            device const CellHeader *headers [[buffer(2)]],
            device const uint *sdfRefs [[buffer(3)]],
            device const uint *gaussianRefs [[buffer(4)]],
            device const SDFInstance *sdfs [[buffer(5)]],
            device const Gaussian *gaussians [[buffer(6)]],
            constant FrameUniforms *frames [[buffer(7)]],
            uint3 gid [[thread_position_in_grid]]) {
            FrameUniforms frame = frames[gid.z];
            if (any(gid.xy >= frame.viewportAndOptions.xy) || gid.z >= 2u) return;
            float2 pixel = float2(gid.xy) + 0.5f;
            float horizontal = (2.0f * pixel.x / float(frame.viewportAndOptions.x) - 1.0f)
                * frame.cameraForwardAndFOV.w * frame.cameraRightAndAspect.w;
            float vertical = (1.0f - 2.0f * pixel.y / float(frame.viewportAndOptions.y))
                * frame.cameraForwardAndFOV.w;
            float3 direction = normalize(frame.cameraForwardAndFOV.xyz
                + frame.cameraRightAndAspect.xyz * horizontal
                + frame.cameraUpAndMaxDistance.xyz * vertical);
            float3 origin = frame.cameraPositionAndTime.xyz;
            HybridHit fullHit;
            TraceCounts fullCounts = {};
            bool fullFound = traceMixedScene(
                terrain, mixed, headers, sdfRefs, gaussianRefs, sdfs, gaussians, scene,
                origin, direction, frame.cameraUpAndMaxDistance.w,
                frame.cameraPositionAndTime.w, 3u, fullHit, fullCounts
            );
            if (fullFound && fullHit.primitiveKind == 1u
                && fullHit.stableID >= 2u && fullHit.stableID < 8u) {
                atomic_fetch_add_explicit(
                    &output[gid.z * 6u + fullHit.stableID - 2u], 1u, memory_order_relaxed
                );
            }
            HybridHit binnedHit;
            TraceCounts binnedCounts = {};
            bool binnedFound = traceMixedScene(
                emptyVoxels, mixed, headers, sdfRefs, gaussianRefs, sdfs, gaussians, scene,
                origin, direction, frame.cameraUpAndMaxDistance.w,
                frame.cameraPositionAndTime.w, 3u, binnedHit, binnedCounts
            );
            if (binnedFound && binnedHit.primitiveKind == 1u
                && binnedHit.stableID >= 2u && binnedHit.stableID < 8u) {
                atomic_fetch_add_explicit(
                    &output[12u + gid.z * 6u + binnedHit.stableID - 2u], 1u, memory_order_relaxed
                );
            }
            for (uint instanceIndex = 0u; instanceIndex < scene.counts.x; ++instanceIndex) {
                SDFInstance sourceInstance = sdfs[instanceIndex];
                if (sourceInstance.metadata.x != 1u) continue;
                SDFInstance instance = animateSDFInstance(
                    sourceInstance, frame.cameraPositionAndTime.w
                );
                HybridHit isolatedHit;
                TraceCounts isolatedCounts = {};
                bool isolatedFound = traceSDFInstance(
                    origin, direction, 0.0f, frame.cameraUpAndMaxDistance.w,
                    instance, scene, isolatedHit, isolatedCounts
                );
                if (!isolatedFound) continue;
                uint creatureIndex = sourceInstance.metadata.w - 2u;
                uint outputIndex = gid.z * 6u + creatureIndex;
                atomic_fetch_add_explicit(&output[24u + outputIndex], 1u, memory_order_relaxed);
                if (!binnedFound) {
                    atomic_fetch_add_explicit(
                        &output[72u + outputIndex], 1u, memory_order_relaxed
                    );
                } else if (binnedHit.stableID != sourceInstance.metadata.w
                           || binnedHit.primitiveKind != 1u) {
                    atomic_fetch_add_explicit(
                        &output[60u + outputIndex], 1u, memory_order_relaxed
                    );
                }
                if (!fullFound || fullHit.stableID != sourceInstance.metadata.w
                    || fullHit.primitiveKind != 1u) {
                    if (fullFound && fullHit.primitiveKind == 0u) {
                        atomic_fetch_add_explicit(
                            &output[36u + outputIndex], 1u, memory_order_relaxed
                        );
                    } else if (fullFound) {
                        atomic_fetch_add_explicit(
                            &output[48u + outputIndex], 1u, memory_order_relaxed
                        );
                    }
                }
            }
        }
        """
        let (device, library) = try MetalProbeHarness.makeLibrary(extraSource: source)
        let terrainPipeline = try MetalProbeHarness.makePipeline(name: "generateTerrain", library: library, device: device)
        let reducePipeline = try MetalProbeHarness.makePipeline(name: "reduceOccupancy", library: library, device: device)
        let mixedPipeline = try MetalProbeHarness.makePipeline(name: "buildMixedOccupancy", library: library, device: device)
        let reduceMixedPipeline = try MetalProbeHarness.makePipeline(name: "reduceMixedOccupancy", library: library, device: device)
        let probePipeline = try MetalProbeHarness.makePipeline(name: "probeHeroVisibility", library: library, device: device)
        let sceneData = try SceneData.makeHero()
        let terrain = try makeVoxelTexture(device: device)
        let emptyVoxels = try makeVoxelTexture(device: device)
        let mixed = try makeMixedTexture(device: device)
        let output = try XCTUnwrap(device.makeBuffer(
            length: 84 * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ))
        _ = output.contents().initializeMemory(as: UInt32.self, repeating: 0, count: 84)
        let headers = try makeBuffer(device: device, values: sceneData.cellHeaders)
        let sdfRefs = try makeBuffer(device: device, values: sceneData.cellSDFRefs)
        let gaussianRefs = try makeBuffer(device: device, values: sceneData.cellGaussianRefs)
        let sdfs = try makeBuffer(device: device, values: sceneData.sdfInstances)
        let gaussians = try makeBuffer(device: device, values: sceneData.gaussians)
        let width = 1_280
        let height = 800
        let yaw: Float = 0.6
        let pitch: Float = -0.18
        let cosPitch = cos(pitch)
        let sinPitch = sin(pitch)
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)
        let forward = SIMD3<Float>(cosPitch * sinYaw, sinPitch, cosPitch * cosYaw)
        let right = SIMD3<Float>(cosYaw, 0, -sinYaw)
        let up = SIMD3<Float>(-sinPitch * sinYaw, cosPitch, -sinPitch * cosYaw)
        let frames = [Float(0), 1].map { time in
            FrameUniforms(
                cameraPositionAndTime: SIMD4<Float>(Renderer.initialCameraPosition, time),
                cameraForwardAndFOV: SIMD4<Float>(forward, tan(35 * .pi / 180)),
                cameraRightAndAspect: SIMD4<Float>(right, Float(width) / Float(height)),
                cameraUpAndMaxDistance: SIMD4<Float>(up, 256),
                sunDirectionAndAmbient: .zero,
                viewportAndOptions: SIMD4<UInt32>(UInt32(width), UInt32(height), 0, 0),
                fogAndExposure: .zero
            )
        }
        let frameBuffer = try makeBuffer(device: device, values: frames)
        var scene = SceneUniforms(
            counts: SIMD4<UInt32>(
                UInt32(sceneData.sdfInstances.count),
                UInt32(sceneData.gaussians.count),
                UInt32(sceneData.lights.count),
                UInt32(sceneData.materials.count)
            ),
            grid: SIMD4<UInt32>(64, 8, 6, UInt32(sceneData.activeVolumeCells.count)),
            fog: .zero,
            budgets: SIMD4<UInt32>(24, 32, 48, 8)
        )
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        try encodeTerrain(
            texture: terrain,
            fixture: 0,
            terrainPipeline: terrainPipeline,
            reducePipeline: reducePipeline,
            commandBuffer: commandBuffer
        )
        try encodeTerrain(
            texture: emptyVoxels,
            fixture: 1,
            terrainPipeline: terrainPipeline,
            reducePipeline: reducePipeline,
            commandBuffer: commandBuffer
        )
        let mixedEncoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        mixedEncoder.setComputePipelineState(mixedPipeline)
        mixedEncoder.setTexture(terrain, index: 0)
        mixedEncoder.setTexture(mixed, index: 1)
        mixedEncoder.setBuffer(headers, offset: 0, index: 0)
        mixedEncoder.setBuffer(sdfRefs, offset: 0, index: 1)
        mixedEncoder.setBuffer(sdfs, offset: 0, index: 2)
        mixedEncoder.dispatchThreads(
            MTLSize(width: 64, height: 64, depth: 64),
            threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 4)
        )
        mixedEncoder.endEncoding()
        try encodeReductions(
            texture: mixed,
            pipeline: reduceMixedPipeline,
            commandBuffer: commandBuffer
        )
        let probeEncoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        probeEncoder.setComputePipelineState(probePipeline)
        probeEncoder.setTexture(terrain, index: 0)
        probeEncoder.setTexture(mixed, index: 1)
        probeEncoder.setTexture(emptyVoxels, index: 2)
        probeEncoder.setBuffer(output, offset: 0, index: 0)
        probeEncoder.setBytes(&scene, length: MemoryLayout<SceneUniforms>.stride, index: 1)
        probeEncoder.setBuffer(headers, offset: 0, index: 2)
        probeEncoder.setBuffer(sdfRefs, offset: 0, index: 3)
        probeEncoder.setBuffer(gaussianRefs, offset: 0, index: 4)
        probeEncoder.setBuffer(sdfs, offset: 0, index: 5)
        probeEncoder.setBuffer(gaussians, offset: 0, index: 6)
        probeEncoder.setBuffer(frameBuffer, offset: 0, index: 7)
        probeEncoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 2),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )
        probeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, commandBuffer.error?.localizedDescription ?? "")

        let pointer = output.contents().bindMemory(to: UInt32.self, capacity: 84)
        let values = Array(UnsafeBufferPointer(start: pointer, count: 84))
        return HeroVisibilityReport(
            full: Array(values[0..<12]),
            binnedWithoutTerrain: Array(values[12..<24]),
            isolated: Array(values[24..<36]),
            terrainReplacements: Array(values[36..<48]),
            sdfReplacements: Array(values[48..<60]),
            binnedReplacements: Array(values[60..<72]),
            binnedMisses: Array(values[72..<84])
        )
    }

    private func encodeTerrain(
        texture: MTLTexture,
        fixture: UInt32,
        terrainPipeline: MTLComputePipelineState,
        reducePipeline: MTLComputePipelineState,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(terrainPipeline)
        encoder.setTexture(texture, index: 0)
        var fixture = fixture
        encoder.setBytes(&fixture, length: MemoryLayout<UInt32>.stride, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: 512, height: 512, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )
        encoder.endEncoding()
        try encodeReductions(texture: texture, pipeline: reducePipeline, commandBuffer: commandBuffer)
    }

    private func encodeReductions(
        texture: MTLTexture,
        pipeline: MTLComputePipelineState,
        commandBuffer: MTLCommandBuffer
    ) throws {
        for level in 1..<texture.mipmapLevelCount {
            let source = try XCTUnwrap(texture.makeTextureView(
                pixelFormat: .r8Uint,
                textureType: .type3D,
                levels: (level - 1)..<level,
                slices: 0..<1
            ))
            let destination = try XCTUnwrap(texture.makeTextureView(
                pixelFormat: .r8Uint,
                textureType: .type3D,
                levels: level..<(level + 1),
                slices: 0..<1
            ))
            let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
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
