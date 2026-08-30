import Metal
import XCTest
@testable import MicroCubeMetal

final class VolumeProbeTests: XCTestCase {
    func testVolumeAndMotionEnvelopesUseRequiredMetricKeysFromGPUResults() throws {
        let math = try runMathProbe()
        let clear = try runVolumeLighting(blocked: false)
        let blocked = try runVolumeLighting(blocked: true)
        let first = try runMotionProbe(time: 0)
        let repeated = try runMotionProbe(time: 0)
        let later = try runMotionProbe(time: 1)
        let expectedHomogeneous = exp(-2.0)
        let expectedGaussian = 1.253313
        let sunRatio = Double(blocked.x / clear.x)
        let localRatio = Double(blocked.w / clear.w)
        let volumeMetrics = VolumeProbeMetrics(
            maxHomogeneousRelativeError: abs(Double(math[0]) - expectedHomogeneous) / expectedHomogeneous,
            maxGaussianRelativeError: abs(Double(math[1]) - expectedGaussian) / expectedGaussian,
            maxSurfaceTransmittanceRelativeError: abs(Double(math[2]) - exp(-expectedGaussian)) / exp(-expectedGaussian),
            sunShadowRadianceRatio: sunRatio,
            localShadowRadianceRatio: localRatio,
            smokeSunReceiverRatio: sunRatio,
            smokeLocalReceiverRatio: localRatio,
            nonFiniteCount: Int(math[3])
        )
        let motionMetrics = MotionProbeMetrics(
            creatureCount: 6,
            lightCount: 6,
            repeatMismatchCount: first == repeated ? 0 : 1,
            poseDeltaAtOneSecond: zip(first[0..<4], later[0..<4]).map { abs($0 - $1) }.reduce(0, +),
            lightDeltaAtOneSecond: zip(first[4..<8], later[4..<8]).map { abs($0 - $1) }.reduce(0, +)
        )
        let volumeData = try ProbeEnvelope.evaluated(
            probe: "volume", device: "test-device", metrics: volumeMetrics
        ).encodedJSON()
        let motionData = try ProbeEnvelope.evaluated(
            probe: "motion", device: "test-device", metrics: motionMetrics
        ).encodedJSON()
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
            uint gid [[thread_position_in_grid]]) {
            if (gid != 0u) return;
            SDFInstance creature;
            creature.sweptBoundsMin = float4(270.0f, 84.0f, 288.0f, 0.0f);
            creature.sweptBoundsMax = float4(282.0f, 112.0f, 300.0f, 0.0f);
            creature.positionScale = float4(276.0f, 96.0f, 294.0f, 3.0f);
            creature.rotationQuaternion = float4(0.0f, 0.0f, 0.0f, 1.0f);
            creature.parameters = float4(12.0f, 0.0f, 0.0f, 0.0f);
            creature.metadata = uint4(1u, 3u, 1u, 2u);
            Light light;
            light.positionRadius = float4(276.0f, 103.0f, 294.0f, 18.0f);
            light.colorIntensity = float4(1.0f, 0.3f, 0.1f, 9.0f);
            SDFInstance moved = animateSDFInstance(creature, time);
            Light animated = animateLight(light, 2u, time);
            output[0] = moved.positionScale.x;
            output[1] = moved.positionScale.y;
            output[2] = moved.positionScale.z;
            output[3] = moved.rotationQuaternion.w;
            output[4] = animated.positionRadius.x;
            output[5] = animated.positionRadius.y;
            output[6] = animated.positionRadius.z;
            output[7] = animated.colorIntensity.w;
        }
        """
        let (device, library) = try MetalProbeHarness.makeLibrary(extraSource: source)
        let pipeline = try MetalProbeHarness.makePipeline(name: "probeMotion", library: library, device: device)
        let output = try XCTUnwrap(device.makeBuffer(length: 8 * MemoryLayout<Float>.stride, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        var probeTime = time
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBytes(&probeTime, length: MemoryLayout<Float>.stride, index: 1)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, commandBuffer.error?.localizedDescription ?? "")
        let pointer = output.contents().bindMemory(to: Float.self, capacity: 8)
        return Array(UnsafeBufferPointer(start: pointer, count: 8))
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

    private func runVolumeLighting(blocked: Bool) throws -> SIMD4<Float> {
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
        let lights = try XCTUnwrap(device.makeBuffer(length: MemoryLayout<Light>.stride))
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
            viewportAndOptions: .zero,
            fogAndExposure: .zero
        )
        var scene = SceneUniforms(
            counts: .zero,
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
