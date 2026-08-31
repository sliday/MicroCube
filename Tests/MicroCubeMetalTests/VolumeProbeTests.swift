import Metal
import XCTest
@testable import MicroCubeMetal

final class VolumeProbeTests: XCTestCase {
    func testVolumeAndMotionEnvelopesUseRequiredMetricKeysFromGPUResults() throws {
        let math = try runMathProbe()
        let clear = try runVolumeLighting(blocked: false)
        let blocked = try runVolumeLighting(blocked: true)
        let smoke = try runSurfaceSmokeProbe()
        let first = try runMotionProbe(time: 0)
        let repeated = try runMotionProbe(time: 0)
        let later = try runMotionProbe(time: 1)
        let expectedHomogeneous = exp(-2.0)
        let expectedGaussian = 1.253313
        let sunRatio = Double(blocked.x / clear.x)
        let localRatio = Double(blocked.w / clear.w)
        let smokeSunRatio = Double(smoke[1] / smoke[0])
        let smokeLocalRatio = Double(smoke[3] / smoke[2])
        let expectedLocalTransmittance = exp(-0.65 * 0.75 * sqrt(2 * .pi))
        let volumeMetrics = VolumeProbeMetrics(
            maxHomogeneousRelativeError: abs(Double(math[0]) - expectedHomogeneous) / expectedHomogeneous,
            maxGaussianRelativeError: abs(Double(math[1]) - expectedGaussian) / expectedGaussian,
            maxSurfaceTransmittanceRelativeError: max(
                abs(smokeSunRatio - exp(-expectedGaussian)) / exp(-expectedGaussian),
                abs(smokeLocalRatio - expectedLocalTransmittance) / expectedLocalTransmittance
            ),
            sunShadowRadianceRatio: sunRatio,
            localShadowRadianceRatio: localRatio,
            smokeSunReceiverRatio: smokeSunRatio,
            smokeLocalReceiverRatio: smokeLocalRatio,
            nonFiniteCount: Int(math[3]) + smoke.filter { !$0.isFinite }.count
        )
        let motionMetrics = MotionProbeMetrics(
            creatureCount: Int(first[8]),
            lightCount: Int(first[9]),
            repeatMismatchCount: first == repeated ? 0 : 1,
            poseDeltaAtOneSecond: zip(first[0..<4], later[0..<4]).map { abs($0 - $1) }.reduce(0, +),
            lightDeltaAtOneSecond: zip(first[4..<8], later[4..<8]).map { abs($0 - $1) }.reduce(0, +)
        )
        let volumeData = try ProbeEnvelope.evaluated(
            probe: "volume", device: try XCTUnwrap(MTLCreateSystemDefaultDevice()).name, metrics: volumeMetrics
        ).encodedJSON()
        let motionData = try ProbeEnvelope.evaluated(
            probe: "motion", device: try XCTUnwrap(MTLCreateSystemDefaultDevice()).name, metrics: motionMetrics
        ).encodedJSON()
        try MetalProbeHarness.writeEvidence(volumeData, named: "volume")
        try MetalProbeHarness.writeEvidence(motionData, named: "motion")
        let volumeObject = try XCTUnwrap(JSONSerialization.jsonObject(with: volumeData) as? [String: Any])
        let encodedMetrics = try XCTUnwrap(volumeObject["metrics"] as? [String: Any])

        XCTAssertEqual(
            Set(encodedMetrics.keys),
            ["maxHomogeneousRelativeError", "maxGaussianRelativeError",
             "maxSurfaceTransmittanceRelativeError", "sunShadowRadianceRatio",
             "localShadowRadianceRatio", "smokeSunReceiverRatio", "smokeLocalReceiverRatio",
             "nonFiniteCount"]
        )
        XCTAssertLessThan(try ProbeEnvelope<VolumeProbeMetrics>.decodeValidated(volumeData).metrics.sunShadowRadianceRatio, 0.35)
        XCTAssertEqual(try ProbeEnvelope<MotionProbeMetrics>.decodeValidated(motionData).metrics.repeatMismatchCount, 0)
        XCTAssertNotEqual(volumeMetrics.sunShadowRadianceRatio, volumeMetrics.smokeSunReceiverRatio)
        XCTAssertNotEqual(volumeMetrics.localShadowRadianceRatio, volumeMetrics.smokeLocalReceiverRatio)
    }

    func testGaussianOpticalDepthMatchesAnalyticReference() throws {
        let values = try runMathProbe()

        XCTAssertEqual(values[0], exp(-2), accuracy: 0.0001)
        XCTAssertEqual(values[1], 1.253313, accuracy: 0.02 * 1.253313)
        XCTAssertEqual(values[2], exp(-1.253313), accuracy: 0.02)
        XCTAssertEqual(values[3], 0)
    }

    func testCreatureAndLightMotionIsRepeatableAndChangesAtOneSecond() throws {
        let first = try runMotionProbe(time: 0)
        let repeated = try runMotionProbe(time: 0)
        let later = try runMotionProbe(time: 1)

        XCTAssertEqual(first.count, 10)
        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(Array(first[0..<4]), Array(later[0..<4]))
        XCTAssertNotEqual(Array(first[4..<8]), Array(later[4..<8]))
    }

    func testVolumeLightingRespondsToExactSunBlocker() throws {
        let clear = try runVolumeLighting(blocked: false)
        let blocked = try runVolumeLighting(blocked: true)

        XCTAssertLessThan(blocked.x / clear.x, 0.35)
        XCTAssertLessThan(blocked.w / clear.w, 0.35)
    }

    func testVolumeLightingUsesCalibratedLocalLightContribution() throws {
        let baseline = try runVolumeLighting(blocked: false, localLightIntensity: 0)
        let illuminated = try runVolumeLighting(blocked: false, localLightIntensity: 1)
        let expectedContribution: Float = 0.22 * 0.725 * 0.999 * 0.999

        XCTAssertEqual(illuminated.x - baseline.x, expectedContribution, accuracy: 0.002)
        XCTAssertEqual(illuminated.y, baseline.y, accuracy: 0.002)
        XCTAssertEqual(illuminated.z, baseline.z, accuracy: 0.002)
    }

    private func runMathProbe() throws -> [Float] {
        let source = """
        kernel void probeVolumeMath(device float *output [[buffer(0)]], uint gid [[thread_position_in_grid]]) {
            if (gid != 0u) return;
            Gaussian gaussian;
            gaussian.localCenterSigma = float4(0.0f, 0.0f, 0.0f, 1.0f);
            gaussian.colorDensity = float4(0.6f, 0.7f, 0.8f, 0.5f);
            gaussian.motionPhase = float4(0.0f);
            float depth = gaussianOpticalDepth(
                float3(-5.0f, 0.0f, 0.0f), float3(1.0f, 0.0f, 0.0f), 0.0f, 10.0f, gaussian
            );
            output[0] = homogeneousTransmittance(0.5f, 4.0f);
            output[1] = depth;
            output[2] = exp(-depth);
            output[3] = (!isfinite(depth) || depth < 0.0f) ? 1.0f : 0.0f;
        }
        """
        return try runSingleThreadProbe(name: "probeVolumeMath", source: source, count: 4)
    }

    private func runMotionProbe(time: Float) throws -> [Float] {
        let source = """
        kernel void probeMotion(
            device float *output [[buffer(0)]],
            constant float &time [[buffer(1)]],
            device const SDFInstance *sdfs [[buffer(2)]],
            device const Light *lights [[buffer(3)]],
            constant SceneUniforms &scene [[buffer(4)]],
            uint gid [[thread_position_in_grid]]) {
            if (gid != 0u) return;
            uint creatureCount = 0u;
            uint firstCreature = 0u;
            for (uint index = 0u; index < scene.counts.x; ++index) {
                if (sdfs[index].metadata.x == 1u) {
                    if (creatureCount == 0u) firstCreature = index;
                    ++creatureCount;
                }
            }
            SDFInstance creature = sdfs[firstCreature];
            Light light = lights[0];
            SDFInstance moved = animateSDFInstance(creature, time);
            Light animated = animateLight(light, 0u, time);
            // Creature position is CPU-animated (CreatureAnimation); the
            // shader-side pose that still varies with time is the limb gait
            // phase, so slot 3 pins that instead of the (static) quaternion.
            output[0] = moved.positionScale.x;
            output[1] = moved.positionScale.y;
            output[2] = moved.positionScale.z;
            output[3] = moved.parameters.z;
            output[4] = animated.positionRadius.x;
            output[5] = animated.positionRadius.y;
            output[6] = animated.positionRadius.z;
            output[7] = animated.colorIntensity.w;
            output[8] = float(creatureCount);
            output[9] = float(scene.counts.z);
        }
        """
        let (device, library) = try MetalProbeHarness.makeLibrary(extraSource: source)
        let pipeline = try MetalProbeHarness.makePipeline(name: "probeMotion", library: library, device: device)
        let hero = try SceneData.makeHero()
        let sdfs = try XCTUnwrap(hero.sdfInstances.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        })
        let lights = try XCTUnwrap(hero.lights.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        })
        let output = try XCTUnwrap(device.makeBuffer(length: 10 * MemoryLayout<Float>.stride, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        var probeTime = time
        var scene = SceneUniforms(
            counts: SIMD4<UInt32>(UInt32(hero.sdfInstances.count), UInt32(hero.gaussians.count), UInt32(hero.lights.count), UInt32(hero.materials.count)),
            grid: SIMD4<UInt32>(64, 8, 6, UInt32(hero.activeVolumeCells.count)),
            fog: .zero,
            budgets: SIMD4<UInt32>(24, 32, 48, 8)
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBytes(&probeTime, length: MemoryLayout<Float>.stride, index: 1)
        encoder.setBuffer(sdfs, offset: 0, index: 2)
        encoder.setBuffer(lights, offset: 0, index: 3)
        encoder.setBytes(&scene, length: MemoryLayout<SceneUniforms>.stride, index: 4)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, commandBuffer.error?.localizedDescription ?? "")
        let pointer = output.contents().bindMemory(to: Float.self, capacity: 10)
        return Array(UnsafeBufferPointer(start: pointer, count: 10))
    }

    private func runSurfaceSmokeProbe() throws -> [Float] {
        let source = """
        kernel void probeSurfaceSmoke(
            device float *output [[buffer(0)]],
            device const Gaussian *gaussians [[buffer(1)]],
            uint gid [[thread_position_in_grid]]) {
            if (gid != 0u) return;
            output[0] = gaussianSceneTransmittance(
                float3(-5.0f, 0.0f, 0.0f), float3(1.0f, 0.0f, 0.0f),
                0.0f, 10.0f, gaussians, 0u
            );
            output[1] = gaussianSceneTransmittance(
                float3(-5.0f, 0.0f, 0.0f), float3(1.0f, 0.0f, 0.0f),
                0.0f, 10.0f, gaussians, 1u
            );
            output[2] = gaussianSceneTransmittance(
                float3(20.0f, -4.0f, 0.0f), float3(0.0f, 1.0f, 0.0f),
                0.0f, 8.0f, gaussians + 1, 0u
            );
            output[3] = gaussianSceneTransmittance(
                float3(20.0f, -4.0f, 0.0f), float3(0.0f, 1.0f, 0.0f),
                0.0f, 8.0f, gaussians + 1, 1u
            );
        }
        """
        let gaussians = [
            Gaussian(
                localCenterSigma: SIMD4<Float>(0, 0, 0, 1),
                colorDensity: SIMD4<Float>(0.6, 0.7, 0.8, 0.5),
                motionPhase: .zero
            ),
            Gaussian(
                localCenterSigma: SIMD4<Float>(20, 0, 0, 0.75),
                colorDensity: SIMD4<Float>(0.8, 0.6, 0.4, 0.65),
                motionPhase: .zero
            ),
        ]
        let (device, library) = try MetalProbeHarness.makeLibrary(extraSource: source)
        let pipeline = try MetalProbeHarness.makePipeline(name: "probeSurfaceSmoke", library: library, device: device)
        let gaussianBuffer = try XCTUnwrap(gaussians.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        })
        let output = try XCTUnwrap(device.makeBuffer(length: 4 * MemoryLayout<Float>.stride, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBuffer(gaussianBuffer, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, commandBuffer.error?.localizedDescription ?? "")
        let pointer = output.contents().bindMemory(to: Float.self, capacity: 4)
        return Array(UnsafeBufferPointer(start: pointer, count: 4))
    }

    private func runSingleThreadProbe(name: String, source: String, count: Int) throws -> [Float] {
        let (device, library) = try MetalProbeHarness.makeLibrary(extraSource: source)
        let pipeline = try MetalProbeHarness.makePipeline(name: name, library: library, device: device)
        let output = try XCTUnwrap(device.makeBuffer(length: count * MemoryLayout<Float>.stride, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, commandBuffer.error?.localizedDescription ?? "")
        let pointer = output.contents().bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private func runVolumeLighting(blocked: Bool, localLightIntensity: Float? = nil) throws -> SIMD4<Float> {
        let (device, library) = try MetalProbeHarness.makeLibrary()
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
        if blocked {
            var occupied: UInt8 = 1
            voxels.replace(
                region: MTLRegionMake3D(96, 84, 84, 1, 1, 1),
                mipmapLevel: 0,
                slice: 0,
                withBytes: &occupied,
                bytesPerRow: 1,
                bytesPerImage: 1
            )
        }
        let lightingDescriptor = MTLTextureDescriptor()
        lightingDescriptor.textureType = .type3D
        lightingDescriptor.pixelFormat = .rgba16Float
        lightingDescriptor.width = 64
        lightingDescriptor.height = 64
        lightingDescriptor.depth = 64
        lightingDescriptor.storageMode = .shared
        lightingDescriptor.usage = [.shaderRead, .shaderWrite]
        let lighting = try XCTUnwrap(device.makeTexture(descriptor: lightingDescriptor))
        var activeCell = SceneData.linearIndex(x: 10, y: 10, z: 10)
        let activeCells = try XCTUnwrap(device.makeBuffer(bytes: &activeCell, length: MemoryLayout<UInt32>.stride))
        let gaussians = try XCTUnwrap(device.makeBuffer(length: MemoryLayout<Gaussian>.stride))
        var light = Light(
            positionRadius: SIMD4<Float>(84, 84, 82.5, 10),
            colorIntensity: SIMD4<Float>(1, 0, 0, localLightIntensity ?? 0)
        )
        let lights = try XCTUnwrap(device.makeBuffer(bytes: &light, length: MemoryLayout<Light>.stride))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
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
            sunDirectionAndAmbient: SIMD4<Float>(1, 0, 0, 0),
            viewportAndOptions: SIMD4<UInt32>(
                0,
                0,
                0,
                localLightIntensity == nil
                    ? 0
                    : RenderFeatures.lights.rawValue | RenderFeatures.gaussian.rawValue | (1 << 31)
            ),
            fogAndExposure: .zero
        )
        var scene = SceneUniforms(
            counts: SIMD4<UInt32>(0, 0, localLightIntensity == nil ? 0 : 1, 0),
            grid: SIMD4<UInt32>(64, 8, 6, 1),
            fog: .zero,
            budgets: SIMD4<UInt32>(24, 32, 48, 8)
        )
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(inject)
        encoder.setTexture(voxels, index: 0)
        encoder.setTexture(lighting, index: 2)
        encoder.setBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        encoder.setBytes(&scene, length: MemoryLayout<SceneUniforms>.stride, index: 1)
        encoder.setBuffer(gaussians, offset: 0, index: 6)
        encoder.setBuffer(lights, offset: 0, index: 7)
        encoder.setBuffer(activeCells, offset: 0, index: 9)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, commandBuffer.error?.localizedDescription ?? "")
        var values = [Float16](repeating: 0, count: 4)
        lighting.getBytes(
            &values,
            bytesPerRow: 4 * MemoryLayout<Float16>.stride,
            bytesPerImage: 4 * MemoryLayout<Float16>.stride,
            from: MTLRegionMake3D(10, 10, 10, 1, 1, 1),
            mipmapLevel: 0,
            slice: 0
        )
        return SIMD4<Float>(Float(values[0]), Float(values[1]), Float(values[2]), Float(values[3]))
    }
}
